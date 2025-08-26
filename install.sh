#!/bin/bash

# Функции для цветного вывода и логирования
log() { 
  echo -e "\033[34m[INFO]\033[0m $1" | tee -a "$LOG_FILE"
}
success() { 
  echo -e "\033[32m[SUCCESS]\033[0m $1" | tee -a "$LOG_FILE"
}
error() { 
  echo -e "\033[31m[ERROR]\033[0m $1" | tee -a "$LOG_FILE"
}

# Определение полного пути к директории, в которой находится install.sh
SCRIPT_DIR=$(realpath "$(dirname "$0")")
SYSTEM_INSTALL_DIR="/opt/block-traffic"
INSTALL_DIR="$SYSTEM_INSTALL_DIR/blocked-ips"
LOG_DIR="$SYSTEM_INSTALL_DIR/logs"
LOG_FILE="$LOG_DIR/install-$(date +%F_%H-%M-%S).log"

# Создание системной директории и копирование файлов
log "Копирование файлов в $SYSTEM_INSTALL_DIR..."
sudo mkdir -p "$SYSTEM_INSTALL_DIR" "$INSTALL_DIR" "$LOG_DIR" "$INSTALL_DIR/blocked-domains"
sudo cp -r "$SCRIPT_DIR"/* "$SYSTEM_INSTALL_DIR/" 2>> "$LOG_FILE"
if [ -d "$SCRIPT_DIR/blocked-domains" ]; then
  sudo cp -r "$SCRIPT_DIR/blocked-domains" "$INSTALL_DIR/" 2>> "$LOG_FILE"
  sudo chmod -R 755 "$INSTALL_DIR/blocked-domains"
else
  error "Папка blocked-domains не найдена в $SCRIPT_DIR."
  exit 1
fi
sudo chmod -R 755 "$SYSTEM_INSTALL_DIR"
sudo chmod 755 "$LOG_DIR"

# Проверка, существует ли директория blocked-ips
if [ ! -d "$INSTALL_DIR" ]; then
  error "Директория $INSTALL_DIR не создана."
  exit 1
fi

# Проверка, существует ли файл block_domains.py
if [ ! -f "$INSTALL_DIR/blocked-domains/block_domains.py" ]; then
  error "Файл $INSTALL_DIR/blocked-domains/block_domains.py не найден."
  exit 1
fi

# Проверка, существует ли файл block_ips.py
if [ ! -f "$INSTALL_DIR/block_ips.py" ]; then
  error "Файл $INSTALL_DIR/block_ips.py не найден."
  exit 1
fi

# Создание конфигурационного файла
log "Создание конфигурации в /etc/block-ips/config..."
sudo mkdir -p /etc/block-ips
echo "INSTALL_DIR=$INSTALL_DIR" | sudo tee /etc/block-ips/config > /dev/null

# Проверка и удаление существующего сервиса block-ips
if systemctl list-units --full -all | grep -Fq "block-ips.service"; then
  log "Отключение и удаление существующего сервиса block-ips..."
  if [ -f /etc/systemd/system/block-ips.service ]; then
    sudo systemctl stop block-ips.service
    sudo systemctl disable block-ips.service
    sudo rm -f /etc/systemd/system/block-ips.service
    log "[INFO] Существующий сервис block-ips удалён"
  else
    log "[INFO] Сервис block-ips не найден, пропускаем удаление"
  fi
  
fi

# Проверка и удаление существующего сервиса block-domains
if systemctl list-units --full -all | grep -Fq "block-domains.service"; then
  log "Отключение и удаление существующего сервиса block-domains..."

  if [ -f /etc/systemd/system/block-ips.service ]; then
    sudo systemctl stop block-domains.service
    sudo systemctl disable block-domains.service
    sudo rm -f /etc/systemd/system/block-domains.service
    log "[INFO] Существующий сервис block-domains удалён"
  else
    log "[INFO] Сервис block-domains не найден, пропускаем удаление"
  fi

fi

# Проверка версии Python и установка нужного пакета venv
log "Проверка версии Python..."
PYTHON_VERSION=$(python3 --version 2>> "$LOG_FILE" | awk '{print $2}' | cut -d'.' -f1,2)
if [ -z "$PYTHON_VERSION" ]; then
  error "Не удалось определить версию Python. Проверьте $LOG_FILE."
  exit 1
fi
log "Обнаружена версия Python: $PYTHON_VERSION"

VENV_PACKAGE="python${PYTHON_VERSION}-venv"
log "Установка пакетов (python3, $VENV_PACKAGE, iptables, ipset, unbound, dnsutils)..."
sudo apt update -qq >> "$LOG_FILE" 2>&1
sudo apt install -y -qq python3 "$VENV_PACKAGE" iptables ipset unbound dnsutils >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось установить пакеты (python3, $VENV_PACKAGE, iptables, ipset, unbound, dnsutils). Проверьте $LOG_FILE."
  exit 1
fi

# Отключение и остановка systemd-resolved
log "Остановка и отключение systemd-resolved..."
sudo systemctl stop systemd-resolved >> "$LOG_FILE" 2>&1
sudo systemctl disable systemd-resolved >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось остановить или отключить systemd-resolved. Проверьте $LOG_FILE."
  exit 1
fi

# Настройка Unbound
log "Настройка Unbound..."
sudo bash -c 'cat > /etc/unbound/unbound.conf <<EOF
server:
    verbosity: 1
    interface: 0.0.0.0
    access-control: 127.0.0.0/8 allow
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    harden-dnssec-stripped: no
    chroot: ""
    cache-max-ttl: 86400
    cache-min-ttl: 3600

include: "/etc/unbound/blocked-domains.conf"
EOF'

# Убедиться, что /etc/unbound/blocked-domains.conf существует
log "Создание /etc/unbound/blocked-domains.conf, если не существует..."
sudo touch /etc/unbound/blocked-domains.conf >> "$LOG_FILE" 2>&1
sudo chmod 644 /etc/unbound/blocked-domains.conf >> "$LOG_FILE" 2>&1
sudo chown unbound:unbound /etc/unbound/blocked-domains.conf >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось создать или настроить /etc/unbound/blocked-domains.conf. Проверьте $LOG_FILE."
  exit 1
fi

# Проверка синтаксиса конфигурации Unbound
log "Проверка синтаксиса конфигурации Unbound..."
sudo unbound-checkconf >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Ошибка в конфигурации Unbound. Проверьте $LOG_FILE."
  exit 1
fi

# Запуск и включение Unbound
log "Запуск и включение Unbound..."
sudo systemctl enable unbound >> "$LOG_FILE" 2>&1
sudo systemctl start unbound >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось запустить Unbound. Проверьте $LOG_FILE."
  exit 1
fi

log "Проверка, что Unbound слушает на порту 53..."
if sudo ss -tuln | grep -q ":53 "; then
  success "Unbound слушает на порту 53."
else
  error "Unbound не слушает на порту 53. Проверьте конфигурацию."
  exit 1
fi

# Проверка DNS-разрешения через Unbound
log "Проверка DNS-разрешения через Unbound..."
if [ -n "$(dig @127.0.0.1 google.com +short)" ]; then
  success "DNS-разрешение работает корректно."
else
  error "DNS-разрешение не работает корректно. Проверьте конфигурацию Unbound."
  exit 1
fi

# Настройка NetworkManager, если установлен
if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
  log "Настройка NetworkManager для использования Unbound..."
  sudo bash -c 'echo "[main]\ndns=none" > /etc/NetworkManager/conf.d/no-dns.conf'
  sudo systemctl restart NetworkManager >> "$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    error "Не удалось перезапустить NetworkManager. Проверьте $LOG_FILE."
    exit 1
  fi
fi

# Разрешение исходящего трафика на порт 53, если ufw активен
if sudo ufw status | grep -q "Status: active"; then
  log "Разрешение исходящего трафика на порт 53 через ufw..."
  sudo ufw allow out to any port 53 proto udp >> "$LOG_FILE" 2>&1
  sudo ufw allow out to any port 53 proto tcp >> "$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    error "Не удалось разрешить исходящий трафик на порт 53. Проверьте $LOG_FILE."
    exit 1
  fi
fi

# Настройка /etc/resolv.conf на использование Unbound
log "Настройка /etc/resolv.conf на использование Unbound..."
if [ -L /etc/resolv.conf ]; then
  log "Удаление символической ссылки /etc/resolv.conf..."
  sudo rm /etc/resolv.conf >> "$LOG_FILE" 2>&1
fi
sudo bash -c 'echo "nameserver 127.0.0.1" > /etc/resolv.conf'

# Создание виртуального окружения
log "Создание виртуального окружения в $INSTALL_DIR/venv..."
cd "$INSTALL_DIR" || { error "Не удалось перейти в $INSTALL_DIR"; exit 1; }
python3 -m venv "$INSTALL_DIR/venv" >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось создать виртуальное окружение. Проверьте $LOG_FILE."
  exit 1
fi

source "$INSTALL_DIR/venv/bin/activate"
pip install -q requests >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось установить библиотеку requests. Проверьте $LOG_FILE."
  exit 1
fi

# Создание systemd сервиса для block-ips
log "Настройка systemd сервиса block-ips..."
cat << EOF | sudo tee /etc/systemd/system/block-ips.service > /dev/null
[Unit]
Description=Block IPs from antifilter.network
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/block_ips.py
WorkingDirectory=$INSTALL_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
if [ $? -ne 0 ]; then
  error "Не удалось создать файл сервиса block-ips.service. Проверьте $LOG_FILE."
  exit 1
fi

# Создание systemd таймера для block-ips
log "Настройка systemd таймера block-ips..."
cat << EOF | sudo tee /etc/systemd/system/block-ips.timer > /dev/null
[Unit]
Description=Run block-ips.service daily at midnight
Requires=block-ips.service

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true
Unit=block-ips.service

[Install]
WantedBy=timers.target
EOF
if [ $? -ne 0 ]; then
  error "Не удалось создать файл таймера block-ips.timer. Проверьте $LOG_FILE."
  exit 1
fi

# Создание systemd сервиса для block-domains
log "Настройка systemd сервиса block-domains..."
cat << EOF | sudo tee /etc/systemd/system/block-domains.service > /dev/null
[Unit]
Description=Update blocked domains daily
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/blocked-domains/block_domains.py
WorkingDirectory=$INSTALL_DIR
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
if [ $? -ne 0 ]; then
  error "Не удалось создать файл сервиса block-domains.service. Проверьте $LOG_FILE."
  exit 1
fi

# Создание systemd таймера для block-domains
log "Настройка systemd таймера block-domains..."
cat << EOF | sudo tee /etc/systemd/system/block-domains.timer > /dev/null
[Unit]
Description=Run block-domains.service daily at midnight
Requires=block-domains.service

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true
Unit=block-domains.service

[Install]
WantedBy=timers.target
EOF
if [ $? -ne 0 ]; then
  error "Не удалось создать файл таймера block-domains.timer. Проверьте $LOG_FILE."
  exit 1
fi

# Копирование manage.sh в /usr/local/bin/blockme
log "Установка команды blockme..."
sudo cp "$SYSTEM_INSTALL_DIR/manage.sh" /usr/local/bin/blockme 2>> "$LOG_FILE"
if [ $? -ne 0 ]; then
  error "Не удалось скопировать manage.sh в /usr/local/bin/blockme. Проверьте $LOG_FILE."
  exit 1
fi
sudo chmod +x /usr/local/bin/blockme 2>> "$LOG_FILE"

# Настройка и запуск сервисов и таймеров
log "Запуск и включение сервисов и таймеров..."
sudo systemctl daemon-reload >> "$LOG_FILE" 2>&1
sudo systemctl enable block-ips.timer >> "$LOG_FILE" 2>&1
sudo systemctl start block-ips.timer >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось включить или запустить block-ips.timer. Проверьте $LOG_FILE."
  exit 1
fi
sudo systemctl enable block-domains.timer >> "$LOG_FILE" 2>&1
sudo systemctl start block-domains.timer >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
  error "Не удалось включить или запустить block-domains.timer. Проверьте $LOG_FILE."
  exit 1
fi

# Проверка статуса таймеров
log "Проверка статуса таймеров..."
if systemctl is-active --quiet block-ips.timer; then
  success "Таймер block-ips.timer активен и работает."
else
  error "Таймер block-ips.timer не активен."
  log "Мини-диагностика:"
  sudo systemctl status block-ips.timer --no-pager | tee -a "$LOG_FILE"
  error "Проверьте $LOG_FILE или выполните 'sudo systemctl status block-ips.timer' для деталей."
  exit 1
fi
if systemctl is-active --quiet block-domains.timer; then
  success "Таймер block-domains.timer активен и работает."
else
  error "Таймер block-domains.timer не активен."
  log "Мини-диагностика:"
  sudo systemctl status block-domains.timer --no-pager | tee -a "$LOG_FILE"
  error "Проверьте $LOG_FILE или выполните 'sudo systemctl status block-domains.timer' для деталей."
  exit 1
fi

success "Установка завершена."

# Вывод сводной информации
echo -e "\n\033[1mСводная информация:\033[0m" | tee -a "$LOG_FILE"
echo "  - Скрипт IP: $INSTALL_DIR/block_ips.py" | tee -a "$LOG_FILE"
echo "  - Скрипт доменов: $INSTALL_DIR/blocked-domains/block_domains.py" | tee -a "$LOG_FILE"
echo "  - Виртуальное окружение: $INSTALL_DIR/venv" | tee -a "$LOG_FILE"
echo "  - Сервис IP: block-ips.service" | tee -a "$LOG_FILE"
echo "  - Таймер IP: block-ips.timer" | tee -a "$LOG_FILE"
echo "  - Сервис доменов: block-domains.service" | tee -a "$LOG_FILE"
echo "  - Таймер доменов: block-domains.timer" | tee -a "$LOG_FILE"
echo "  - Команда blockme: /usr/local/bin/blockme" | tee -a "$LOG_FILE"
echo "  - Лог установки: $LOG_FILE" | tee -a "$LOG_FILE"

echo -e "\n\033[1mИнструкции:\033[0m" | tee -a "$LOG_FILE"
echo "  - Запустите 'blockme' для открытия меню управления" | tee -a "$LOG_FILE"
echo "  - Проверить статус таймеров: sudo systemctl status block-ips.timer block-domains.timer" | tee -a "$LOG_FILE"
echo "  - Просмотреть логи: sudo journalctl -u block-ips.service -u block-domains.service" | tee -a "$LOG_FILE"
echo "  - Перезапустить таймеры: sudo systemctl restart block-ips.timer block-domains.timer" | tee -a "$LOG_FILE"

echo -e "\nБольшой выбор стран, хорошее железо, быстрая поддержка,"
echo "VPS хостинг, который работает со скидками до -60%:"
echo "==============================================================="
echo "https://vk.cc/ct29NQ"
echo "https://vk.cc/ct29NQ"
echo "https://vk.cc/ct29NQ"
echo ""
echo "OFF60         для 60% скидки на первый месяц"
echo "antenka20     буст скидка на 20% + 3% при оплате за 3 месяца"
echo "antenka6      буст скидка на 15% + 5% при оплате 6 месяцев"
echo "==============================================================="
echo "https://vk.cc/cO0UaZ"
echo "https://vk.cc/cO0UaZ"
echo "https://vk.cc/cO0UaZ"
echo ""
echo "(бонус 15% по ссылке в течении 24 часов)"
echo "==============================================================="