#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Диагностика VPN-сервера (VLESS + TLS)
# https://github.com/opndoor-io/vless-tls-server
# =============================================================================

# ─── Цвета и форматирование ──────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
fail() { echo -e "  ${RED}[!!]${NC} $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; WARNINGS=$((WARNINGS + 1)); }

ERRORS=0
WARNINGS=0

# ─── Определение домена ──────────────────────────────────────────────────────

detect_domain() {
    # Пробуем прочитать домен из нашего nginx-конфига
    local detected=""
    if [[ -f /etc/nginx/sites-available/default ]]; then
        detected=$(grep -oP 'vless-tls-server \| opndoor-io \| \K.*' /etc/nginx/sites-available/default 2>/dev/null || true)
    fi

    if [[ -n "$detected" ]]; then
        read -rp "$(echo -e "${BOLD}Домен${NC} [${detected}]: ")" DOMAIN
        DOMAIN="${DOMAIN:-$detected}"
    else
        read -rp "$(echo -e "${BOLD}Введите домен для проверки:${NC} ")" DOMAIN
        [[ -n "$DOMAIN" ]] || { echo -e "${RED}Домен не указан${NC}"; exit 1; }
    fi
}

# ─── Проверки ─────────────────────────────────────────────────────────────────

check_system() {
    echo ""
    echo -e "${BOLD}Система${NC}"

    if grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        local version
        version=$(grep -oP 'VERSION_ID="\K[^"]+' /etc/os-release 2>/dev/null || echo "?")
        ok "Ubuntu $version"
    else
        warn "Не Ubuntu — скрипт установки рассчитан на Ubuntu"
    fi

    local server_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || curl -s4 --max-time 5 icanhazip.com 2>/dev/null || true)
    if [[ -n "$server_ip" ]]; then
        ok "IP сервера: $server_ip"
    else
        fail "Не удалось определить IP сервера"
        server_ip=""
    fi

    SERVER_IP="$server_ip"
}

check_domain() {
    echo ""
    echo -e "${BOLD}Домен: ${DOMAIN}${NC}"

    local domain_ip
    domain_ip=$(dig +short "$DOMAIN" A 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)

    if [[ -z "$domain_ip" ]]; then
        fail "Домен не резолвится"
        return
    fi

    if [[ -n "$SERVER_IP" && "$domain_ip" == "$SERVER_IP" ]]; then
        ok "DNS → $domain_ip (совпадает с IP сервера)"
    elif [[ -n "$SERVER_IP" ]]; then
        fail "DNS → $domain_ip (IP сервера: $SERVER_IP — не совпадает!)"
    else
        warn "DNS → $domain_ip (IP сервера не определён, сравнить не удалось)"
    fi

    # Проверка через Google DNS
    local google_ip
    google_ip=$(dig +short "$DOMAIN" A @8.8.8.8 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
    if [[ -n "$google_ip" && "$google_ip" == "$domain_ip" ]]; then
        ok "Google DNS (8.8.8.8) → $google_ip"
    elif [[ -n "$google_ip" ]]; then
        warn "Google DNS (8.8.8.8) → $google_ip (отличается от основного DNS!)"
    fi
}

check_nginx() {
    echo ""
    echo -e "${BOLD}Nginx${NC}"

    if ! command -v nginx &>/dev/null; then
        fail "Nginx не установлен"
        return
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        ok "Запущен"
    else
        fail "Не запущен (systemctl start nginx)"
    fi

    if nginx -t 2>/dev/null; then
        ok "Конфиг валидный"
    else
        fail "Ошибка в конфигурации (nginx -t)"
    fi

    if ss -tlnp | grep -q ':80 '; then
        ok "Порт 80 слушает"
    else
        fail "Порт 80 не слушает"
    fi

    # Проверяем наш конфиг
    if [[ -f /etc/nginx/sites-available/default ]] && grep -q "vless-tls-server" /etc/nginx/sites-available/default; then
        ok "Конфиг vless-tls-server найден"
    else
        warn "Конфиг vless-tls-server не найден в sites-available/default"
    fi
}

check_ssl() {
    echo ""
    echo -e "${BOLD}SSL-сертификат${NC}"

    local cert_path="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    local key_path="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

    if [[ ! -f "$cert_path" ]]; then
        fail "Сертификат не найден: $cert_path"
        return
    fi

    ok "Сертификат найден"

    # Срок действия
    local expiry_date expiry_epoch now_epoch days_left
    expiry_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
    if [[ -n "$expiry_date" ]]; then
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || true)
        now_epoch=$(date +%s)
        if [[ -n "$expiry_epoch" ]]; then
            days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            if (( days_left < 0 )); then
                fail "Сертификат ИСТЁК $((-days_left)) дней назад!"
            elif (( days_left < 14 )); then
                warn "Истекает: $(date -d "$expiry_date" '+%Y-%m-%d') (через ${days_left} дней — скоро!)"
            else
                ok "Истекает: $(date -d "$expiry_date" '+%Y-%m-%d') (через ${days_left} дней)"
            fi
        fi
    fi

    if [[ ! -f "$key_path" ]]; then
        fail "Приватный ключ не найден: $key_path"
    else
        ok "Приватный ключ найден"
    fi

    # Автопродление
    if systemctl is-active --quiet certbot.timer 2>/dev/null; then
        ok "Автопродление: certbot.timer активен"
    elif crontab -l 2>/dev/null | grep -q "certbot"; then
        ok "Автопродление: cron-задача найдена"
    else
        warn "Автопродление не обнаружено (certbot.timer / cron)"
    fi

    # Deploy-hook
    if [[ -x /etc/letsencrypt/renewal-hooks/deploy/99-restart-3xui.sh ]]; then
        ok "Deploy-hook для 3x-ui установлен"
    else
        warn "Deploy-hook для 3x-ui не найден"
    fi
}

