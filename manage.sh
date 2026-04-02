#!/bin/bash
VERSION="0.4"

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m[!] Запустите скрипт от root: sudo blockme\033[0m"
  exit 1
fi

# Настройка путей
SYSTEM_INSTALL_DIR="/opt/block-traffic"
TELEGRAM_BOT_DIR="$SYSTEM_INSTALL_DIR/telegram-bot"
LOG_DIR="$SYSTEM_INSTALL_DIR/logs"
LOG_FILE="$LOG_DIR/manage-$(date +%F_%H-%M-%S).log"
CONFIG_DIR="/etc/block-ips"
BOT_CONFIG_FILE="$CONFIG_DIR/bot_config.json"
PROJECT_DIR="$SYSTEM_INSTALL_DIR"
DOCKER_RULES="$SYSTEM_INSTALL_DIR/docker_rules.sh"
WHITELIST_DIR="$SYSTEM_INSTALL_DIR/whitelist"
WHITELIST_CONF="$WHITELIST_DIR/whitelist.conf"

# Загрузка конфигурации
if [ -f "$CONFIG_DIR/config" ]; then
  source "$CONFIG_DIR/config"
fi

# Создание директорий
mkdir -p "$LOG_DIR" "$WHITELIST_DIR"

# Функции для цветного вывода
log() {
  echo -e "\033[34m[INFO]\033[0m $1" | tee -a "$LOG_FILE"
}
success() {
  echo -e "\033[32m[OK]\033[0m $1" | tee -a "$LOG_FILE"
}
error() {
  echo -e "\033[31m[ОШИБКА]\033[0m $1" | tee -a "$LOG_FILE"
}
warn() {
  echo -e "\033[33m[!]\033[0m $1" | tee -a "$LOG_FILE"
}

# =======================================================================
# Реферальные ссылки
# =======================================================================

show_referral() {
  local last_ref_file="$LOG_DIR/.last_referral_shown"
  local now
  now=$(date +%s)
  local last_shown=0

  if [ -f "$last_ref_file" ]; then
    last_shown=$(cat "$last_ref_file" 2>/dev/null || echo 0)
  fi

  # Показываем только раз в 24 часа (86400 сек)
  if [ $((now - last_shown)) -lt 86400 ]; then
    return
  fi
  echo "$now" > "$last_ref_file"

  echo ""
  echo -e "\033[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
  echo -e "\033[1m💰 Партнёрские предложения:\033[0m"
  echo ""
  echo "🖥  VPS хостинг со скидкой до 60%:"
  echo "    https://vk.cc/ct29NQ"
  echo ""
  echo "    Промокоды:"
  echo "    OFF60       — 60% на первый месяц"
  echo "    antenka20   — 20% + 3% при оплате за 3 мес."
  echo "    antenka6    — 15% + 5% при оплате за 6 мес."
  echo ""
  echo "🌐  Бонус 15% по ссылке (24 часа):"
  echo "    https://vk.cc/cO0UaZ"
  echo -e "\033[33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
}

# =======================================================================
# Whitelist — функции
# =======================================================================

load_whitelist_status() {
  # Defaults
  WL_TELEGRAM=1
  WL_YOUTUBE=1
  WL_CUSTOM=1

  if [ -f "$WHITELIST_CONF" ]; then
    while IFS='=' read -r key val; do
      key=$(echo "$key" | tr -d ' ')
      val=$(echo "$val" | tr -d ' ')
      case "$key" in
        telegram) WL_TELEGRAM="$val" ;;
        youtube)  WL_YOUTUBE="$val" ;;
        custom)   WL_CUSTOM="$val" ;;
      esac
    done < <(grep -v '^#' "$WHITELIST_CONF" | grep '=')
  fi
}

save_whitelist_status() {
  cat > "$WHITELIST_CONF" << EOF
# WhiteVPN — Конфигурация белого списка
telegram=$WL_TELEGRAM
youtube=$WL_YOUTUBE
custom=$WL_CUSTOM
EOF
}

get_status_icon() {
  if [ "$1" = "1" ]; then
    echo -e "\033[32m✅ ВКЛ\033[0m"
  else
    echo -e "\033[31m❌ ВЫКЛ\033[0m"
  fi
}

