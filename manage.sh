#!/bin/bash
VERSION="0.5"

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m[!] Запустите скрипт от root: sudo blockme\033[0m"
  exit 1
fi

# Пути
SYSTEM_DIR="/opt/block-traffic"
LOG_DIR="$SYSTEM_DIR/logs"
LOG_FILE="$LOG_DIR/manage-$(date +%F_%H-%M-%S).log"
CONFIG_DIR="/etc/block-ips"
BOT_CONFIG="$CONFIG_DIR/bot_config.json"
DOCKER_RULES="$SYSTEM_DIR/docker_rules.sh"
WHITELIST_DIR="$SYSTEM_DIR/whitelist"
WHITELIST_CONF="$WHITELIST_DIR/whitelist.conf"
BLOCK_LOG="$LOG_DIR/block_access.log"
VENV_PY="$SYSTEM_DIR/venv/bin/python3"

mkdir -p "$LOG_DIR" "$WHITELIST_DIR"

# Цвета
log()     { echo -e "\033[34m[INFO]\033[0m $1" | tee -a "$LOG_FILE"; }
success() { echo -e "\033[32m[OK]\033[0m $1" | tee -a "$LOG_FILE"; }
error()   { echo -e "\033[31m[ОШИБКА]\033[0m $1" | tee -a "$LOG_FILE"; }
warn()    { echo -e "\033[33m[!]\033[0m $1" | tee -a "$LOG_FILE"; }

# ═══════════════════════════════════════════════════════
# Реферальные ссылки
# ═══════════════════════════════════════════════════════

show_referral() {
  local last_ref_file="$LOG_DIR/.last_referral_shown"
  local now; now=$(date +%s)
  local last_shown=0
  [ -f "$last_ref_file" ] && last_shown=$(cat "$last_ref_file" 2>/dev/null || echo 0)
  [ $((now - last_shown)) -lt 86400 ] && return
  echo "$now" > "$last_ref_file"

  echo ""
  echo -e "\033[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
  echo -e "\033[1m💰 Партнёрские предложения:\033[0m"
  echo ""
  echo "🖥  Хостинг #1 — скидка до 60%:"
  echo "    https://vk.cc/ct29NQ"
  echo "    Промокоды:"
  echo "    OFF60       — 60% на первый месяц"
  echo "    antenka20   — 20% + 3% при оплате за 3 мес."
  echo "    antenka6    — 15% + 5% при оплате за 6 мес."
  echo ""
  echo "🖥  Хостинг #2 — скидка 60%:"
  echo "    https://vk.cc/cUxAhj"
  echo "    OFF60       — 60% на первый месяц"
  echo -e "\033[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

# ═══════════════════════════════════════════════════════
# Whitelist
# ═══════════════════════════════════════════════════════

load_whitelist_status() {
  WL_TELEGRAM=1; WL_YOUTUBE=1; WL_CUSTOM=1
  [ -f "$WHITELIST_CONF" ] || return
  while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d ' '); val=$(echo "$val" | tr -d ' ')
    case "$key" in
      telegram) WL_TELEGRAM="$val" ;; youtube) WL_YOUTUBE="$val" ;; custom) WL_CUSTOM="$val" ;;
    esac
  done < <(grep -v '^#' "$WHITELIST_CONF" | grep '=')
}

save_whitelist_status() {
  cat > "$WHITELIST_CONF" << EOF
# WhiteVPN whitelist config
telegram=$WL_TELEGRAM
youtube=$WL_YOUTUBE
custom=$WL_CUSTOM
EOF
}

get_status_icon() {
  [ "$1" = "1" ] && echo -e "\033[32m✅ ВКЛ\033[0m" || echo -e "\033[31m❌ ВЫКЛ\033[0m"
}

count_custom() {
  local f="$WHITELIST_DIR/custom.txt"
  [ -f "$f" ] && grep -cv '^#\|^$' "$f" 2>/dev/null || echo "0"
}

