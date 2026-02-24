# vless-tls-server

[English](README.md) | **Русский**

Автоматическая установка VPN-сервера (VLESS + TLS) с настройкой через собственный домен.

## Что делает скрипт

1. Устанавливает необходимые пакеты (nginx, certbot)
2. Настраивает nginx для вашего домена (ACME-челлендж + редирект на HTTPS)
3. Получает бесплатный SSL-сертификат от Let's Encrypt
4. Настраивает автопродление сертификата с deploy-хуком
5. Запускает установщик панели [3x-ui](https://github.com/mhsanaei/3x-ui) (интерактивный — вы завершаете его сами)

## Требования

- **VPS** с Ubuntu 24 и root-доступом
- **Домен** с A-записью, указывающей на IP сервера
- **Порты 80 и 443** открыты (проверьте файрвол провайдера)

## Быстрый старт

```bash
bash <(curl -Ls https://raw.githubusercontent.com/opndoor-io/vless-tls-server/main/install.sh)
```

Скрипт запросит домен и email, проверит DNS и проведёт вас через каждый шаг.

## Диагностика

Если что-то не работает — запустите скрипт диагностики:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/opndoor-io/vless-tls-server/main/check.sh)
```

Проверяет nginx, SSL-сертификат, статус 3x-ui, файрвол и DNS — ничего не меняет.

## После установки

После установки сервера необходимо создать VLESS-подключение через панель 3x-ui.

Пошаговая инструкция со скриншотами: [opndoor.io]([https://opndoor.io](https://opndoor.io/ru/guides/svoj-vpn-server-za-15-minut-vless-tls-svoj-domen))

## Лицензия

[MIT](LICENSE)