count_custom_entries() {
  local custom_file="$WHITELIST_DIR/custom.txt"
  if [ -f "$custom_file" ]; then
    grep -v '^#' "$custom_file" | grep -v '^$' | wc -l
  else
    echo "0"
  fi
}

whitelist_menu() {
  while true; do
    load_whitelist_status
    local custom_count
    custom_count=$(count_custom_entries)

    echo ""
    echo -e "\033[36m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[36m║         📋 БЕЛЫЙ СПИСОК (ИСКЛЮЧЕНИЯ)            ║\033[0m"
    echo -e "\033[36m╠══════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[36m║\033[0m                                                  \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  1. Telegram       $(get_status_icon $WL_TELEGRAM)                     \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  2. YouTube        $(get_status_icon $WL_YOUTUBE)                     \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  3. Пользоват.     $(get_status_icon $WL_CUSTOM)  ($custom_count записей)    \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m                                                  \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  4. ➕ Добавить домены/IP в пользовательский     \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  5. ➖ Удалить запись из пользовательского        \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  6. 📄 Показать пользовательский список          \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  7. 🗑  Очистить пользовательский список         \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  0. ◀️  Назад                                     \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m                                                  \033[36m║\033[0m"
    echo -e "\033[36m╚══════════════════════════════════════════════════╝\033[0m"
    echo ""
    echo -e "\033[33m⚠️  ВНИМАНИЕ: Добавление доменов/IP в белый список\033[0m"
    echo -e "\033[33m   снижает уровень защиты. Ответственность за\033[0m"
    echo -e "\033[33m   использование белого списка полностью лежит\033[0m"
    echo -e "\033[33m   на пользователе.\033[0m"
    echo ""
    read -rp "  Выберите действие: " wl_choice

    case $wl_choice in
      1)
        if [ "$WL_TELEGRAM" = "1" ]; then
          WL_TELEGRAM=0
          warn "Telegram ВЫКЛЮЧЕН из белого списка"
        else
          WL_TELEGRAM=1
          success "Telegram ВКЛЮЧЁН в белый список"
        fi
        save_whitelist_status
        ;;
      2)
        if [ "$WL_YOUTUBE" = "1" ]; then
          WL_YOUTUBE=0
          warn "YouTube ВЫКЛЮЧЕН из белого списка"
        else
          WL_YOUTUBE=1
          success "YouTube ВКЛЮЧЁН в белый список"
        fi
        save_whitelist_status
        ;;
      3)
        if [ "$WL_CUSTOM" = "1" ]; then
          WL_CUSTOM=0
          warn "Пользовательский список ВЫКЛЮЧЕН"
        else
          WL_CUSTOM=1
          success "Пользовательский список ВКЛЮЧЁН"
        fi
        save_whitelist_status
        ;;
      4)
        echo ""
        echo -e "\033[33m⚠️  ВНИМАНИЕ: Вы добавляете домены/IP в белый список.\033[0m"
        echo -e "\033[33m   Это исключит их из блокировки. Ответственность за\033[0m"
        echo -e "\033[33m   последствия полностью лежит на вас.\033[0m"
        echo ""
        echo "Введите домены и/или IP, каждый с новой строки."
        echo "Для завершения введите пустую строку:"
        echo ""

        local custom_file="$WHITELIST_DIR/custom.txt"
        [ ! -f "$custom_file" ] && echo "# WhiteVPN — Белый список: Пользовательский" > "$custom_file"

        local added=0
        while true; do
          read -rp "  > " entry
          if [ -z "$entry" ]; then
            break
          fi
          # Проверка на дубликаты
          if grep -qxF "$entry" "$custom_file" 2>/dev/null; then
            warn "  '$entry' уже в списке, пропускаем"
          else
            echo "$entry" >> "$custom_file"
            success "  Добавлено: $entry"
            ((added++))
          fi
        done
        if [ "$added" -gt 0 ]; then
          success "Добавлено $added записей."
          echo ""
          warn "Не забудьте обновить списки блокировки (пункт 1 в главном меню),"
          warn "чтобы изменения вступили в силу."
        else
          log "Ничего не добавлено."
        fi
        ;;
      5)
        # Удаление конкретной записи
        echo ""
        local custom_file="$WHITELIST_DIR/custom.txt"
        if [ -f "$custom_file" ]; then
          local entries
          entries=$(grep -v '^#' "$custom_file" | grep -v '^$')
          if [ -n "$entries" ]; then
            echo -e "\033[1m➖ Удаление записи:\033[0m"
            echo "$entries" | nl -ba
            echo ""
            read -rp "  Введите номер для удаления (0 = отмена): " del_num
            if [ "$del_num" != "0" ] && [ -n "$del_num" ]; then
              local target
              target=$(echo "$entries" | sed -n "${del_num}p")
              if [ -n "$target" ]; then
                # Удаляем строку из файла
                grep -vxF "$target" "$custom_file" > "${custom_file}.tmp"
                mv "${custom_file}.tmp" "$custom_file"
                success "Удалено: $target"
                warn "Обновите списки (пункт 1), чтобы изменения вступили в силу."
              else
                error "Неверный номер."
              fi
            fi
          else
            echo "Пользовательский список пуст."
          fi
        else
          echo "Пользовательский список пуст."
        fi
        ;;
      6)
        echo ""
        local custom_file="$WHITELIST_DIR/custom.txt"
        if [ -f "$custom_file" ]; then
          local entries
          entries=$(grep -v '^#' "$custom_file" | grep -v '^$')
          if [ -n "$entries" ]; then
            echo -e "\033[1m📄 Пользовательский белый список:\033[0m"
            echo "$entries" | nl -ba
          else
            echo "Пользовательский список пуст."
          fi
        else
          echo "Пользовательский список пуст."
        fi
        echo ""
        ;;
      7)
        echo ""
        read -rp "  Очистить весь пользовательский список? (y/n): " confirm
        if [[ "$confirm" =~ ^[yYдД] ]]; then
          echo "# WhiteVPN — Белый список: Пользовательский" > "$WHITELIST_DIR/custom.txt"
          success "Пользовательский список очищен."
        fi
        ;;
      0)
        break
        ;;
      *)
        error "Неверный выбор."
        ;;
    esac
  done
}