whitelist_menu() {
  while true; do
    load_whitelist_status
    local cc; cc=$(count_custom)

    echo ""
    echo -e "\033[36m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[36m║         📋 БЕЛЫЙ СПИСОК (ИСКЛЮЧЕНИЯ)            ║\033[0m"
    echo -e "\033[36m╠══════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[36m║\033[0m  1. Telegram       $(get_status_icon $WL_TELEGRAM)                     \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  2. YouTube        $(get_status_icon $WL_YOUTUBE)                     \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  3. Пользоват.     $(get_status_icon $WL_CUSTOM)  ($cc записей)       \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  4. ➕ Добавить    5. ➖ Удалить               \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  6. 📄 Показать   7. 🗑  Очистить             \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  0. ◀️  Назад                                  \033[36m║\033[0m"
    echo -e "\033[36m╚══════════════════════════════════════════════════╝\033[0m"
    echo -e "\033[33m⚠️  Добавление в белый список снижает уровень защиты.\033[0m"
    echo ""
    read -rp "  Выберите: " wl_choice

    case $wl_choice in
      1) [ "$WL_TELEGRAM" = "1" ] && WL_TELEGRAM=0 || WL_TELEGRAM=1; save_whitelist_status
         [ "$WL_TELEGRAM" = "1" ] && success "Telegram ВКЛ" || warn "Telegram ВЫКЛ" ;;
      2) [ "$WL_YOUTUBE" = "1" ] && WL_YOUTUBE=0 || WL_YOUTUBE=1; save_whitelist_status
         [ "$WL_YOUTUBE" = "1" ] && success "YouTube ВКЛ" || warn "YouTube ВЫКЛ" ;;
      3) [ "$WL_CUSTOM" = "1" ] && WL_CUSTOM=0 || WL_CUSTOM=1; save_whitelist_status
         [ "$WL_CUSTOM" = "1" ] && success "Свой ВКЛ" || warn "Свой ВЫКЛ" ;;
      4)
        echo ""
        echo "Введите домены/IP (по одному), пустая строка = конец:"
        local custom_file="$WHITELIST_DIR/custom.txt"
        [ ! -f "$custom_file" ] && echo "# WhiteVPN custom whitelist" > "$custom_file"
        local added=0
        while true; do
          read -rp "  > " entry
          [ -z "$entry" ] && break
          if grep -qxF "$entry" "$custom_file" 2>/dev/null; then
            warn "'$entry' уже есть"
          else
            echo "$entry" >> "$custom_file"; success "  + $entry"; ((added++))
          fi
        done
        [ "$added" -gt 0 ] && success "Добавлено: $added. Обновите списки (п.1)."
        ;;
      5)
        local custom_file="$WHITELIST_DIR/custom.txt"
        if [ -f "$custom_file" ]; then
          local entries; entries=$(grep -v '^#' "$custom_file" | grep -v '^$')
          if [ -n "$entries" ]; then
            echo "$entries" | nl -ba
            read -rp "  Номер для удаления (0=отмена): " del_num
            if [ "$del_num" != "0" ] && [ -n "$del_num" ]; then
              local target; target=$(echo "$entries" | sed -n "${del_num}p")
              [ -n "$target" ] && { grep -vxF "$target" "$custom_file" > "${custom_file}.tmp"; mv "${custom_file}.tmp" "$custom_file"; success "Удалено: $target"; } || error "Неверный номер."
            fi
          else echo "Список пуст."; fi
        else echo "Список пуст."; fi
        ;;
      6)
        local custom_file="$WHITELIST_DIR/custom.txt"
        if [ -f "$custom_file" ]; then
          local entries; entries=$(grep -v '^#' "$custom_file" | grep -v '^$')
          [ -n "$entries" ] && { echo -e "\033[1m📄 Пользовательский:\033[0m"; echo "$entries" | nl -ba; } || echo "Список пуст."
        else echo "Список пуст."; fi
        ;;
      7)
        read -rp "  Очистить весь список? (y/n): " confirm
        [[ "$confirm" =~ ^[yYдД] ]] && { echo "# WhiteVPN custom whitelist" > "$WHITELIST_DIR/custom.txt"; success "Список очищен."; }
        ;;
      0) break ;;
      *) error "Неверный выбор." ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════