check_3xui() {
    echo ""
    echo -e "${BOLD}3x-ui${NC}"

    if ! systemctl list-unit-files x-ui.service &>/dev/null; then
        fail "3x-ui не установлен"
        return
    fi

    if systemctl is-active --quiet x-ui.service 2>/dev/null; then
        ok "Сервис запущен"
    else
        fail "Сервис не запущен (systemctl start x-ui)"
        return
    fi

    # Порт и URL панели через x-ui settings
    if command -v x-ui &>/dev/null; then
        local xui_output
        xui_output=$(x-ui settings 2>/dev/null)

        local panel_port
        panel_port=$(echo "$xui_output" | grep -oP '^port:\s*\K[0-9]+')
        if [[ -n "$panel_port" ]]; then
            ok "Порт панели: $panel_port"
        else
            warn "Порт панели не удалось определить"
        fi

        local panel_url
        panel_url=$(echo "$xui_output" | grep -oP 'Access URL:\s*\K.*')
        if [[ -n "$panel_url" ]]; then
            ok "URL панели: $panel_url"
        fi
    else
        warn "Команда x-ui не найдена — не удалось определить порт панели"
    fi
}

check_firewall() {
    echo ""
    echo -e "${BOLD}Firewall (UFW)${NC}"

    if ! command -v ufw &>/dev/null; then
        ok "UFW не установлен"
        return
    fi

    local ufw_status
    ufw_status=$(ufw status 2>/dev/null)

    if echo "$ufw_status" | grep -q "Status: inactive"; then
        ok "UFW неактивен"
        return
    fi

    ok "UFW активен"

    if ufw status | grep -qE "80[/ ].*ALLOW"; then
        ok "Порт 80 разрешён"
    else
        fail "Порт 80 не разрешён (ufw allow 80/tcp)"
    fi

    if ufw status | grep -qE "443[/ ].*ALLOW"; then
        ok "Порт 443 разрешён"
    else
        fail "Порт 443 не разрешён (ufw allow 443/tcp)"
    fi
}

# ─── Итог ─────────────────────────────────────────────────────────────────────

print_result() {
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
    if (( ERRORS == 0 && WARNINGS == 0 )); then
        echo -e "  ${GREEN}Всё в порядке!${NC}"
    elif (( ERRORS == 0 )); then
        echo -e "  ${YELLOW}Предупреждений: ${WARNINGS}${NC} — не критично, но стоит проверить"
    else
        echo -e "  ${RED}Ошибок: ${ERRORS}${NC}  ${YELLOW}Предупреждений: ${WARNINGS}${NC}"
    fi
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
    echo ""
}

# ─── Запуск ───────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}VLESS + TLS — Диагностика сервера${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"

    [[ $EUID -eq 0 ]] || { echo -e "${RED}Запустите от root (sudo)${NC}"; exit 1; }

    detect_domain
    check_system
    check_domain
    check_nginx
    check_ssl
    check_3xui
    check_firewall
    print_result
}

main "$@"