# =======================================================================
# Управление Telegram-ботом
# =======================================================================

manage_bot() {
  log "Управление Telegram-ботом..."

  if ! command -v python3 &>/dev/null; then
    error "Python3 не установлен."
    return 1
  fi

  PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}' | cut -d'.' -f1,2)
  VENV_PACKAGE="python${PYTHON_VERSION}-venv"

  if systemctl list-units --full -all | grep -Fq "block-ips-bot.service"; then
    log "Telegram-бот уже установлен."
    echo "Хотите обновить токен и ID администратора?"
    read -rp "  (y/n): " update_bot
    if [[ "$update_bot" =~ ^[yYдД] ]]; then
      echo ""
      echo "Получите токен у @BotFather в Telegram"
      read -rp "  Введите токен бота: " BOT_TOKEN
      echo "Узнайте свой ID у @userinfobot в Telegram"
      read -rp "  Введите Telegram ID администратора: " ADMIN_ID

      sudo bash -c "cat > $BOT_CONFIG_FILE << EOF
{\"BOT_TOKEN\": \"$BOT_TOKEN\", \"ADMIN_ID\": $ADMIN_ID}
EOF"
      sudo chmod 600 "$BOT_CONFIG_FILE"
      sudo systemctl restart block-ips-bot.service
      success "Бот обновлён и перезапущен."
    fi
    return 0
  fi

  log "Установка Telegram-бота..."

  sudo apt install -y -qq "$VENV_PACKAGE" >> "$LOG_FILE" 2>&1
  sudo mkdir -p "$TELEGRAM_BOT_DIR"

  if [ -f "$SYSTEM_INSTALL_DIR/bot.py" ]; then
    sudo cp "$SYSTEM_INSTALL_DIR/bot.py" "$TELEGRAM_BOT_DIR/bot.py"
  else
    error "Файл bot.py не найден в $SYSTEM_INSTALL_DIR"
    return 1
  fi

  python3 -m venv "$TELEGRAM_BOT_DIR/venv" >> "$LOG_FILE" 2>&1
  "$TELEGRAM_BOT_DIR/venv/bin/pip" install -q aiogram==3.5.0 >> "$LOG_FILE" 2>&1

  echo ""
  echo "Получите токен у @BotFather в Telegram"
  read -rp "  Введите токен бота: " BOT_TOKEN
  echo "Узнайте свой ID у @userinfobot в Telegram"
  read -rp "  Введите Telegram ID администратора: " ADMIN_ID

  sudo mkdir -p "$CONFIG_DIR"
  sudo bash -c "cat > $BOT_CONFIG_FILE << EOF
{\"BOT_TOKEN\": \"$BOT_TOKEN\", \"ADMIN_ID\": $ADMIN_ID}
EOF"
  sudo chmod 600 "$BOT_CONFIG_FILE"

  cat << EOF | sudo tee /etc/systemd/system/block-ips-bot.service > /dev/null
[Unit]
Description=WhiteVPN Telegram Bot
After=network.target

[Service]
Type=simple
ExecStart=$TELEGRAM_BOT_DIR/venv/bin/python3 $TELEGRAM_BOT_DIR/bot.py
WorkingDirectory=$TELEGRAM_BOT_DIR
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable block-ips-bot.service >> "$LOG_FILE" 2>&1
  sudo systemctl start block-ips-bot.service >> "$LOG_FILE" 2>&1

  if systemctl is-active --quiet block-ips-bot.service; then
    success "Telegram-бот установлен и запущен."
  else
    error "Не удалось запустить бота. Проверьте: sudo systemctl status block-ips-bot.service"
  fi
}

# =======================================================================
# Деинсталляция
# =======================================================================

uninstall() {
  log "Остановка и отключение сервисов..."
  systemctl stop block-ips.service 2>/dev/null
  systemctl disable block-ips.service 2>/dev/null
  systemctl stop block-domains.service 2>/dev/null
  systemctl disable block-domains.service 2>/dev/null
  systemctl stop block-ips-bot.service 2>/dev/null
  systemctl disable block-ips-bot.service 2>/dev/null
  systemctl stop unbound 2>/dev/null
  systemctl disable unbound 2>/dev/null

  log "Удаление iptables правила..."
  iptables -D OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null

  if [ -f "$DOCKER_RULES" ]; then
    log "Очистка Docker-блокировки..."
    bash "$DOCKER_RULES" cleanup 2>&1
  fi

  log "Удаление файлов сервисов..."
  rm -f /etc/systemd/system/block-ips.service
  rm -f /etc/systemd/system/block-ips.timer
  rm -f /etc/systemd/system/block-domains.service
  rm -f /etc/systemd/system/block-domains.timer
  rm -f /etc/systemd/system/block-ips-bot.service
  rm -f /etc/systemd/system/docker-block-restore.service
  systemctl daemon-reload

  log "Удаление команды blockme..."
  rm -f /usr/local/bin/blockme

  log "Удаление директории проекта $SYSTEM_INSTALL_DIR..."
  rm -rf "$SYSTEM_INSTALL_DIR"

  log "Удаление конфигурации..."
  rm -rf /etc/block-ips

  log "Сброс DNS на 8.8.8.8..."
  echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf > /dev/null

  success "Деинсталляция завершена."
}

# =======================================================================
# Включение / Отключение защиты
# =======================================================================

enable_blocking() {
  log "Включение защиты..."
  echo ""

  log "DNS > 127.0.0.1"
  echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf > /dev/null
  success "DNS настроен"

  log "Запуск Unbound..."
  systemctl start unbound
  success "Unbound запущен"

  log "iptables правило OUTPUT..."
  iptables -C OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null || \
    iptables -A OUTPUT -m set --match-set blocked_ips dst -j DROP
  success "iptables правило применено"

  systemctl start block-ips.service 2>/dev/null
  systemctl start block-domains.service 2>/dev/null

  if [ -f "$DOCKER_RULES" ] && command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    if [ -f /etc/block-ips/docker_containers.conf ]; then
      bash "$DOCKER_RULES" enable 2>&1
    fi
    bash "$DOCKER_RULES" brief-status 2>&1
  fi

  # Показать статус whitelist
  load_whitelist_status
  echo ""
  echo -e "\033[36m📋 Белый список:\033[0m"
  echo -e "   Telegram:        $(get_status_icon $WL_TELEGRAM)"
  echo -e "   YouTube:         $(get_status_icon $WL_YOUTUBE)"
  echo -e "   Пользовательский: $(get_status_icon $WL_CUSTOM) ($(count_custom_entries) записей)"

  echo ""
  success "Защита включена."
}

disable_blocking() {
  log "Отключение защиты..."

  iptables -D OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null
  systemctl stop unbound
  systemctl stop block-ips.service 2>/dev/null
  systemctl stop block-domains.service 2>/dev/null
  echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf > /dev/null

  if [ -f "$DOCKER_RULES" ]; then
    bash "$DOCKER_RULES" disable 2>&1
  fi

  success "Защита отключена."
}

# =======================================================================
# Статус защиты
# =======================================================================

show_status() {
  echo ""
  echo -e "\033[1m📊 Состояние сервера:\033[0m"
  echo ""

  # Uptime
  local uptime_s
  uptime_s=$(awk '{print int($1)}' /proc/uptime)
  local days=$((uptime_s / 86400))
  local hours=$(( (uptime_s % 86400) / 3600 ))
  local mins=$(( (uptime_s % 3600) / 60 ))
  echo -e "  ⏱  Uptime: ${days}д ${hours}ч ${mins}м"

  # Protection
  local unbound_active iptables_active
  systemctl is-active --quiet unbound && unbound_active=1 || unbound_active=0
  iptables -C OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null && iptables_active=1 || iptables_active=0

  if [ "$unbound_active" = "1" ] && [ "$iptables_active" = "1" ]; then
    echo -e "  🟢 Защита: \033[32mВКЛЮЧЕНА\033[0m"
  else
    echo -e "  🔴 Защита: \033[31mВЫКЛЮЧЕНА\033[0m"
  fi

  # ipset count
  local ipset_count
  ipset_count=$(ipset list blocked_ips -t 2>/dev/null | grep "Number of entries" | awk -F: '{print $2}' | tr -d ' ')
  [ -n "$ipset_count" ] && echo "  📊 Заблокировано IP: $ipset_count" || echo "  📊 ipset: не найден"

  # Whitelist
  load_whitelist_status
  echo ""
  echo -e "  \033[36m📋 Белый список:\033[0m"
  echo -e "     Telegram:        $(get_status_icon $WL_TELEGRAM)"
  echo -e "     YouTube:         $(get_status_icon $WL_YOUTUBE)"
  echo -e "     Пользовательский: $(get_status_icon $WL_CUSTOM) ($(count_custom_entries) записей)"

  # Disk
  echo ""
  echo "  💾 Диск:"
  df -h / | tail -1 | awk '{print "     " $1 " " $2 " всего, " $3 " занято (" $5 ")"}'

  # Memory
  echo "  🧠 Память:"
  free -h | grep Mem | awk '{print "     " $2 " всего, " $3 " использовано"}'
  echo ""
}

# =======================================================================
# Docker-подменю
# =======================================================================

docker_menu() {
  if [ ! -f "$DOCKER_RULES" ] || ! command -v docker &>/dev/null; then
    error "Docker или docker_rules.sh не найден."
    return
  fi

  while true; do
    bash "$DOCKER_RULES" scan

    echo ""
    echo -e "\033[36m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[36m║              🐳 DOCKER-КОНТЕЙНЕРЫ               ║\033[0m"
    echo -e "\033[36m╠══════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[36m║\033[0m  1. 🔧 Автонастройка (рекомендуется)             \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  2. ✋ Выбрать контейнеры вручную               \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  3. 📊 Подробный статус                         \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  4. 🔴 Отключить Docker-блокировку              \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  5. 🗑  Полная очистка                           \033[36m║\033[0m"
    echo -e "\033[36m║\033[0m  0. ◀️  Назад                                     \033[36m║\033[0m"
    echo -e "\033[36m╚══════════════════════════════════════════════════╝\033[0m"
    echo ""
    read -rp "  Выберите действие: " dc

    case $dc in
      1) bash "$DOCKER_RULES" auto-setup ;;
      2)
        bash "$DOCKER_RULES" select
        if [ $? -eq 0 ]; then
          read -rp "  Включить блокировку для выбранных контейнеров? (y/n): " apply
          [[ "$apply" =~ ^[yYдД] ]] && bash "$DOCKER_RULES" enable
        fi
        ;;
      3) bash "$DOCKER_RULES" status ;;
      4) bash "$DOCKER_RULES" disable ;;
      5)
        echo ""
        warn "Будут удалены ВСЕ Docker-настройки блокировки"
        read -rp "  Вы уверены? (y/n): " confirm
        [[ "$confirm" =~ ^[yYдД] ]] && bash "$DOCKER_RULES" cleanup
        ;;
      0) break ;;
      *) error "Неверный выбор." ;;
    esac
  done
}