# Лог блокировок
# ═══════════════════════════════════════════════════════

block_log_menu() {
  while true; do
    echo ""
    echo -e "\033[36m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[36m║           📜 ЛОГ БЛОКИРОВОК                     ║\033[0m"
    echo -e "\033[36m╠══════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[36m║\033[0m  1. 📄 Последние 30 записей                     \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  2. 📄 Последние 100 записей                    \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  3. 📊 Статистика по IP                          \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  4. 📊 Статистика по доменам                     \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  5. 🗑  Очистить лог                             \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  0. ◀️  Назад                                    \033[36m║\033[0m"
    echo -e "\033[36m╚══════════════════════════════════════════════════╝\033[0m"
    echo ""
    read -rp "  Выберите: " bl_choice

    case $bl_choice in
      1)
        if [ -f "$BLOCK_LOG" ]; then
          echo -e "\033[1m📜 Последние 30 записей:\033[0m"
          tail -30 "$BLOCK_LOG"
        else echo "Лог пуст."; fi
        ;;
      2)
        if [ -f "$BLOCK_LOG" ]; then
          echo -e "\033[1m📜 Последние 100 записей:\033[0m"
          tail -100 "$BLOCK_LOG"
        else echo "Лог пуст."; fi
        ;;
      3)
        if [ -f "$BLOCK_LOG" ]; then
          echo -e "\033[1m📊 Топ-20 заблокированных IP:\033[0m"
          grep "BLOCKED IP" "$BLOCK_LOG" | grep -oP '-> \K\S+' | sort | uniq -c | sort -rn | head -20
        else echo "Лог пуст."; fi
        ;;
      4)
        if [ -f "$BLOCK_LOG" ]; then
          echo -e "\033[1m📊 Топ-20 заблокированных доменов:\033[0m"
          grep "BLOCKED DNS" "$BLOCK_LOG" | grep -oP 'DNS: \K\S+' | sort | uniq -c | sort -rn | head -20
        else echo "Лог пуст."; fi
        ;;
      5)
        read -rp "  Очистить лог блокировок? (y/n): " confirm
        [[ "$confirm" =~ ^[yYдД] ]] && { > "$BLOCK_LOG"; success "Лог очищен."; }
        ;;
      0) break ;;
      *) error "Неверный выбор." ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════
# Telegram-бот
# ═══════════════════════════════════════════════════════

manage_bot() {
  if systemctl is-active --quiet block-ips-bot; then
    echo -e "  🟢 Бот: \033[32mактивен\033[0m"
  else
    echo -e "  🔴 Бот: \033[31mнеактивен\033[0m"
  fi

  echo ""
  echo "  1. 🔄 Перезапустить бота"
  echo "  2. 🔴 Остановить бота"
  echo "  3. 🟢 Запустить бота"
  echo "  4. 📝 Изменить токен/ID"
  echo "  5. 📋 Логи бота"
  echo "  0. ◀️  Назад"
  echo ""
  read -rp "  Выберите: " bc

  case $bc in
    1) systemctl restart block-ips-bot && success "Бот перезапущен" || error "Ошибка" ;;
    2) systemctl stop block-ips-bot && success "Бот остановлен" || error "Ошибка" ;;
    3) systemctl start block-ips-bot && success "Бот запущен" || error "Ошибка" ;;
    4)
      echo ""
      read -rp "  Bot Token: " new_token
      read -rp "  Admin ID: " new_admin
      if [ -n "$new_token" ] && [ -n "$new_admin" ]; then
        cat > "$BOT_CONFIG" << BCFG
{
  "BOT_TOKEN": "$new_token",
  "ADMIN_ID": $new_admin
}
BCFG
        chmod 600 "$BOT_CONFIG"
        systemctl restart block-ips-bot
        success "Конфигурация обновлена, бот перезапущен."
      else
        error "Пустые данные, отмена."
      fi
      ;;
    5) journalctl -u block-ips-bot --no-pager -n 50 ;;
    0) ;;
    *) error "Неверный выбор." ;;
  esac
}

