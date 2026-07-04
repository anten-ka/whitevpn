#!/bin/bash
# ============================================================================
# apply_firewall.sh — единая точка применения/снятия правил защиты WhiteVPN
#
# Решает проблемы:
#   • восстановление ВСЕХ правил после перезагрузки (systemd: whitevpn-firewall)
#   • ipset создаётся до правил iptables (правильный порядок)
#   • whitelist-ipset (whitevpn_allow) с правилом ACCEPT ПЕРЕД блокировкой —
#     белый список работает независимо от агрегации блок-листов
#   • идемпотентность: повторный запуск не плодит дубликаты правил
#
# Команды:
#   up          — включить защиту (все правила + DNS)
#   down        — выключить защиту (снять правила, вернуть системный DNS)
#   boot        — вызов при загрузке: включить, только если защита не была
#                 выключена вручную (state-файл)
#   ensure-sets — создать ipset'ы, если их нет (+восстановить из /etc/ipset.rules)
#   save        — сохранить ipset'ы в /etc/ipset.rules (для восстановления)
#   status      — краткий статус
# ============================================================================

INSTALL_DIR="/opt/block-traffic"
CONFIG_DIR="/etc/block-ips"
STATE_FILE="${CONFIG_DIR}/protection_state"
IPSET_SAVE_FILE="/etc/ipset.rules"
BLOCK_SET="blocked_ips"
ALLOW_SET="whitevpn_allow"
DOCKER_RULES="${INSTALL_DIR}/docker_rules.sh"
DOCKER_CONFIG="${CONFIG_DIR}/docker_containers.conf"
LOG_PREFIX="WHITEVPN_BLOCK: "

log()     { echo -e "\033[34m[INFO]\033[0m $1"; }
success() { echo -e "\033[32m[OK]\033[0m $1"; }
error()   { echo -e "\033[31m[ОШИБКА]\033[0m $1"; }

# --- ipset ------------------------------------------------------------

ensure_sets() {
  # Восстановление из сохранённого файла (после перезагрузки)
  if ! ipset list "$BLOCK_SET" -t &>/dev/null && [ -s "$IPSET_SAVE_FILE" ]; then
    ipset restore -exist -f "$IPSET_SAVE_FILE" 2>/dev/null \
      && success "ipset восстановлен из $IPSET_SAVE_FILE"
  fi
  ipset create "$BLOCK_SET" hash:net maxelem 2097152 -exist
  ipset create "$ALLOW_SET" hash:net maxelem 65536 -exist
}

save_sets() {
  ensure_sets
  {
    ipset save "$BLOCK_SET"
    ipset save "$ALLOW_SET"
  } > "${IPSET_SAVE_FILE}.tmp" 2>/dev/null && mv "${IPSET_SAVE_FILE}.tmp" "$IPSET_SAVE_FILE"
  success "ipset сохранён в $IPSET_SAVE_FILE"
}

# --- iptables: OUTPUT (хост / 3x-ui / Xray) ----------------------------

# Приватные диапазоны — куда VPN-клиент (через Xray freedom, помеченный mark 255)
# не должен ходить: внутренняя сеть, панель на 127.0.0.1, метаданные облака.
XRAY_MARK=255
PRIVATE_NETS_HOST="127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10"

xray_ssrf_up() {
  local pnet
  iptables -C OUTPUT -m mark --mark $XRAY_MARK -d 127.0.0.1 -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -m mark --mark $XRAY_MARK -d 127.0.0.1 -p udp --dport 53 -j ACCEPT
  iptables -C OUTPUT -m mark --mark $XRAY_MARK -d 127.0.0.1 -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -m mark --mark $XRAY_MARK -d 127.0.0.1 -p tcp --dport 53 -j ACCEPT
  for pnet in $PRIVATE_NETS_HOST; do
    iptables -C OUTPUT -m mark --mark $XRAY_MARK -d "$pnet" -j DROP 2>/dev/null ||       iptables -A OUTPUT -m mark --mark $XRAY_MARK -d "$pnet" -j DROP
  done
}
xray_ssrf_down() {
  local pnet
  iptables -D OUTPUT -m mark --mark $XRAY_MARK -d 127.0.0.1 -p udp --dport 53 -j ACCEPT 2>/dev/null
  iptables -D OUTPUT -m mark --mark $XRAY_MARK -d 127.0.0.1 -p tcp --dport 53 -j ACCEPT 2>/dev/null
  for pnet in $PRIVATE_NETS_HOST; do
    iptables -D OUTPUT -m mark --mark $XRAY_MARK -d "$pnet" -j DROP 2>/dev/null
  done
  iptables -D OUTPUT -m mark --mark $XRAY_MARK -p tcp --dport 853 -j DROP 2>/dev/null
}

