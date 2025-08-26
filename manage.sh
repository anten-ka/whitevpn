#!/bin/bash

# Загрузка конфигурации
if [ -f /etc/block-ips/config ]; then
  source /etc/block-ips/config
else
  echo -e "\033[31m[ERROR]\033[0m Файл конфигурации /etc/block-ips/config не найден."
  exit 1
fi

# Проверка, существует ли директория blocked-ips
if [ ! -d "$INSTALL_DIR" ]; then
  echo -e "\033[31m[ERROR]\033[0m Директория $INSTALL_DIR не существует."
  exit 1
fi

# Определение путей для Telegram-бота
SYSTEM_INSTALL_DIR="/opt/block-traffic"
TELEGRAM_BOT_DIR="$SYSTEM_INSTALL_DIR/telegram-bot"
LOG_DIR="$SYSTEM_INSTALL_DIR/logs"
LOG_FILE="$LOG_DIR/install-bot-$(date +%F_%H-%M-%S).log"
CONFIG_DIR="/etc/block-ips"
BOT_CONFIG_FILE="$CONFIG_DIR/bot_config.json"
PROJECT_DIR="$SYSTEM_INSTALL_DIR"

# Функции для цветного вывода
log() { echo -e "\033[34m[INFO]\033[0m $1"; }
success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; }

# Функция для логирования в файл
log_to_file() { echo -e "$1" | tee -a "$LOG_FILE"; }