# ═══════════════════════════════════════════════════════
# Деинсталляция
# ═══════════════════════════════════════════════════════

uninstall() {
  log "Деинсталляция..."

  for svc in block-ips-bot whitevpn-update; do
    systemctl stop "$svc" 2>/dev/null; systemctl disable "$svc" 2>/dev/null
  done
  systemctl stop whitevpn-update.timer 2>/dev/null; systemctl disable whitevpn-update.timer 2>/dev/null

  # iptables
  iptables -D OUTPUT -m set --match-set blocked_ips dst -j LOG --log-prefix "WHITEVPN_BLOCK: " --log-level 4 2>/dev/null
  iptables -D OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null

  [ -f "$DOCKER_RULES" ] && bash "$DOCKER_RULES" cleanup 2>/dev/null

  rm -f /etc/systemd/system/block-ips-bot.service
  rm -f /etc/systemd/system/whitevpn-update.service
  rm -f /etc/systemd/system/whitevpn-update.timer
  rm -f /etc/systemd/system/ipset-restore.service
  systemctl daemon-reload

  systemctl stop unbound 2>/dev/null; systemctl disable unbound 2>/dev/null
  echo 'nameserver 8.8.8.8' > /etc/resolv.conf

  rm -f /usr/local/bin/blockme
  rm -rf "$SYSTEM_DIR"
  rm -rf "$CONFIG_DIR"

  success "Деинсталляция завершена."
}

# ═══════════════════════════════════════════════════════
# Включение / Отключение защиты
# ═══════════════════════════════════════════════════════

enable_blocking() {
  log "Включение защиты..."

  echo 'nameserver 127.0.0.1' > /etc/resolv.conf
  systemctl start unbound
  success "Unbound запущен, DNS → 127.0.0.1"

  # LOG-правило (перед DROP)
  if ! iptables -C OUTPUT -m set --match-set blocked_ips dst -j LOG --log-prefix "WHITEVPN_BLOCK: " --log-level 4 2>/dev/null; then
    iptables -A OUTPUT -m set --match-set blocked_ips dst -j LOG --log-prefix "WHITEVPN_BLOCK: " --log-level 4
  fi
  # DROP-правило
  if ! iptables -C OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null; then
    iptables -A OUTPUT -m set --match-set blocked_ips dst -j DROP
  fi
  success "iptables (LOG + DROP)"

  if [ -f "$DOCKER_RULES" ] && command -v docker &>/dev/null; then
    bash "$DOCKER_RULES" enable 2>/dev/null && success "Docker-защита ВКЛ"
  fi

  load_whitelist_status
  echo ""
  echo -e "  \033[36m📋 Белый список:\033[0m"
  echo -e "     Telegram:   $(get_status_icon $WL_TELEGRAM)"
  echo -e "     YouTube:    $(get_status_icon $WL_YOUTUBE)"
  echo -e "     Свой:       $(get_status_icon $WL_CUSTOM) ($(count_custom) записей)"
  echo ""
  success "Защита включена."
}

disable_blocking() {
  log "Отключение защиты..."
  iptables -D OUTPUT -m set --match-set blocked_ips dst -j LOG --log-prefix "WHITEVPN_BLOCK: " --log-level 4 2>/dev/null
  iptables -D OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null
  systemctl stop unbound 2>/dev/null
  echo 'nameserver 8.8.8.8' > /etc/resolv.conf
  [ -f "$DOCKER_RULES" ] && bash "$DOCKER_RULES" disable 2>/dev/null
  success "Защита отключена."
}

# ═══════════════════════════════════════════════════════
# Статус
# ═══════════════════════════════════════════════════════

