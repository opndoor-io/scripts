#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Удаление VLESS + Reality (Xray-core)
# https://github.com/opndoor-io/scripts/tree/main/xray-reality
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

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_CONFIG_DIR/config.json"

# ─── Проверки ─────────────────────────────────────────────────────────────────

check_root() {
    [[ $EUID -eq 0 ]] || error "Скрипт нужно запускать от root (sudo)"
}

# ─── Подтверждение ────────────────────────────────────────────────────────────

confirm_removal() {
    echo ""
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  ВНИМАНИЕ: Полное удаление Xray Reality${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Будет удалено:"
    echo -e "  - Systemd-сервис xray"
    echo -e "  - Бинарник Xray-core"
    echo -e "  - Конфигурация и ключи ($XRAY_CONFIG_DIR)"
    echo -e "  - CLI-утилиты (xray-sharelink, xray-adduser, xray-rmuser, xray-userlist)"
    echo ""
    warn "Правила UFW НЕ будут изменены"
    echo ""
    read -rp "$(echo -e "${RED}Для подтверждения введите${NC} ${BOLD}yes${NC}: ")" CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        error "Удаление отменено"
    fi
}

# ─── Бэкап конфига ────────────────────────────────────────────────────────────

offer_backup() {
    if [[ -f "$XRAY_CONFIG" ]]; then
        echo ""
        read -rp "$(echo -e "${YELLOW}Сохранить бэкап конфига перед удалением? (Y/n):${NC} ")" BACKUP
        if [[ "$BACKUP" != "n" && "$BACKUP" != "N" ]]; then
            local backup_path
            backup_path="$HOME/xray-config-backup-$(date +%Y%m%d_%H%M%S).json"
            cp "$XRAY_CONFIG" "$backup_path"
            success "Бэкап сохранён: $backup_path"
        fi
    fi
}

# ─── Удаление ─────────────────────────────────────────────────────────────────

remove_service() {
    info "Останавливаю сервис..."

    if systemctl is-active --quiet xray 2>/dev/null; then
        systemctl stop xray
    fi

    if systemctl is-enabled --quiet xray 2>/dev/null; then
        systemctl disable xray
    fi

    success "Сервис остановлен и отключён"
}

remove_xray() {
    info "Удаляю Xray-core..."

    if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null; then
        success "Xray удалён через официальный скрипт"
    else
        rm -f /usr/local/bin/xray
        rm -rf /usr/local/share/xray
        rm -f /etc/systemd/system/xray.service
        rm -f /etc/systemd/system/xray@.service
        systemctl daemon-reload
        success "Xray удалён вручную"
    fi
}

remove_config() {
    info "Удаляю конфигурацию..."
    rm -rf "$XRAY_CONFIG_DIR"
    success "Конфигурация удалена"
}

remove_cli_tools() {
    info "Удаляю CLI-утилиты..."
    rm -f /usr/local/bin/xray-sharelink
    rm -f /usr/local/bin/xray-adduser
    rm -f /usr/local/bin/xray-rmuser
    rm -f /usr/local/bin/xray-userlist
    success "CLI-утилиты удалены"
}

# ─── Итог ─────────────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Удаление завершено${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ -n "$SAVED_PORT" && "$SAVED_PORT" != "null" ]]; then
        warn "Если порт $SAVED_PORT был открыт в UFW — закройте вручную: ufw delete allow $SAVED_PORT/tcp"
        echo ""
    fi
}

# ─── Запуск ───────────────────────────────────────────────────────────────────

main() {
    check_root

    # Save port before removal for the summary
    SAVED_PORT=""
    if [[ -f "$XRAY_CONFIG" ]] && command -v jq &>/dev/null; then
        SAVED_PORT=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || true)
    fi

    confirm_removal
    offer_backup
    remove_service
    remove_xray
    remove_config
    remove_cli_tools
    print_summary
}

main "$@"
