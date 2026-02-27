#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# OPN Door — Установка VLESS + Reality (Xray-core)
# https://github.com/opndoor-io/scripts/tree/main/xray-reality
#
# Требования: Ubuntu 24, root-доступ
# Не требует: домен, SSL-сертификат
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

# ─── Константы ───────────────────────────────────────────────────────────────

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_CONFIG_DIR/config.json"
XRAY_KEYS="$XRAY_CONFIG_DIR/.keys"

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

check_existing_install() {
    if [[ -f "$XRAY_CONFIG" ]]; then
        warn "Обнаружена существующая установка Xray"
        echo ""
        echo -e "  Конфиг: ${BOLD}$XRAY_CONFIG${NC}"
        echo ""

        local backup
        backup="$XRAY_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$XRAY_CONFIG" "$backup"
        success "Бэкап текущего конфига: $backup"

        read -rp "$(echo -e "${YELLOW}Продолжить и перезаписать? (y/N):${NC} ")" CONTINUE
        if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
            error "Установка отменена"
        fi
    fi
}

# ─── Ввод данных ──────────────────────────────────────────────────────────────

ask_transport() {
    echo ""
    echo -e "${BOLD}Выберите транспорт:${NC}"
    echo -e "  ${BOLD}1)${NC} TCP   — простой и надёжный (рекомендуется)"
    echo -e "  ${BOLD}2)${NC} XHTTP — мультиплексированный, лучше для нестабильных сетей"
    echo ""
    read -rp "$(echo -e "${BOLD}Транспорт${NC} [1]: ")" TRANSPORT_CHOICE
    TRANSPORT_CHOICE="${TRANSPORT_CHOICE:-1}"

    case "$TRANSPORT_CHOICE" in
        1) TRANSPORT="tcp" ;;
        2) TRANSPORT="xhttp" ;;
        *) error "Неверный выбор. Укажите 1 или 2" ;;
    esac

    success "Транспорт: $TRANSPORT"
}

ask_port() {
    echo ""
    read -rp "$(echo -e "${BOLD}Порт${NC} [443]: ")" PORT
    PORT="${PORT:-443}"

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        error "Некорректный порт: $PORT"
    fi

    if ss -tlnp | grep -q ":${PORT} "; then
        local proc
        proc=$(ss -tlnp | grep ":${PORT} " | head -1)
        if echo "$proc" | grep -q 'xray'; then
            warn "Порт $PORT занят Xray — будет переконфигурирован"
        else
            error "Порт $PORT занят другим процессом:\n$proc\nОсвободите порт или выберите другой"
        fi
    fi

    success "Порт: $PORT"
}

ask_sni() {
    echo ""
    read -rp "$(echo -e "${BOLD}SNI (маскировка под сайт)${NC} [github.com]: ")" SNI
    SNI="${SNI:-github.com}"

    if ! dig +short "$SNI" A 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        warn "Домен $SNI не резолвится — убедитесь что он существует"
        read -rp "$(echo -e "${YELLOW}Продолжить? (y/N):${NC} ")" SNI_CONTINUE
        if [[ "$SNI_CONTINUE" != "y" && "$SNI_CONTINUE" != "Y" ]]; then
            error "Установка отменена"
        fi
    else
        success "SNI: $SNI"
    fi
}

ask_name() {
    echo ""
    read -rp "$(echo -e "${BOLD}Имя первого пользователя${NC} [user1]: ")" USERNAME
    USERNAME="${USERNAME:-user1}"

    if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "Имя может содержать только буквы, цифры, дефис и подчёркивание"
    fi

    success "Пользователь: $USERNAME"
}

confirm_settings() {
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Транспорт:${NC}     $TRANSPORT"
    echo -e "  ${BOLD}Порт:${NC}          $PORT"
    echo -e "  ${BOLD}SNI:${NC}           $SNI"
    echo -e "  ${BOLD}Пользователь:${NC}  $USERNAME"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
    echo ""
    read -rp "$(echo -e "${BOLD}Всё верно? Начинаем установку? (Y/n):${NC} ")" CONFIRM
    if [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
        error "Установка отменена. Запустите скрипт снова"
    fi
}

# ─── Установка пакетов ────────────────────────────────────────────────────────

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    info "Обновляю список пакетов..."
    apt update -y

    info "Устанавливаю необходимые пакеты..."
    apt install -y curl jq openssl qrencode dnsutils
    success "Пакеты установлены"
}

# ─── Оптимизация сети ─────────────────────────────────────────────────────────

enable_bbr() {
    info "Включаю TCP BBR..."

    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        success "TCP BBR уже включён"
        return
    fi

    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        cat >> /etc/sysctl.conf <<'EOF'

# TCP BBR (added by xray-reality installer)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi

    sysctl -p &>/dev/null
    success "TCP BBR включён"
}

# ─── Установка Xray ──────────────────────────────────────────────────────────

install_xray() {
    info "Устанавливаю Xray-core..."

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    if ! command -v xray &>/dev/null; then
        error "Не удалось установить Xray"
    fi

    local version
    version=$(xray version 2>/dev/null | head -1 || echo "unknown")
    success "Xray установлен: $version"
}