# =======================================================================
# Главное меню
# =======================================================================

# Показать рефералку при старте
show_referral

while true; do
  echo ""
  echo -e "\033[36m╔══════════════════════════════════════════════════╗\033[0m"
  echo -e "\033[36m║       🛡  WhiteVPN v$VERSION — Управление            ║\033[0m"
  echo -e "\033[36m╠══════════════════════════════════════════════════╣\033[0m"

  # Показать текущий статус защиты в меню
  local_unbound=$(systemctl is-active unbound 2>/dev/null)
  local_ipt=$(iptables -C OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null && echo "active" || echo "inactive")
  if [ "$local_unbound" = "active" ] && [ "$local_ipt" = "active" ]; then
    echo -e "\033[36m║\033[0m       Статус: \033[32m🟢 Защита ВКЛЮЧЕНА\033[0m               \033[36m║\033[0m"
  else
    echo -e "\033[36m║\033[0m       Статус: \033[31m🔴 Защита ВЫКЛЮЧЕНА\033[0m              \033[36m║\033[0m"
  fi

  echo -e "\033[36m║\033[0m                                                  \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  1. 🔄 Обновить списки IP и доменов              \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  2. 🟢 Включить защиту                           \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  3. 🔴 Отключить защиту                          \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  4. 🔁 Перезагрузить сервисы                     \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  5. 📋 Белый список (исключения)                 \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  6. 🐳 Docker-контейнеры                         \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  7. 🤖 Telegram-бот                              \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  8. 📊 Статус сервера                            \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  9. 🗑  Деинсталлировать                          \033[36m║\033[0m"
  echo -e "\033[36m║\033[0m  0. 🚪 Выход                                     \033[36m║\033[0m"
  echo -e "\033[36m╚══════════════════════════════════════════════════╝\033[0m"
  echo ""

  read -rp "  Выберите действие: " choice

  case $choice in
    0)
      success "Выход."
      break
      ;;
    1)
      log "Обновление списков IP и доменов..."
      "$SYSTEM_INSTALL_DIR/venv/bin/python3" "$SYSTEM_INSTALL_DIR/blocked-ips/block_ips.py" 2>&1 | tee -a "$LOG_FILE"
      "$SYSTEM_INSTALL_DIR/venv/bin/python3" "$SYSTEM_INSTALL_DIR/blocked-domains/block_domains.py" 2>&1 | tee -a "$LOG_FILE"
      success "Обновление завершено."
      ;;
    2)
      enable_blocking
      ;;
    3)
      disable_blocking
      ;;
    4)
      log "Перезапуск сервисов..."
      systemctl restart unbound
      iptables -D OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null
      iptables -A OUTPUT -m set --match-set blocked_ips dst -j DROP
      if [ -f "$DOCKER_RULES" ] && [ -f /etc/block-ips/docker_containers.conf ]; then
        bash "$DOCKER_RULES" apply-ipt 2>&1
      fi
      success "Сервисы перезапущены."
      ;;
    5)
      whitelist_menu
      ;;
    6)
      docker_menu
      ;;
    7)
      manage_bot
      ;;
    8)
      show_status
      ;;
    9)
      echo ""
      echo -e "\033[31m[!] Все данные проекта будут удалены!\033[0m"
      read -rp "  Вы уверены? (y/n): " confirm
      if [[ "$confirm" =~ ^[yYдД] ]]; then
        uninstall
        break
      fi
      ;;
    *)
      error "Неверный выбор. Выберите 0 - 9."
      ;;
  esac
done