host_rules_up() {
  xray_ssrf_up
  # 1) ACCEPT для белого списка — строго ПЕРВЫМ
  if ! iptables -C OUTPUT -m set --match-set "$ALLOW_SET" dst -j ACCEPT 2>/dev/null; then
    iptables -I OUTPUT 1 -m set --match-set "$ALLOW_SET" dst -j ACCEPT
  fi
  # 2) LOG перед DROP
  if ! iptables -C OUTPUT -m set --match-set "$BLOCK_SET" dst -j LOG --log-prefix "$LOG_PREFIX" --log-level 4 2>/dev/null; then
    iptables -A OUTPUT -m set --match-set "$BLOCK_SET" dst -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
  fi
  # 3) DROP
  if ! iptables -C OUTPUT -m set --match-set "$BLOCK_SET" dst -j DROP 2>/dev/null; then
    iptables -A OUTPUT -m set --match-set "$BLOCK_SET" dst -j DROP
  fi
}

host_rules_down() {
  xray_ssrf_down
  iptables -D OUTPUT -m set --match-set "$ALLOW_SET" dst -j ACCEPT 2>/dev/null
  iptables -D OUTPUT -m set --match-set "$BLOCK_SET" dst -j LOG --log-prefix "$LOG_PREFIX" --log-level 4 2>/dev/null
  iptables -D OUTPUT -m set --match-set "$BLOCK_SET" dst -j DROP 2>/dev/null
}

# --- DNS --------------------------------------------------------------

dns_up() {
  systemctl start unbound 2>/dev/null
  systemctl enable unbound 2>/dev/null
  echo "nameserver 127.0.0.1" > /etc/resolv.conf
}

dns_down() {
  systemctl stop unbound 2>/dev/null
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
}

# --- IPv6 ------------------------------------------------------------
# Проект фильтрует ТОЛЬКО IPv4 (ipset hash:net v4, Unbound do-ip6 no). Чтобы
# трафик VPN-клиента не ушёл к заблокированному ресурсу по IPv6 мимо фильтра,
# отключаем IPv6-форвардинг (трафик клиентов) и режем форвард ip6tables.
# Хостовый IPv6 (SSH/управление) НЕ трогаем — только форвардинг.
ipv6_up() {
  sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1
  if command -v ip6tables &>/dev/null; then
    ip6tables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -C FORWARD -p ipv6-icmp -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 2 -p ipv6-icmp -j ACCEPT
    ip6tables -C FORWARD -j DROP 2>/dev/null || ip6tables -A FORWARD -j DROP
  fi
}

ipv6_down() {
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1  # вернуть форвардинг (нужен VPN)
  if command -v ip6tables &>/dev/null; then
    ip6tables -D FORWARD -j DROP 2>/dev/null
    ip6tables -D FORWARD -p ipv6-icmp -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
  fi
}

# --- Docker -----------------------------------------------------------

