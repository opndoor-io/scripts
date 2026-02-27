#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# OPN Door — Установка VPN-сервера (VLESS + TLS) через собственный домен
# https://github.com/opndoor-io/vless-tls-server/tree/main/vless-tls-server
#
# Требования: Ubuntu 24, root-доступ, домен с A-записью на IP сервера
# =============================================================================

# ─── Цвета и форматирование ──────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[ОШИБКА]${NC} $*"; exit 1; }

# ─── Проверки перед началом ───────────────────────────────────────────────────

check_root() {
    [[ $EUID -eq 0 ]] || error "Скрипт нужно запускать от root (sudo)"
}

check_os() {
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        error "Скрипт поддерживает только Ubuntu"
    fi
    success "ОС: Ubuntu"
}

check_port_80() {
    if ss -tlnp | grep -q ':80 '; then
        local proc
        proc=$(ss -tlnp | grep ':80 ' | head -1)
        # Если порт 80 занят nginx — это ок, мы его переконфигурируем
        if echo "$proc" | grep -q 'nginx'; then
            warn "Порт 80 занят nginx — будет переконфигурирован"
        else
            error "Порт 80 занят другим процессом:\n$proc\nОсвободите порт и запустите скрипт снова"
        fi
    fi
}

check_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        local needs_warning=false
        if ! ufw status | grep -qE "80[/ ].*ALLOW"; then
            warn "Порт 80 не открыт в UFW (нужен для получения SSL-сертификата)"
            needs_warning=true
        fi
        if ! ufw status | grep -qE "443[/ ].*ALLOW"; then
            warn "Порт 443 не открыт в UFW (нужен для HTTPS)"
            needs_warning=true
        fi
        if [[ "$needs_warning" == true ]]; then
            echo ""
            warn "Рекомендуется выполнить: ufw allow 80/tcp && ufw allow 443/tcp"
            read -rp "$(echo -e "${YELLOW}Продолжить без открытия портов? (y/N):${NC} ")" FW_CONTINUE
            if [[ "$FW_CONTINUE" != "y" && "$FW_CONTINUE" != "Y" ]]; then
                error "Откройте порты и запустите скрипт снова"
            fi
        fi
    fi
}

# ─── Ввод данных ──────────────────────────────────────────────────────────────

