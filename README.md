# OPN Door Scripts

**English** | [Русский](README.ru.md)

Open-source scripts for setting up VPN tools — designed for users in countries with internet censorship.

Each folder contains a self-contained tool with its own installation script and documentation.

## Available scripts

| Script | Description |
|--------|-------------|
| [vless-tls-server](vless-tls-server/) | VLESS + TLS server setup with your own domain (nginx, certbot, 3x-ui) |
| [xray-reality](xray-reality/) | VLESS + Reality server setup with Xray-core — no domain required |

## How it works

Every script can be run with a single command — no need to clone the repo:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/opndoor-io/scripts/main/vless-tls-server/install.sh)
```

See each folder's README for details.

## License

[MIT](LICENSE)
