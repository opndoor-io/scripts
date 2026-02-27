# OPN Door Scripts

[English](README.md) | **Русский**

Скрипты с открытым кодом для установки VPN-инструментов — для пользователей в странах с интернет-цензурой.

Каждая папка содержит отдельный инструмент со своим скриптом установки и документацией.

## Доступные скрипты

| Скрипт | Описание |
|--------|----------|
| [vless-tls-server](vless-tls-server/) | Установка VLESS + TLS сервера с собственным доменом (nginx, certbot, 3x-ui) |
| [xray-reality](xray-reality/) | Установка VLESS + Reality сервера на Xray-core — без домена |

## Как это работает

Каждый скрипт запускается одной командой — клонировать репозиторий не нужно:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/opndoor-io/scripts/main/vless-tls-server/install.sh)
```

Подробности — в README каждой папки.

## Лицензия

[MIT](LICENSE)