# ─── Генерация ключей ─────────────────────────────────────────────────────────

generate_keys() {
    info "Генерирую ключи..."

    local key_output
    key_output=$(xray x25519 2>&1)

    # v26+: "PrivateKey: ..." + "Password: ..." (публичный ключ)
    # старые версии: "Private key: ..." + "Public key: ..."
    PRIVATE_KEY=$(echo "$key_output" | awk '/PrivateKey:|Private key:/ {print $NF}')
    PUBLIC_KEY=$(echo "$key_output" | awk '/Password:|Public key:/ {print $NF}')

    [[ -n "$PRIVATE_KEY" ]] || error "Не удалось получить приватный ключ из xray x25519"
    [[ -n "$PUBLIC_KEY" ]]  || error "Не удалось получить публичный ключ из xray x25519"

    UUID=$(xray uuid 2>&1)
    [[ -n "$UUID" ]] || error "Не удалось сгенерировать UUID"

    SHORT_ID=$(openssl rand -hex 8)

    mkdir -p "$XRAY_CONFIG_DIR"
    cat > "$XRAY_KEYS" <<EOF
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
EOF

    chmod 600 "$XRAY_KEYS"
    success "Ключи сгенерированы и сохранены в $XRAY_KEYS"
}

# ─── Генерация конфига ────────────────────────────────────────────────────────

generate_config() {
    info "Создаю конфигурацию..."

    mkdir -p "$XRAY_CONFIG_DIR"

    if [[ "$TRANSPORT" == "tcp" ]]; then
        cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "email": "$USERNAME",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
    else
        cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "email": "$USERNAME",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        },
        "xhttpSettings": {
          "path": "/"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
    fi

    success "Конфигурация создана ($TRANSPORT)"
}

# ─── Файрвол ─────────────────────────────────────────────────────────────────

check_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        if ! ufw status | grep -qE "${PORT}[/ ].*ALLOW"; then
            warn "Порт $PORT не открыт в UFW"
            echo ""
            read -rp "$(echo -e "${YELLOW}Открыть порт $PORT в UFW? (Y/n):${NC} ")" FW_OPEN
            if [[ "$FW_OPEN" != "n" && "$FW_OPEN" != "N" ]]; then
                ufw allow "$PORT/tcp"
                success "Порт $PORT открыт в UFW"
            else
                warn "Не забудьте открыть порт вручную: ufw allow $PORT/tcp"
            fi
        else
            success "Порт $PORT уже открыт в UFW"
        fi
    fi
}

# ─── Systemd ─────────────────────────────────────────────────────────────────

setup_systemd() {
    info "Запускаю Xray..."

    systemctl enable xray
    systemctl restart xray

    sleep 2

    if systemctl is-active --quiet xray; then
        success "Xray запущен и добавлен в автозагрузку"
    else
        echo ""
        warn "Xray не запустился. Проверьте логи:"
        echo -e "  journalctl -u xray --no-pager -n 20"
        echo ""
        error "Не удалось запустить Xray"
    fi
}

# ─── CLI-утилиты ─────────────────────────────────────────────────────────────

install_cli_tools() {
    info "Устанавливаю CLI-утилиты..."

    # ── xray-sharelink ──
    cat > /usr/local/bin/xray-sharelink <<'TOOLEOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
KEYS="/usr/local/etc/xray/.keys"

[[ -f "$CONFIG" ]] || { echo "Конфиг не найден: $CONFIG"; exit 1; }
[[ -f "$KEYS" ]] || { echo "Файл ключей не найден: $KEYS"; exit 1; }

# shellcheck source=/dev/null
source "$KEYS"

SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || curl -s4 --max-time 5 icanhazip.com 2>/dev/null || true)
[[ -n "$SERVER_IP" ]] || { echo "Не удалось определить IP сервера"; exit 1; }

TRANSPORT=$(jq -r '.inbounds[0].streamSettings.network' "$CONFIG")
PORT=$(jq -r '.inbounds[0].port' "$CONFIG")
SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$CONFIG")
    NAME=$(jq -r '.inbounds[0].settings.clients[0].email // "user"' "$CONFIG")
else
    UUID=$(jq -r --arg name "$NAME" '.inbounds[0].settings.clients[] | select(.email == $name) | .id' "$CONFIG")
    [[ -n "$UUID" ]] || { echo "Пользователь '$NAME' не найден"; exit 1; }
fi

if [[ "$TRANSPORT" == "tcp" ]]; then
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#${NAME}"
else
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=xhttp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&path=%2F#${NAME}"
fi

echo ""
echo "$LINK"
echo ""
if command -v qrencode &>/dev/null; then
    qrencode -t ansiutf8 "$LINK"
fi
TOOLEOF

    # ── xray-adduser ──
    cat > /usr/local/bin/xray-adduser <<'TOOLEOF'
#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Запустите от root (sudo)"; exit 1; }
[[ -n "${1:-}" ]] || { echo "Использование: xray-adduser <имя>"; exit 1; }

