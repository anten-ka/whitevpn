#!/bin/bash

# Настройка путей и логирования
SYSTEM_INSTALL_DIR="/opt/block-traffic"
TELEGRAM_BOT_DIR="$SYSTEM_INSTALL_DIR/telegram-bot"
LOG_DIR="$SYSTEM_INSTALL_DIR/logs"
LOG_FILE="$LOG_DIR/install-bot-$(date +%F_%H-%M-%S).log"
CONFIG_DIR="/etc/block-ips"
BOT_CONFIG_FILE="$CONFIG_DIR/bot_config.json"
PROJECT_DIR="$SYSTEM_INSTALL_DIR"
DOCKER_RULES="$SYSTEM_INSTALL_DIR/docker_rules.sh"

# Загрузка конфигурации
if [ -f "$CONFIG_DIR/config" ]; then
  source "$CONFIG_DIR/config"
fi

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

# ═══════════════════════════════════════════════════════════════════════
# Управление Telegram-ботом
# ═══════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════
# Деинсталляция
# ═══════════════════════════════════════════════════════════════════════

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

  # Очистка Docker-блокировки
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
  echo 'nameserver 8.8.8.8' | tee /etc/resolv.conf > /dev/null

  success "Деинсталляция завершена."
}

# ═══════════════════════════════════════════════════════════════════════
# Включение / Отключение защиты
# ═══════════════════════════════════════════════════════════════════════

enable_blocking() {
  log "Включение защиты..."
  echo ""

  log "DNS → 127.0.0.1"
  echo 'nameserver 127.0.0.1' | tee /etc/resolv.conf > /dev/null
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

  # Docker: автосканирование и показ статуса
  if [ -f "$DOCKER_RULES" ] && command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    # Включаем Docker-блокировку если контейнеры настроены
    if [ -f /etc/block-ips/docker_containers.conf ]; then
      bash "$DOCKER_RULES" enable 2>&1
    fi
    # Показываем краткий статус
    bash "$DOCKER_RULES" brief-status 2>&1
  fi

  echo ""
  success "Защита включена."
}

disable_blocking() {
  log "Отключение защиты..."

  iptables -D OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null
  systemctl stop unbound
  systemctl stop block-ips.service 2>/dev/null
  systemctl stop block-domains.service 2>/dev/null
  echo 'nameserver 8.8.8.8' | tee /etc/resolv.conf > /dev/null

  if [ -f "$DOCKER_RULES" ]; then
    bash "$DOCKER_RULES" disable 2>&1
  fi

  success "Защита отключена."
}

# ═══════════════════════════════════════════════════════════════════════
# Docker-подменю
# ═══════════════════════════════════════════════════════════════════════

docker_menu() {
  if [ ! -f "$DOCKER_RULES" ] || ! command -v docker &>/dev/null; then
    error "Docker или docker_rules.sh не найден."
    return
  fi

  while true; do
    # Автосканирование при входе в меню
    bash "$DOCKER_RULES" scan

    echo ""
    echo -e "\033[36m══════ Docker-контейнеры ════════════════════════════\033[0m"
    echo "  1. Автонастройка защиты (рекомендуется)"
    echo "  2. Выбрать контейнеры вручную"
    echo "  3. Подробный статус"
    echo "  4. Отключить Docker-блокировку"
    echo "  5. Полная очистка Docker-настроек"
    echo "  0. Назад"
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
        echo -e "\033[33m[!]\033[0m Будут удалены ВСЕ Docker-настройки блокировки:"
        echo "    - iptables правила DOCKER-USER"
        echo "    - Unbound access-control для Docker"
        echo "    - DNS настройки Docker-демона"
        echo "    - Конфигурация выбранных контейнеров"
        echo ""
        read -rp "  Вы уверены? (y/n): " confirm
        [[ "$confirm" =~ ^[yYдД] ]] && bash "$DOCKER_RULES" cleanup
        ;;
      0) break ;;
      *) error "Неверный выбор." ;;
    esac
  done
}

# ═══════════════════════════════════════════════════════════════════════
# Главное меню
# ═══════════════════════════════════════════════════════════════════════

while true; do
  echo ""
  echo -e "\033[1m══════════════════════════════════════════\033[0m"
  echo -e "\033[1m       WhiteVPN — Меню управления\033[0m"
  echo -e "\033[1m══════════════════════════════════════════\033[0m"
  echo "  1. Обновить списки IP и доменов"
  echo "  2. Включить защиту"
  echo "  3. Отключить защиту"
  echo "  4. Перезагрузить сервисы"
  echo "  5. Docker-контейнеры"
  echo "  6. Telegram-бот"
  echo "  7. Деинсталлировать"
  echo "  0. Выход"
  echo -e "\033[1m══════════════════════════════════════════\033[0m"

  echo -e "\nБольшой выбор стран, хорошее железо, быстрая поддержка,"
  echo "VPS хостинг, который работает со скидками до -60%:"
  echo "==============================================================="
  echo "https://vk.cc/ct29NQ"
  echo ""
  echo "OFF60         для 60% скидки на первый месяц"
  echo "antenka20     буст скидка на 20% + 3% при оплате за 3 месяца"
  echo "antenka6      буст скидка на 15% + 5% при оплате 6 месяцев"
  echo "==============================================================="
  echo "https://vk.cc/cO0UaZ"
  echo ""
  echo "(бонус 15% по ссылке в течении 24 часов)"
  echo "==============================================================="

  read -rp "  Выберите действие: " choice

  case $choice in
    0)
      success "Выход."
      break
      ;;
    1)
      log "Обновление списков IP и доменов..."
      "$INSTALL_DIR/venv/bin/python3" "$INSTALL_DIR/block_ips.py" 2>&1 | tee -a "$LOG_FILE"
      "$INSTALL_DIR/venv/bin/python3" "$INSTALL_DIR/blocked-domains/block_domains.py" 2>&1 | tee -a "$LOG_FILE"
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
      docker_menu
      ;;
    6)
      manage_bot
      ;;
    7)
      echo ""
      echo -e "\033[31m[!] Все данные проекта будут удалены!\033[0m"
      read -rp "  Вы уверены? (y/n): " confirm
      if [[ "$confirm" =~ ^[yYдД] ]]; then
        uninstall
        break
      fi
      ;;
    *)
      error "Неверный выбор. Выберите 0 - 7."
      ;;
  esac
done
