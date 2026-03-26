import asyncio
import subprocess
import json
import os
import re
from datetime import datetime
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from aiogram.types import (
    ReplyKeyboardMarkup, KeyboardButton, FSInputFile,
    InlineKeyboardMarkup, InlineKeyboardButton, CallbackQuery
)

# Загрузка конфигурации
with open('/etc/block-ips/bot_config.json', 'r') as f:
    bot_config = json.load(f)
BOT_TOKEN = bot_config['BOT_TOKEN']
ADMIN_ID = bot_config['ADMIN_ID']

with open('/etc/block-ips/config', 'r') as f:
    for line in f:
        if line.startswith('INSTALL_DIR='):
            INSTALL_DIR = line.split('=')[1].strip()
            break
    else:
        raise ValueError("INSTALL_DIR not found in /etc/block-ips/config")

DOCKER_RULES_SCRIPT = "/opt/block-traffic/docker_rules.sh"

LOG_DIR = os.path.join(os.path.dirname(INSTALL_DIR), "logs")
LOG_FILE = os.path.join(LOG_DIR, f"bot-run-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.log")
AD_TIMESTAMP_FILE = "/etc/block-ips/last_ad_timestamp"

# Хранение выбора контейнеров по user_id
docker_selection = {}

# Рекламный текст
referal_text = '''
VPS хостинг, который работает со скидками до -60%:
=================
Хостинг #1
https://vk.cc/ct29NQ

OFF60 - 60% скидка на первый месяц
antenka20 - скидка на 20% + 3% за 3 месяца
antenka6 - скидка на 15% + 5% за 6 месяцев
antenka12 - скидка на 5% + 10% за год
=================
Хостинг #2
https://vk.cc/cO0UaZ
(бонус 15% по ссылке в течении 24 часов)
=================
Реферальные ссылки помогают проекту. Спасибо.
'''

def log_to_file(message):
    with open(LOG_FILE, "a") as f:
        f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - {message}\n")

async def show_ad_if_needed(message: types.Message):
    current_time = int(datetime.now().timestamp())
    if os.path.exists(AD_TIMESTAMP_FILE):
        with open(AD_TIMESTAMP_FILE, 'r') as f:
            last_ad_time = int(f.read().strip())
        if current_time - last_ad_time < 3600:
            return
    await message.answer(referal_text)
    log_to_file("Реклама отображена")
    with open(AD_TIMESTAMP_FILE, 'w') as f:
        f.write(str(current_time))

def strip_ansi(text):
    return re.sub(r'\033\[[0-9;]*m', '', text)

# ═══════════════════════════════════════════════════════════════════════
# Инициализация
# ═══════════════════════════════════════════════════════════════════════

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()

def get_main_menu():
    key = [
        [KeyboardButton(text='Обновить IP и домены')],
        [KeyboardButton(text='Отключить защиту'), KeyboardButton(text='Включить защиту')],
        [KeyboardButton(text='Перезапустить сервисы')],
        [KeyboardButton(text='Состояние сервера'), KeyboardButton(text='Скачать логи')],
        [KeyboardButton(text='Docker-контейнеры')],
    ]
    return ReplyKeyboardMarkup(keyboard=key, resize_keyboard=True)

async def is_admin(message: types.Message):
    if message.from_user.id != ADMIN_ID:
        await message.answer("Доступ запрещён.")
        log_to_file(f"Неавторизованный доступ: ID {message.from_user.id}")
        return False
    return True

async def is_admin_callback(callback: CallbackQuery):
    if callback.from_user.id != ADMIN_ID:
        await callback.answer("Доступ запрещён.", show_alert=True)
        return False
    return True

# ═══════════════════════════════════════════════════════════════════════
# Основные команды
# ═══════════════════════════════════════════════════════════════════════

@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    await message.answer(
        "WhiteVPN — Управление блокировкой\n"
        "GitHub: https://github.com/anten-ka/whitevpn\n\n"
        "Выберите действие:",
        reply_markup=get_main_menu()
    )
    log_to_file(f"Админ {message.from_user.id} запустил бота")