show_status() {
  echo ""
  echo -e "\033[1m📊 Состояние сервера:\033[0m"
  echo ""

  local up_s; up_s=$(awk '{print int($1)}' /proc/uptime)
  echo -e "  ⏱  Uptime: $((up_s/86400))д $(( (up_s%86400)/3600 ))ч $(( (up_s%3600)/60 ))м"

  local ub_ok=0 ipt_ok=0
  systemctl is-active --quiet unbound && ub_ok=1
  iptables -C OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null && ipt_ok=1

  if [ "$ub_ok" = "1" ] && [ "$ipt_ok" = "1" ]; then
    echo -e "  🟢 Защита: \033[32mВКЛЮЧЕНА\033[0m"
  else
    echo -e "  🔴 Защита: \033[31mВЫКЛЮЧЕНА\033[0m"
  fi

  local ipc; ipc=$(ipset list blocked_ips -t 2>/dev/null | grep "Number of entries" | awk -F: '{print $2}' | tr -d ' ')
  [ -n "$ipc" ] && echo "  📊 IP: $ipc" || echo "  📊 ipset: не найден"

  local dom_cnt=0
  [ -f /etc/unbound/blocked-domains.conf ] && dom_cnt=$(grep -c 'local-zone' /etc/unbound/blocked-domains.conf 2>/dev/null || echo 0)
  echo "  📊 Доменов: $dom_cnt"

  # 3x-ui
  if systemctl is-active --quiet x-ui 2>/dev/null; then
    echo -e "  🖥  3x-ui: \033[32mактивна\033[0m"
  fi

  # Docker
  if command -v docker &>/dev/null; then
    local containers; containers=$(docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    if [ -n "$containers" ]; then
      local dprot="🔴"
      iptables -L DOCKER-USER -n 2>/dev/null | grep -q blocked_ips && dprot="🟢"
      echo "  🐳 Docker: $dprot ($containers)"
    fi
  fi

  # Whitelist
  load_whitelist_status
  echo ""
  echo -e "  \033[36m📋 Белый список:\033[0m"
  echo -e "     Telegram:   $(get_status_icon $WL_TELEGRAM)"
  echo -e "     YouTube:    $(get_status_icon $WL_YOUTUBE)"
  echo -e "     Свой:       $(get_status_icon $WL_CUSTOM) ($(count_custom) записей)"

  # Бот
  echo ""
  if systemctl is-active --quiet block-ips-bot; then
    echo -e "  🤖 Бот: \033[32mактивен\033[0m"
  else
    echo -e "  🤖 Бот: \033[31mнеактивен\033[0m"
  fi

  # Блок-лог
  if [ -f "$BLOCK_LOG" ]; then
    local log_size; log_size=$(du -h "$BLOCK_LOG" 2>/dev/null | awk '{print $1}')
    local log_lines; log_lines=$(wc -l < "$BLOCK_LOG" 2>/dev/null)
    echo "  📜 Лог блокировок: $log_lines записей ($log_size)"
  fi

  # Диск + память
  echo ""
  echo "  💾 Диск:"
  df -h / | tail -1 | awk '{print "     " $1 " " $2 " всего, " $3 " занято (" $5 ")"}'
  echo "  🧠 Память:"
  free -h | grep Mem | awk '{print "     " $2 " всего, " $3 " использовано"}'
  echo ""
}

# ═══════════════════════════════════════════════════════
# Docker-подменю
# ═══════════════════════════════════════════════════════

docker_menu() {
  if [ ! -f "$DOCKER_RULES" ] || ! command -v docker &>/dev/null; then
    error "Docker или docker_rules.sh не найден."
    return
  fi
  while true; do
    bash "$DOCKER_RULES" scan 2>/dev/null
    echo ""
    echo -e "\033[36m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[36m║              🐳 DOCKER-КОНТЕЙНЕРЫ               ║\033[0m"
    echo -e "\033[36m╠══════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[36m║\033[0m  1. 🔧 Автонастройка                             \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  2. ✋ Выбрать вручную                           \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  3. 📊 Статус                                    \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  4. 🔴 Отключить                                \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  5. 🗑  Очистка                                  \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  0. ◀️  Назад                                    \033[36m║\033[0m"
    echo -e "\033[36m╚══════════════════════════════════════════════════╝\033[0m"
    echo ""
    read -rp "  Выберите: " dc
    case $dc in
      1) bash "$DOCKER_RULES" auto-setup ;; 2) bash "$DOCKER_RULES" select ;;
      3) bash "$DOCKER_RULES" status ;; 4) bash "$DOCKER_RULES" disable ;;
      5) read -rp "  Удалить ВСЕ Docker-настройки? (y/n): " c; [[ "$c" =~ ^[yYдД] ]] && bash "$DOCKER_RULES" cleanup ;;
      0) break ;; *) error "Неверный выбор." ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════
