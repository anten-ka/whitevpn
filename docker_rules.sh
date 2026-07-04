#!/bin/bash
# ============================================================================
# docker_rules.sh — управление iptables/DNS-блокировкой для Docker-контейнеров
# Часть проекта WhiteVPN (блокировка для Docker/AmneziaWG)
#
# Команды:
#   scan               — сканирование контейнеров (человекочитаемый вывод)
#   scan-json          — сканирование (JSON, для бота)
#   auto-setup         — автонастройка (интерактивно, с подтверждением)
#   auto-setup-confirm — автонастройка без подтверждения (для бота)
#   select             — выбрать контейнеры вручную (интерактивно)
#   list-containers    — список контейнеров (JSON)
#   select-by-name     — выбрать контейнеры по именам
#   enable             — включить блокировку
#   disable            — отключить блокировку
#   status             — статус блокировки
#   apply-ipt          — только iptables (+DNAT DNS)
#   remove-ipt         — убрать iptables (+DNAT DNS)
#   unbound-on         — настроить Unbound для Docker
#   unbound-off        — убрать Docker из Unbound
#   dns-on             — настроить DNS Docker-демона
#   dns-off            — вернуть DNS по умолчанию
#   cleanup            — полная очистка
# ============================================================================

DOCKER_CONFIG="/etc/block-ips/docker_containers.conf"
UNBOUND_CONF="/etc/unbound/unbound.conf"
IPSET_NAME="blocked_ips"
ALLOW_SET="whitevpn_allow"
DAEMON_JSON="/etc/docker/daemon.json"
MARKER="# whitevpn-docker"
LOG_PREFIX="WHITEVPN_BLOCK: "
VERSION="0.8"

log()     { echo -e "\033[34m[INFO]\033[0m $1"; }
success() { echo -e "\033[32m[OK]\033[0m $1"; }
error()   { echo -e "\033[31m[ОШИБКА]\033[0m $1"; }
warn()    { echo -e "\033[33m[!]\033[0m $1"; }

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

get_network_subnet() {
  docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$1" 2>/dev/null
}

get_network_gateway() {
  docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$1" 2>/dev/null
}

get_docker_gateway() {
  local gateway
  gateway=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
  if [ -z "$gateway" ]; then
    local first_net
    first_net=$(docker network ls --format '{{.Name}}' | grep -v "^none$\|^host$" | head -1)
    [ -n "$first_net" ] && gateway=$(docker network inspect "$first_net" --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
  fi
  echo "$gateway"
}

# Список "subnet|gateway" для всех сетей выбранных контейнеров
get_configured_pairs() {
  [ -f "$DOCKER_CONFIG" ] || return
  local pairs=()
  while IFS= read -r container; do
    [ -z "$container" ] && continue
    [[ "$container" =~ ^# ]] && continue
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
      local nets
      nets=$(docker inspect --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' "$container" 2>/dev/null)
      for net in $nets; do
        [ "$net" = "host" ] && continue
        local subnet gateway
        subnet=$(get_network_subnet "$net")
        gateway=$(get_network_gateway "$net")
        [ -z "$gateway" ] && gateway=$(get_docker_gateway)
        [ -n "$subnet" ] && [ -n "$gateway" ] && pairs+=("${subnet}|${gateway}")
      done
    fi
  done < "$DOCKER_CONFIG"
  [ ${#pairs[@]} -gt 0 ] && printf '%s\n' "${pairs[@]}" | sort -u
}

get_configured_subnets() {
  get_configured_pairs | cut -d'|' -f1 | sort -u
}

# --- Классификация контейнеров по образу ------------------------------

json_escape() {
  echo -n "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Возвращает машинный тип: VPN | PANEL | OTHER
classify_container() {
  local lower_image
  lower_image=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower_image" in
    *amneziawg*|*amnezia*|*awg*)          echo "VPN" ;;
    *wireguard*|*wg-easy*|*wg-quick*)     echo "VPN" ;;
    *openvpn*)                            echo "VPN" ;;
    *outline*|*shadowbox*)                echo "VPN" ;;
    *softether*|*ipsec*|*strongswan*)     echo "VPN" ;;
    *3x-ui*|*x-ui*|*mhsanaei*)            echo "PANEL" ;;
    *xray*|*v2ray*|*sing-box*|*vless*)    echo "PANEL" ;;
    *)                                    echo "OTHER" ;;
  esac
}

