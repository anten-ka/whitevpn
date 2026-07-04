#!/bin/bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# WhiteVPN v0.8 — Установка компонента защиты
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

VERSION="0.8"
INSTALL_DIR="/opt/block-traffic"
CONFIG_DIR="/etc/block-ips"
BOT_CONFIG="${CONFIG_DIR}/bot_config.json"
LOG="/var/log/whitevpn-install.log"
GITHUB_RAW="https://raw.githubusercontent.com/anten-ka/whitevpn/test"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $1" | tee -a "$LOG"; }
err()  { echo -e "${RED}✗${NC} $1" | tee -a "$LOG"; }
warn() { echo -e "${YELLOW}⚠${NC} $1" | tee -a "$LOG"; }
info() { echo -e "${BLUE}ℹ${NC} $1" | tee -a "$LOG"; }
log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG"; }

# Определяем каталог, откуда запущен скрипт
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Проверка root
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [[ $EUID -ne 0 ]]; then
    err "Запуск только от root (sudo bash install.sh)"
    exit 1
fi

touch "$LOG"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Баннер
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

clear
cat << 'BANNER'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🛡  WhiteVPN v0.8 — Установка компонента защиты
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  📋 О компоненте:

  ПО для Linux Ubuntu, которое снизит риски санкций
  со стороны органов, как для автора канала, так и
  для обычных пользователей, когда на VPS / серверы
  устанавливается ПО для VPN / Proxy, которое
  предотвращает переход на запрещенные сайты / ресурсы
  со стороны контролирующих органов РФ.

  🎯 Задача — удовлетворить 3 стороны:
  • Автора канала — рассказывает о сетевых технологиях
  • Пользователя — сам принимает решение о работе
  • Контролирующие органы — ПО помогает не нарушать закон

  ⚙️ Как работает:
  Скачивает публичные списки запрещённых ресурсов,
  добавляет подсети в iptables (ipset) и блокирует
  домены через Unbound DNS.

  🤖 Telegram-бот для управления хоть с телефона —
  включение/отключение за 3 секунды.

  ⚠️ Решение не гарантирует 100% защищённости и
  поставляется «как есть».

  📢 Решение о работоспособности принимать вам.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

BANNER
sleep 1

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. Обнаружение старой версии
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SAVED_TOKEN=""
SAVED_ADMIN=""