ask_domain() {
    echo ""
    read -rp "$(echo -e "${BOLD}Введите ваш домен${NC} (например, example.com): ")" DOMAIN
    [[ -n "$DOMAIN" ]] || error "Домен не может быть пустым"

    # Убираем протокол и слеш если вставили URL
    DOMAIN=$(echo "$DOMAIN" | sed 's|https\?://||;s|/.*||')

    info "Проверяю DNS для $DOMAIN..."

    local server_ip domain_ip
    server_ip=$(curl -s4 --max-time 10 ifconfig.me 2>/dev/null || curl -s4 --max-time 10 icanhazip.com 2>/dev/null || true)
    [[ -n "$server_ip" ]] || error "Не удалось определить IP сервера. Проверьте подключение к интернету"

    # dig +short может вернуть CNAME → берём только строку похожую на IP
    domain_ip=$(dig +short "$DOMAIN" A | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)

    if [[ -z "$domain_ip" ]]; then
        error "Домен $DOMAIN не резолвится. Убедитесь что A-запись указывает на IP этого сервера ($server_ip)"
    fi

    if [[ "$server_ip" != "$domain_ip" ]]; then
        error "Домен $DOMAIN указывает на $domain_ip, а IP сервера — $server_ip\nИсправьте A-запись и подождите обновления DNS"
    fi

    success "Домен $DOMAIN → $server_ip — всё верно"

    # Предупреждение о DNS-кэшировании
    local google_ip
    google_ip=$(dig +short "$DOMAIN" A @8.8.8.8 | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
    if [[ -n "$google_ip" && "$google_ip" != "$server_ip" ]]; then
        warn "Google DNS (8.8.8.8) ещё возвращает старый IP ($google_ip)."
        warn "Let's Encrypt может не выдать сертификат — подождите обновления DNS и запустите скрипт снова."
    fi
}

ask_email() {
    local default_email="admin@${DOMAIN}"
    echo ""
    read -rp "$(echo -e "${BOLD}Введите email${NC} для Let's Encrypt [${default_email}]: ")" EMAIL
    EMAIL="${EMAIL:-$default_email}"
    success "Email: $EMAIL"
}

confirm_settings() {
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Домен:${NC}  $DOMAIN"
    echo -e "  ${BOLD}Email:${NC}  $EMAIL"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
    echo ""
    read -rp "$(echo -e "${BOLD}Всё верно? Начинаем установку? (Y/n):${NC} ")" CONFIRM
    if [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
        error "Установка отменена. Запустите скрипт снова и введите правильные данные"
    fi
}

# ─── Установка пакетов ────────────────────────────────────────────────────────

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    info "Обновляю список пакетов..."
    apt update -y

    info "Устанавливаю необходимые пакеты..."
    apt install -y nginx certbot ca-certificates curl dnsutils
    success "Пакеты установлены"
}

# ─── Настройка nginx ──────────────────────────────────────────────────────────

configure_nginx() {
    local default_conf="/etc/nginx/sites-available/default"
    local default_enabled="/etc/nginx/sites-enabled/default"

    # Проверяем, не чей-то ли это рабочий сайт
    if [[ -f "$default_conf" ]]; then
        if grep -q "default_server" "$default_conf" && ! grep -q "vless-tls-server" "$default_conf"; then
            # Проверяем — стандартная ли это заглушка (ищем типичные признаки)
            if grep -q "Welcome to nginx" "$default_conf" || grep -q "listen 80 default_server" "$default_conf"; then
                info "Обнаружен стандартный конфиг nginx — будет заменён"
            else
                echo ""
                warn "В /etc/nginx/sites-available/default обнаружен нестандартный конфиг."
                warn "Возможно, здесь настроен другой сайт."
                echo ""
                read -rp "$(echo -e "${YELLOW}Заменить конфиг? (y/N):${NC} ")" CONFIRM
                if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
                    error "Установка отменена. Настройте nginx вручную и запустите скрипт снова"
                fi
            fi
        fi
    fi

    info "Настраиваю nginx для $DOMAIN..."

    # Создаём директории
    mkdir -p "/var/www/vless-${DOMAIN}"
    mkdir -p "/var/www/letsencrypt/.well-known/acme-challenge"

    # Заглушка index.html
    cat > "/var/www/vless-${DOMAIN}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: system-ui, sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #f5f5f5; color: #333; }
        .container { text-align: center; }
        h1 { font-weight: 300; font-size: 2rem; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome</h1>
        <p>The site is under construction.</p>
    </div>
</body>
</html>
HTMLEOF

    chown -R www-data:www-data "/var/www/vless-${DOMAIN}"
    chown -R www-data:www-data "/var/www/letsencrypt"

    # Конфиг nginx
    # Помечаем наш конфиг маркером для идентификации
    cat > "$default_conf" <<NGINXEOF
# vless-tls-server | opndoor-io | $DOMAIN
server {
    listen 80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:8080;
    server_name ${DOMAIN};
    root /var/www/vless-${DOMAIN}/;
    index index.html;
    add_header Strict-Transport-Security "max-age=63072000" always;
}
NGINXEOF

    # Убедимся что симлинк есть
    [[ -L "$default_enabled" ]] || ln -sf "$default_conf" "$default_enabled"

    # Проверяем конфиг и перезагружаем
    nginx -t || error "Ошибка в конфигурации nginx"
    nginx -s reload 2>/dev/null || systemctl restart nginx

    success "Nginx настроен для $DOMAIN"
}

# ─── SSL-сертификат ───────────────────────────────────────────────────────────

obtain_certificate() {
    info "Получаю SSL-сертификат от Let's Encrypt..."

    # Проверяем, может уже есть сертификат для этого домена
    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        success "Сертификат для $DOMAIN уже существует"
        return
    fi

    certbot certonly \
        --webroot \
        -w "/var/www/letsencrypt" \
        -d "$DOMAIN" \
        --agree-tos \
        -m "$EMAIL" \
        --non-interactive

    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        success "SSL-сертификат получен"
    else
        error "Не удалось получить сертификат. Проверьте что домен доступен по порту 80"
    fi

    # Deploy-hook: перезапуск 3x-ui после обновления сертификата
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook_file="${hook_dir}/99-restart-3xui.sh"
    mkdir -p "$hook_dir"

    cat > "$hook_file" <<'HOOKEOF'
#!/usr/bin/env bash
set -euo pipefail

echo "[$(date -Is)] deploy-hook: restarting services" >> /var/log/certbot-deploy.log
systemctl restart x-ui.service 2>/dev/null || true
HOOKEOF

    chmod +x "$hook_file"
    success "Deploy-hook для автообновления сертификата создан"

    # Проверяем что автопродление активно
    if systemctl is-active --quiet certbot.timer 2>/dev/null; then
        success "Таймер автопродления certbot активен"
    elif crontab -l 2>/dev/null | grep -q "certbot"; then
        success "Cron-задача автопродления certbot найдена"
    else
        warn "Автопродление certbot не обнаружено — сертификат нужно будет обновлять вручную (certbot renew)"
    fi
}

# ─── Установка 3x-ui ─────────────────────────────────────────────────────────

install_3xui() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Установка панели 3x-ui${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    info "Сейчас запустится установщик 3x-ui."
    info "Следуйте его инструкциям (логин, пароль, порт панели)."
    echo ""
    warn "Когда установщик спросит про SSL-сертификат — выберите вариант 3 (ввести пути)."
    echo ""
    echo -e "  ${BOLD}Путь к сертификату:${NC}  /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    echo -e "  ${BOLD}Путь к ключу:${NC}        /etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    echo ""
    echo -e "${YELLOW}Запишите или скопируйте пути выше — они понадобятся при установке.${NC}"
    echo ""

    # Если 3x-ui уже установлен — спрашиваем
    if systemctl list-unit-files x-ui.service &>/dev/null && systemctl is-enabled x-ui.service &>/dev/null; then
        warn "3x-ui уже установлен."
        read -rp "$(echo -e "${YELLOW}Переустановить? (y/N):${NC} ")" REINSTALL
        if [[ "$REINSTALL" != "y" && "$REINSTALL" != "Y" ]]; then
            info "Пропускаю установку 3x-ui"
            return
        fi
    fi

    read -rp "$(echo -e "${BOLD}Нажмите Enter чтобы начать установку 3x-ui...${NC}")" _

    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
}

# ─── Итог ─────────────────────────────────────────────────────────────────────

print_summary() {
    echo ""

    # Проверяем что 3x-ui реально запущен
    if systemctl is-active --quiet x-ui.service 2>/dev/null; then
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  Установка завершена!${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    else
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  Установка завершена частично — 3x-ui не запущен${NC}"
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
        echo ""
        warn "Панель 3x-ui не обнаружена. Установите вручную:"
        echo -e "  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
    fi

    echo ""
    echo -e "  ${BOLD}Домен:${NC}           $DOMAIN"
    echo -e "  ${BOLD}Сертификат:${NC}      /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    echo -e "  ${BOLD}Ключ:${NC}            /etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    echo ""
    echo -e "  ${BOLD}Что дальше:${NC}"
    echo -e "  Создайте VLESS-подключение в панели 3x-ui по инструкции:"
    echo -e "  ${CYAN}https://opndoor.io${NC}"
    echo ""
}

# ─── Запуск ───────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}OPN Door — Установка VPN-сервера VLESS + TLS${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Автоматическая настройка через собственный домен         ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_root
    check_os
    check_port_80
    check_firewall
    ask_domain
    ask_email
    confirm_settings
    install_packages
    configure_nginx
    obtain_certificate
    install_3xui
    print_summary
}

main "$@"