type_label() {
  case "$1" in
    VPN)   echo "VPN" ;;
    PANEL) echo "Прокси-панель" ;;
    *)     echo "Другое" ;;
  esac
}

find_compose_file() {
  docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$1" 2>/dev/null | grep -v '^<no value>$' | head -1
}

patch_compose_dns() {
  local compose_file="$1"
  local gateway="$2"

  if [ ! -f "$compose_file" ]; then
    error "Файл не найден: $compose_file"
    return 1
  fi

  if grep -q "dns:" "$compose_file" 2>/dev/null; then
    if grep -q "$gateway" "$compose_file" 2>/dev/null; then
      log "DNS уже настроен в $compose_file"
      return 0
    fi
    warn "В $compose_file уже есть секция dns:, пропускаем (правьте вручную)"
    return 1
  fi

  cp "$compose_file" "${compose_file}.bak.$(date +%s)"

  local patch_out
  patch_out=$(GATEWAY="$gateway" COMPOSE_FILE="$compose_file" python3 << 'PYEOF'
import os, sys
gw = os.environ["GATEWAY"]
path = os.environ["COMPOSE_FILE"]
try:
    with open(path) as f:
        lines = f.readlines()
    result, added = [], False
    for line in lines:
        result.append(line)
        stripped = line.lstrip()
        if not added and (stripped.startswith('image:') or stripped.startswith('container_name:')):
            indent = len(line) - len(stripped)
            result.append(' ' * indent + 'dns:\n')
            result.append(' ' * indent + f'  - {gw}\n')
            added = True
    if added:
        with open(path, 'w') as f:
            f.writelines(result)
        print('OK')
    else:
        print('SKIP')
except Exception as e:
    print(f'ERROR:{e}', file=sys.stderr)
    sys.exit(1)
PYEOF
)
  [ "$patch_out" = "OK" ] && return 0
  return 1
}

verify_dns() {
  local container="$1"
  local test_result
  test_result=$(docker exec "$container" sh -c "nslookup google.com 2>/dev/null | head -1" 2>/dev/null)
  [ -n "$test_result" ] && return 0
  test_result=$(docker exec "$container" sh -c "getent hosts google.com 2>/dev/null" 2>/dev/null)
  [ -n "$test_result" ] && return 0
  return 1
}

restart_container() {
  local container="$1"
  local compose_file
  compose_file=$(find_compose_file "$container")

  if [ -n "$compose_file" ]; then
    local compose_dir
    compose_dir=$(dirname "$compose_file")
    log "Перезапускаю через docker-compose ($compose_dir)..."
    (cd "$compose_dir" && docker compose down && docker compose up -d) 2>/dev/null || \
    (cd "$compose_dir" && docker-compose down && docker-compose up -d) 2>/dev/null
  else
    log "Перезапускаю контейнер $container..."
    docker restart "$container" 2>/dev/null
  fi
}

# =======================================================================
# СКАНИРОВАНИЕ
# =======================================================================