# Функция управления Telegram-ботом
manage_bot() {
  # Создание директории логов, если не существует
  if [ ! -d "$LOG_DIR" ]; then
    log "Создание директории для логов: $LOG_DIR"
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    log_to_file "[INFO] Создание директории для логов: $LOG_DIR"
  fi

  # Проверка, установлен ли бот
  if systemctl list-units --full -all | grep -Fq "block-ips-bot.service"; then
    log "Telegram-бот уже установлен. Обновление конфигурации..."
    log_to_file "[INFO] Telegram-бот уже установлен. Обновление конфигурации..."
    # Инструкция перед запросом токена и Telegram ID
    echo -e "\nДля подключения telegram бота и удобного управления скриптом \"белый VPN\", нужно 2 переменных:"
    echo "1) API ключ бота, получить можно только в официальном боте https://t.me/BotFather"
    echo "Создайте бота, придумайте уникальное название что бы в конце названия был \"bot\" и запишите приватный API ключ."
    echo ""
    echo "2) Уникальный идентификатор пользователя, который получит права администратора для управления ботом. Узнать свой id можно тут: https://t.me/userinfobot"
    echo ""
    echo "После привязки 2х переменных вам станет доступно управление защитой \"белого VPN\" в боте, которого вы создали. Найти бота можете в поисковой строке по придуманному вами названию. Приятного пользования."
    echo ""
    # Запрос токена и Telegram ID
    read -p "Введите токен Telegram-бота: " BOT_TOKEN
    read -p "Введите Telegram ID администратора: " ADMIN_ID
    if [ -z "$BOT_TOKEN" ] || [ -z "$ADMIN_ID" ]; then
      error "Токен или Telegram ID не указаны."
      log_to_file "[ERROR] Токен или Telegram ID не указаны."
      return 1
    fi

    # Обновление конфигурационного файла
    log "Обновление конфигурации в $BOT_CONFIG_FILE..."
    log_to_file "[INFO] Обновление конфигурации в $BOT_CONFIG_FILE..."
    mkdir -p "$CONFIG_DIR"
    cat << EOF | tee "$BOT_CONFIG_FILE" > /dev/null
{
    "BOT_TOKEN": "$BOT_TOKEN",
    "ADMIN_ID": $ADMIN_ID
}
EOF
    if [ $? -ne 0 ]; then
      error "Не удалось обновить $BOT_CONFIG_FILE."
      log_to_file "[ERROR] Не удалось обновить $BOT_CONFIG_FILE."
      return 1
    fi
    chmod 600 "$BOT_CONFIG_FILE"

    # Перезапуск сервиса
    log "Перезапуск сервиса block-ips-bot..."
    log_to_file "[INFO] Перезапуск сервиса block-ips-bot..."
    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl restart block-ips-bot.service >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
      error "Не удалось перезапустить сервис block-ips-bot.service."
      log_to_file "[ERROR] Не удалось перезапустить сервис block-ips-bot.service."
      systemctl status block-ips-bot.service --no-pager | tee -a "$LOG_FILE"
      return 1
    fi
    if systemctl is-active --quiet block-ips-bot.service; then
      success "Сервис block-ips-bot.service успешно перезапущен."
      log_to_file "[SUCCESS] Сервис block-ips-bot.service успешно перезапущен."
    else
      error "Сервис block-ips-bot.service не активен."
      log_to_file "[ERROR] Сервис block-ips-bot.service не активен."
      systemctl status block-ips-bot.service --no-pager | tee -a "$LOG_FILE"
      return 1
    fi
  else
    log "Telegram-бот не установлен. Начало установки..."
    log_to_file "[INFO] Начало установки Telegram-бота..."

    # Проверка версии Python
    log "Проверка версии Python..."
    log_to_file "[INFO] Проверка версии Python..."
    PYTHON_VERSION=$(python3 --version 2>> "$LOG_FILE" | awk '{print $2}' | cut -d'.' -f1,2)
    if [ -z "$PYTHON_VERSION" ]; then
      error "Не удалось определить версию Python."
      log_to_file "[ERROR] Не удалось определить версию Python."
      return 1
    fi
    log "Обнаружена версия Python: $PYTHON_VERSION"
    log_to_file "[INFO] Обнаружена версия Python: $PYTHON_VERSION"

    # Проверка и установка пакета python3-venv
    VENV_PACKAGE="python${PYTHON_VERSION}-venv"
    log "Установка пакета $VENV_PACKAGE..."
    log_to_file "[INFO] Установка пакета $VENV_PACKAGE..."
    apt update -qq >> "$LOG_FILE" 2>&1
    apt install -y -qq "$VENV_PACKAGE" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
      error "Не удалось установить $VENV_PACKAGE."
      log_to_file "[ERROR] Не удалось установить $VENV_PACKAGE."
      return 1
    fi

    # Проверка доступности python3 -m venv
    log "Проверка модуля venv..."
    log_to_file "[INFO] Проверка модуля venv..."
    python3 -m venv --help >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
      error "Модуль venv недоступен для Python $PYTHON_VERSION."
      log_to_file "[ERROR] Модуль venv недоступен для Python $PYTHON_VERSION."
      return 1
    fi

    # Создание директории для бота
    log "Создание директории для бота: $TELEGRAM_BOT_DIR..."
    log_to_file "[INFO] Создание директории для бота: $TELEGRAM_BOT_DIR..."
    mkdir -p "$TELEGRAM_BOT_DIR"
    chmod 755 "$TELEGRAM_BOT_DIR"

    # Копирование bot.py
    log "Копирование bot.py в $TELEGRAM_BOT_DIR..."
    log_to_file "[INFO] Копирование bot.py в $TELEGRAM_BOT_DIR..."
    if [ -f "$PROJECT_DIR/bot.py" ]; then
      cp "$PROJECT_DIR/bot.py" "$TELEGRAM_BOT_DIR/bot.py" 2>> "$LOG_FILE"
      if [ $? -ne 0 ]; then
        error "Не удалось скопировать bot.py."
        log_to_file "[ERROR] Не удалось скопировать bot.py."
        return 1
      fi
    else
      error "Файл bot.py не найден в $PROJECT_DIR."
      log_to_file "[ERROR] Файл bot.py не найден в $PROJECT_DIR."
      return 1
    fi
    chmod 644 "$TELEGRAM_BOT_DIR/bot.py"

    # Создание виртуального окружения
    log "Создание виртуального окружения в $TELEGRAM_BOT_DIR/venv..."
    log_to_file "[INFO] Создание виртуального окружения в $TELEGRAM_BOT_DIR/venv..."
    cd "$TELEGRAM_BOT_DIR" || { error "Не удалось перейти в $TELEGRAM_BOT_DIR"; log_to_file "[ERROR] Не удалось перейти в $TELEGRAM_BOT_DIR"; return 1; }
    timeout 60 python3 -m venv venv >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
      error "Не удалось создать виртуальное окружение."
      log_to_file "[ERROR] Не удалось создать виртуальное окружение."
      return 1
    fi

    # Проверка существования виртуального окружения
    if [ ! -d "$TELEGRAM_BOT_DIR/venv/bin" ]; then
      error "Виртуальное окружение не создано."
      log_to_file "[ERROR] Виртуальное окружение не создано."
      return 1
    fi

    # Установка aiogram
    log "Установка aiogram==3.5.0 в виртуальном окружении..."
    log_to_file "[INFO] Установка aiogram==3.5.0 в виртуальном окружении..."
    source "$TELEGRAM_BOT_DIR/venv/bin/activate"
    pip install -q aiogram==3.5.0 >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
      error "Не удалось установить aiogram==3.5.0."
      log_to_file "[ERROR] Не удалось установить aiogram==3.5.0."
      return 1
    fi

    # Инструкция перед запросом токена и Telegram ID
    echo -e "\nДля подключения telegram бота и удобного управления скриптом \"белый VPN\", нужно 2 переменных:"
    echo "1) API ключ бота, получить можно только в официальном боте https://t.me/BotFather"
    echo "Создайте бота, придумайте уникальное название что бы в конце названия был \"bot\" и запишите приватный API ключ."
    echo ""
    echo "2) Уникальный идентификатор пользователя, который получит права администратора для управления ботом. Узнать свой id можно тут: https://t.me/userinfobot"
    echo ""
    echo "После привязки 2х переменных вам станет доступно управление защитой \"белого VPN\" в боте, которого вы создали. Найти бота можете в поисковой строке по придуманному вами названию. Приятного пользования."
    echo ""
    # Запрос токена и Telegram ID
    read -p "Введите токен Telegram-бота: " BOT_TOKEN
    read -p "Введите Telegram ID администратора: " ADMIN_ID
    if [ -z "$BOT_TOKEN" ] || [ -z "$ADMIN_ID" ]; then
      error "Токен или Telegram ID не указаны."
      log_to_file "[ERROR] Токен или Telegram ID не указаны."
      return 1
    fi

    # Создание конфигурационного файла
    log "Создание конфигурации в $BOT_CONFIG_FILE..."
    log_to_file "[INFO] Создание конфигурации в $BOT_CONFIG_FILE..."
    mkdir -p "$CONFIG_DIR"
    cat << EOF | tee "$BOT_CONFIG_FILE" > /dev/null
{
    "BOT_TOKEN": "$BOT_TOKEN",
    "ADMIN_ID": $ADMIN_ID
}
EOF
    if [ $? -ne 0 ]; then
      error "Не удалось создать $BOT_CONFIG_FILE."
      log_to_file "[ERROR] Не удалось создать $BOT_CONFIG_FILE."
      return 1
    fi
    chmod 600 "$BOT_CONFIG_FILE"

    # Создание systemd-сервиса
    log "Настройка systemd-сервиса block-ips-bot..."
    log_to_file "[INFO] Настройка systemd-сервиса block-ips-bot..."
    cat << EOF | tee /etc/systemd/system/block-ips-bot.service > /dev/null
[Unit]
Description=Telegram Bot for Block IPs
After=network.target

[Service]
Type=simple
ExecStart=$TELEGRAM_BOT_DIR/venv/bin/python3 $TELEGRAM_BOT_DIR/bot.py
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
    if [ $? -ne 0 ]; then
      error "Не удалось создать сервис block-ips-bot.service."
      log_to_file "[ERROR] Не удалось создать сервис block-ips-bot.service."
      return 1
    fi

    # Запуск сервиса
    log "Запуск и включение сервиса block-ips-bot..."
    log_to_file "[INFO] Запуск и включение сервиса block-ips-bot..."
    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable block-ips-bot.service >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
      error "Не удалось включить сервис block-ips-bot.service."
      log_to_file "[ERROR] Не удалось включить сервис block-ips-bot.service."
      return 1
    fi

    systemctl start block-ips-bot.service >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
      error "Не удалось запустить сервис block-ips-bot.service."
      log_to_file "[ERROR] Не удалось запустить сервис block-ips-bot.service."
      systemctl status block-ips-bot.service --no-pager | tee -a "$LOG_FILE"
      return 1
    fi

    # Проверка статуса сервиса
    log "Проверка статуса сервиса..."
    log_to_file "[INFO] Проверка статуса сервиса..."
    if systemctl is-active --quiet block-ips-bot.service; then
      success "Сервис block-ips-bot.service активен и работает."
      log_to_file "[SUCCESS] Сервис block-ips-bot.service активен и работает."
    else
      error "Сервис block-ips-bot.service не активен."
      log_to_file "[ERROR] Сервис block-ips-bot.service не активен."
      systemctl status block-ips-bot.service --no-pager | tee -a "$LOG_FILE"
      return 1
    fi
  fi
  success "Управление Telegram-ботом завершено."
  log_to_file "[SUCCESS] Управление Telegram-ботом завершено."
}