detect_old() {
    local found=0
    [[ -d "$INSTALL_DIR" ]] && found=1
    [[ -f /usr/local/bin/blockme ]] && found=1

    if [[ $found -eq 0 ]]; then
        info "Предыдущая установка не найдена"
        return
    fi

    warn "🔍 Обнаружена предыдущая версия WhiteVPN!"

    # Извлечь токен и admin_id из конфига
    if [[ -f "$BOT_CONFIG" ]]; then
        SAVED_TOKEN=$(python3 -c "
import json,sys
try:
    d=json.load(open('$BOT_CONFIG'))
    print(d.get('BOT_TOKEN',d.get('token','')))
except: pass
" 2>/dev/null || true)
        SAVED_ADMIN=$(python3 -c "
import json,sys
try:
    d=json.load(open('$BOT_CONFIG'))
    print(d.get('ADMIN_ID',d.get('admin_id','')))
except: pass
" 2>/dev/null || true)
        [[ -n "$SAVED_TOKEN" ]] && ok "Токен бота извлечён"
        [[ -n "$SAVED_ADMIN" ]] && ok "Admin ID извлечён: $SAVED_ADMIN"
    fi

    echo ""
    read -rp "  Удалить старую версию и установить v${VERSION}? (y/n): "
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "Установка отменена."
        exit 0
    fi

    # Остановить старые сервисы
    for svc in block-ips-bot whitevpn-bot whitevpn-update; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    for timer in whitevpn-update; do
        systemctl stop "${timer}.timer" 2>/dev/null || true
        systemctl disable "${timer}.timer" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/whitevpn-*.service /etc/systemd/system/whitevpn-*.timer
    rm -f /etc/systemd/system/block-ips-bot.service
    systemctl disable ipset-restore 2>/dev/null || true
    rm -f /etc/systemd/system/ipset-restore.service
    systemctl daemon-reload 2>/dev/null || true

    # Удалить старую установку (конфиг сохраняем)
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/blockme
    ok "Старая версия удалена"
}

detect_old

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. Обнаружение 3x-ui и Docker
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

XUI_FOUND=0
DOCKER_FOUND=0
DOCKER_NAMES=()

# 3x-ui
if systemctl is-active --quiet x-ui 2>/dev/null || [[ -d /usr/local/x-ui ]]; then
    XUI_FOUND=1
    echo -e "  ${GREEN}🖥  Обнаружена панель 3x-ui!${NC}"
    echo -e "  ${GREEN}✅ На панель будет включена защита${NC}"
    echo ""
fi

# Docker контейнеры
if command -v docker &>/dev/null; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local_name=$(echo "$line" | awk '{print $1}')
        local_image=$(echo "$line" | awk '{print $2}')
        if [[ "$local_name$local_image" =~ amnezia|wireguard|openvpn|vpn ]]; then
            DOCKER_NAMES+=("$local_name")
            DOCKER_FOUND=1
        fi
    done < <(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null)

    if [[ $DOCKER_FOUND -eq 1 ]]; then
        echo -e "  ${GREEN}🐳 Обнаружены Docker-контейнеры:${NC}"
        for n in "${DOCKER_NAMES[@]}"; do
            echo -e "  ${GREEN}  • $n ✅${NC}"
        done
        echo -e "  ${GREEN}✅ На контейнеры будет включена защита${NC}"
        echo ""
    fi
fi

sleep 1

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. Установка зависимостей
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Установка зависимостей..."
apt-get update -qq >> "$LOG" 2>&1 || true

PKGS=(python3 python3-venv python3-pip iptables ipset unbound dnsutils dos2unix curl wget iptables-persistent)
for pkg in "${PKGS[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        ok "$pkg уже установлен"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >> "$LOG" 2>&1 && ok "$pkg установлен" || warn "$pkg не удалось"
    fi
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. Создание каталогов
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Создание каталогов..."
mkdir -p "$INSTALL_DIR"/{whitelist,logs,blocked-ips,blocked-domains}
mkdir -p "$CONFIG_DIR"
ok "Каталоги созданы"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. Копирование / загрузка файлов проекта
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Копирование файлов проекта..."

copy_or_download() {
    local src="$1" dst="$2" remote="$3"
    if [[ -f "$SCRIPT_DIR/$src" ]]; then
        cp "$SCRIPT_DIR/$src" "$dst"
    else
        wget -q -O "$dst" "${GITHUB_RAW}/${remote:-$src}" || { err "Не удалось загрузить $src"; return 1; }
    fi
    ok "  $src"
}

# Основные файлы
copy_or_download "bot.py" "$INSTALL_DIR/bot.py" "bot.py"
copy_or_download "manage.sh" "$INSTALL_DIR/manage.sh" "manage.sh"
copy_or_download "docker_rules.sh" "$INSTALL_DIR/docker_rules.sh" "docker_rules.sh"
copy_or_download "apply_firewall.sh" "$INSTALL_DIR/apply_firewall.sh" "apply_firewall.sh"
copy_or_download "fix_xray_template.py" "$INSTALL_DIR/fix_xray_template.py" "fix_xray_template.py"
copy_or_download "VERSION" "$INSTALL_DIR/VERSION" "VERSION"

# Скрипты блокировки
copy_or_download "blocked-ips/block_ips.py" "$INSTALL_DIR/blocked-ips/block_ips.py" "blocked-ips/block_ips.py"
copy_or_download "blocked-domains/block_domains.py" "$INSTALL_DIR/blocked-domains/block_domains.py" "blocked-domains/block_domains.py"

# Белый список
for f in telegram.txt youtube.txt custom.txt whitelist.conf; do
    copy_or_download "whitelist/$f" "$INSTALL_DIR/whitelist/$f" "whitelist/$f"
done

chmod +x "$INSTALL_DIR/manage.sh" "$INSTALL_DIR/docker_rules.sh" "$INSTALL_DIR/apply_firewall.sh"
dos2unix "$INSTALL_DIR"/*.sh "$INSTALL_DIR"/*.py 2>/dev/null || true
dos2unix "$INSTALL_DIR"/blocked-*/*.py 2>/dev/null || true

ok "Файлы проекта скопированы"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. Python venv
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Создание Python venv..."
python3 -m venv "$INSTALL_DIR/venv" >> "$LOG" 2>&1
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip >> "$LOG" 2>&1
"$INSTALL_DIR/venv/bin/pip" install aiogram==3.5.0 requests >> "$LOG" 2>&1
ok "Python venv (aiogram 3.5.0, requests)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. Настройка Unbound DNS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Настройка Unbound DNS..."

systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

# Бэкап
[[ -f /etc/unbound/unbound.conf ]] && cp /etc/unbound/unbound.conf /etc/unbound/unbound.conf.bak.$(date +%s)

cat > /etc/unbound/unbound.conf << 'UNBCONF'
server:
    verbosity: 1
    log-local-actions: yes
    use-syslog: yes
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    interface: 127.0.0.1
    access-control: 127.0.0.0/8 allow
    access-control: 0.0.0.0/0 refuse
    num-threads: 2
    msg-cache-size: 4m
    rrset-cache-size: 8m
    include: "/etc/unbound/whitelist-zones.conf"
    include: "/etc/unbound/blocked-domains.conf"

forward-zone:
    name: "."
    forward-addr: 8.8.8.8
    forward-addr: 8.8.4.4
    forward-addr: 1.1.1.1
UNBCONF

touch /etc/unbound/blocked-domains.conf
touch /etc/unbound/whitelist-zones.conf
chown -R unbound:unbound /etc/unbound 2>/dev/null || true

echo "nameserver 127.0.0.1" > /etc/resolv.conf

systemctl restart unbound
systemctl enable unbound
ok "Unbound DNS настроен"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 8. ipset + iptables
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Настройка ipset и iptables..."

# Единая точка применения правил: apply_firewall.sh
# (создаёт ipset'ы blocked_ips + whitevpn_allow, правила ACCEPT/LOG/DROP, DNS)
bash "$INSTALL_DIR/apply_firewall.sh" up >> "$LOG" 2>&1 \
    && ok "Правила защиты применены" \
    || warn "apply_firewall.sh up завершился с предупреждениями (см. лог)"

# Docker-защита: автонастройка выбранных VPN-контейнеров
if [[ $DOCKER_FOUND -eq 1 ]] && [[ -f "$INSTALL_DIR/docker_rules.sh" ]]; then
    warn "Сейчас будет настроена Docker-защита (контейнеры будут перезапущены)"
    bash "$INSTALL_DIR/docker_rules.sh" auto-setup-confirm >> "$LOG" 2>&1 \
        && ok "Docker-защита включена" \
        || warn "Docker-защита не настроена полностью (см. лог)"
fi

# Сохранение ipset для восстановления после перезагрузки
bash "$INSTALL_DIR/apply_firewall.sh" save >> "$LOG" 2>&1 || true

ok "ipset + iptables настроены"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 9. Настройка бота (опционально)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

BOT_TOKEN_VAL=""
ADMIN_ID_VAL=""
SETUP_BOT=false

# Проверяем сохранённые данные от предыдущей версии
if [[ -n "$SAVED_TOKEN" ]] && [[ -n "$SAVED_ADMIN" ]]; then
    echo ""
    echo -e "  ${GREEN}Найдены данные бота от предыдущей версии:${NC}"
    echo -e "  Токен: ${SAVED_TOKEN:0:15}..."
    echo -e "  Admin: $SAVED_ADMIN"
    echo ""
    read -rp "  Использовать сохранённые данные? (y/n): "
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        BOT_TOKEN_VAL="$SAVED_TOKEN"
        ADMIN_ID_VAL="$SAVED_ADMIN"
        SETUP_BOT=true
    fi
fi

# Если нет сохранённых данных — предлагаем опционально настроить бота
if [[ "$SETUP_BOT" != true ]]; then
    echo ""
    echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}Telegram-бот (опционально)${NC}"
    echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Бот позволяет управлять блокировками прямо из Telegram:"
    echo -e "  включать/выключать YouTube, Telegram, обновлять списки,"
    echo -e "  смотреть статус и лог блокировок."
    echo ""
    echo -e "  Бот не обязателен — всё это доступно через SSH-команду ${GREEN}blockme${NC}."
    echo ""
    read -rp "  Хотите настроить Telegram-бота? (y/n): "
    echo ""

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${YELLOW}Инструкция по созданию бота:${NC}"
        echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  1. Откройте @BotFather в Telegram:"
        echo -e "     ${GREEN}https://t.me/BotFather${NC}"
        echo ""
        echo -e "  2. Отправьте команду /newbot и следуйте инструкциям."
        echo -e "     Скопируйте полученный API-токен."
        echo ""
        echo -e "  3. Чтобы узнать свой Telegram ID, откройте @userinfobot:"
        echo -e "     ${GREEN}https://t.me/userinfobot${NC}"
        echo -e "     Отправьте любое сообщение и скопируйте число из ответа."
        echo ""
        echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        read -p "  Введите Bot Token: " BOT_TOKEN_VAL
        echo ""

        if [[ -n "$BOT_TOKEN_VAL" ]]; then
            echo -e "  ${YELLOW}Определение администратора:${NC}"
            echo ""
            echo -e "  Выберите способ:"
            echo -e "  ${GREEN}1${NC} — Автоматически: бот определит ID из ваших сообщений"
            echo -e "  ${GREEN}2${NC} — Вручную: ввести Telegram ID через запятую"
            echo ""
            read -rp "  Ваш выбор (1/2): " ADMIN_METHOD
            echo ""

            if [[ "$ADMIN_METHOD" == "1" ]]; then
                # Автоматическое определение: запускаем временный скрипт
                echo -e "  ${YELLOW}Запускаю бота для определения администратора...${NC}"
                echo -e "  Откройте вашего бота в Telegram и отправьте 3 сообщения."
                echo -e "  Бот определит ваш ID автоматически."
                echo ""

                # Создаём временный Python-скрипт для определения admin ID
                DETECT_SCRIPT="${INSTALL_DIR}/detect_admin.py"
                cat > "$DETECT_SCRIPT" << 'DETECTPY'
import asyncio
import sys
from aiogram import Bot, Dispatcher, types
from aiogram.filters import CommandStart

TOKEN = sys.argv[1]
messages_received = {}
required_messages = 3

bot = Bot(token=TOKEN)
dp = Dispatcher()

@dp.message()
async def handle_message(message: types.Message):
    uid = message.from_user.id
    uname = message.from_user.full_name
    messages_received.setdefault(uid, {"name": uname, "count": 0})
    messages_received[uid]["count"] += 1
    remaining = required_messages - messages_received[uid]["count"]
    if remaining > 0:
        await message.answer(f"Получено! Осталось {remaining} сообщений для подтверждения.")
    else:
        await message.answer(f"Отлично! Вы определены как администратор (ID: {uid}).")
        print(f"ADMIN_DETECTED:{uid}:{uname}")
        await bot.session.close()
        sys.exit(0)

async def main():
    print("WAITING_FOR_MESSAGES")
    try:
        await asyncio.wait_for(dp.start_polling(bot), timeout=120)
    except (asyncio.TimeoutError, SystemExit):
        await bot.session.close()
    if messages_received:
        top = max(messages_received.items(), key=lambda x: x[1]["count"])
        print(f"ADMIN_DETECTED:{top[0]}:{top[1]['name']}")
    else:
        print("NO_MESSAGES")

if __name__ == "__main__":
    asyncio.run(main())
DETECTPY

                # Запускаем скрипт определения
                DETECT_OUTPUT=$("${INSTALL_DIR}/venv/bin/python3" "$DETECT_SCRIPT" "$BOT_TOKEN_VAL" 2>/dev/null)
                rm -f "$DETECT_SCRIPT"

                if echo "$DETECT_OUTPUT" | grep -q "ADMIN_DETECTED"; then
                    DETECTED_ID=$(echo "$DETECT_OUTPUT" | grep "ADMIN_DETECTED" | tail -1 | cut -d: -f2)
                    DETECTED_NAME=$(echo "$DETECT_OUTPUT" | grep "ADMIN_DETECTED" | tail -1 | cut -d: -f3)
                    echo ""
                    echo -e "  ${GREEN}Администратор определён:${NC}"
                    echo -e "  Имя: $DETECTED_NAME"
                    echo -e "  ID:  $DETECTED_ID"
                    echo ""
                    ADMIN_ID_VAL="$DETECTED_ID"
                    SETUP_BOT=true
                else
                    echo ""
                    echo -e "  ${RED}Не удалось определить администратора автоматически.${NC}"
                    echo -e "  Введите Telegram ID вручную."
                    echo ""
                    read -p "  Admin ID (через запятую, если несколько): " ADMIN_ID_VAL
                    if [[ -n "$ADMIN_ID_VAL" ]]; then
                        SETUP_BOT=true
                    fi
                fi
            else
                # Ручной ввод
                echo -e "  Узнать свой ID можно у @userinfobot: ${GREEN}https://t.me/userinfobot${NC}"
                echo ""
                read -p "  Введите Telegram ID администраторов (через запятую): " ADMIN_ID_VAL
                if [[ -n "$ADMIN_ID_VAL" ]]; then
                    SETUP_BOT=true
                fi
            fi
        fi
    fi
fi

# Сохраняем конфиг бота
if [[ "$SETUP_BOT" == true ]] && [[ -n "$BOT_TOKEN_VAL" ]] && [[ -n "$ADMIN_ID_VAL" ]]; then
    # Проверяем, содержит ли ADMIN_ID_VAL запятую (несколько ID)
    if [[ "$ADMIN_ID_VAL" == *","* ]]; then
        # Формируем JSON-массив из списка ID
        ADMIN_JSON="["
        IFS=',' read -ra IDS <<< "$ADMIN_ID_VAL"
        FIRST=true
        for id in "${IDS[@]}"; do
            id=$(echo "$id" | tr -d ' ')
            if [[ "$FIRST" == true ]]; then
                ADMIN_JSON+="$id"
                FIRST=false
            else
                ADMIN_JSON+=", $id"
            fi
        done
        ADMIN_JSON+="]"
        cat > "$BOT_CONFIG" << BOTCFG
{
  "BOT_TOKEN": "$BOT_TOKEN_VAL",
  "ADMIN_IDS": $ADMIN_JSON
}
BOTCFG
    else
        cat > "$BOT_CONFIG" << BOTCFG
{
  "BOT_TOKEN": "$BOT_TOKEN_VAL",
  "ADMIN_ID": $ADMIN_ID_VAL
}
BOTCFG
    fi
    chmod 600 "$BOT_CONFIG"
    ok "Конфигурация бота сохранена"
else
    warn "Бот не настроен. Настройте позже вручную: $BOT_CONFIG или перезапустите установку."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 10. Systemd-сервисы
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Создание systemd-сервисов..."

# Бот
cat > /etc/systemd/system/block-ips-bot.service << BOTSVC
[Unit]
Description=WhiteVPN Telegram Bot v${VERSION}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/bot.py
Restart=always
RestartSec=10
WorkingDirectory=${INSTALL_DIR}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
BOTSVC

# Обновление списков (one-shot) — wrapper-скрипт для двух команд
cat > "${INSTALL_DIR}/update_all.sh" << 'UPDSH'
#!/bin/bash
set -e
INSTALL_DIR="/opt/block-traffic"
"$INSTALL_DIR/venv/bin/python3" "$INSTALL_DIR/blocked-ips/block_ips.py"
"$INSTALL_DIR/venv/bin/python3" "$INSTALL_DIR/blocked-domains/block_domains.py"
UPDSH
chmod +x "${INSTALL_DIR}/update_all.sh"

cat > /etc/systemd/system/whitevpn-update.service << UPDSVC
[Unit]
Description=WhiteVPN List Update
After=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/update_all.sh
WorkingDirectory=${INSTALL_DIR}
UPDSVC

# Таймер обновления (раз в сутки)
cat > /etc/systemd/system/whitevpn-update.timer << UPDTMR
[Unit]
Description=WhiteVPN Update Timer
Requires=whitevpn-update.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
UPDTMR

# Сервис восстановления защиты после перезагрузки
cat > /etc/systemd/system/whitevpn-firewall.service << FWSVC
[Unit]
Description=WhiteVPN Firewall Restore v${VERSION}
After=network-online.target unbound.service docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_DIR}/apply_firewall.sh boot