scan_server() {
  check_docker || return 1

  local panel_found=""
  local panel_name=""
  local vpn_containers=()
  local other_containers=()

  echo ""
  echo -e "\033[36m--- Сканирование Docker-контейнеров ---------------\033[0m"
  echo ""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local name image status ctype
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    status=$(echo "$line" | cut -f3-)
    ctype=$(classify_container "$image")

    local protected="нет"
    if [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null; then
      protected="да"
    fi

    local nets
    nets=$(docker inspect --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}({{$conf.IPAddress}}) {{end}}' "$name" 2>/dev/null)

    local compose
    compose=$(find_compose_file "$name" 2>/dev/null)
    [ -z "$compose" ] && compose="---"

    case "$ctype" in
      PANEL)
        panel_found="true"
        panel_name="$name"
        ;;
      VPN)
        vpn_containers+=("$name|$image|$ctype|$protected|$nets|$compose")
        ;;
      *)
        other_containers+=("$name|$image|$ctype|$protected|$nets|$compose")
        ;;
    esac
  done < <(docker ps --format $'{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)

  if [ -n "$panel_found" ]; then
    success "Панель 3X-UI обнаружена (контейнер: $panel_name)"
  fi

  echo ""

  if [ ${#vpn_containers[@]} -gt 0 ]; then
    echo -e "  \033[1mVPN-контейнеры (рекомендуется защита):\033[0m"
    echo "  --------------------------------------------------"
    for entry in "${vpn_containers[@]}"; do
      IFS='|' read -r name image ctype protected nets compose <<< "$entry"
      if [ "$protected" = "да" ]; then
        echo -e "    \033[32m[OK]\033[0m $name ($image)"
      else
        echo -e "    \033[33m[!]\033[0m  $name ($image) — \033[33mне защищён\033[0m"
      fi
      echo "         Сети: $nets"
      [ "$compose" != "---" ] && echo "         Compose: $compose"
    done
    echo ""
  fi

  if [ ${#other_containers[@]} -gt 0 ]; then
    echo -e "  \033[1mПрочие контейнеры:\033[0m"
    echo "  --------------------------------------------------"
    for entry in "${other_containers[@]}"; do
      IFS='|' read -r name image ctype protected nets compose <<< "$entry"
      if [ "$protected" = "да" ]; then
        echo -e "    \033[32m[OK]\033[0m $name ($image) — $(type_label "$ctype")"
      else
        echo -e "    \033[90m[--]\033[0m $name ($image) — $(type_label "$ctype")"
      fi
    done
    echo ""
  fi

  if [ ${#vpn_containers[@]} -eq 0 ] && [ ${#other_containers[@]} -eq 0 ] && [ -z "$panel_found" ]; then
    warn "Docker-контейнеры не найдены."
  fi
}

scan_json() {
  check_docker || { echo '{"error":"Docker не запущен"}'; return 1; }
  echo "{"
  echo '  "containers": ['
  local first=true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local name image ctype selected
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    ctype=$(classify_container "$image")
    selected=false
    [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null && selected=true
    [ "$first" = true ] && first=false || echo ","
    printf '    {"name":"%s","image":"%s","type":"%s","selected":%s}' \
      "$(json_escape "$name")" "$(json_escape "$image")" "$ctype" "$selected"
  done < <(docker ps --format $'{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)
  echo ""
  echo "  ],"
  local prot=false
  iptables -S DOCKER-USER 2>/dev/null | grep -q "$IPSET_NAME" && prot=true
  echo "  \"protected\": $prot"
  echo "}"
}

# =======================================================================
# АВТОНАСТРОЙКА
# =======================================================================

auto_setup() {
  local confirm_mode="${1:-ask}"
  check_docker || return 1

  local gateway
  gateway=$(get_docker_gateway)
  if [ -z "$gateway" ]; then
    error "Не удалось определить gateway IP Docker-сети."
    return 1
  fi

  local vpn_names=()
  local vpn_images=()
  local vpn_compose=()

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local name image ctype
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    ctype=$(classify_container "$image")

    if [ "$ctype" = "VPN" ]; then
      vpn_names+=("$name")
      vpn_images+=("$image")
      local cf
      cf=$(find_compose_file "$name" 2>/dev/null)
      vpn_compose+=("${cf:-}")
    fi
  done < <(docker ps --format $'{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)

  if [ ${#vpn_names[@]} -eq 0 ]; then
    warn "VPN-контейнеры не обнаружены."
    log "Если контейнер назван нестандартно — используйте ручной выбор (select)."
    return 1
  fi

  echo ""
  echo -e "\033[36m--- Автонастройка Docker-защиты ---------------------\033[0m"
  echo ""
  echo -e "  \033[1mНайденные VPN-контейнеры:\033[0m"
  for i in "${!vpn_names[@]}"; do
    echo "    - ${vpn_names[$i]} (${vpn_images[$i]})"
    local nets_info
    nets_info=$(docker inspect --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}({{$conf.IPAddress}}) {{end}}' "${vpn_names[$i]}" 2>/dev/null)
    echo "      Сети: $nets_info"
    [ -n "${vpn_compose[$i]}" ] && echo "      Compose: ${vpn_compose[$i]}"
  done

  echo ""
  echo -e "  \033[1mБудет выполнено:\033[0m"
  echo "    1. Блокировка iptables (цепочка DOCKER-USER + белый список)"
  echo "    2. Перенаправление DNS контейнеров на Unbound (DNAT :53)"
  echo "    3. Настройка Unbound для Docker-подсетей"
  echo "    4. Настройка DNS Docker-демона (daemon.json -> $gateway)"
  echo "    5. Перезапуск Docker и контейнеров"
  echo "    6. Проверка работы DNS в контейнерах"
  echo ""
  warn "Контейнеры будут перезапущены!"
  echo ""

  if [ "$confirm_mode" = "ask" ]; then
    read -rp "  Продолжить настройку? (y/n): " answer
    if [[ ! "$answer" =~ ^[yYдД] ]]; then
      log "Отменено."
      return 1
    fi
  fi

  echo ""

  mkdir -p "$(dirname "$DOCKER_CONFIG")"
  printf '%s\n' "${vpn_names[@]}" > "$DOCKER_CONFIG"
  success "Контейнеры сохранены в конфиге: ${vpn_names[*]}"

  apply_docker_rules
  configure_unbound_docker

  # Перечитываем gateway (переменную мог не сохранить apply_docker_rules) и проверяем
  gateway=$(get_docker_gateway)
  if [ -n "$gateway" ]; then
    local new_config
    new_config=$(GATEWAY="$gateway" python3 << 'PYEOF'
import json, os
gw = os.environ["GATEWAY"]
try:
    with open("/etc/docker/daemon.json") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
cfg["dns"] = [gw]
print(json.dumps(cfg, indent=2))
PYEOF
)
    if [ -n "$new_config" ]; then
      [ -f "$DAEMON_JSON" ] && cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%s)"
      echo "$new_config" > "$DAEMON_JSON"
      success "daemon.json: dns -> $gateway"
    fi
  else
    warn "gateway пуст — daemon.json не изменён (DNAT :53 всё равно направит DNS в Unbound)"
  fi

  for i in "${!vpn_names[@]}"; do
    if [ -n "${vpn_compose[$i]}" ]; then
      if patch_compose_dns "${vpn_compose[$i]}" "$gateway"; then
        success "docker-compose.yml: dns -> $gateway (${vpn_names[$i]})"
      fi
    fi
  done

  log "Перезапускаю Docker-демон..."
  if systemctl restart docker; then
    success "Docker-демон перезапущен"
  else
    error "Не удалось перезапустить Docker"
  fi

  local wait_count=0
  while ! docker info &>/dev/null 2>&1; do
    sleep 2
    ((wait_count++))
    [ $wait_count -ge 15 ] && { error "Docker не запустился за 30 секунд"; break; }
  done

  for name in "${vpn_names[@]}"; do
    restart_container "$name"
    success "$name перезапущен"
  done

  sleep 3

  # После рестарта Docker цепочки пересозданы — применяем правила заново
  apply_docker_rules

  for name in "${vpn_names[@]}"; do
    if docker ps --format '{{.Names}}' | grep -qx "$name"; then
      if verify_dns "$name"; then
        success "Проверка DNS в $name... работает!"
      else
        warn "Проверка DNS в $name... не удалось проверить (в образе нет nslookup)"
      fi
    fi
  done

  echo ""
  echo -e "\033[32m=== Готово! Docker-защита настроена ===\033[0m"
  echo ""
}

# =======================================================================
# КРАТКИЙ СТАТУС
# =======================================================================

brief_status() {
  check_docker || return 1
  echo ""
  local total=0 protected=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local name
    name=$(echo "$line" | cut -f1)
    ((total++))
    if [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null; then
      ((protected++))
    fi
  done < <(docker ps --format $'{{.Names}}\t{{.Image}}' | sort)
  local rules="выкл"
  iptables -S DOCKER-USER 2>/dev/null | grep -q "$IPSET_NAME" && rules="вкл"
  echo "  Контейнеров: $total | В защите: $protected | Правила DOCKER-USER: $rules"
  echo ""
}

# =======================================================================
# ВЫБОР КОНТЕЙНЕРОВ
# =======================================================================

select_containers() {
  check_docker || return 1

  local containers=()
  while IFS= read -r line; do
    [ -n "$line" ] && containers+=("$line")
  done < <(docker ps --format $'{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)

  if [ ${#containers[@]} -eq 0 ]; then
    error "Нет запущенных Docker-контейнеров."
    return 1
  fi

  echo ""
  log "Запущенные Docker-контейнеры:"
  echo "  ----------------------------------------------------------"
  printf "  %-4s %-20s %-30s %-14s %s\n" "№" "Имя" "Образ" "Тип" "Защита"
  echo "  ----------------------------------------------------------"

  local names=()
  local i=1
  for line in "${containers[@]}"; do
    local name image ctype protected_mark
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    ctype=$(classify_container "$image")
    names+=("$name")

    protected_mark="\033[90m---\033[0m"
    if [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null; then
      protected_mark="\033[32m[OK]\033[0m"
    fi

    printf "  %-4s %-20s %-30s %-14s " "$i)" "$name" "$image" "$(type_label "$ctype")"
    echo -e "$protected_mark"
    ((i++))
  done

  echo "  ----------------------------------------------------------"
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
  success "Выбрано ${#selected[@]} контейнер(ов):"
  for name in "${selected[@]}"; do echo "    - $name"; done
  return 0
}

list_containers() {
  check_docker || return 1
  echo "["
  local first=true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local name image ctype
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    ctype=$(classify_container "$image")

    local selected=false
    [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null && selected=true

    [ "$first" = true ] && first=false || echo ","
    printf '  {"name":"%s","image":"%s","type":"%s","selected":%s}' \
      "$(json_escape "$name")" "$(json_escape "$image")" "$ctype" "$selected"
  done < <(docker ps --format $'{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)
  echo ""
  echo "]"
}

select_by_name() {
  check_docker || return 1
  local names=("$@")
  [ ${#names[@]} -eq 0 ] && { error "Не указаны имена контейнеров."; return 1; }

  local valid=()
  local running
  running=$(docker ps --format '{{.Names}}' 2>/dev/null)

  for name in "${names[@]}"; do
    if echo "$running" | grep -qx "$name"; then
      valid+=("$name")
    else
      error "Контейнер '$name' не найден среди запущенных."
    fi
  done

  [ ${#valid[@]} -eq 0 ] && { error "Ни один контейнер не выбран."; return 1; }

  mkdir -p "$(dirname "$DOCKER_CONFIG")"
  printf '%s\n' "${valid[@]}" > "$DOCKER_CONFIG"
  success "Выбрано ${#valid[@]} контейнер(ов)."
  return 0
}

# =======================================================================
# ПРАВИЛА IPTABLES (DOCKER-USER + DNAT DNS)
# =======================================================================

apply_docker_rules() {
  check_docker || return 1
  local pairs
  pairs=$(get_configured_pairs)
  [ -z "$pairs" ] && { error "Нет подсетей. Выберите контейнеры сначала (select / auto-setup)."; return 1; }
  ipset list "$IPSET_NAME" -t &>/dev/null || { error "ipset '$IPSET_NAME' не существует. Запустите обновление списков."; return 1; }
  ipset create "$ALLOW_SET" hash:net maxelem 65536 -exist

  log "Применяю правила DOCKER-USER + DNAT DNS..."
  local subnet gateway proto
  while IFS='|' read -r subnet gateway; do
    [ -z "$subnet" ] && continue

    # Порядок в цепочке: RETURN(белый список) -> LOG -> DROP.
    # Вставляем в обратном порядке, каждый раз в начало цепочки.
    if ! iptables -C DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; then
      iptables -I DOCKER-USER 1 -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP
    fi
    if ! iptables -C DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j LOG --log-prefix "$LOG_PREFIX" --log-level 4 2>/dev/null; then
      iptables -I DOCKER-USER 1 -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
    fi
    if ! iptables -C DOCKER-USER -s "$subnet" -m set --match-set "$ALLOW_SET" dst -j RETURN 2>/dev/null; then
      iptables -I DOCKER-USER 1 -s "$subnet" -m set --match-set "$ALLOW_SET" dst -j RETURN
    fi
    success "DOCKER-USER: $subnet (whitelist -> LOG -> DROP)"

    # DNAT: любой DNS-запрос из контейнера принудительно попадает в Unbound.
    # Клиент VPN может указать свой DNS (1.1.1.1 и т.п.) — фильтрация всё равно сработает.
    for proto in udp tcp; do
      if ! iptables -t nat -C PREROUTING -s "$subnet" -p "$proto" --dport 53 ! -d "$gateway" -j DNAT --to-destination "${gateway}:53" 2>/dev/null; then
        iptables -t nat -I PREROUTING -s "$subnet" -p "$proto" --dport 53 ! -d "$gateway" -j DNAT --to-destination "${gateway}:53"
      fi
    done
    success "DNAT DNS: $subnet -> ${gateway}:53"
  done <<< "$pairs"
}

remove_docker_rules() {
  log "Удаляю правила Docker-блокировки..."
  local removed=0

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    eval "iptables -D DOCKER-USER ${rule#-A DOCKER-USER }" 2>/dev/null && ((removed++))
  done < <(iptables -S DOCKER-USER 2>/dev/null | grep -E "match-set ($IPSET_NAME|$ALLOW_SET) dst")

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    eval "iptables -t nat -D PREROUTING ${rule#-A PREROUTING }" 2>/dev/null && ((removed++))
  done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -E -- '--dport 53 .*--to-destination')

  success "Удалено правил: $removed"
}

# =======================================================================
# UNBOUND
# =======================================================================

configure_unbound_docker() {
  check_docker || return 1
  local subnets
  subnets=$(get_configured_subnets)
  [ -z "$subnets" ] && { error "Нет подсетей."; return 1; }

  log "Настраиваю Unbound для Docker..."
  local iface_changed=0
  if grep -q "interface: 127.0.0.1" "$UNBOUND_CONF" 2>/dev/null; then
    sed -i 's/interface: 127.0.0.1/interface: 0.0.0.0/' "$UNBOUND_CONF"
    iface_changed=1
    success "Unbound: interface -> 0.0.0.0"
  fi
  while IFS= read -r subnet; do
    [ -z "$subnet" ] && continue
    if ! grep -q "access-control: $subnet allow" "$UNBOUND_CONF" 2>/dev/null; then
      sed -i "/access-control: 127.0.0.0\/8 allow/a\\    access-control: $subnet allow $MARKER" "$UNBOUND_CONF"
      success "Unbound: access-control $subnet"
    fi
  done <<< "$subnets"
  # ВАЖНО: смена interface требует полного restart — reload НЕ перепривязывает сокеты,
  # unbound останется слушать 127.0.0.1 и контейнеры не достучатся до DNS.
  if [ "$iface_changed" = "1" ]; then
    systemctl restart unbound
    success "Unbound перезапущен (interface 0.0.0.0)"
  else
    systemctl reload unbound 2>/dev/null || systemctl restart unbound
  fi
  success "Unbound настроен для Docker-подсетей"
}

remove_unbound_docker() {
  log "Удаляю Docker-подсети из Unbound..."
  sed -i "/$MARKER/d" "$UNBOUND_CONF" 2>/dev/null
  # Возвращаем interface на localhost (restart для перепривязки сокета)
  if grep -q "interface: 0.0.0.0" "$UNBOUND_CONF" 2>/dev/null; then
    sed -i 's/interface: 0.0.0.0/interface: 127.0.0.1/' "$UNBOUND_CONF"
    systemctl restart unbound
  else
    systemctl reload unbound 2>/dev/null || systemctl restart unbound
  fi
  success "Docker-настройки Unbound удалены."
}

# =======================================================================
# DNS DOCKER-ДЕМОНА
# =======================================================================

configure_docker_dns() {
  check_docker || return 1
  local gateway
  gateway=$(get_docker_gateway)
  [ -z "$gateway" ] && { error "Не удалось определить gateway."; return 1; }

  log "Настраиваю DNS Docker-демона на $gateway..."
  local new_config
  new_config=$(GATEWAY="$gateway" python3 << 'PYEOF'
import json, os
gw = os.environ["GATEWAY"]
try:
    with open("/etc/docker/daemon.json") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
cfg["dns"] = [gw]
print(json.dumps(cfg, indent=2))
PYEOF
)
  if [ -n "$new_config" ]; then
    [ -f "$DAEMON_JSON" ] && cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%s)"
    echo "$new_config" > "$DAEMON_JSON"
  else
    echo "{\"dns\": [\"$gateway\"]}" > "$DAEMON_JSON"
  fi

  success "daemon.json: dns -> $gateway"
  log "Перезапуск Docker-демона..."
  systemctl restart docker
  success "Docker-демон перезапущен."
  echo ""
  warn "Пересоздайте контейнеры для применения DNS!"
  echo ""
}

remove_docker_dns() {
  [ ! -f "$DAEMON_JSON" ] && { log "daemon.json не найден."; return 0; }
  log "Удаляю DNS из Docker-демона..."
  local new_config
  new_config=$(python3 << 'PYEOF'
import json
try:
    with open("/etc/docker/daemon.json") as f:
        cfg = json.load(f)
except Exception:
    cfg = {}
cfg.pop("dns", None)
if cfg:
    print(json.dumps(cfg, indent=2))
PYEOF
)
  if [ -z "$new_config" ]; then
    rm -f "$DAEMON_JSON"
  else
    echo "$new_config" > "$DAEMON_JSON"
  fi
  systemctl restart docker
  success "DNS Docker-демона сброшен."
}

# =======================================================================
# ПОЛНОЕ ВКЛЮЧЕНИЕ/ВЫКЛЮЧЕНИЕ
# =======================================================================

enable_docker_blocking() {
  log "Включаю блокировку для Docker-контейнеров..."
  apply_docker_rules || return 1
  configure_unbound_docker
  if [ ! -f "$DAEMON_JSON" ] || ! grep -q '"dns"' "$DAEMON_JSON" 2>/dev/null; then
    echo ""
    warn "DNS Docker-демона не настроен — контейнерам без явного dns: нужен 'dns-on'."
    if [ -t 0 ]; then
      read -rp "Настроить DNS сейчас (перезапустит Docker)? (y/n): " setup_dns
      [[ "$setup_dns" =~ ^[yYдД] ]] && configure_docker_dns
    else
      log "Неинтерактивный режим — пропуск. Используйте 'dns-on' вручную."
    fi
  fi
  success "Docker-блокировка включена."
}

disable_docker_blocking() {
  log "Отключаю Docker-блокировку..."
  remove_docker_rules
  success "Docker-блокировка отключена."
}

# =======================================================================
# СТАТУС
# =======================================================================

show_docker_status() {
  echo ""
  log "=== Состояние защиты Docker-контейнеров ==="
  echo ""

  if [ -f "$DOCKER_CONFIG" ]; then
    echo "  Контейнеры в конфиге:"
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      local state="\033[31mне запущен\033[0m"
      docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name" && state="\033[32mзапущен\033[0m"
      echo -e "    - $name ($state)"
    done < "$DOCKER_CONFIG"
  else
    echo "  Конфиг: не создан"
  fi
  echo ""

  echo "  Правила DOCKER-USER:"
  local rules
  rules=$(iptables -S DOCKER-USER 2>/dev/null | grep -E "$IPSET_NAME|$ALLOW_SET" || true)
  if [ -n "$rules" ]; then
    echo "$rules" | while IFS= read -r line; do echo "    $line"; done
  else
    echo "    (нет правил)"
  fi
  echo ""

  echo "  DNAT DNS (nat/PREROUTING):"
  local dnat
  dnat=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -E -- '--dport 53 .*--to-destination' || true)
  if [ -n "$dnat" ]; then
    echo "$dnat" | while IFS= read -r line; do echo "    $line"; done
  else
    echo "    (нет правил)"
  fi
  echo ""

  echo "  Unbound Docker:"
  local unbound_rules
  unbound_rules=$(grep "$MARKER" "$UNBOUND_CONF" 2>/dev/null || true)
  if [ -n "$unbound_rules" ]; then
    echo "$unbound_rules" | while IFS= read -r line; do echo "    $line"; done
  else
    echo "    (нет)"
  fi
  echo ""

  echo "  DNS Docker-демона:"
  if [ -f "$DAEMON_JSON" ] && grep -q '"dns"' "$DAEMON_JSON" 2>/dev/null; then
    local dns_val
    dns_val=$(python3 -c "import json; print(json.load(open('/etc/docker/daemon.json')).get('dns','---'))" 2>/dev/null || echo "---")
    echo "    $dns_val"
  else
    echo "    (не настроен)"
  fi
  echo ""
}

# =======================================================================
# CLI
# =======================================================================

case "${1:-}" in
  scan)               scan_server ;;
  scan-json)          scan_json ;;
  auto-setup)         auto_setup "ask" ;;
  auto-setup-confirm) auto_setup "force" ;;
  brief-status)       brief_status ;;
  select)             select_containers ;;
  list-containers)    list_containers ;;
  select-by-name)     shift; select_by_name "$@" ;;
  enable)             enable_docker_blocking ;;
  disable)            disable_docker_blocking ;;
  status)             show_docker_status ;;
  apply-ipt)          apply_docker_rules ;;
  remove-ipt)         remove_docker_rules ;;
  unbound-on)         configure_unbound_docker ;;
  unbound-off)        remove_unbound_docker ;;
  dns-on)             configure_docker_dns ;;
  dns-off)            remove_docker_dns ;;
  cleanup)
    remove_docker_rules
    remove_unbound_docker
    remove_docker_dns
    rm -f "$DOCKER_CONFIG"
    systemctl daemon-reload 2>/dev/null
    success "Полная очистка Docker-блокировки завершена."
    ;;
  *)
    echo "WhiteVPN Docker — блокировка трафика контейнеров (v$VERSION)"
    echo ""
    echo "Использование: $0 <команда>"
    echo ""
    echo "  scan               — сканирование контейнеров"
    echo "  scan-json          — сканирование (JSON)"
    echo "  auto-setup         — автонастройка (с подтверждением)"
    echo "  auto-setup-confirm — автонастройка (без подтверждения)"
    echo "  brief-status       — краткий статус (для меню)"
    echo "  select             — ручной выбор контейнеров"
    echo "  list-containers    — список контейнеров (JSON)"
    echo "  select-by-name     — выбор по именам"
    echo "  enable             — включить блокировку"
    echo "  disable            — отключить блокировку"
    echo "  status             — подробный статус"
    echo "  apply-ipt          — только правила iptables (+DNAT)"
    echo "  remove-ipt         — убрать правила iptables (+DNAT)"
    echo "  unbound-on         — Unbound для Docker"
    echo "  unbound-off        — убрать Docker из Unbound"
    echo "  dns-on             — DNS демона -> Unbound"
    echo "  dns-off            — DNS демона -> по умолчанию"
    echo "  cleanup            — полная очистка"
    ;;
esac
