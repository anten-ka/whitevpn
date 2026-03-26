#!/bin/bash
# ============================================================================
# docker_rules.sh — Управление iptables/DNS-блокировкой для Docker-контейнеров
# Часть проекта WhiteVPN (расширение для Docker/AmneziaWG)
#
# Использование:
#   docker_rules.sh select           — выбрать контейнеры (интерактивно)
#   docker_rules.sh list-containers  — вывести список контейнеров (JSON)
#   docker_rules.sh select-by-name <name1> [name2] ... — выбрать по имени
#   docker_rules.sh enable           — включить блокировку (iptables + Unbound + DNS)
#   docker_rules.sh disable          — отключить блокировку
#   docker_rules.sh status           — показать статус
#   docker_rules.sh apply-ipt        — применить только iptables
#   docker_rules.sh remove-ipt       — удалить только iptables
#   docker_rules.sh unbound-on       — настроить Unbound для Docker
#   docker_rules.sh unbound-off      — убрать Docker из Unbound
#   docker_rules.sh dns-on           — настроить DNS Docker-демона на Unbound
#   docker_rules.sh dns-off          — вернуть DNS Docker-демона по умолчанию
#   docker_rules.sh cleanup          — полная очистка
# ============================================================================

DOCKER_CONFIG="/etc/block-ips/docker_containers.conf"
UNBOUND_CONF="/etc/unbound/unbound.conf"
IPSET_NAME="blocked_ips"
DAEMON_JSON="/etc/docker/daemon.json"
MARKER="# whitevpn-docker"

# Цветной вывод
log()     { echo -e "\033[34m[DOCKER]\033[0m $1"; }
success() { echo -e "\033[32m[DOCKER]\033[0m $1"; }
error()   { echo -e "\033[31m[DOCKER]\033[0m $1"; }

# ─── Утилиты ────────────────────────────────────────────────────────

check_docker() {
  if ! command -v docker &>/dev/null; then
    error "Docker не установлен."
    return 1
  fi
  if ! docker info &>/dev/null 2>&1; then
    error "Docker daemon не запущен."
    return 1
  fi
  return 0
}

# Получить подсеть Docker-сети по имени
get_network_subnet() {
  local network="$1"
  docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$network" 2>/dev/null
}

