#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Диагностика VLESS + Reality (Xray-core)
# https://github.com/opndoor-io/scripts/tree/main/xray-reality
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

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_CONFIG_DIR/config.json"
XRAY_KEYS="$XRAY_CONFIG_DIR/.keys"

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
    fi
}

check_xray() {
    echo ""
    echo -e "${BOLD}Xray-core${NC}"

    if ! command -v xray &>/dev/null; then
        fail "Xray не установлен"
        return
    fi

    local version
    version=$(xray version 2>/dev/null | head -1 || echo "?")
    ok "Установлен: $version"
}

check_config() {
    echo ""
    echo -e "${BOLD}Конфигурация${NC}"

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        fail "Конфиг не найден: $XRAY_CONFIG"
        return
    fi

    ok "Конфиг найден"

    if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
        fail "Конфиг не является валидным JSON"
        return
    fi

    ok "JSON валидный"

    local client_count
    client_count=$(jq '.inbounds[0].settings.clients | length' "$XRAY_CONFIG" 2>/dev/null || echo "0")
    if (( client_count > 0 )); then
        ok "Клиентов: $client_count"
    else
        fail "Клиенты не найдены в конфиге"
    fi

    local transport
    transport=$(jq -r '.inbounds[0].streamSettings.network' "$XRAY_CONFIG" 2>/dev/null || echo "?")
    ok "Транспорт: $transport"

    local port
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "?")
    ok "Порт в конфиге: $port"
}

check_service() {
    echo ""
    echo -e "${BOLD}Systemd-сервис${NC}"

    if ! systemctl list-unit-files xray.service &>/dev/null; then
        fail "Сервис xray.service не найден"
        return
    fi

    if systemctl is-enabled --quiet xray 2>/dev/null; then
        ok "Автозагрузка: включена"
    else
        warn "Автозагрузка: выключена (systemctl enable xray)"
    fi

    if systemctl is-active --quiet xray 2>/dev/null; then
        ok "Статус: запущен"
    else
        fail "Статус: не запущен (systemctl start xray)"
    fi
}

check_port() {
    echo ""
    echo -e "${BOLD}Сетевой порт${NC}"

    local port
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "")

    if [[ -z "$port" || "$port" == "null" ]]; then
        warn "Не удалось определить порт из конфига"
        return
    fi

    if ss -tlnp | grep -q ":${port} "; then
        ok "Порт $port слушает"
    else
        fail "Порт $port не слушает"
    fi
}

check_keys() {
    echo ""
    echo -e "${BOLD}Ключи${NC}"

    if [[ ! -f "$XRAY_KEYS" ]]; then
        fail "Файл ключей не найден: $XRAY_KEYS"
        return
    fi

    ok "Файл ключей найден"

    local perms
    perms=$(stat -c '%a' "$XRAY_KEYS" 2>/dev/null || echo "?")
    if [[ "$perms" == "600" ]]; then
        ok "Права доступа: $perms"
    else
        warn "Права доступа: $perms (рекомендуется 600)"
    fi

    if grep -q "PUBLIC_KEY=" "$XRAY_KEYS" && grep -q "PRIVATE_KEY=" "$XRAY_KEYS" && grep -q "SHORT_ID=" "$XRAY_KEYS"; then
        ok "Все ключи присутствуют"
    else
        fail "Файл ключей неполный"
    fi
}

check_sni() {
    echo ""
    echo -e "${BOLD}SNI${NC}"

    local sni
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null || echo "")

    if [[ -z "$sni" || "$sni" == "null" ]]; then
        warn "SNI не определён в конфиге"
        return
    fi

    ok "SNI: $sni"

    if dig +short "$sni" A 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        ok "DNS: резолвится"
    else
        warn "DNS: $sni не резолвится"
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

    local port
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "443")

    if ufw status | grep -qE "${port}[/ ].*ALLOW"; then
        ok "Порт $port разрешён"
    else
        fail "Порт $port не разрешён (ufw allow $port/tcp)"
    fi
}

check_cli_tools() {
    echo ""
    echo -e "${BOLD}CLI-утилиты${NC}"

    local tools=("xray-sharelink" "xray-adduser" "xray-rmuser" "xray-userlist")
    for tool in "${tools[@]}"; do
        if [[ -x "/usr/local/bin/$tool" ]]; then
            ok "$tool"
        else
            warn "$tool не найден"
        fi
    done
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
    echo -e "  ${BOLD}VLESS + Reality — Диагностика${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"

    [[ $EUID -eq 0 ]] || { echo -e "${RED}Запустите от root (sudo)${NC}"; exit 1; }

    check_system
    check_xray
    check_config
    check_service
    check_port
    check_keys
    check_sni
    check_firewall
    check_cli_tools
    print_result
}

main "$@"
