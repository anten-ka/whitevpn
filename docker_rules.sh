#!/bin/bash
# ============================================================================
# docker_rules.sh — Управление iptables/DNS-блокировкой для Docker-контейнеров
# Часть проекта WhiteVPN (расширение для Docker/AmneziaWG)
#
# Команды:
#   scan              — сканирование контейнеров (человекочитаемый вывод)
#   scan-json         — сканирование (JSON, для бота)
#   auto-setup        — автонастройка (интерактивно, с подтверждением)
#   auto-setup-confirm — автонастройка без подтверждения (для бота)
#   select            — выбрать контейнеры вручную (интерактивно)
#   list-containers   — список контейнеров (JSON)
#   select-by-name    — выбрать контейнеры по имени
#   enable            — включить блокировку
#   disable           — отключить блокировку
#   status            — статус блокировки
#   apply-ipt         — только iptables
#   remove-ipt        — удалить iptables
#   unbound-on        — настроить Unbound для Docker
#   unbound-off       — убрать Docker из Unbound
#   dns-on            — настроить DNS Docker-демона
#   dns-off           — вернуть DNS по умолчанию
#   cleanup           — полная очистка
# ============================================================================

DOCKER_CONFIG="/etc/block-ips/docker_containers.conf"
UNBOUND_CONF="/etc/unbound/unbound.conf"
IPSET_NAME="blocked_ips"
DAEMON_JSON="/etc/docker/daemon.json"
MARKER="# whitevpn-docker"
VERSION="0.3"

# ─── Цветной вывод ──────────────────────────────────────────────────

log()     { echo -e "\033[34m[INFO]\033[0m $1"; }
success() { echo -e "\033[32m[OK]\033[0m $1"; }
error()   { echo -e "\033[31m[ОШИБКА]\033[0m $1"; }
warn()    { echo -e "\033[33m[!]\033[0m $1"; }

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

get_network_subnet() {
  local network="$1"
  docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$network" 2>/dev/null
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
    fi
  done < "$DOCKER_CONFIG"
  printf '%s\n' "${subnets[@]}" | sort -u
}

# ─── Классификация контейнера по образу ──────────────────────────────


json_escape() {
  echo -n "classify_container()" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'
}

classify_container() {
  local image="$1"
  local lower_image
  lower_image=$(echo "$image" | tr '[:upper:]' '[:lower:]')

  case "$lower_image" in
    *amneziawg*|*amnesia-wg*|*awg*)
      echo "VPN"
      ;;
    *wireguard*|*wg-easy*|*wg-quick*)
      echo "VPN"
      ;;
    *openvpn*)
      echo "VPN"
      ;;
    *outline*|*shadowbox*)
      echo "VPN"
      ;;
    *3x-ui*|*x-ui*|*mhsanaei*)
      echo "Панель"
      ;;
    *xray*|*v2ray*|*sing-box*|*vless*)
      echo "Прокси"
      ;;
    *)
      echo "Другой"
      ;;
  esac
}

# ─── Поиск docker-compose.yml контейнера ────────────────────────────

find_compose_file() {
  local container="$1"
  local compose_dir
  compose_dir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container" 2>/dev/null)
  if [ -n "$compose_dir" ] && [ "$compose_dir" != "<no value>" ]; then
    for fname in "docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml"; do
      if [ -f "$compose_dir/$fname" ]; then
        echo "$compose_dir/$fname"
        return 0
      fi
    done
  fi
  return 1
}

# ─── Патч docker-compose.yml — добавление DNS ──────────────────────

