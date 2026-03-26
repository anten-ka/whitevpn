# WhiteVPN — Block unwanted resources on your VPN server

[Русская версия](README.md)

This script blocks access to unwanted websites and IP addresses at the VPN server level. Works with **proxy-based VPNs** (VLESS/Xray via 3X-UI) and **tunnel-based VPNs** in Docker (AmneziaWG, WireGuard, etc.).

## Features

- IP blocking via `ipset` + `iptables`
- Domain blocking via `Unbound DNS`
- Docker container blocking (AmneziaWG, etc.) via `DOCKER-USER` chain
- Auto-updating blocklists daily (systemd timers)
- CLI management menu (`blockme`)
- Telegram bot for remote management
- Auto-restore Docker rules after restart

## How it works

```
                         VPN SERVER

  VPN client ──> Xray/VLESS (proxy) ──> iptables OUTPUT
                                              |
                   ipset blocked_ips ─────> DROP
                                              |
                   Unbound DNS ──────────> NXDOMAIN

  WG client ───> AmneziaWG (Docker) ──> iptables DOCKER-USER
                                              |
                   ipset blocked_ips ─────> DROP
                                              |
                   Unbound DNS (0.0.0.0) ─> NXDOMAIN
```

### Two blocking layers

| Layer | Mechanism | Source |
|-------|-----------|--------|
| IP | `ipset` (hash:net) + `iptables` DROP | [antifilter.network](https://antifilter.network/download/ip.lst) |
| DNS | Unbound `local-zone: "domain" deny` | [Re-filter-lists](https://github.com/1andrevich/Re-filter-lists) |

### For proxy VPNs (VLESS/Xray)

Client traffic is handled by the Xray process on the server -> `OUTPUT` chain -> ipset rule matches.

### For Docker containers (AmneziaWG)

Client traffic is routed by the kernel -> `FORWARD` / `DOCKER-USER` chain -> ipset rule matches. Rules are applied **only to selected containers**.

## Installation

```bash
git clone https://github.com/anten-ka/whitevpn.git
cd whitevpn
sudo bash install.sh
```

At the end of installation, the script will automatically:
1. Detect Docker (if installed)
2. Show a list of running containers
3. Ask you to select containers for blocking
4. Apply the rules

If Docker is not installed, this step is skipped without errors.

## Management

### CLI menu

```bash
blockme
```

```
Management menu:
0. Exit
1. Update IP and domain blocklists
2. Uninstall
3. Disable protection
4. Enable protection
5. Restart services
6. Install/update Telegram bot
7. Docker blocking (AmneziaWG)
```

### Docker submenu (option 7)

```
1. Select containers for blocking
2. Enable Docker blocking
3. Disable Docker blocking
4. Docker blocking status
5. Reconfigure Unbound for Docker
0. Back
```

### Telegram bot

Install: `blockme` -> option 6

Buttons:
- **Update IP and domains** — refresh blocklists
- **Enable/Disable protection** — toggle all protection
- **Restart services** — restart Unbound and iptables
- **Server status** — uptime, disk, memory, service status
- **Download logs** — download bot log file
- **Docker: status** — Docker blocking status
- **Docker: on / Docker: off** — toggle Docker blocking

### Direct CLI

```bash
/opt/block-traffic/docker_rules.sh select       # select containers
/opt/block-traffic/docker_rules.sh enable       # enable blocking
/opt/block-traffic/docker_rules.sh disable      # disable blocking
/opt/block-traffic/docker_rules.sh status       # show status
/opt/block-traffic/docker_rules.sh cleanup      # full cleanup
```

## Docker: important notes

### Container DNS

You must explicitly set the container's DNS to the host, otherwise DNS blocking won't work:

**docker-compose.yml:**
```yaml
services:
  amneziawg:
    dns:
      - 172.17.0.1    # Docker gateway IP
```

**docker run:**
```bash
docker run --dns 172.17.0.1 ...
```

### Docker restart

When Docker restarts, `DOCKER-USER` rules are cleared. The script creates a systemd service `docker-block-restore.service` that automatically restores the rules.

### host network

If a container runs with `--network host`, its traffic already goes through the `OUTPUT` chain and is blocked by standard WhiteVPN rules without additional configuration.

## File structure

```
whitevpn/
├── install.sh                  # Installer
├── install_bot.sh              # Telegram bot installer
├── manage.sh                   # CLI menu (-> /usr/local/bin/blockme)
├── bot.py                      # Telegram bot
├── docker_rules.sh             # Docker blocking module
├── blocked-ips/
│   └── block_ips.py            # IP blocklist download and apply
└── blocked-domains/
    └── block_domains.py        # Domain blocklist download and apply
```

## License

MIT License
