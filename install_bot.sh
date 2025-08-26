#!/bin/bash

# Функции для цветного вывода и логирования
log() { echo -e "\033[34m[INFO]\033[0m $1" | tee -a "$LOG_FILE"; }
success() { echo -e "\033[32m[SUCCESS]\033[0m $1" | tee -a "$LOG_FILE"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1" | tee -a "$LOG_FILE"; }

# Определение путей
SYSTEM_INSTALL_DIR="/opt/block-traffic"
TELEGRAM_BOT_DIR="$SYSTEM_INSTALL_DIR/telegram-bot"
LOG_DIR="$SYSTEM_INSTALL_DIR/logs"
LOG_FILE="$LOG_DIR/install-bot-$(date +%F_%H-%M-%S).log"
CONFIG_DIR="/etc/block-ips"
BOT_CONFIG_FILE="$CONFIG_DIR/bot_config.json"

# Создание директории логов
if [ ! -d "$LOG_DIR" ]; then
  log "Создание директории для логов: $LOG_DIR"
  mkdir -p "$LOG_DIR"
  chmod 755 "$LOG_DIR"
fi

log "Начало установки Telegram-бота..."

# Проверка установки block-ips
if [ ! -f "$CONFIG_DIR/config" ]; then
  error "Скрипт block-ips не установлен. Установите его с помощью install.sh."
  exit 1
fi
source "$CONFIG_DIR/config"
if ! systemctl list-units --full -all | grep -Fq "block-ips.service"; then
  error "Сервис block-ips.service не найден. Установите block-ips."
  exit 1
fi

# Проверка версии Python
log "Проверка версии Python..."
PYTHON_VERSION=$(python3 --version 2>> "$LOG_FILE" | awk '{print $2}' | cut -d'.' -f1,2)
if [ -z "$PYTHON_VERSION" ]; then
  error "Не удалось определить версию Python. Проверьте $LOG_FILE."
  exit 1
fi
log "Обнаружена версия Python: $PYTHON_VERSION"

# Проверка и установка пакета python3-venv
VENV_PACKAGE="python${PYTHON_VERSION}-venv"
log "Установка пакета $VENV_PACKAGE..."
sudo apt update -qq >> "$LOG_FILE" 2>&1
sudo apt install -y -qq "$VENV_PACKAGE" >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось установить $VENV_PACKAGE. Проверьте $LOG_FILE."
  exit 1
fi

# Проверка доступности python3 -m venv
log "Проверка модуля venv..."
python3 -m venv --help >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Модуль venv недоступен для Python $PYTHON_VERSION. Проверьте $LOG_FILE."
  exit 1
fi

# Создание директории для бота
log "Создание директории для бота: $TELEGRAM_BOT_DIR..."
sudo mkdir -p "$TELEGRAM_BOT_DIR"
sudo chmod 755 "$TELEGRAM_BOT_DIR"

# Копирование bot.py
log "Копирование bot.py в $TELEGRAM_BOT_DIR..."
sudo cp "$(dirname "$0")/bot.py" "$TELEGRAM_BOT_DIR/bot.py" 2>> "$LOG_FILE"
if [ $? -ne 0 ]; then
  error "Не удалось скопировать bot.py. Проверьте $LOG_FILE."
  exit 1
fi
sudo chmod 644 "$TELEGRAM_BOT_DIR/bot.py"

# Создание виртуального окружения с таймаутом
log "Создание виртуального окружения в $TELEGRAM_BOT_DIR/venv..."
cd "$TELEGRAM_BOT_DIR" || { error "Не удалось перейти в $TELEGRAM_BOT_DIR"; exit 1; }
timeout 60 python3 -m venv venv >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось создать виртуальное окружение. Проверьте $LOG_FILE."
  exit 1
fi

# Проверка существования виртуального окружения
if [ ! -d "$TELEGRAM_BOT_DIR/venv/bin" ]; then
  error "Виртуальное окружение не создано. Проверьте $LOG_FILE."
  exit 1
fi

# Активация и установка aiogram
log "Установка aiogram==3.5.0 в виртуальном окружении..."
source "$TELEGRAM_BOT_DIR/venv/bin/activate"
pip install -q aiogram==3.5.0 >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось установить aiogram==3.5.0. Проверьте $LOG_FILE."
  exit 1
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
  exit 1
fi

# Создание конфигурационного файла
log "Создание конфигурации в $BOT_CONFIG_FILE..."
sudo mkdir -p "$CONFIG_DIR"
cat << EOF | sudo tee "$BOT_CONFIG_FILE" > /dev/null
{
    "BOT_TOKEN": "$BOT_TOKEN",
    "ADMIN_ID": $ADMIN_ID
}
EOF
if [ $? -ne 0 ]; then
  error "Не удалось создать $BOT_CONFIG_FILE. Проверьте $LOG_FILE."
  exit 1
fi
sudo chmod 600 "$BOT_CONFIG_FILE"

# Создание systemd-сервиса
log "Настройка systemd-сервиса block-ips-bot..."
cat << EOF | sudo tee /etc/systemd/system/block-ips-bot.service > /dev/null
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
  error "Не удалось создать сервис block-ips-bot.service. Проверьте $LOG_FILE."
  exit 1
fi

# Запуск сервиса
log "Запуск и включение сервиса block-ips-bot..."
sudo systemctl daemon-reload >> "$LOG_FILE" 2>&1
sudo systemctl enable block-ips-bot.service >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось включить сервис block-ips-bot.service. Проверьте $LOG_FILE."
  exit 1
fi

sudo systemctl start block-ips-bot.service >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось запустить сервис block-ips-bot.service."
  log "Мини-диагностика:"
  sudo systemctl status block-ips-bot.service --no-pager | tee -a "$LOG_FILE"
  exit 1
fi

# Проверка статуса сервиса
log "Проверка статуса сервиса..."
if systemctl is-active --quiet block-ips-bot.service; then
  success "Сервис block-ips-bot.service активен и работает."
else
  error "Сервис block-ips-bot.service не активен."
  log "Мини-диагностика:"
  sudo systemctl status block-ips-bot.service --no-pager | tee -a "$LOG_FILE"
  exit 1
fi

success "Установка Telegram-бота завершена."

# Вывод сводной информации
echo -e "\n\033[1mСводная информация:\033[0m" | tee -a "$LOG_FILE"
echo "  - Скрипт бота: $TELEGRAM_BOT_DIR/bot.py" | tee -a "$LOG_FILE"
echo "  - Виртуальное окружение: $TELEGRAM_BOT_DIR/venv" | tee -a "$LOG_FILE"
echo "  - Конфигурация: $BOT_CONFIG_FILE" | tee -a "$LOG_FILE"
echo "  - Сервис: block-ips-bot.service" | tee -a "$LOG_FILE"
echo "  - Лог установки: $LOG_FILE" | tee -a "$LOG_FILE"

echo -e "\n\033[1mИнструкции:\033[0m" | tee -a "$LOG_FILE"
echo "  - Для смены Telegram ID отредактируйте: $BOT_CONFIG_FILE" | tee -a "$LOG_FILE"
echo "  - Проверить статус: sudo systemctl status block-ips-bot.service" | tee -a "$LOG_FILE"
echo "  - Просмотреть логи: sudo journalctl -u block-ips-bot.service" | tee -a "$LOG_FILE"
echo "  - Перезапустить сервис: sudo systemctl restart block-ips-bot.service" | tee -a "$LOG_FILE"

echo -e "\nVPS хостинг, который работает со скидками до -60%:" | tee -a "$LOG_FILE"
echo "=================" | tee -a "$LOG_FILE"
echo "Хостинг #1" | tee -a "$LOG_FILE"
echo "https://vk.cc/ct29NQ" | tee -a "$LOG_FILE"
echo "https://vk.cc/ct29NQ" | tee -a "$LOG_FILE"
echo "https://vk.cc/ct29NQ" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "OFF60" | tee -a "$LOG_FILE"
echo "- 60% скидка на первый месяц" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "antenka20" | tee -a "$LOG_FILE"
echo "- скидка на 20% + 3% за 3 месяца" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "antenka6" | tee -a "$LOG_FILE"
echo "- скидка на 15% + 5% за 6 месяцев" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "antenka12" | tee -a "$LOG_FILE"
echo "- скидка на 5% + 10% за год" | tee -a "$LOG_FILE"
echo "=================" | tee -a "$LOG_FILE"
echo "Хостинг #2" | tee -a "$LOG_FILE"
echo "https://vk.cc/cO0UaZ" | tee -a "$LOG_FILE"
echo "https://vk.cc/cO0UaZ" | tee -a "$LOG_FILE"
echo "https://vk.cc/cO0UaZ" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "(бонус 15% по ссылке в течении 24 часов)" | tee -a "$LOG_FILE"
echo "=================" | tee -a "$LOG_FILE"
echo "Реферальные ссылки помогают проекту. Спасибо." | tee -a "$LOG_FILE"