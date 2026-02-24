# vless-tls-server

**English** | [Русский](README.ru.md)

Automated VLESS + TLS VPN server setup with your own domain.

## What does the script do

1. Installs required packages (nginx, certbot)
2. Configures nginx for your domain (ACME challenge + HTTPS redirect)
3. Obtains a free SSL certificate from Let's Encrypt
4. Sets up automatic certificate renewal with a deploy hook
5. Launches the [3x-ui](https://github.com/mhsanaei/3x-ui) panel installer (interactive — you complete it yourself)

## Requirements

- **VPS** with Ubuntu 24 and root access
- **Domain** with an A record pointing to your server's IP
- **Ports 80 and 443** open (check your provider's firewall)

## Quick start

```bash
bash <(curl -Ls https://raw.githubusercontent.com/opndoor-io/vless-tls-server/main/install.sh)
```

The script will ask for your domain and email, verify DNS, and walk you through each step.

## Diagnostics

If something doesn't work — run the diagnostic script:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/opndoor-io/vless-tls-server/main/check.sh)
```

It checks nginx, SSL certificate, 3x-ui status, firewall, and DNS — without changing anything.

## After installation

Once the server is set up, you need to create a VLESS connection through the 3x-ui panel.

Step-by-step guide with screenshots: [opndoor.io](https://opndoor.io)

## License

[MIT](LICENSE)