CONFIG="/usr/local/etc/xray/config.json"
NAME="$1"

if ! [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Имя может содержать только буквы, цифры, дефис и подчёркивание"
    exit 1
fi

if jq -e --arg name "$NAME" '.inbounds[0].settings.clients[] | select(.email == $name)' "$CONFIG" &>/dev/null; then
    echo "Пользователь '$NAME' уже существует"
    exit 1
fi

TRANSPORT=$(jq -r '.inbounds[0].streamSettings.network' "$CONFIG")
if [[ "$TRANSPORT" == "tcp" ]]; then
    FLOW="xtls-rprx-vision"
else
    FLOW=""
fi

UUID=$(/usr/local/bin/xray uuid)

cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d_%H%M%S)"

TMP=$(mktemp)
jq --arg uuid "$UUID" --arg name "$NAME" --arg flow "$FLOW" \
    '.inbounds[0].settings.clients += [{"id": $uuid, "email": $name, "flow": $flow}]' \
    "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"

systemctl restart xray
echo "Пользователь '$NAME' добавлен"
echo ""
xray-sharelink "$NAME"
TOOLEOF

    # ── xray-rmuser ──
    cat > /usr/local/bin/xray-rmuser <<'TOOLEOF'
#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Запустите от root (sudo)"; exit 1; }
[[ -n "${1:-}" ]] || { echo "Использование: xray-rmuser <имя>"; exit 1; }

CONFIG="/usr/local/etc/xray/config.json"
NAME="$1"

if ! jq -e --arg name "$NAME" '.inbounds[0].settings.clients[] | select(.email == $name)' "$CONFIG" &>/dev/null; then
    echo "Пользователь '$NAME' не найден"
    exit 1
fi

COUNT=$(jq '.inbounds[0].settings.clients | length' "$CONFIG")
if (( COUNT <= 1 )); then
    echo "Нельзя удалить последнего пользователя"
    exit 1
fi

cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d_%H%M%S)"

TMP=$(mktemp)
jq --arg name "$NAME" \
    '.inbounds[0].settings.clients |= map(select(.email != $name))' \
    "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"

systemctl restart xray
echo "Пользователь '$NAME' удалён"
TOOLEOF

    # ── xray-userlist ──
    cat > /usr/local/bin/xray-userlist <<'TOOLEOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
[[ -f "$CONFIG" ]] || { echo "Конфиг не найден: $CONFIG"; exit 1; }

echo ""
echo "Пользователи Xray:"
jq -r '.inbounds[0].settings.clients[] | "  \(.email // "без имени") — \(.id)"' "$CONFIG"
echo ""
echo "Всего: $(jq '.inbounds[0].settings.clients | length' "$CONFIG")"
TOOLEOF

    chmod +x /usr/local/bin/xray-sharelink
    chmod +x /usr/local/bin/xray-adduser
    chmod +x /usr/local/bin/xray-rmuser
    chmod +x /usr/local/bin/xray-userlist

    success "CLI-утилиты установлены: xray-sharelink, xray-adduser, xray-rmuser, xray-userlist"
}

# ─── Итог ─────────────────────────────────────────────────────────────────────

print_summary() {
    local server_ip
    server_ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || curl -s4 --max-time 5 icanhazip.com 2>/dev/null || true)

    local link
    if [[ "$TRANSPORT" == "tcp" ]]; then
        link="vless://${UUID}@${server_ip}:${PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#${USERNAME}"
    else
        link="vless://${UUID}@${server_ip}:${PORT}?type=xhttp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&path=%2F#${USERNAME}"
    fi

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Установка завершена!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Транспорт:${NC}     $TRANSPORT"
    echo -e "  ${BOLD}Порт:${NC}          $PORT"
    echo -e "  ${BOLD}SNI:${NC}           $SNI"
    echo -e "  ${BOLD}Пользователь:${NC}  $USERNAME"
    echo ""
    echo -e "${CYAN}─── Ссылка для подключения ─────────────────────────────────────${NC}"
    echo ""
    echo -e "  $link"
    echo ""

    if command -v qrencode &>/dev/null; then
        qrencode -t ansiutf8 "$link"
    fi

    echo -e "${CYAN}─── Команды управления ─────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${BOLD}xray-sharelink${NC} [имя]    — ссылка + QR-код"
    echo -e "  ${BOLD}xray-adduser${NC} <имя>      — добавить пользователя"
    echo -e "  ${BOLD}xray-rmuser${NC} <имя>       — удалить пользователя"
    echo -e "  ${BOLD}xray-userlist${NC}            — список пользователей"
    echo ""
}

# ─── Запуск ───────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}OPN Door — VLESS + Reality (Xray-core)${NC}                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Без домена, без сертификата — только IP сервера           ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_root
    check_os
    check_existing_install
    ask_transport
    ask_port
    ask_sni
    ask_name
    confirm_settings
    install_packages
    enable_bbr
    install_xray
    generate_keys
    generate_config
    check_firewall
    setup_systemd
    install_cli_tools
    print_summary
}

main "$@"
