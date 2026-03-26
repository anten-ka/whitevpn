import asyncio
import subprocess
import json
import os
import re
import glob
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

# Docker
DOCKER_RULES_SCRIPT = "/opt/block-traffic/docker_rules.sh"

# Определение директории логов и файла для временной метки рекламы
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
https://vk.cc/ct29NQ
https://vk.cc/ct29NQ

OFF60
- 60% скидка на первый месяц

antenka20
- скидка на 20% + 3% за 3 месяца

antenka6
- скидка на 15% + 5% за 6 месяцев

antenka12
- скидка на 5% + 10% за год
=================
Хостинг #2
https://vk.cc/cO0UaZ
https://vk.cc/cO0UaZ
https://vk.cc/cO0UaZ

(бонус 15% по ссылке в течении 24 часов)
=================
Реферальные ссылки помогают проекту. Спасибо.
'''

# Функция для логирования
def log_to_file(message):
    with open(LOG_FILE, "a") as f:
        f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - {message}\n")

# Функция для проверки и отображения рекламы
async def show_ad_if_needed(message: types.Message):
    current_time = int(datetime.now().timestamp())
    if os.path.exists(AD_TIMESTAMP_FILE):
        with open(AD_TIMESTAMP_FILE, 'r') as f:
            last_ad_time = int(f.read().strip())
        time_diff = current_time - last_ad_time
        if time_diff < 3600:
            return
    await message.answer(referal_text)
    log_to_file("Реклама отображена")
    with open(AD_TIMESTAMP_FILE, 'w') as f:
        f.write(str(current_time))

# Вспомогательная функция: очистка ANSI-кодов
def strip_ansi(text):
    return re.sub(r'\033\[[0-9;]*m', '', text)

# Инициализация бота
bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()

# Создание клавиатуры
def get_main_menu():
    key = [
        [KeyboardButton(text='Обновить IP и домены')],
        [KeyboardButton(text='Отключить защиту'), KeyboardButton(text='Включить защиту')],
        [KeyboardButton(text='Перезапустить сервисы')],
        [KeyboardButton(text='Состояние сервера'), KeyboardButton(text='Скачать логи')],
        [KeyboardButton(text='Docker: статус')],
        [KeyboardButton(text='Docker: вкл'), KeyboardButton(text='Docker: выкл')],
        [KeyboardButton(text='Docker: контейнеры'), KeyboardButton(text='Docker: DNS')],
    ]
    return ReplyKeyboardMarkup(keyboard=key, resize_keyboard=True)

# Проверка прав администратора
async def is_admin(message: types.Message):
    if message.from_user.id != ADMIN_ID:
        await message.answer("Доступ запрещён. Вы не администратор.")
        log_to_file(f"Неавторизованный доступ: ID {message.from_user.id}, Username: @{message.from_user.username}")
        return False
    return True

# Проверка прав для callback
async def is_admin_callback(callback: CallbackQuery):
    if callback.from_user.id != ADMIN_ID:
        await callback.answer("Доступ запрещён.", show_alert=True)
        return False
    return True

@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    await message.answer("Добро пожаловать! \nИнструкции можно найти на GitHub: https://github.com/anten-ka/whitevpn\n Выберите действие:", reply_markup=get_main_menu())
    log_to_file(f"Админ {message.from_user.id} запустил бота")

@dp.message(lambda m: m.text == "Обновить IP и домены")
async def update_all(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    await message.answer("Обновление IP и доменов...")
    log_to_file("Обновление IP и доменов")

    ip_script = f"{INSTALL_DIR}/block_ips.py"
    if os.path.exists(ip_script):
        result = subprocess.run(
            [f"{INSTALL_DIR}/venv/bin/python3", ip_script],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            await message.answer(f"Обновление IP завершено:\n{result.stdout}")
            log_to_file("Обновление IP завершено")
        else:
            await message.answer(f"Ошибка обновления IP:\n{result.stderr}")
            log_to_file(f"Ошибка обновления IP: {result.stderr}")
    else:
        await message.answer(f"Файл {ip_script} не найден.")
        log_to_file(f"Файл {ip_script} не найден")

    domain_script = f"{INSTALL_DIR}/blocked-domains/block_domains.py"
    if os.path.exists(domain_script):
        result = subprocess.run(
            [f"{INSTALL_DIR}/venv/bin/python3", domain_script],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            await message.answer(f"Обновление доменов завершено:\n{result.stdout}")
            log_to_file("Обновление доменов завершено")
        else:
            await message.answer(f"Ошибка обновления доменов:\n{result.stderr}")
            log_to_file(f"Ошибка обновления доменов: {result.stderr}")
    else:
        await message.answer(f"Файл {domain_script} не найден.")
        log_to_file(f"Файл {domain_script} не найден")

@dp.message(lambda m: m.text == "Отключить защиту")
async def disable_blocking(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    await message.answer("Отключение защиты...")
    log_to_file("Отключение защиты")

    commands = [
        ["iptables", "-D", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        ["systemctl", "stop", "unbound"],
        ["systemctl", "stop", "block-ips.service"],
        ["systemctl", "stop", "block-domains.service"],
        ["sh", "-c", "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"]
    ]
    for cmd in commands:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 and "iptables" not in cmd:
            await message.answer(f"Ошибка: {result.stderr}")
            log_to_file(f"Ошибка при выполнении {cmd}: {result.stderr}")
            return

    # Docker-блокировка
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
    log_to_file("Включение зыщиты")

    commands = [
        ["sh", "-c", "echo 'nameserver 127.0.0.1' > /etc/resolv.conf"],
        ["systemctl", "start", "unbound"],
        ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        ["iptables", "-A", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        ["systemctl", "start", "block-ips.service"],
        ["systemctl", "start", "block-domains.service"]
    ]
    for cmd in commands:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 and cmd[1] != "-C":
            await message.answer(f"Ошибка: {result.stderr}")
            log_to_file(f"Ошибка при выполнении {cmd}: {result.stderr}")
            return

    # Docker-блокировка
    if os.path.exists(DOCKER_RULES_SCRIPT) and os.path.exists("/etc/block-ips/docker_containers.conf"):
        subprocess.run(["bash", DOCKER_RULES_SCRIPT, "enable"],
                       capture_output=True, text=True, timeout=60)

    await message.answer("Защита включена.")
    log_to_file("Защита включена")

@dp.message(lambda m: m.text == "Перезапустить сервисы")
async def restart_services(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    await message.answer("Перезапуск Unbound и iptables...")
    log_to_file("Перезапуск Unbound и iptables")

    commands = [
        ["systemctl", "restart", "unbound"],
        ["iptables", "-D", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        ["iptables", "-A", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"]
    ]
    for cmd in commands:
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 and "iptables" not in cmd:
            await message.answer(f"Ошибка: {result.stderr}")
            log_to_file(f"Ошибка при выполнении {cmd}: {result.stderr}")
            return

    # Docker-правила
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
    await message.answer("Сбор информации о состоянии сервера...")
    log_to_file("Запрос состояния сервера")

    cmds = [
        ["uptime"],
        ["df", "-h", "/"],
        ["free", "-h"],
        ["systemctl", "is-active", "unbound"],
        ["iptables", "-L", "-n"]
    ]
    report = ""
    for cmd in cmds:
        result = subprocess.run(cmd, capture_output=True, text=True)
        report += f"$ {' '.join(cmd)}\n{result.stdout}\n"

    await message.answer(f"Состояние сервера:\n{report}")
    log_to_file("Состояние сервера отправлено")

@dp.message(lambda m: m.text == "Скачать логи")
async def send_logs(message: types.Message):
    if not await is_admin(message):
        return
    await show_ad_if_needed(message)
    await message.answer("Отправка логов...")
    log_to_file("Запрошена отправка логов")

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
        log_to_file("Логи отправлены")
    except Exception as e:
        await message.answer(f"Ошибка отправки логов: {e}")
        log_to_file(f"Ошибка отправки логов: {e}")

# ─── Docker-обработчики ──────────────────────────────────────────────

@dp.message(lambda m: m.text == "Docker: статус")
async def docker_status_handler(message: types.Message):
    if not await is_admin(message):
        return
    if not os.path.exists(DOCKER_RULES_SCRIPT):
        await message.answer("Docker-модуль не установлен.")
        return
    try:
        result = subprocess.run(["bash", DOCKER_RULES_SCRIPT, "status"],
                                capture_output=True, text=True, timeout=30)
        output = strip_ansi(result.stdout or "Нет данных")
        await message.answer(f"Docker-блокировка:\n\n{output[:4000]}")
        log_to_file("Docker: запрошен статус")
    except Exception as e:
        await message.answer(f"Ошибка: {e}")
        log_to_file(f"Docker статус ошибка: {e}")

@dp.message(lambda m: m.text == "Docker: вкл")
async def docker_enable_handler(message: types.Message):
    if not await is_admin(message):
        return
    if not os.path.exists(DOCKER_RULES_SCRIPT):
        await message.answer("Docker-модуль не установлен.")
        return
    await message.answer("Включаю Docker-блокировку...")
    try:
        result = subprocess.run(["bash", DOCKER_RULES_SCRIPT, "enable"],
                                capture_output=True, text=True, timeout=60)
        output = strip_ansi(result.stdout or "")
        if result.returncode == 0:
            await message.answer(f"Docker-блокировка включена.\n\n{output[:3000]}")
            log_to_file("Docker: блокировка включена")
        else:
            err = strip_ansi(result.stderr or "")
            await message.answer(f"Ошибка:\n{err[:3000]}\n{output[:1000]}")
            log_to_file(f"Docker включение ошибка: {err}")
    except Exception as e:
        await message.answer(f"Ошибка: {e}")
        log_to_file(f"Docker включение ошибка: {e}")

@dp.message(lambda m: m.text == "Docker: выкл")
async def docker_disable_handler(message: types.Message):
    if not await is_admin(message):
        return
    if not os.path.exists(DOCKER_RULES_SCRIPT):
        await message.answer("Docker-модуль не установлен.")
        return
    await message.answer("Отключаю Docker-блокировку...")
    try:
        result = subprocess.run(["bash", DOCKER_RULES_SCRIPT, "disable"],
                                capture_output=True, text=True, timeout=60)
        output = strip_ansi(result.stdout or "")
        await message.answer(f"Docker-блокировка отключена.\n\n{output[:3000]}")
        log_to_file("Docker: блокировка отключена")
    except Exception as e:
        await message.answer(f"Ошибка: {e}")
        log_to_file(f"Docker отключение ошибка: {e}")

# ─── Docker: выбор контейнеров (inline-клавиатура) ──────────────────

def build_container_keyboard(user_id: int, containers: list) -> InlineKeyboardMarkup:
    """Строит inline-клавиатуру для выбора контейнеров."""
    selected = docker_selection.get(user_id, set())
    buttons = []
    for c in containers:
        name = c["name"]
        mark = "+" if name in selected else "-"
        buttons.append([
            InlineKeyboardButton(
                text=f"[{mark}] {name} ({c['image']})",
                callback_data=f"docker_toggle:{name}"
            )
        ])
    buttons.append([
        InlineKeyboardButton(text="Применить выбор", callback_data="docker_apply"),
        InlineKeyboardButton(text="Отмена", callback_data="docker_cancel")
    ])
    return InlineKeyboardMarkup(inline_keyboard=buttons)


def get_docker_containers() -> list:
    """Получает список контейнеров через docker_rules.sh list-containers."""
    try:
        result = subprocess.run(
            ["bash", DOCKER_RULES_SCRIPT, "list-containers"],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
    except Exception:
        pass
    return []


@dp.message(lambda m: m.text == "Docker: контейнеры")
async def docker_containers_handler(message: types.Message):
    if not await is_admin(message):
        return
    if not os.path.exists(DOCKER_RULES_SCRIPT):
        await message.answer("Docker-модуль не установлен.")
        return

    containers = get_docker_containers()
    if not containers:
        await message.answer("Нет запущенных Docker-контейнеров.")
        return

    user_id = message.from_user.id
    # Инициализируем выбор текущими сохранёнными контейнерами
    docker_selection[user_id] = {
        c["name"] for c in containers if c.get("selected")
    }

    kb = build_container_keyboard(user_id, containers)
    await message.answer(
        "Выберите контейнеры для блокировки.\n"
        "[+] — выбран, [-] — не выбран.\n"
        "Нажмите на контейнер для переключения.",
        reply_markup=kb
    )
    log_to_file("Docker: открыт выбор контейнеров")


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

    # Обновляем клавиатуру
    containers = get_docker_containers()
    if containers:
        kb = build_container_keyboard(user_id, containers)
        await callback.message.edit_reply_markup(reply_markup=kb)
    await callback.answer()


@dp.callback_query(F.data == "docker_apply")
async def docker_apply_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return

    user_id = callback.from_user.id
    selected = docker_selection.get(user_id, set())

    if not selected:
        await callback.answer("Ничего не выбрано!", show_alert=True)
        return

    names = list(selected)
    await callback.message.edit_text(f"Сохраняю контейнеры: {', '.join(names)}...")

    try:
        result = subprocess.run(
            ["bash", DOCKER_RULES_SCRIPT, "select-by-name"] + names,
            capture_output=True, text=True, timeout=15
        )
        output = strip_ansi(result.stdout or "")
        if result.returncode == 0:
            await callback.message.edit_text(
                f"Контейнеры сохранены:\n{output[:3000]}\n\n"
                "Для применения блокировки нажмите 'Docker: вкл'"
            )
            log_to_file(f"Docker: выбраны контейнеры: {', '.join(names)}")
        else:
            err = strip_ansi(result.stderr or "")
            await callback.message.edit_text(f"Ошибка:\n{err[:3000]}")
    except Exception as e:
        await callback.message.edit_text(f"Ошибка: {e}")

    docker_selection.pop(user_id, None)
    await callback.answer()


@dp.callback_query(F.data == "docker_cancel")
async def docker_cancel_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    user_id = callback.from_user.id
    docker_selection.pop(user_id, None)
    await callback.message.edit_text("Выбор контейнеров отменён.")
    await callback.answer()


# ─── Docker: DNS ─────────────────────────────────────────────────────

@dp.message(lambda m: m.text == "Docker: DNS")
async def docker_dns_handler(message: types.Message):
    if not await is_admin(message):
        return
    if not os.path.exists(DOCKER_RULES_SCRIPT):
        await message.answer("Docker-модуль не установлен.")
        return

    kb = InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="Настроить DNS", callback_data="docker_dns_on"),
            InlineKeyboardButton(text="Сбросить DNS", callback_data="docker_dns_off"),
        ],
        [InlineKeyboardButton(text="Отмена", callback_data="docker_dns_cancel")]
    ])
    await message.answer(
        "DNS Docker-демона:\n\n"
        "Настроить — контейнеры будут использовать Unbound\n"
        "(необходимо для блокировки по доменам)\n\n"
        "Сбросить — вернуть DNS по умолчанию\n\n"
        "ВАЖНО: после изменения DNS контейнеры нужно пересоздать!",
        reply_markup=kb
    )


@dp.callback_query(F.data == "docker_dns_on")
async def docker_dns_on_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("Настраиваю DNS Docker-демона...")
    try:
        result = subprocess.run(
            ["bash", DOCKER_RULES_SCRIPT, "dns-on"],
            capture_output=True, text=True, timeout=120
        )
        output = strip_ansi(result.stdout or "")
        if result.returncode == 0:
            await callback.message.edit_text(
                f"DNS Docker-демона настроен.\n\n{output[:3000]}\n\n"
                "Пересоздайте контейнеры для применения!"
            )
            log_to_file("Docker: DNS настроен")
        else:
            err = strip_ansi(result.stderr or "")
            await callback.message.edit_text(f"Ошибка:\n{err[:3000]}")
    except Exception as e:
        await callback.message.edit_text(f"Ошибка: {e}")
    await callback.answer()


@dp.callback_query(F.data == "docker_dns_off")
async def docker_dns_off_callback(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("Сбрасываю DNS Docker-демона...")
    try:
        result = subprocess.run(
            ["bash", DOCKER_RULES_SCRIPT, "dns-off"],
            capture_output=True, text=True, timeout=120
        )
        output = strip_ansi(result.stdout or "")
        await callback.message.edit_text(
            f"DNS Docker-демона сброшен.\n\n{output[:3000]}\n\n"
            "Пересоздайте контейнеры для применения!"
        )
        log_to_file("Docker: DNS сброшен")
    except Exception as e:
        await callback.message.edit_text(f"Ошибка: {e}")
    await callback.answer()


@dp.callback_query(F.data == "docker_dns_cancel")
async def docker_dns_cancel_callback(callback: CallbackQuery):
    await callback.message.edit_text("Настройка DNS отменена.")
    await callback.answer()


# ─── Запуск ──────────────────────────────────────────────────────────

async def main():
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