# Главное меню
# ═══════════════════════════════════════════════════════

show_referral

while true; do
  echo ""
  echo -e "\033[36m╔══════════════════════════════════════════════════╗\033[0m"
  echo -e "\033[36m║       🛡  WhiteVPN v$VERSION — Управление            ║\033[0m"
  echo -e "\033[36m╠══════════════════════════════════════════════════╣\033[0m"

  local_ub=$(systemctl is-active unbound 2>/dev/null)
  local_ipt=$(iptables -C OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null && echo "active" || echo "inactive")
  if [ "$local_ub" = "active" ] && [ "$local_ipt" = "active" ]; then
    echo -e "\033[36m║\033[0m       Статус: \033[32m🟢 Защита ВКЛЮЧЕНА\033[0m               \033[36m║\033[0m"
  else
    echo -e "\033[36m║\033[0m       Статус: \033[31m🔴 Защита ВЫКЛЮЧЕНА\033[0m              \033[36m║\033[0m"
  fi

  echo -e "\033[36m║\033[0m                                                  \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m   1. 🔄 Обновить списки IP и доменов             \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m   2. 🟢 Включить защиту                          \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m   3. 🔴 Отключить защиту                         \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m   4. 🔁 Перезагрузить сервисы                    \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m   5. 📋 Белый список                             \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m   6. 🐳 Docker-контейнеры                        \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m   7. 🤖 Telegram-бот                             \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m   8. 📊 Статус сервера                           \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m   9. 📜 Лог блокировок                           \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  10. 🗑  Деинсталлировать                         \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m   0. 🚪 Выход                                    \033[36m║\033[0m"
  echo -e "\033[36m╚══════════════════════════════════════════════════╝\033[0m"
  echo ""

  read -rp "  Выберите действие: " choice

  case $choice in
    0) success "Выход."; break ;;
    1)
      log "Обновление списков..."
      "$VENV_PY" "$SYSTEM_DIR/blocked-ips/block_ips.py" 2>&1 | tee -a "$LOG_FILE"
      "$VENV_PY" "$SYSTEM_DIR/blocked-domains/block_domains.py" 2>&1 | tee -a "$LOG_FILE"
      success "Обновление завершено."
      ;;
    2) enable_blocking ;;
    3) disable_blocking ;;
    4)
      log "Перезапуск сервисов..."
      systemctl restart unbound 2>/dev/null
      # Переприменяем iptables
      iptables -D OUTPUT -m set --match-set blocked_ips dst -j LOG --log-prefix "WHITEVPN_BLOCK: " --log-level 4 2>/dev/null
      iptables -D OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null
      iptables -A OUTPUT -m set --match-set blocked_ips dst -j LOG --log-prefix "WHITEVPN_BLOCK: " --log-level 4
      iptables -A OUTPUT -m set --match-set blocked_ips dst -j DROP
      [ -f "$DOCKER_RULES" ] && bash "$DOCKER_RULES" apply-ipt 2>/dev/null
      success "Сервисы перезапущены."
      ;;
    5) whitelist_menu ;;
    6) docker_menu ;;
    7) manage_bot ;;
    8) show_status ;;
    9) block_log_menu ;;
    10)
      echo ""
      echo -e "\033[31m[!] Все данные проекта будут удалены!\033[0m"
      read -rp "  Вы уверены? (y/n): " confirm
      if [[ "$confirm" =~ ^[yYдД] ]]; then
        uninstall; break
      fi
      ;;
    *) error "Неверный выбор (0-10)." ;;
  esac
done