[Install]
WantedBy=multi-user.target
FWSVC

systemctl daemon-reload
systemctl enable whitevpn-firewall.service >> "$LOG" 2>&1
ok "Сервис восстановления защиты (whitevpn-firewall) включён"

# Запускаем бот (если настроен)
if [[ "$SETUP_BOT" == true ]] && [[ -n "$BOT_TOKEN_VAL" ]]; then
    systemctl enable block-ips-bot
    systemctl start block-ips-bot
    ok "Бот запущен"
else
    log "Бот не настроен — сервис не запущен"
fi

# Запускаем таймер обновления
systemctl enable whitevpn-update.timer
systemctl start whitevpn-update.timer
ok "Таймер обновления (24ч) запущен"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 11. Команда blockme (SSH-меню)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Установка команды blockme..."
ln -sf "$INSTALL_DIR/manage.sh" /usr/local/bin/blockme
chmod +x /usr/local/bin/blockme
ok "Команда blockme установлена"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 12. Первичное обновление списков
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log "Первичное обновление списков блокировки..."
"$INSTALL_DIR/venv/bin/python3" "$INSTALL_DIR/blocked-ips/block_ips.py" >> "$LOG" 2>&1 || warn "Ошибка обновления IP"
"$INSTALL_DIR/venv/bin/python3" "$INSTALL_DIR/blocked-domains/block_domains.py" >> "$LOG" 2>&1 || warn "Ошибка обновления доменов"
ok "Списки обновлены"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 12b. Настройка Xray (3x-ui): DNS через Unbound + IPv4
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if [[ $XUI_FOUND -eq 1 ]] && [[ -f /etc/x-ui/x-ui.db ]]; then
    echo ""
    info "Панель 3x-ui: без настройки Xray блокировка ДОМЕНОВ для VLESS-клиентов работать не будет."
    info "Скрипт направит DNS Xray на Unbound и включит принудительный IPv4."
    info "(старый шаблон сохраняется в /etc/block-ips/xray_template_backup.json)"
    read -rp "  Настроить Xray сейчас (рекомендуется)? (y/n): "
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        python3 "$INSTALL_DIR/fix_xray_template.py" >> "$LOG" 2>&1 \
            && ok "Шаблон Xray обновлён (DNS -> Unbound, UseIPv4)" \
            || warn "Не удалось обновить шаблон Xray (см. лог)"
    else
        warn "Пропущено. Позже: python3 $INSTALL_DIR/fix_xray_template.py"
    fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 13. Права доступа
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

chown -R root:root "$INSTALL_DIR"
chmod -R 755 "$INSTALL_DIR"
chmod 600 "$BOT_CONFIG" 2>/dev/null || true

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ИТОГО
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
cat << SUMMARY

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ WhiteVPN v${VERSION} — Установка завершена!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  📂 Каталог:   ${INSTALL_DIR}
  📝 Конфиг:    ${BOT_CONFIG}
  📊 Логи:      ${INSTALL_DIR}/logs/

  🛠  SSH-команда: blockme
  🤖 Бот:         systemctl status block-ips-bot

  📋 Сервисы:
  • block-ips-bot.service    — Telegram бот
  • whitevpn-update.timer    — обновление раз в сутки
  • whitevpn-firewall        — восстановление защиты после перезагрузки

  🔗 Партнёрские хостинги:
  • Хостинг #1: vk.cc/ct29NQ
    OFF60 · antenka20 · antenka6
  • Хостинг #2: vk.cc/cUxAhj
    OFF60

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY

echo ""
ok "Установка завершена! Введите 'blockme' для SSH-меню."
echo ""