@dp.message(lambda m: m.text == "Обновить IP и домены")
async def update_all(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    await message.answer("Обновление IP и доменов...")
    log_to_file("Обновление IP и доменов")

    for script_name, label in [
        (f"{INSTALL_DIR}/block_ips.py", "IP"),
        (f"{INSTALL_DIR}/blocked-domains/block_domains.py", "доменов")
    ]:
        if os.path.exists(script_name):
            result = subprocess.run(
                [f"{INSTALL_DIR}/venv/bin/python3", script_name],
                capture_output=True, text=True, timeout=120
            )
            if result.returncode == 0:
                await message.answer(f"Обновление {label} завершено:\n{result.stdout[:2000]}")
            else:
                await message.answer(f"Ошибка обновления {label}:\n{result.stderr[:2000]}")
        else:
            await message.answer(f"Файл {script_name} не найден.")

@dp.message(lambda m: m.text == "Отключить защиту")
async def disable_blocking(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    await message.answer("Отключение защиты...")

    commands = [
        ["iptables", "-D", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        ["systemctl", "stop", "unbound"],
        ["systemctl", "stop", "block-ips.service"],
        ["systemctl", "stop", "block-domains.service"],
        ["sh", "-c", "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"]
    ]
    for cmd in commands:
        subprocess.run(cmd, capture_output=True, text=True)

    if os.path.exists(DOCKER_RULES_SCRIPT):
        subprocess.run(["bash", DOCKER_RULES_SCRIPT, "disable"],
                       capture_output=True, text=True, timeout=30)

    await message.answer("Защита отключена.")
    log_to_file("Защита отключена")

@dp.message(lambda m: m.text == "Включить защиту")
async def enable_blocking(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    await message.answer("Включение защиты...")

    commands = [
        ["sh", "-c", "echo 'nameserver 127.0.0.1' > /etc/resolv.conf"],
        ["systemctl", "start", "unbound"],
    ]
    for cmd in commands:
        subprocess.run(cmd, capture_output=True, text=True)

    # iptables — проверяем, потом добавляем
    check = subprocess.run(
        ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        capture_output=True, text=True
    )
    if check.returncode != 0:
        subprocess.run(
            ["iptables", "-A", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
            capture_output=True, text=True
        )

    subprocess.run(["systemctl", "start", "block-ips.service"], capture_output=True, text=True)
    subprocess.run(["systemctl", "start", "block-domains.service"], capture_output=True, text=True)

    # Docker
    if os.path.exists(DOCKER_RULES_SCRIPT) and os.path.exists("/etc/block-ips/docker_containers.conf"):
        subprocess.run(["bash", DOCKER_RULES_SCRIPT, "enable"],
                       capture_output=True, text=True, timeout=60)

    # Краткий статус Docker
    status_text = "Защита включена."
    if os.path.exists(DOCKER_RULES_SCRIPT):
        scan = get_scan_data()
        if scan and scan.get("containers"):
            status_text += "\n\n" + format_scan_brief(scan)

    await message.answer(status_text)
    log_to_file("Защита включена")

@dp.message(lambda m: m.text == "Перезапустить сервисы")
async def restart_services(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    await message.answer("Перезапуск сервисов...")

    subprocess.run(["systemctl", "restart", "unbound"], capture_output=True, text=True)
    subprocess.run(
        ["iptables", "-D", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        capture_output=True, text=True
    )
    subprocess.run(
        ["iptables", "-A", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        capture_output=True, text=True
    )
    if os.path.exists(DOCKER_RULES_SCRIPT) and os.path.exists("/etc/block-ips/docker_containers.conf"):
        subprocess.run(["bash", DOCKER_RULES_SCRIPT, "apply-ipt"],
                       capture_output=True, text=True, timeout=30)

    await message.answer("Сервисы перезапущены.")
    log_to_file("Сервисы перезапущены")

@dp.message(lambda m: m.text == "Состояние сервера")
async def server_status(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)

    cmds = [["uptime"], ["df", "-h", "/"], ["free", "-h"],
            ["systemctl", "is-active", "unbound"], ["iptables", "-L", "-n"]]
    report = ""
    for cmd in cmds:
        result = subprocess.run(cmd, capture_output=True, text=True)
        report += f"$ {' '.join(cmd)}\n{result.stdout}\n"

    await message.answer(f"Состояние:\n{report[:4000]}")
    log_to_file("Состояние сервера")

@dp.message(lambda m: m.text == "Скачать логи")
async def send_logs(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    try:
        log_files = sorted(
            [f for f in os.listdir(LOG_DIR) if f.startswith("bot-run")],
            reverse=True
        )
        if not log_files:
            await message.answer("Логи не найдены.")
            return
        log_path = os.path.join(LOG_DIR, log_files[0])
        await message.answer_document(FSInputFile(log_path))
    except Exception as e:
        await message.answer(f"Ошибка: {e}")

# ═══════════════════════════════════════════════════════════════════════
# Docker — утилиты
# ═══════════════════════════════════════════════════════════════════════

def get_scan_data() -> dict:
    """Получить данные сканирования через scan-json."""
    try:
        result = subprocess.run(
            ["bash", DOCKER_RULES_SCRIPT, "scan-json"],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
    except Exception:
        pass
    return {}


def format_scan_brief(scan: dict) -> str:
    """Форматировать краткий статус для сообщения."""
    lines = []

    if scan.get("panel_3xui"):
        lines.append(f"Панель 3X-UI обнаружена (контейнер: {scan.get('panel_name', '?')})")
        lines.append("")

    protected = []
    unprotected = []
    for c in scan.get("containers", []):
        if c.get("protected"):
            protected.append(c)
        elif c.get("type") != "Панель":
            unprotected.append(c)

    if protected:
        lines.append("Под защитой:")
        for c in protected:
            lines.append(f"  [OK] {c['name']} ({c['image']}) — {c['type']}")

    if unprotected:
        lines.append("Без защиты:")
        for c in unprotected:
            lines.append(f"  [!] {c['name']} ({c['image']}) — {c['type']}")

    return "\n".join(lines)


def format_scan_full(scan: dict) -> str:
    """Форматировать полный статус для сообщения."""
    lines = []

    if scan.get("panel_3xui"):
        lines.append(f"Панель: 3X-UI ({scan.get('panel_name', '?')})")
        lines.append("")

    containers = scan.get("containers", [])
    if not containers:
        lines.append("Docker-контейнеры не найдены.")
        return "\n".join(lines)

    lines.append("Контейнеры:")
    for c in containers:
        mark = "[OK]" if c.get("protected") else "[!] " if c.get("type") == "VPN" else "[--]"
        status = "защищён" if c.get("protected") else "не защищён"
        lines.append(f"  {mark} {c['name']} — {c['type']}, {status}")
        lines.append(f"       Образ: {c['image']}")
        if c.get("compose"):
            lines.append(f"       Compose: {c['compose']}")

    return "\n".join(lines)


# ═══════════════════════════════════════════════════════════════════════
# Docker — главная кнопка
# ═══════════════════════════════════════════════════════════════════════

@dp.message(lambda m: m.text == "Docker-контейнеры")
async def docker_main_handler(message: types.Message):
    if not await is_admin(message):
        return
    if not os.path.exists(DOCKER_RULES_SCRIPT):
        await message.answer("Docker-модуль не установлен.")
        return

    await message.answer("Сканирование...")

    scan = get_scan_data()
    if not scan or not scan.get("containers"):
        await message.answer("Docker-контейнеры не найдены.")
        return

    text = format_scan_full(scan)

    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="Автонастройка", callback_data="docker_auto"),
         InlineKeyboardButton(text="Статус", callback_data="docker_status_detail")],
        [InlineKeyboardButton(text="Выбрать контейнеры", callback_data="docker_select")],
        [InlineKeyboardButton(text="Отключить Docker-защиту", callback_data="docker_off")],
    ])

    await message.answer(text[:4000], reply_markup=kb)
    log_to_file("Docker: открыто главное меню")


# ═══════════════════════════════════════════════════════════════════════
# Docker — автонастройка
# ═══════════════════════════════════════════════════════════════════════

@dp.callback_query(F.data == "docker_auto")
async def docker_auto_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return

    scan = get_scan_data()
    vpn = [c for c in scan.get("containers", []) if c.get("type") == "VPN"]

    if not vpn:
        await callback.answer("VPN-контейнеры не найдены!", show_alert=True)
        return

    gateway = scan.get("gateway", "?")
    text = "Обнаружены VPN-контейнеры:\n"
    for c in vpn:
        text += f"  - {c['name']} ({c['image']})\n"
    text += f"\nБудет выполнено:\n"
    text += f"  1. iptables DOCKER-USER правила\n"
    text += f"  2. Unbound DNS для Docker\n"
    text += f"  3. DNS в daemon.json ({gateway})\n"
    if any(c.get("compose") for c in vpn):
        text += f"  4. DNS в docker-compose.yml\n"
        text += f"  5. Перезапуск контейнеров\n"
    else:
        text += f"  4. Перезапуск контейнеров\n"
    text += f"\n[!] Контейнеры будут перезапущены!"

    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="Применить", callback_data="docker_auto_confirm"),
         InlineKeyboardButton(text="Отмена", callback_data="docker_auto_cancel")],
    ])

    await callback.message.edit_text(text[:4000], reply_markup=kb)
    await callback.answer()


@dp.callback_query(F.data == "docker_auto_confirm")
async def docker_auto_confirm_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return

    await callback.message.edit_text("Настройка Docker-защиты...")

    try:
        result = subprocess.run(
            ["bash", DOCKER_RULES_SCRIPT, "auto-setup-confirm"],
            capture_output=True, text=True, timeout=180
        )
        output = strip_ansi(result.stdout or "")

        if result.returncode == 0:
            await callback.message.edit_text(f"Docker-защита активирована!\n\n{output[:3500]}")
            log_to_file("Docker: автонастройка выполнена")
        else:
            err = strip_ansi(result.stderr or "")
            await callback.message.edit_text(f"Ошибка:\n{err[:2000]}\n{output[:1500]}")
    except Exception as e:
        await callback.message.edit_text(f"Ошибка: {e}")
    await callback.answer()


@dp.callback_query(F.data == "docker_auto_cancel")
async def docker_auto_cancel_callback(callback: CallbackQuery):
    await callback.message.edit_text("Автонастройка отменена.")
    await callback.answer()


# ═══════════════════════════════════════════════════════════════════════
# Docker — выбор контейнеров
# ═══════════════════════════════════════════════════════════════════════

def build_container_keyboard(user_id: int, containers: list) -> InlineKeyboardMarkup:
    selected = docker_selection.get(user_id, set())
    buttons = []
    for c in containers:
        name = c["name"]
        ctype = c.get("type", "")
        mark = "[+]" if name in selected else "[-]"
        buttons.append([
            InlineKeyboardButton(
                text=f"{mark} {name} ({ctype})",
                callback_data=f"docker_toggle:{name}"
            )
        ])
    buttons.append([
        InlineKeyboardButton(text="Применить", callback_data="docker_sel_apply"),
        InlineKeyboardButton(text="Отмена", callback_data="docker_sel_cancel")
    ])
    return InlineKeyboardMarkup(inline_keyboard=buttons)


@dp.callback_query(F.data == "docker_select")
async def docker_select_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return

    scan = get_scan_data()
    containers = [c for c in scan.get("containers", []) if c.get("type") != "Панель"]

    if not containers:
        await callback.answer("Нет контейнеров для выбора.", show_alert=True)
        return

    user_id = callback.from_user.id
    docker_selection[user_id] = {c["name"] for c in containers if c.get("protected")}

    kb = build_container_keyboard(user_id, containers)
    await callback.message.edit_text(
        "Выберите контейнеры для блокировки:\n"
        "[+] — выбран, [-] — не выбран",
        reply_markup=kb
    )
    await callback.answer()


@dp.callback_query(F.data.startswith("docker_toggle:"))
async def docker_toggle_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return

    name = callback.data.split(":", 1)[1]
    user_id = callback.from_user.id
    selected = docker_selection.get(user_id, set())

    if name in selected:
        selected.discard(name)
    else:
        selected.add(name)
    docker_selection[user_id] = selected

    scan = get_scan_data()
    containers = [c for c in scan.get("containers", []) if c.get("type") != "Панель"]
    if containers:
        kb = build_container_keyboard(user_id, containers)
        await callback.message.edit_reply_markup(reply_markup=kb)
    await callback.answer()


@dp.callback_query(F.data == "docker_sel_apply")
async def docker_sel_apply_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return

    user_id = callback.from_user.id
    selected = docker_selection.get(user_id, set())

    if not selected:
        await callback.answer("Ничего не выбрано!", show_alert=True)
        return

    names = list(selected)
    await callback.message.edit_text(f"Сохраняю: {', '.join(names)}...")

    try:
        result = subprocess.run(
            ["bash", DOCKER_RULES_SCRIPT, "select-by-name"] + names,
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0:
            await callback.message.edit_text(
                f"Контейнеры сохранены: {', '.join(names)}\n\n"
                "Нажмите 'Включить защиту' для применения блокировки."
            )
            log_to_file(f"Docker: выбраны контейнеры: {', '.join(names)}")
        else:
            err = strip_ansi(result.stderr or "")
            await callback.message.edit_text(f"Ошибка:\n{err[:3000]}")
    except Exception as e:
        await callback.message.edit_text(f"Ошибка: {e}")

    docker_selection.pop(user_id, None)
    await callback.answer()


@dp.callback_query(F.data == "docker_sel_cancel")
async def docker_sel_cancel_callback(callback: CallbackQuery):
    docker_selection.pop(callback.from_user.id, None)
    await callback.message.edit_text("Выбор отменён.")
    await callback.answer()


# ═══════════════════════════════════════════════════════════════════════
# Docker — статус и отключение
# ═══════════════════════════════════════════════════════════════════════

@dp.callback_query(F.data == "docker_status_detail")
async def docker_status_detail_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    try:
        result = subprocess.run(
            ["bash", DOCKER_RULES_SCRIPT, "status"],
            capture_output=True, text=True, timeout=30
        )
        output = strip_ansi(result.stdout or "Нет данных")
        await callback.message.edit_text(f"Подробный статус:\n\n{output[:4000]}")
    except Exception as e:
        await callback.message.edit_text(f"Ошибка: {e}")
    await callback.answer()


@dp.callback_query(F.data == "docker_off")
async def docker_off_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return

    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="Да, отключить", callback_data="docker_off_confirm"),
         InlineKeyboardButton(text="Отмена", callback_data="docker_off_cancel")],
    ])
    await callback.message.edit_text(
        "Отключить Docker-блокировку?\n"
        "Правила iptables DOCKER-USER будут удалены.",
        reply_markup=kb
    )
    await callback.answer()


@dp.callback_query(F.data == "docker_off_confirm")
async def docker_off_confirm_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    try:
        result = subprocess.run(
            ["bash", DOCKER_RULES_SCRIPT, "disable"],
            capture_output=True, text=True, timeout=60
        )
        output = strip_ansi(result.stdout or "")
        await callback.message.edit_text(f"Docker-блокировка отключена.\n\n{output[:3000]}")
        log_to_file("Docker: блокировка отключена")
    except Exception as e:
        await callback.message.edit_text(f"Ошибка: {e}")
    await callback.answer()


@dp.callback_query(F.data == "docker_off_cancel")
async def docker_off_cancel_callback(callback: CallbackQuery):
    await callback.message.edit_text("Отключение отменено.")
    await callback.answer()


# ═══════════════════════════════════════════════════════════════════════
# Запуск
# ═══════════════════════════════════════════════════════════════════════

async def main():
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
