![Version](https://img.shields.io/badge/version-0.7-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Ubuntu%2022.04+-orange)

# WhiteVPN — Block unwanted resources on your VPN server

[Русская версия](README.md)

WhiteVPN blocks access to unwanted websites and IP addresses at the VPN server level. Works with **proxy-based VPNs** (VLESS/Xray via 3X-UI) and **tunnel-based VPNs** in Docker (AmneziaWG, WireGuard, etc.).

---

## Table of Contents

1. [Architecture](#architecture)
2. [How Blocking Works](#how-blocking-works)
3. [Installation](#installation)
4. [Management](#management)
5. [Telegram Bot](#telegram-bot)
6. [Whitelists](#whitelists)
7. [Docker Protection](#docker-protection)
8. [VLESS/Xray (3X-UI)](#vlessxray-3x-ui)
9. [Auto-Updates](#auto-updates)
10. [File Structure](#file-structure)
11. [Systemd Units](#systemd-units)
12. [Troubleshooting](#troubleshooting)

---

## Architecture

```
                              VPN SERVER
                    ┌──────────────────────────┐
                    │                          │
  VLESS client ───► │  Xray (3X-UI, on host)   │──► iptables OUTPUT ──► ipset DROP
                    │  DNS: Unbound 127.0.0.1  │              │
                    │                          │     Unbound DNS ──► deny (NXDOMAIN)
                    │                          │
  WG client ──────► │  AmneziaWG (Docker)      │──► iptables DOCKER-USER ──► ipset DROP
                    │  DNS: DNAT → Unbound     │              │
                    │                          │     Unbound DNS ──► deny (NXDOMAIN)
                    └──────────────────────────┘
```

The system uses two blocking layers that work simultaneously: IP-level blocking via ipset/iptables, and domain-level blocking via the Unbound DNS server.

---

## How Blocking Works

### Layer 1: IP Blocking

The `block_ips.py` script downloads a list of IP addresses from [antifilter.network](https://antifilter.network/download/ip.lst) (~100,000 subnets), applies whitelist filtering, and loads the result into an ipset called `blocked_ips` using the `hash:net` format (up to 2M entries).

Iptables rules intercept traffic at two points: the `OUTPUT` chain catches traffic from Xray (proxy VPN), while the `DOCKER-USER` chain catches traffic from Docker containers. Packets destined for IPs in `blocked_ips` are first logged with the `WHITEVPN_BLOCK` prefix, then dropped.

### Layer 2: Domain Blocking

The `block_domains.py` script downloads a domain list from [Re-filter-lists](https://github.com/1andrevich/Re-filter-lists) (~81,000 domains), applies whitelist filtering, and writes the result to `/etc/unbound/blocked-domains.conf` using the format `local-zone: "domain." deny`.

Unbound DNS runs on `127.0.0.1:53` and serves DNS queries for the server. When a blocked domain is queried, Unbound silently drops the request (`deny` type), causing a DNS timeout on the client side. For non-blocked domains, Unbound functions as a normal recursive resolver.

### Force-Blocking

Some domains (youtube.com, telegram.org, etc.) are not present in Re-filter-lists since they are not DNS-blocked at the source. When a whitelist category is **disabled** (e.g., `youtube=0`), `block_domains.py` force-adds these domains to the blocklist. The force-block dictionary `FORCE_BLOCK_DOMAINS` includes: youtube.com, www.youtube.com, m.youtube.com, youtubei.googleapis.com, i.ytimg.com, and other YouTube CDN domains (22 total), as well as telegram.org, web.telegram.org, t.me, and others (5 total).

### Unbound Limit

On a VPS with 2 GB RAM, Unbound hangs when loading more than ~50,000 domain zones. The `trim_blocked_domains()` function in the bot caps the file at 50,000 entries after each update.

---

## Installation

```bash
git clone https://github.com/anten-ka/whitevpn.git
cd whitevpn
sudo bash install.sh
```

The installer will automatically: install dependencies (ipset, iptables, unbound, python3), create directories and configs in `/opt/block-traffic/`, download and apply IP and domain lists, set up systemd timers for auto-updates, install the CLI menu `blockme`, detect Docker and offer to select containers for protection.

If Docker is not installed, the container step is skipped.

### Installing the Telegram Bot

```bash
blockme   # select option 6
```

The bot is installed separately. You will need: a bot token from @BotFather and your Telegram user ID (use @userinfobot to find it).

---

## Management

### CLI Menu

```bash
blockme
```

Menu options: update IP and domain lists, uninstall the system, disable/enable protection, restart services, install/update Telegram bot, Docker blocking (AmneziaWG).

### Direct Commands

```bash
# Docker management
/opt/block-traffic/docker_rules.sh scan          # scan containers
/opt/block-traffic/docker_rules.sh auto-setup    # auto-configure
/opt/block-traffic/docker_rules.sh enable        # enable
/opt/block-traffic/docker_rules.sh disable       # disable
/opt/block-traffic/docker_rules.sh status        # status
/opt/block-traffic/docker_rules.sh cleanup       # full cleanup

# Manual list update
python3 /opt/block-traffic/blocked-domains/block_domains.py
python3 /opt/block-traffic/blocked-ips/block_ips.py
```

---

## Telegram Bot

The bot is built on **aiogram 3.5.0** (async, with FSM) and provides full remote server management via Telegram.

### Commands

`/start` — main menu, `/help` — help, `/health` — diagnostics, `/whitelist` — whitelist management.

### Main Menu

The bot supports two menu modes (togglable): **Inline buttons** (under the message) and **Reply keyboard** (at the bottom of the screen). There is also a **compact** and **full** menu size mode.

### Bot Features

**Server status** — shows uptime, load, memory, disk, number of blocked IPs and domains, Unbound status, iptables, 3X-UI, Docker containers.

**List update** — downloads fresh lists from sources, applies whitelists, trims to limit, reloads Unbound. Records the result in update history (last 5 entries).

**Enable/disable protection** — starts/stops Unbound, adds/removes iptables rules, sets up/removes DNAT for Docker containers, switches resolv.conf between 127.0.0.1 and 8.8.8.8.

**Docker management** — enable/disable/status of Docker protection. When disabling, DOCKER-USER rules and DNS DNAT redirects are removed.

**Block log** — real-time journalctl monitoring for `WHITEVPN_BLOCK` and Unbound `deny` entries. Log rotation at 30 MB. Optional block notifications.

**Diagnostics** — full report on all component health: Unbound, iptables, ipset, Docker, 3X-UI, DNS resolution, free disk space.

**Whitelists** — full category management (YouTube, Telegram, custom). See details below.

### Background Tasks

The bot runs three background tasks: **auto_update_lists** refreshes lists every 24 hours; **health_watchdog** checks Unbound and iptables health every 5 minutes and alerts on failures; **monitor_block_log** tracks the system journal in real time.

---

## Whitelists

Whitelists allow you to exclude specific resources from blocking. The system supports three categories.

### Categories

**YouTube** (`youtube=1/0`) — when enabled, excludes ~600 YouTube and CDN domains from blocking. Source: [v2fly domain-list-community](https://github.com/v2fly/domain-list-community/blob/master/data/youtube) plus 22 additional CDN domains (googlevideo.com, ytimg.com, ggpht.com, etc.). When **disabled** (`youtube=0`), these domains are force-added to the blocklist.

**Telegram** (`telegram=1/0`) — when enabled, excludes Telegram domains and IP subnets (AS62041, AS59930, AS62014). Source: [v2fly](https://github.com/v2fly/domain-list-community/blob/master/data/telegram) plus 19 additional domains. When **disabled**, domains like telegram.org, t.me, web.telegram.org, etc. are force-blocked.

**Custom** (`custom=1/0`) — domains and IP addresses added manually through the bot. Supports add, delete, clear, import/export.

### Configuration

File `/opt/block-traffic/whitelist/whitelist.conf`:
```
telegram=1
youtube=1
custom=1
```

Domain files: `telegram.txt`, `youtube.txt`, `custom.txt` in `/opt/block-traffic/whitelist/`.

### How It Works

When lists are updated (`block_domains.py`): first, all domains are downloaded from Re-filter-lists; then for each domain it checks whether it (or a parent domain) belongs to an enabled whitelist category — if so, the domain is excluded from blocking. After filtering, disabled categories are checked: if a category is off (=0), its domains from the `FORCE_BLOCK_DOMAINS` dictionary are force-added to the blocklist.

For IP blocking (`block_ips.py`), the same logic applies: enabled whitelist categories exclude IP subnets from the ipset.

### Bot Management

Through the "Whitelist" menu: toggle categories on/off (Telegram, YouTube, Custom), add domains and IPs to the custom list, delete entries by number, view all entries, clear, export to text, import from text or file. After toggling a category, the bot automatically rebuilds the blocklists.

---

## Docker Protection

### How It Works

Docker containers (AmneziaWG, WireGuard, etc.) run in isolated networks. Their traffic goes through the `FORWARD` chain, not `OUTPUT`, so standard iptables rules don't apply. WhiteVPN uses the `DOCKER-USER` chain (which Docker does not overwrite on restart) to block traffic from containers to IPs in the `blocked_ips` ipset.

### DNS for Docker

VPN clients in Docker containers use DNS servers specified in the container configuration (often 1.1.1.1 or 8.8.8.8). For DNS blocking via Unbound to work, WhiteVPN intercepts DNS queries from Docker subnets and redirects them to Unbound via DNAT rules in the NAT table.

The `_setup_dns_dnat()` function automatically discovers all Docker networks (`docker network ls` + `docker network inspect`), identifies subnets and gateway addresses, and for each subnet creates PREROUTING DNAT rules redirecting UDP and TCP port 53 to gateway:53 (where Unbound listens). Exception: queries already destined for 127.0.0.1 (already going to Unbound).

When disabling protection, `_remove_dns_dnat()` removes all DNAT rules (retrying up to 3 times to handle duplicates), so containers revert to their original DNS servers.

### docker_rules.sh

Manages iptables rules in the `DOCKER-USER` chain. Supports commands: `scan` (find containers), `auto-setup` (auto-configure), `enable`/`disable` (on/off), `status`, `cleanup` (full cleanup). Selected container configuration is stored in `/etc/block-ips/docker_containers.conf`.

### Restart Recovery

When Docker restarts, the `DOCKER-USER` chain is cleared. The systemd service `docker-block-restore.service` automatically restores the rules.

### host network

If a container runs with `--network host`, its traffic already goes through the `OUTPUT` chain and is blocked by standard WhiteVPN rules without additional configuration.

---

## VLESS/Xray (3X-UI)

### The Problem

Xray uses the `AsIs` strategy by default — it resolves domains on the client side and passes traffic directly, bypassing DNS blocking on the server. Additionally, 3X-UI overwrites `/usr/local/x-ui/bin/config.json` from its database on every restart, so manual config edits are lost.

### The Solution

The `fix_xray_template.py` script writes an Xray configuration template directly into the 3X-UI SQLite database (`/etc/x-ui/x-ui.db`) as the `xrayTemplateConfig` setting. The template contains: a DNS section pointing to `127.0.0.1:53` (Unbound), and the `UseIPv4` strategy in outbound, which forces Xray to resolve domains through the specified DNS before establishing connections. `IPIfNonMatch` is also enabled in routing for domain resolution.

After writing to the database, `systemctl restart x-ui` is executed, and 3X-UI generates the config from the template — DNS blocking works.

---

## Auto-Updates

Systemd timers run list updates on a schedule. The bot additionally updates lists every 24 hours via the `auto_update_lists` background task. Each update: downloads fresh domains from v2fly (for whitelists), downloads the Re-filter-lists domain list, applies filtering, trims to 50,000 entries, reloads Unbound. Similarly for IPs — downloads the antifilter.network list, filters, loads into ipset.

---

## File Structure

### Repository

```
whitevpn/
├── install.sh                 # Main installer
├── install_bot.sh             # Telegram bot installer
├── manage.sh                  # CLI menu (→ /usr/local/bin/blockme)
├── bot.py                     # Telegram bot (aiogram 3.5.0)
├── docker_rules.sh            # Docker blocking management
├── fix_xray_template.py       # DNS patch for 3X-UI / VLESS
├── blocked-ips/
│   └── block_ips.py           # IP list download and apply
├── blocked-domains/
│   └── block_domains.py       # Domain list download and apply
└── whitelist/
    ├── whitelist.conf         # Category configuration
    ├── telegram.txt           # Telegram domains and IPs
    ├── youtube.txt            # YouTube domains and IPs
    └── custom.txt             # User-added entries
```

### On the Server After Installation

```
/opt/block-traffic/                    # All project files
├── bot.py, manage.sh, docker_rules.sh, ...
├── logs/                              # Bot and update logs
├── whitelist/                         # Whitelists
└── venv/                              # Python virtualenv for the bot

/etc/block-ips/
├── config                             # Install path
├── bot_config.json                    # Bot token and admin ID
└── docker_containers.conf             # Selected containers

/etc/unbound/
├── unbound.conf                       # Unbound configuration
└── blocked-domains.conf               # Blocked domains (up to 50K)

/usr/local/bin/blockme                 # Symlink to manage.sh
/etc/x-ui/x-ui.db                     # 3X-UI database (xrayTemplateConfig)
```

---

## Systemd Units

| Unit | Type | Purpose |
|------|------|---------|
| `block-ips.service` | oneshot | Update IP blocklist |
| `block-ips.timer` | timer | Scheduled trigger |
| `block-domains.service` | oneshot | Update domain blocklist |
| `block-domains.timer` | timer | Scheduled trigger |
| `block-ips-bot.service` | simple | Telegram bot (auto-start) |
| `docker-block-restore.service` | oneshot | Restore Docker rules |

---

## Troubleshooting

### Checking Status

```bash
# Protection status
systemctl status unbound
iptables -L OUTPUT -n | grep blocked_ips
ipset list blocked_ips | head -5

# Docker protection status
iptables -L DOCKER-USER -n
iptables -t nat -L PREROUTING -n | grep DNAT

# DNS test (blocked domain → timeout, allowed → IP)
dig @127.0.0.1 example-blocked.com +short +time=3
dig @127.0.0.1 google.com +short

# Entry counts
ipset list blocked_ips | grep "Number of entries"
wc -l /etc/unbound/blocked-domains.conf
```

### Common Issues

**Unbound won't start** — check `journalctl -u unbound -n 20`. Common cause: too many domains (over 50K). Trim the file: `head -50000 /etc/unbound/blocked-domains.conf > /tmp/bd.conf && mv /tmp/bd.conf /etc/unbound/blocked-domains.conf && systemctl restart unbound`.

**YouTube not blocked when youtube=0** — youtube.com domains are not in Re-filter-lists. Make sure you're using block_domains.py v0.7+, which includes `FORCE_BLOCK_DOMAINS`.

**Docker container not blocked** — verify the container is selected (`docker_rules.sh status`), DNAT rules are in place (`iptables -t nat -L PREROUTING -n`), and Unbound is listening on the Docker network gateway address.

**Sites still blocked after disabling protection** — check that DNAT rules were removed (`iptables -t nat -L PREROUTING -n`). This was fixed in v0.7 — `_remove_dns_dnat()` is called during disable.

**SSL error when updating lists** — the VPS may have TLS issues with api.github.com. Try `curl -v https://api.github.com` for diagnostics. Check `ca-certificates`: `apt install ca-certificates`.

---

## License

MIT License