docker_up() {
  [ -x "$DOCKER_RULES" ] || return 0
  command -v docker &>/dev/null || return 0
  [ -s "$DOCKER_CONFIG" ] || return 0
  # Ждём docker daemon (при загрузке может стартовать позже)
  local i=0
  while ! docker info &>/dev/null; do
    sleep 2; ((i++)); [ "$i" -ge 15 ] && { error "Docker не отвечает, пропуск docker-правил"; return 1; }
  done
  # Ждём появления сконфигурированных контейнеров в docker ps (иначе на boot
  # правила не поставятся — контейнер ещё стартует). Таймаут 60с.
  local want running j=0
  want=$(grep -vE '^#|^$' "$DOCKER_CONFIG" | head -1)
  if [ -n "$want" ]; then
    while ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$want"; do
      sleep 3; ((j++)); [ "$j" -ge 20 ] && { warn "Контейнер '$want' не поднялся за 60с — правила поставлю, но проверь"; break; }
    done
  fi
  bash "$DOCKER_RULES" apply-ipt
}

docker_down() {
  [ -x "$DOCKER_RULES" ] || return 0
  command -v docker &>/dev/null || return 0
  bash "$DOCKER_RULES" remove-ipt
}

# --- Основные команды ---------------------------------------------------

fw_up() {
  mkdir -p "$CONFIG_DIR"
  ensure_sets
  host_rules_up
  ipv6_up
  dns_up
  docker_up
  echo "enabled" > "$STATE_FILE"
  success "Защита включена (OUTPUT + Docker + DNS)"
}

fw_down() {
  mkdir -p "$CONFIG_DIR"
  host_rules_down
  ipv6_down
  docker_down
  dns_down
  echo "disabled" > "$STATE_FILE"
  success "Защита выключена"
}

fw_boot() {
  if [ -f "$STATE_FILE" ] && grep -q "disabled" "$STATE_FILE" 2>/dev/null; then
    log "Защита была выключена вручную — правила при загрузке не применяются"
    return 0
  fi
  fw_up
}

fw_status() {
  local ok=1
  ipset list "$BLOCK_SET" -t &>/dev/null && echo "ipset $BLOCK_SET: есть ($(ipset list "$BLOCK_SET" -t 2>/dev/null | awk -F: '/Number of entries/{gsub(/ /,"",$2);print $2}') записей)" || { echo "ipset $BLOCK_SET: НЕТ"; ok=0; }
  ipset list "$ALLOW_SET" -t &>/dev/null && echo "ipset $ALLOW_SET: есть ($(ipset list "$ALLOW_SET" -t 2>/dev/null | awk -F: '/Number of entries/{gsub(/ /,"",$2);print $2}') записей)" || { echo "ipset $ALLOW_SET: НЕТ"; ok=0; }
  iptables -C OUTPUT -m set --match-set "$ALLOW_SET" dst -j ACCEPT 2>/dev/null && echo "OUTPUT ACCEPT(whitelist): есть" || { echo "OUTPUT ACCEPT(whitelist): НЕТ"; ok=0; }
  iptables -C OUTPUT -m set --match-set "$BLOCK_SET" dst -j DROP 2>/dev/null && echo "OUTPUT DROP: есть" || { echo "OUTPUT DROP: НЕТ"; ok=0; }
  systemctl is-active --quiet unbound && echo "unbound: активен" || { echo "unbound: НЕ активен"; ok=0; }
  local v6fwd; v6fwd=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)
  echo "IPv6-форвардинг: ${v6fwd:-?} (0=закрыт)"
  [ "$ok" = "1" ] && echo "СТАТУС: защита активна" || echo "СТАТУС: защита неактивна/частична"
  return 0
}

purge_sets() {
  host_rules_down
  ipset destroy "$BLOCK_SET" 2>/dev/null
  ipset destroy "$ALLOW_SET" 2>/dev/null
  ipset destroy "${BLOCK_SET}_tmp" 2>/dev/null
  ipset destroy "${ALLOW_SET}_tmp" 2>/dev/null
  rm -f "$IPSET_SAVE_FILE"
  success "ipset-наборы уничтожены"
}

case "${1:-}" in
  up)          fw_up ;;
  down)        fw_down ;;
  purge)       purge_sets ;;
  boot)        fw_boot ;;
  ensure-sets) ensure_sets ;;
  save)        save_sets ;;
  status)      fw_status ;;
  *) echo "Использование: $0 up|down|boot|ensure-sets|save|status" ;;
esac