# Получить gateway IP Docker-сети (обычно 172.17.0.1)
get_docker_gateway() {
  local gateway
  gateway=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
  if [ -z "$gateway" ]; then
    # Fallback: первая доступная сеть
    local first_net
    first_net=$(docker network ls --format '{{.Name}}' | head -1)
    gateway=$(docker network inspect "$first_net" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
  fi
  echo "$gateway"
}

# Получить все подсети выбранных контейнеров из конфига
get_configured_subnets() {
  local subnets=()
  [ -f "$DOCKER_CONFIG" ] || return
  while IFS= read -r container; do
    [ -z "$container" ] && continue
    [[ "$container" =~ ^# ]] && continue
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
      local nets
      nets=$(docker inspect --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' "$container" 2>/dev/null)
      for net in $nets; do
        local subnet
        subnet=$(get_network_subnet "$net")
        [ -n "$subnet" ] && subnets+=("$subnet")
      done
    else
      log "Контейнер '$container' не запущен, пропускаю."
    fi
  done < "$DOCKER_CONFIG"
  printf '%s\n' "${subnets[@]}" | sort -u
}

# ─── Интерактивный выбор контейнеров ─────────────────────────────────

select_containers() {
  check_docker || return 1

  local containers=()
  while IFS= read -r line; do
    [ -n "$line" ] && containers+=("$line")
  done < <(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)

  if [ ${#containers[@]} -eq 0 ]; then
    error "Нет запущенных Docker-контейнеров."
    return 1
  fi

  echo ""
  log "Запущенные Docker-контейнеры:"
  echo "──────────────────────────────────────────────────────────────"
  printf "  %-4s %-25s %-35s %s\n" "№" "ИМЯ" "ОБРАЗ" "СТАТУС"
  echo "──────────────────────────────────────────────────────────────"

  local names=()
  local i=1
  for line in "${containers[@]}"; do
    local name image status
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    status=$(echo "$line" | cut -f3-)
    names+=("$name")
    printf "  %-4s %-25s %-35s %s\n" "$i)" "$name" "$image" "$status"
    ((i++))
  done

  echo "──────────────────────────────────────────────────────────────"
  echo ""
  echo "  Введите номера через пробел (например: 1 3 5)"
  echo "  'all' — выбрать все, '0' — отмена"
  echo ""
  read -rp "  Ваш выбор: " choice

  [ "$choice" = "0" ] && { log "Отменено."; return 1; }

  local selected=()
  if [ "$choice" = "all" ]; then
    selected=("${names[@]}")
  else
    for num in $choice; do
      if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#names[@]} ]; then
        selected+=("${names[$((num-1))]}")
      else
        error "Неверный номер: $num"
      fi
    done
  fi

  [ ${#selected[@]} -eq 0 ] && { error "Ничего не выбрано."; return 1; }

  mkdir -p "$(dirname "$DOCKER_CONFIG")"
  printf '%s\n' "${selected[@]}" > "$DOCKER_CONFIG"
  success "Сохранено ${#selected[@]} контейнер(ов):"
  for name in "${selected[@]}"; do echo "    - $name"; done
  return 0
}

# ─── Неинтерактивный список контейнеров (JSON) ──────────────────────

list_containers() {
  check_docker || return 1
  echo "["
  local first=true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local name image status
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    status=$(echo "$line" | cut -f3-)
    if [ "$first" = true ]; then
      first=false
    else
      echo ","
    fi
    # Проверяем, выбран ли уже этот контейнер
    local selected=false
    if [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null; then
      selected=true
    fi
    printf '  {"name": "%s", "image": "%s", "status": "%s", "selected": %s}' \
      "$name" "$image" "$status" "$selected"
  done < <(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)
  echo ""
  echo "]"
}

# ─── Неинтерактивный выбор по имени ─────────────────────────────────

select_by_name() {
  check_docker || return 1
  local names=("$@")

  if [ ${#names[@]} -eq 0 ]; then
    error "Укажите имена контейнеров: $0 select-by-name <name1> [name2] ..."
    return 1
  fi

  local valid=()
  local running
  running=$(docker ps --format '{{.Names}}' 2>/dev/null)

  for name in "${names[@]}"; do
    if echo "$running" | grep -qx "$name"; then
      valid+=("$name")
    else
      error "Контейнер '$name' не найден среди запущенных, пропускаю."
    fi
  done

  [ ${#valid[@]} -eq 0 ] && { error "Ни один контейнер не найден."; return 1; }

  mkdir -p "$(dirname "$DOCKER_CONFIG")"
  printf '%s\n' "${valid[@]}" > "$DOCKER_CONFIG"
  success "Сохранено ${#valid[@]} контейнер(ов):"
  for name in "${valid[@]}"; do echo "    - $name"; done
  return 0
}

# ─── Применение правил iptables ──────────────────────────────────────

apply_docker_rules() {
  check_docker || return 1
  local subnets
  subnets=$(get_configured_subnets)
  [ -z "$subnets" ] && { error "Нет подсетей для блокировки. Выберите контейнеры сначала."; return 1; }
  ipset list "$IPSET_NAME" &>/dev/null || { error "ipset '$IPSET_NAME' не существует. Сначала обновите IP-списки."; return 1; }

  log "Применяю правила DOCKER-USER..."
  while IFS= read -r subnet; do
    [ -z "$subnet" ] && continue
    if ! iptables -C DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; then
      iptables -I DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP
      success "DOCKER-USER: -s $subnet -> DROP (blocked_ips)"
    else
      log "Правило для $subnet уже существует."
    fi
  done <<< "$subnets"
}

# ─── Удаление правил iptables ────────────────────────────────────────

remove_docker_rules() {
  log "Удаляю правила Docker-блокировки..."
  local removed=0

  # Удаляем все правила DOCKER-USER с нашим ipset (без подсети)
  while iptables -D DOCKER-USER -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; do
    ((removed++))
  done

  # Удаляем правила с конкретными подсетями
  local subnets
  subnets=$(get_configured_subnets 2>/dev/null)
  if [ -n "$subnets" ]; then
    while IFS= read -r subnet; do
      [ -z "$subnet" ] && continue
      while iptables -D DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; do
        ((removed++))
      done
    done <<< "$subnets"
  fi

  success "Удалено правил: $removed"
}

# ─── Настройка Unbound для Docker-подсетей ───────────────────────────

configure_unbound_docker() {
  check_docker || return 1
  local subnets
  subnets=$(get_configured_subnets)
  [ -z "$subnets" ] && { error "Нет подсетей. Выберите контейнеры сначала."; return 1; }

  log "Настраиваю Unbound для Docker-подсетей..."

  # interface: 0.0.0.0 (если стоит 127.0.0.1)
  if grep -q "interface: 127.0.0.1" "$UNBOUND_CONF" 2>/dev/null; then
    sed -i 's/interface: 127.0.0.1/interface: 0.0.0.0/' "$UNBOUND_CONF"
    success "Unbound: interface -> 0.0.0.0"
  fi

  # access-control для каждой подсети (с маркером)
  while IFS= read -r subnet; do
    [ -z "$subnet" ] && continue
    if ! grep -q "access-control: $subnet allow" "$UNBOUND_CONF" 2>/dev/null; then
      sed -i "/access-control: 127.0.0.0\/8 allow/a\\    access-control: $subnet allow $MARKER" "$UNBOUND_CONF"
      success "Unbound: access-control $subnet allow"
    else
      log "Unbound: access-control для $subnet уже есть."
    fi
  done <<< "$subnets"

  systemctl reload unbound 2>/dev/null || systemctl restart unbound
  success "Unbound перезагружен с Docker-доступом."
}

# ─── Удаление Unbound-настроек Docker ────────────────────────────────

remove_unbound_docker() {
  log "Удаляю Docker-подсети из Unbound..."
  # Удаляем только строки с маркером whitevpn-docker
  sed -i "/$MARKER/d" "$UNBOUND_CONF" 2>/dev/null

  # НЕ меняем interface обратно на 127.0.0.1 —
  # install.sh изначально ставит 0.0.0.0, менять не нужно

  systemctl reload unbound 2>/dev/null || systemctl restart unbound
  success "Docker-настройки Unbound удалены."
}

# ─── Настройка DNS Docker-демона ─────────────────────────────────────

configure_docker_dns() {
  check_docker || return 1

  local gateway
  gateway=$(get_docker_gateway)
  if [ -z "$gateway" ]; then
    error "Не удалось определить gateway IP Docker-сети."
    return 1
  fi

  log "Gateway IP Docker-сети: $gateway"
  log "Настраиваю DNS Docker-демона на Unbound ($gateway)..."

  # Читаем существующий daemon.json или создаём новый
  local daemon_config="{}"
  if [ -f "$DAEMON_JSON" ]; then
    daemon_config=$(cat "$DAEMON_JSON")
    # Резервная копия
    cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%s)"
    success "Резервная копия daemon.json создана."
  fi

  # Обновляем DNS в конфиге через Python (надёжный JSON-парсинг)
  local new_config
  new_config=$(python3 -c "
import json, sys
try:
    cfg = json.loads('''$daemon_config''')
except:
    cfg = {}
cfg['dns'] = ['$gateway']
print(json.dumps(cfg, indent=2))
" 2>/dev/null)

  if [ -z "$new_config" ]; then
    # Fallback без Python
    if [ -f "$DAEMON_JSON" ] && grep -q '"dns"' "$DAEMON_JSON"; then
      sed -i "s|\"dns\":.*|\"dns\": [\"$gateway\"]|" "$DAEMON_JSON"
    else
      echo "{\"dns\": [\"$gateway\"]}" > "$DAEMON_JSON"
    fi
  else
    echo "$new_config" > "$DAEMON_JSON"
  fi

  success "DNS Docker-демона настроен на $gateway"

  log "Перезапуск Docker-демона..."
  systemctl restart docker
  if [ $? -eq 0 ]; then
    success "Docker-демон перезапущен."
  else
    error "Не удалось перезапустить Docker. Проверьте: systemctl status docker"
    return 1
  fi

  echo ""
  echo -e "\033[33m[ВАЖНО]\033[0m Существующие контейнеры нужно пересоздать,"
  echo "         чтобы они подхватили новый DNS-сервер."
  echo "         Для docker-compose: docker-compose down && docker-compose up -d"
  echo "         Для docker run: остановить и запустить контейнер заново."
  echo ""
}

# ─── Удаление DNS Docker-демона ──────────────────────────────────────

remove_docker_dns() {
  if [ ! -f "$DAEMON_JSON" ]; then
    log "daemon.json не найден, DNS не настроен."
    return 0
  fi

  log "Удаляю настройку DNS из Docker-демона..."

  local new_config
  new_config=$(python3 -c "
import json
with open('$DAEMON_JSON') as f:
    cfg = json.load(f)
cfg.pop('dns', None)
if cfg:
    print(json.dumps(cfg, indent=2))
else:
    print('')
" 2>/dev/null)

  if [ -z "$new_config" ]; then
    rm -f "$DAEMON_JSON"
    log "daemon.json удалён (был пустой)."
  else
    echo "$new_config" > "$DAEMON_JSON"
    success "DNS удалён из daemon.json."
  fi

  log "Перезапуск Docker-демона..."
  systemctl restart docker
  success "Docker-демон перезапущен с DNS по умолчанию."

  echo ""
  echo -e "\033[33m[ВАЖНО]\033[0m Пересоздайте контейнеры для применения изменений DNS."
  echo ""
}

# ─── Статус ──────────────────────────────────────────────────────────

show_docker_status() {
  echo ""
  log "=== Статус Docker-блокировки ==="
  echo ""

  # Конфиг контейнеров
  if [ -f "$DOCKER_CONFIG" ]; then
    echo "  Контейнеры в конфиге:"
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      [[ "$name" =~ ^# ]] && continue
      local state="не запущен"
      docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name" && state="запущен"
      echo "    - $name ($state)"
    done < "$DOCKER_CONFIG"
  else
    echo "  Конфиг не найден ($DOCKER_CONFIG)"
  fi

  echo ""

  # Правила iptables
  echo "  Правила DOCKER-USER (blocked_ips):"
  local rules
  rules=$(iptables -L DOCKER-USER -n 2>/dev/null | grep "blocked_ips" || true)
  if [ -n "$rules" ]; then
    echo "$rules" | while IFS= read -r line; do echo "    $line"; done
  else
    echo "    (нет правил)"
  fi

  echo ""

  # Unbound access-control
  echo "  Unbound access-control для Docker:"
  local unbound_rules
  unbound_rules=$(grep "$MARKER" "$UNBOUND_CONF" 2>/dev/null || true)
  if [ -n "$unbound_rules" ]; then
    echo "$unbound_rules" | while IFS= read -r line; do echo "    $line"; done
  else
    echo "    (нет)"
  fi

  echo ""

  # DNS Docker-демона
  echo "  DNS Docker-демона:"
  if [ -f "$DAEMON_JSON" ] && grep -q '"dns"' "$DAEMON_JSON" 2>/dev/null; then
    local dns_val
    dns_val=$(python3 -c "import json; print(json.load(open('$DAEMON_JSON')).get('dns', 'не задан'))" 2>/dev/null || echo "не удалось прочитать")
    echo "    $dns_val"
  else
    echo "    (по умолчанию, не настроен)"
  fi

  echo ""
}

# ─── Полное включение/выключение ─────────────────────────────────────

enable_docker_blocking() {
  log "Включаю блокировку для Docker-контейнеров..."
  apply_docker_rules
  configure_unbound_docker
  # DNS Docker-демона настраиваем только если ещё не настроен
  if [ ! -f "$DAEMON_JSON" ] || ! grep -q '"dns"' "$DAEMON_JSON" 2>/dev/null; then
    echo ""
    log "DNS Docker-демона ещё не настроен."
    log "Без настройки DNS контейнеры не будут использовать Unbound"
    log "и блокировка по доменам работать НЕ будет."
    echo ""
    read -rp "  Настроить DNS Docker-демона сейчас? (y/n): " setup_dns
    if [[ "$setup_dns" =~ ^[yYдД] ]]; then
      configure_docker_dns
    else
      log "DNS Docker-демона пропущен. Настроить позже: docker_rules.sh dns-on"
    fi
  fi
  success "Docker-блокировка включена."
}

disable_docker_blocking() {
  log "Отключаю блокировку для Docker-контейнеров..."
  remove_docker_rules
  success "Docker-блокировка отключена (правила iptables удалены)."
}

# ─── CLI-интерфейс ───────────────────────────────────────────────────

case "${1:-}" in
  select)          select_containers ;;
  list-containers) list_containers ;;
  select-by-name)  shift; select_by_name "$@" ;;
  enable)          enable_docker_blocking ;;
  disable)         disable_docker_blocking ;;
  status)          show_docker_status ;;
  apply-ipt)       apply_docker_rules ;;
  remove-ipt)      remove_docker_rules ;;
  unbound-on)      configure_unbound_docker ;;
  unbound-off)     remove_unbound_docker ;;
  dns-on)          configure_docker_dns ;;
  dns-off)         remove_docker_dns ;;
  cleanup)
    remove_docker_rules
    remove_unbound_docker
    remove_docker_dns
    rm -f "$DOCKER_CONFIG"
    # Удаление systemd-сервиса восстановления
    systemctl stop docker-block-restore.service 2>/dev/null
    systemctl disable docker-block-restore.service 2>/dev/null
    rm -f /etc/systemd/system/docker-block-restore.service
    systemctl daemon-reload 2>/dev/null
    success "Полная очистка Docker-блокировки завершена."
    ;;
  *)
    echo "Использование: $0 {select|list-containers|select-by-name|enable|disable|status|apply-ipt|remove-ipt|unbound-on|unbound-off|dns-on|dns-off|cleanup}"
    echo ""
    echo "  select           — выбрать контейнеры для блокировки (интерактивно)"
    echo "  list-containers  — вывести список контейнеров (JSON)"
    echo "  select-by-name   — выбрать контейнеры по имени (неинтерактивно)"
    echo "  enable           — включить блокировку (iptables + Unbound + DNS)"
    echo "  disable          — отключить блокировку (только iptables)"
    echo "  status           — показать текущий статус"
    echo "  apply-ipt        — применить только правила iptables"
    echo "  remove-ipt       — удалить только правила iptables"
    echo "  unbound-on       — настроить Unbound для Docker"
    echo "  unbound-off      — убрать Docker из Unbound"
    echo "  dns-on           — настроить DNS Docker-демона на Unbound"
    echo "  dns-off          — вернуть DNS Docker-демона по умолчанию"
    echo "  cleanup          — полная очистка (iptables + Unbound + DNS + конфиг)"
    ;;
esac
