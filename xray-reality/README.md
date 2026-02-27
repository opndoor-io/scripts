# VLESS + Reality (Xray-core)

**English** | [Русский](README.ru.md)

Automated VLESS + Reality VPN server setup using Xray-core — no domain or certificate required.

[← Back to all scripts](../README.md)

## What does the script do

1. Installs Xray-core from the official repository
2. Generates x25519 keys, UUID, and shortId
3. Creates a VLESS + Reality configuration (TCP or XHTTP transport)
4. Enables TCP BBR for better performance
5. Installs CLI tools for user management
6. Outputs a ready-to-use connection link with QR code

## Requirements

- **VPS** with Ubuntu 24 and root access
- **Open port** (443 by default)

No domain or SSL certificate needed — Reality uses TLS fingerprinting of existing websites.

## Quick start

```bash
bash <(curl -Ls https://raw.githubusercontent.com/opndoor-io/scripts/main/xray-reality/install.sh)
```

The script will ask for transport type, port, SNI, and username.

## CLI commands

After installation, these commands are available:

| Command | Description |
|---------|-------------|
| `xray-sharelink [name]` | Show connection link + QR code |
| `xray-adduser <name>` | Add a new user |
| `xray-rmuser <name>` | Remove a user |
| `xray-userlist` | List all users |

## TCP vs XHTTP

| | TCP | XHTTP |
|---|-----|-------|
| Stability | Proven, widely used | Newer, better for unstable networks |
| Flow | `xtls-rprx-vision` | — |
| Multiplexing | No | Yes |
| Recommendation | Default choice | For restricted networks |

## Diagnostics

If something doesn't work — run the diagnostic script:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/opndoor-io/scripts/main/xray-reality/check.sh)
```

Checks xray binary, config, systemd service, port, keys, SNI, and firewall — without changing anything.

## Uninstall

```bash
bash <(curl -Ls https://raw.githubusercontent.com/opndoor-io/scripts/main/xray-reality/uninstall.sh)
```

Requires typing `yes` to confirm. Offers to save a config backup before removal.

## License

[MIT](../LICENSE)