patch_compose_dns() {
  local compose_file="$1"
  local gateway="$2"

  if [ ! -f "$compose_file" ]; then
    error "Файл не найден: $compose_file"
    return 1
  fi

  # Проверяем, есть ли уже dns: с нашим gateway
  if grep -q "dns:" "$compose_file" 2>/dev/null; then
    if grep -q "$gateway" "$compose_file" 2>/dev/null; then
      log "DNS уже настроен в $compose_file"
      return 0
    fi
    warn "В $compose_file уже есть настройка dns:, пропускаю (чтобы не сломать)"
    return 1
  fi

  # Резервная копия
  cp "$compose_file" "${compose_file}.bak.$(date +%s)"

  # Добавляем dns: после строки с image: или container_name: в блоке services
  # Используем Python для надёжного парсинга YAML
  python3 -c "
import sys
try:
    with open('$compose_file', 'r') as f:
        lines = f.readlines()

    # Ищем строку с 'image:' или 'container_name:' внутри services
    result = []
    indent = None
    added = False
    for i, line in enumerate(lines):
        result.append(line)
        stripped = line.lstrip()
        if not added and (stripped.startswith('image:') or stripped.startswith('container_name:')):
            indent = len(line) - len(stripped)
            # Добавляем dns после этой строки
            result.append(' ' * indent + 'dns:\n')
            result.append(' ' * indent + '  - $gateway\n')
            added = True

    if added:
        with open('$compose_file', 'w') as f:
            f.writelines(result)
        print('OK')
    else:
        print('SKIP')
except Exception as e:
    print(f'ERROR:{e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null

  local result=$?
  if [ $result -eq 0 ]; then
    return 0
  fi
  return 1
}

# ─── Проверка DNS из контейнера ──────────────────────────────────────

verify_dns() {
  local container="$1"
  # Пытаемся выполнить nslookup из контейнера
  local test_result
  test_result=$(docker exec "$container" sh -c "nslookup google.com 2>/dev/null | head -1" 2>/dev/null)
  if [ -n "$test_result" ]; then
    return 0
  fi
  # Попробуем через getent
  test_result=$(docker exec "$container" sh -c "getent hosts google.com 2>/dev/null" 2>/dev/null)
  if [ -n "$test_result" ]; then
    return 0
  fi
  return 1
}

# ─── Перезапуск контейнера через compose или docker restart ──────────

restart_container() {
  local container="$1"
  local compose_file
  compose_file=$(find_compose_file "$container")

  if [ -n "$compose_file" ]; then
    local compose_dir
    compose_dir=$(dirname "$compose_file")
    log "Перезапуск через docker-compose ($compose_dir)..."
    (cd "$compose_dir" && docker compose down && docker compose up -d) 2>/dev/null || \
    (cd "$compose_dir" && docker-compose down && docker-compose up -d) 2>/dev/null
  else
    log "Перезапуск контейнера $container..."
    docker restart "$container" 2>/dev/null
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# СКАНИРОВАНИЕ
# ═══════════════════════════════════════════════════════════════════════

scan_server() {
  check_docker || return 1

  local panel_found=""
  local panel_name=""
  local vpn_containers=()
  local other_containers=()

  echo ""
  echo -e "\033[36m─── Сканирование Docker-контейнеров ───────────────\033[0m"
  echo ""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local name image status ctype
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    status=$(echo "$line" | cut -f3-)
    ctype=$(classify_container "$image")

    # Проверка защиты
    local protected="нет"
    if [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null; then
      protected="да"
    fi

    # Сети
    local nets
    nets=$(docker inspect --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}({{$conf.IPAddress}}) {{end}}' "$name" 2>/dev/null)

    # Compose file
    local compose
    compose=$(find_compose_file "$name" 2>/dev/null)
    [ -z "$compose" ] && compose="---"

    # Собираем данные
    case "$ctype" in
      "Панель")
        panel_found="true"
        panel_name="$name"
        ;;
      "VPN")
        vpn_containers+=("$name|$image|$ctype|$protected|$nets|$compose")
        ;;
      *)
        other_containers+=("$name|$image|$ctype|$protected|$nets|$compose")
        ;;
    esac
  done < <(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)

  # Панель
  if [ -n "$panel_found" ]; then
    success "Панель 3X-UI обнаружена (контейнер: $panel_name)"
  fi

  echo ""

  # VPN-контейнеры
  if [ ${#vpn_containers[@]} -gt 0 ]; then
    echo -e "  \033[1mVPN-контейнеры (рекомендуется защита):\033[0m"
    echo "  ──────────────────────────────────────────────────"
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

  # Другие контейнеры
  if [ ${#other_containers[@]} -gt 0 ]; then
    echo -e "  \033[1mДругие контейнеры:\033[0m"
    echo "  ──────────────────────────────────────────────────"
    for entry in "${other_containers[@]}"; do
      IFS='|' read -r name image ctype protected nets compose <<< "$entry"
      if [ "$protected" = "да" ]; then
        echo -e "    \033[32m[OK]\033[0m $name ($image) — $ctype"
      else
        echo -e "    \033[90m[--]\033[0m $name ($image) — $ctype"
      fi
    done
    echo ""
  fi

  if [ ${#vpn_containers[@]} -eq 0 ] && [ ${#other_containers[@]} -eq 0 ] && [ -z "$panel_found" ]; then
    warn "Docker-контейнеры не найдены."
  fi
}

# ─── Сканирование (JSON для бота) ───────────────────────────────────

scan_json() {
  check_docker || { echo '{"error":"Docker не доступен"}'; return 1; }

  echo "{"
  echo '  "containers": ['

  local first=true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local name image status ctype protected compose_file
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    status=$(echo "$line" | cut -f3-)
    ctype=$(classify_container "$image")

    protected="false"
    [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null && protected="true"

    compose_file=$(find_compose_file "$name" 2>/dev/null)
    [ -z "$compose_file" ] && compose_file=""

    local nets_json=""
    local net_list
    net_list=$(docker inspect --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}:{{$conf.IPAddress}} {{end}}' "$name" 2>/dev/null)
    nets_json=$(echo "$net_list" | tr ' ' '\n' | grep -v '^$' | sed 's/^/"/' | sed 's/$/"/' | paste -sd',' -)
    [ -z "$nets_json" ] && nets_json=""

    if [ "$first" = true ]; then
      first=false
    else
      echo ","
    fi
    printf '    {"name":"%s","image":"%s","type":"%s","protected":%s,"compose":"%s","networks":[%s]}' \
      "$name" "$image" "$ctype" "$protected" "$compose_file" "$nets_json"
  done < <(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)

  echo ""
  echo "  ],"

  # 3X-UI
  local panel="false"
  local panel_name=""
  while IFS= read -r line; do
    local img
    img=$(echo "$line" | cut -f2)
    local t
    t=$(classify_container "$img")
    if [ "$t" = "Панель" ]; then
      panel="true"
      panel_name=$(echo "$line" | cut -f1)
      break
    fi
  done < <(docker ps --format '{{.Names}}\t{{.Image}}' | sort)

  printf '  "panel_3xui": %s,\n' "$panel"
  printf '  "panel_name": "%s",\n' "$panel_name"

  # Gateway
  local gw
  gw=$(get_docker_gateway)
  printf '  "gateway": "%s"\n' "$gw"

  echo "}"
}

# ═══════════════════════════════════════════════════════════════════════
# АВТОНАСТРОЙКА
# ═══════════════════════════════════════════════════════════════════════

auto_setup() {
  local confirm_mode="${1:-ask}"  # ask или force
  check_docker || return 1

  local gateway
  gateway=$(get_docker_gateway)
  if [ -z "$gateway" ]; then
    error "Не удалось определить gateway IP Docker-сети."
    return 1
  fi

  # Сбор VPN-контейнеров
  local vpn_names=()
  local vpn_images=()
  local vpn_compose=()
  local all_subnets=()

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

      local nets
      nets=$(docker inspect --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' "$name" 2>/dev/null)
      for net in $nets; do
        local subnet
        subnet=$(get_network_subnet "$net")
        [ -n "$subnet" ] && all_subnets+=("$subnet")
      done
    fi
  done < <(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)

  # Дедупликация подсетей
  local unique_subnets
  unique_subnets=$(printf '%s\n' "${all_subnets[@]}" | sort -u)

  if [ ${#vpn_names[@]} -eq 0 ]; then
    warn "VPN-контейнеры не обнаружены."
    log "Если нужно защитить другие контейнеры, используйте ручной выбор."
    return 1
  fi

  # Показать план
  echo ""
  echo -e "\033[36m─── Автонастройка Docker-защиты ─────────────────────\033[0m"
  echo ""
  echo -e "  \033[1mОбнаружены VPN-контейнеры:\033[0m"
  for i in "${!vpn_names[@]}"; do
    echo "    - ${vpn_names[$i]} (${vpn_images[$i]})"
    local nets_info
    nets_info=$(docker inspect --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}({{$conf.IPAddress}}) {{end}}' "${vpn_names[$i]}" 2>/dev/null)
    echo "      Сети: $nets_info"
    [ -n "${vpn_compose[$i]}" ] && echo "      Compose: ${vpn_compose[$i]}"
  done

  echo ""
  echo -e "  \033[1mБудет выполнено:\033[0m"
  echo "    1. Добавление iptables правил DOCKER-USER"
  echo "       для блокировки IP из antifilter.network"
  echo "    2. Настройка Unbound для Docker-подсетей"
  echo "    3. Настройка DNS Docker-демона (daemon.json → $gateway)"

  local has_compose=false
  for cf in "${vpn_compose[@]}"; do
    [ -n "$cf" ] && has_compose=true && break
  done
  if [ "$has_compose" = true ]; then
    echo "    4. Добавление dns: $gateway в docker-compose.yml"
    echo "    5. Перезапуск VPN-контейнеров"
    echo "    6. Создание сервиса автовосстановления"
  else
    echo "    4. Перезапуск VPN-контейнеров"
    echo "    5. Создание сервиса автовосстановления"
  fi

  echo ""
  warn "Контейнеры будут перезапущены!"
  echo ""

  # Подтверждение
  if [ "$confirm_mode" = "ask" ]; then
    read -rp "  Применить настройки? (y/n): " answer
    if [[ ! "$answer" =~ ^[yYдД] ]]; then
      log "Отменено."
      return 1
    fi
  fi

  echo ""

  # ─── Шаг 1: Сохранить выбранные контейнеры ────────────────────
  mkdir -p "$(dirname "$DOCKER_CONFIG")"
  printf '%s\n' "${vpn_names[@]}" > "$DOCKER_CONFIG"
  success "Контейнеры сохранены в конфиг: ${vpn_names[*]}"

  # ─── Шаг 2: iptables DOCKER-USER ──────────────────────────────
  if ipset list "$IPSET_NAME" &>/dev/null; then
    while IFS= read -r subnet; do
      [ -z "$subnet" ] && continue
      if ! iptables -C DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; then
        iptables -I DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP
        success "iptables: DOCKER-USER для $subnet"
      else
        log "iptables: правило для $subnet уже есть"
      fi
    done <<< "$unique_subnets"
  else
    warn "ipset '$IPSET_NAME' не найден — обновите списки IP (пункт 1 в меню)"
    log "iptables правила будут применены после обновления списков"
  fi

  # ─── Шаг 3: Unbound ───────────────────────────────────────────
  if [ -f "$UNBOUND_CONF" ]; then
    if grep -q "interface: 127.0.0.1" "$UNBOUND_CONF" 2>/dev/null; then
      sed -i 's/interface: 127.0.0.1/interface: 0.0.0.0/' "$UNBOUND_CONF"
    fi
    while IFS= read -r subnet; do
      [ -z "$subnet" ] && continue
      if ! grep -q "access-control: $subnet allow" "$UNBOUND_CONF" 2>/dev/null; then
        sed -i "/access-control: 127.0.0.0\/8 allow/a\\    access-control: $subnet allow $MARKER" "$UNBOUND_CONF"
        success "Unbound: access-control $subnet"
      fi
    done <<< "$unique_subnets"
    systemctl reload unbound 2>/dev/null || systemctl restart unbound
    success "Unbound настроен для Docker-подсетей"
  fi

  # ─── Шаг 4: DNS Docker-демона (daemon.json) ───────────────────
  local daemon_config="{}"
  [ -f "$DAEMON_JSON" ] && daemon_config=$(python3 -c "import json; print(json.dumps(json.load(open('$DAEMON_JSON')), indent=2))")

  local new_config
  new_config=$(python3 -c "
import json
try:
    cfg = json.loads('''$daemon_config''')
except:
    cfg = {}
cfg['dns'] = ['$gateway']
print(json.dumps(cfg, indent=2))
" 2>/dev/null)

  if [ -n "$new_config" ]; then
    [ -f "$DAEMON_JSON" ] && cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%s)"
    echo "$new_config" > "$DAEMON_JSON"
    success "daemon.json: dns → $gateway"
  else
    echo "{\"dns\": [\"$gateway\"]}" > "$DAEMON_JSON"
    success "daemon.json: dns → $gateway"
  fi

  # ─── Шаг 5: Патч docker-compose.yml ───────────────────────────
  for i in "${!vpn_names[@]}"; do
    if [ -n "${vpn_compose[$i]}" ]; then
      local patch_result
      patch_result=$(patch_compose_dns "${vpn_compose[$i]}" "$gateway")
      if [ "$patch_result" = "OK" ] || [ $? -eq 0 ]; then
        success "docker-compose.yml: dns → $gateway (${vpn_names[$i]})"
      fi
    fi
  done

  # ─── Шаг 6: Перезапуск Docker и контейнеров ───────────────────
  log "Перезапуск Docker-демона..."
  systemctl restart docker
  if [ $? -eq 0 ]; then
    success "Docker-демон перезапущен"
  else
    error "Не удалось перезапустить Docker"
  fi

  # Ждём готовности Docker
  local wait_count=0
  while ! docker info &>/dev/null 2>&1; do
    sleep 2
    ((wait_count++))
    [ $wait_count -ge 15 ] && { error "Docker не запустился за 30 секунд"; break; }
  done

  # Перезапуск контейнеров
  for name in "${vpn_names[@]}"; do
    restart_container "$name"
    success "$name перезапущен"
  done

  # Небольшая пауза для старта контейнеров
  sleep 3

  # ─── Шаг 7: Проверка DNS ──────────────────────────────────────
  for name in "${vpn_names[@]}"; do
    if docker ps --format '{{.Names}}' | grep -qx "$name"; then
      if verify_dns "$name"; then
        success "Проверка DNS в $name... работает!"
      else
        warn "Проверка DNS в $name... не удалось проверить (контейнер может не иметь nslookup)"
      fi
    fi
  done

  # Пере-применяем iptables после рестарта Docker
  if ipset list "$IPSET_NAME" &>/dev/null; then
    local fresh_subnets
    fresh_subnets=$(get_configured_subnets)
    if [ -n "$fresh_subnets" ]; then
      while IFS= read -r subnet; do
        [ -z "$subnet" ] && continue
        if ! iptables -C DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; then
          iptables -I DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP
        fi
      done <<< "$fresh_subnets"
    fi
  fi

  echo ""
  echo -e "\033[32m═══ Готово! Docker-защита активирована ═══\033[0m"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# КРАТКИЙ СТАТУС (для вывода при включении защиты)
# ═══════════════════════════════════════════════════════════════════════

brief_status() {
  check_docker || return 1

  local panel_found=""
  local panel_name=""

  echo ""
  echo -e "\033[36m─── Сканирование сервера ─────────────────────────────\033[0m"

  # Панель
  while IFS= read -r line; do
    local img
    img=$(echo "$line" | cut -f2)
    if [ "$(classify_container "$img")" = "Панель" ]; then
      panel_name=$(echo "$line" | cut -f1)
      panel_found=true
      break
    fi
  done < <(docker ps --format '{{.Names}}\t{{.Image}}' | sort)

  [ -n "$panel_found" ] && success "Панель 3X-UI обнаружена (контейнер: $panel_name)"

  echo ""
  echo -e "\033[36m─── Docker-контейнеры ───────────────────────────────\033[0m"

  local has_protected=false
  local has_unprotected=false

  # Защищённые
  if [ -f "$DOCKER_CONFIG" ]; then
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
        local img
        img=$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null)
        echo -e "  \033[32m[OK]\033[0m $name ($img) — IP + DNS блокировка"
        has_protected=true
      fi
    done < "$DOCKER_CONFIG"
  fi

  # Незащищённые
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local name image ctype
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    ctype=$(classify_container "$image")

    if [ "$ctype" = "Панель" ]; then
      continue
    fi

    if [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null; then
      continue
    fi

    echo -e "  \033[33m[!]\033[0m  $name ($image) — не защищён"
    has_unprotected=true
  done < <(docker ps --format '{{.Names}}\t{{.Image}}' | sort)

  if [ "$has_protected" = false ] && [ "$has_unprotected" = false ]; then
    log "Docker-контейнеры не найдены"
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# РУЧНОЙ ВЫБОР КОНТЕЙНЕРОВ
# ═══════════════════════════════════════════════════════════════════════

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
  echo "  ──────────────────────────────────────────────────────────"
  printf "  %-4s %-20s %-30s %-10s %s\n" "№" "ИМЯ" "ОБРАЗ" "ТИП" "ЗАЩИТА"
  echo "  ──────────────────────────────────────────────────────────"

  local names=()
  local i=1
  for line in "${containers[@]}"; do
    local name image status ctype protected_mark
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    ctype=$(classify_container "$image")
    names+=("$name")

    protected_mark="\033[90m---\033[0m"
    if [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null; then
      protected_mark="\033[32m[OK]\033[0m"
    fi

    printf "  %-4s %-20s %-30s %-10s " "$i)" "$name" "$image" "$ctype"
    echo -e "$protected_mark"
    ((i++))
  done

  echo "  ──────────────────────────────────────────────────────────"
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
    local name image status ctype
    name=$(echo "$line" | cut -f1)
    image=$(echo "$line" | cut -f2)
    status=$(echo "$line" | cut -f3-)
    ctype=$(classify_container "$image")

    local selected=false
    [ -f "$DOCKER_CONFIG" ] && grep -qx "$name" "$DOCKER_CONFIG" 2>/dev/null && selected=true

    [ "$first" = true ] && first=false || echo ","
    printf '  {"name":"%s","image":"%s","type":"%s","selected":%s}' \
      "$name" "$image" "$ctype" "$selected"
  done < <(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | sort)
  echo ""
  echo "]"
}

# ─── Неинтерактивный выбор по имени ─────────────────────────────────

select_by_name() {
  check_docker || return 1
  local names=("$@")
  [ ${#names[@]} -eq 0 ] && { error "Укажите имена контейнеров."; return 1; }

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

  [ ${#valid[@]} -eq 0 ] && { error "Ни один контейнер не найден."; return 1; }

  mkdir -p "$(dirname "$DOCKER_CONFIG")"
  printf '%s\n' "${valid[@]}" > "$DOCKER_CONFIG"
  success "Сохранено ${#valid[@]} контейнер(ов)."
  return 0
}

# ═══════════════════════════════════════════════════════════════════════
# ПРАВИЛА IPTABLES
# ═══════════════════════════════════════════════════════════════════════

apply_docker_rules() {
  check_docker || return 1
  local subnets
  subnets=$(get_configured_subnets)
  [ -z "$subnets" ] && { error "Нет подсетей. Выберите контейнеры сначала."; return 1; }
  ipset list "$IPSET_NAME" &>/dev/null || { error "ipset '$IPSET_NAME' не существует."; return 1; }

  log "Применяю правила DOCKER-USER..."
  while IFS= read -r subnet; do
    [ -z "$subnet" ] && continue
    if ! iptables -C DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; then
      iptables -I DOCKER-USER -s "$subnet" -m set --match-set "$IPSET_NAME" dst -j DROP
      success "DOCKER-USER: -s $subnet → DROP"
    else
      log "Правило для $subnet уже существует."
    fi
  done <<< "$subnets"
}

remove_docker_rules() {
  log "Удаляю правила Docker-блокировки..."
  local removed=0
  while iptables -D DOCKER-USER -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; do
    ((removed++))
  done
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

# ═══════════════════════════════════════════════════════════════════════
# UNBOUND
# ═══════════════════════════════════════════════════════════════════════

configure_unbound_docker() {
  check_docker || return 1
  local subnets
  subnets=$(get_configured_subnets)
  [ -z "$subnets" ] && { error "Нет подсетей."; return 1; }

  log "Настраиваю Unbound для Docker..."
  if grep -q "interface: 127.0.0.1" "$UNBOUND_CONF" 2>/dev/null; then
    sed -i 's/interface: 127.0.0.1/interface: 0.0.0.0/' "$UNBOUND_CONF"
    success "Unbound: interface → 0.0.0.0"
  fi
  while IFS= read -r subnet; do
    [ -z "$subnet" ] && continue
    if ! grep -q "access-control: $subnet allow" "$UNBOUND_CONF" 2>/dev/null; then
      sed -i "/access-control: 127.0.0.0\/8 allow/a\\    access-control: $subnet allow $MARKER" "$UNBOUND_CONF"
      success "Unbound: access-control $subnet"
    fi
  done <<< "$subnets"
  systemctl reload unbound 2>/dev/null || systemctl restart unbound
  success "Unbound перезагружен."
}

remove_unbound_docker() {
  log "Удаляю Docker-подсети из Unbound..."
  sed -i "/$MARKER/d" "$UNBOUND_CONF" 2>/dev/null
  systemctl reload unbound 2>/dev/null || systemctl restart unbound
  success "Docker-настройки Unbound удалены."
}

# ═══════════════════════════════════════════════════════════════════════
# DNS DOCKER-ДЕМОНА
# ═══════════════════════════════════════════════════════════════════════

configure_docker_dns() {
  check_docker || return 1
  local gateway
  gateway=$(get_docker_gateway)
  [ -z "$gateway" ] && { error "Не удалось определить gateway."; return 1; }

  log "Настраиваю DNS Docker-демона на $gateway..."
  local daemon_config="{}"
  [ -f "$DAEMON_JSON" ] && daemon_config=$(python3 -c "import json; print(json.dumps(json.load(open('$DAEMON_JSON')), indent=2))")

  local new_config
  new_config=$(python3 -c "
import json
try:
    cfg = json.loads('''$daemon_config''')
except:
    cfg = {}
cfg['dns'] = ['$gateway']
print(json.dumps(cfg, indent=2))
" 2>/dev/null)

  if [ -n "$new_config" ]; then
    [ -f "$DAEMON_JSON" ] && cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%s)"
    echo "$new_config" > "$DAEMON_JSON"
  else
    echo "{\"dns\": [\"$gateway\"]}" > "$DAEMON_JSON"
  fi

  success "daemon.json: dns → $gateway"
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
  new_config=$(python3 -c "
import json
with open('$DAEMON_JSON') as f:
    cfg = json.load(f)
cfg.pop('dns', None)
if cfg:
    print(json.dumps(cfg, indent=2))
" 2>/dev/null)

  if [ -z "$new_config" ]; then
    rm -f "$DAEMON_JSON"
  else
    echo "$new_config" > "$DAEMON_JSON"
  fi
  systemctl restart docker
  success "DNS Docker-демона сброшен."
}

# ═══════════════════════════════════════════════════════════════════════
# ПОЛНОЕ ВКЛЮЧЕНИЕ/ВЫКЛЮЧЕНИЕ
# ═══════════════════════════════════════════════════════════════════════

enable_docker_blocking() {
  log "Включаю блокировку для Docker-контейнеров..."
  apply_docker_rules
  configure_unbound_docker
  if [ ! -f "$DAEMON_JSON" ] || ! grep -q '"dns"' "$DAEMON_JSON" 2>/dev/null; then
    echo ""
    warn "DNS Docker-демона не настроен — блокировка доменов не будет работать."
    if [ -t 0 ]; then (y/n): " setup_dns
    [[ "$setup_dns" =~ ^[yYдД] ]] && configure_docker_dns
    else
      log "Неинтерактивный режим — пропуск настройки DNS. Используйте 'dns-on' вручную."
    fi
  fi
  success "Docker-блокировка включена."
}

disable_docker_blocking() {
  log "Отключаю Docker-блокировку..."
  remove_docker_rules
  success "Docker-блокировка отключена."
}

# ═══════════════════════════════════════════════════════════════════════
# ПОДРОБНЫЙ СТАТУС
# ═══════════════════════════════════════════════════════════════════════

show_docker_status() {
  echo ""
  log "=== Подробный статус Docker-блокировки ==="
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
    echo "  Конфиг: не найден"
  fi
  echo ""

  echo "  Правила DOCKER-USER:"
  local rules
  rules=$(iptables -L DOCKER-USER -n 2>/dev/null | grep "blocked_ips" || true)
  if [ -n "$rules" ]; then
    echo "$rules" | while IFS= read -r line; do echo "    $line"; done
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
    dns_val=$(python3 -c "import json; print(json.load(open('$DAEMON_JSON')).get('dns','---'))" 2>/dev/null || echo "---")
    echo "    $dns_val"
  else
    echo "    (не настроен)"
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════

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
    systemctl stop docker-block-restore.service 2>/dev/null
    systemctl disable docker-block-restore.service 2>/dev/null
    rm -f /etc/systemd/system/docker-block-restore.service
    systemctl daemon-reload 2>/dev/null
    success "Полная очистка Docker-блокировки завершена."
    ;;
  *)
    echo "WhiteVPN Docker — управление блокировкой контейнеров"
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
    echo "  select-by-name     — выбор по имени"
    echo "  enable             — включить блокировку"
    echo "  disable            — отключить блокировку"
    echo "  status             — подробный статус"
    echo "  apply-ipt          — только iptables"
    echo "  remove-ipt         — удалить iptables"
    echo "  unbound-on         — Unbound для Docker"
    echo "  unbound-off        — убрать Docker из Unbound"
    echo "  dns-on             — DNS демона → Unbound"
    echo "  dns-off            — DNS демона → по умолчанию"
    echo "  cleanup            — полная очистка"
    ;;
esac