# Функция деинсталляции
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

  log "Удаление файлов сервисов..."
  rm -f /etc/systemd/system/block-ips.service
  rm -f /etc/systemd/system/block-domains.service
  rm -f /etc/systemd/system/block-ips-bot.service
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

disable_blocking() {
  log "Удаление правила iptables..."
  iptables -D OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null

  log "Остановка unbound..."
  systemctl stop unbound

  log "Остановка связанных сервисов..."
  systemctl stop block-ips.service 2>/dev/null
  systemctl stop block-domains.service 2>/dev/null

  log "Изменение DNS на 8.8.8.8..."
  echo 'nameserver 8.8.8.8' | tee /etc/resolv.conf > /dev/null

  success "Защита отключена"
}

enable_blocking() {
  log "Изменение DNS на 127.0.0.1..."
  echo 'nameserver 127.0.0.1' | tee /etc/resolv.conf > /dev/null

  log "Запуск unbound..."
  systemctl start unbound

  log "Проверка и установка iptables правила..."
  iptables -C OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null || \
    iptables -A OUTPUT -m set --match-set blocked_ips dst -j DROP

  log "Запуск связанных сервисов..."
  systemctl start block-ips.service
  systemctl start block-domains.service

  success "Защита включена"
}

# Основной цикл меню
while true; do
  echo -e "\nVPS хостинг, который работает со скидками до -60%:"
  echo "================="
  echo "Хостинг #1"
  echo "https://vk.cc/ct29NQ"
  echo "https://vk.cc/ct29NQ"
  echo "https://vk.cc/ct29NQ"
  echo ""
  echo "OFF60"
  echo "- 60% скидка на первый месяц"
  echo ""
  echo "antenka20"
  echo "- скидка на 20% + 3% за 3 месяца"
  echo ""
  echo "antenka6"
  echo "- скидка на 15% + 5% за 6 месяцев"
  echo ""
  echo "antenka12"
  echo "- скидка на 5% + 10% за год"
  echo "================="
  echo "Хостинг #2"
  echo "https://vk.cc/cO0UaZ"
  echo "https://vk.cc/cO0UaZ"
  echo "https://vk.cc/cO0UaZ"
  echo ""
  echo "(бонус 15% по ссылке в течении 24 часов)"
  echo "================="
  echo "Реферальные ссылки помогают проекту. Спасибо."
  echo -e "\n\033[1mМеню управления:\033[0m"
  echo "0. Выход"
  echo "1. Запустить обновление списка IP и доменов"
  echo "2. Деинсталлировать проект"
  echo "3. Отключить защиту"
  echo "4. Включить защиту"
  echo "5. Перезагрузить сервисы"
  echo "6. Установить/обновить Telegram-бот"

  read -p "Выберите действие (0 - 6): " choice

  case $choice in
    0)
      success "Выход."
      break
      ;;
    1)
      log "Запуск обновления списка IP и доменов..."
      if [ -f "$INSTALL_DIR/block_ips.py" ]; then
        "$INSTALL_DIR/venv/bin/python3" "$INSTALL_DIR/block_ips.py"
        success "Обновление IP завершено."
      else
        error "Файл $INSTALL_DIR/block_ips.py не найден."
      fi

      if [ -f "$INSTALL_DIR/blocked-domains/block_domains.py" ]; then
        "$INSTALL_DIR/venv/bin/python3" "$INSTALL_DIR/blocked-domains/block_domains.py"
        success "Обновление доменов завершено."
      else
        error "Файл $INSTALL_DIR/blocked-domains/block_domains.py не найден."
      fi
      ;;
    2)
      log "Запуск деинсталляции..."
      uninstall
      success "Проект удален."
      break
      ;;
    3)
      log "Отключение защиты..."
      disable_blocking
      ;;
    4)
      log "Включение защиты..."
      enable_blocking
      ;;
    5)
      log "Перезапуск unbound и iptables..."
      systemctl restart unbound
      iptables -D OUTPUT -m set --match-set blocked_ips dst -j DROP 2>/dev/null
      iptables -A OUTPUT -m set --match-set blocked_ips dst -j DROP
      success "Перезапуск завершен."
      ;;
    6)
      log "Управление Telegram-ботом..."
      manage_bot
      ;;
    *)
      error "Неверный выбор. Пожалуйста, выберите 0 - 6."
      ;;
  esac
  echo -e "\nНажмите Enter, чтобы вернуться в меню..."
  read -r
done