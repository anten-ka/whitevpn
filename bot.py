import asyncio
import subprocess
import json
import os
import glob
from datetime import datetime
from aiogram import Bot, Dispatcher, types
from aiogram.filters import Command
from aiogram.types import ReplyKeyboardMarkup, KeyboardButton, FSInputFile

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

# Определение директории логов и файла для временной метки рекламы
LOG_DIR = os.path.join(os.path.dirname(INSTALL_DIR), "logs")
LOG_FILE = os.path.join(LOG_DIR, f"bot-run-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.log")
AD_TIMESTAMP_FILE = "/etc/block-ips/last_ad_timestamp"

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
    # Проверка времени последнего показа рекламы
    if os.path.exists(AD_TIMESTAMP_FILE):
        with open(AD_TIMESTAMP_FILE, 'r') as f:
            last_ad_time = int(f.read().strip())
        time_diff = current_time - last_ad_time
        # 3600 секунд = 1 час
        if time_diff < 3600:
            return
    # Отображение рекламы и обновление временной метки
    await message.answer(referal_text)
    log_to_file("Реклама отображена")
    with open(AD_TIMESTAMP_FILE, 'w') as f:
        f.write(str(current_time))

# Инициализация бота
bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()

# Создание клавиатуры
def get_main_menu():
    key = [
        [KeyboardButton(text='Обновить IP и домены')],
        [KeyboardButton(text='Отключить защиту'), KeyboardButton(text='Включить защиту')],
        [KeyboardButton(text='Перезапустить сервисы')],
        [KeyboardButton(text='Состояние сервера'), KeyboardButton(text='Скачать логи')]
    ]
    return ReplyKeyboardMarkup(keyboard=key, resize_keyboard=True)

# Проверка прав администратора
async def is_admin(message: types.Message):
    if message.from_user.id != ADMIN_ID:
        await message.answer("Доступ запрещён. Вы не администратор.")
        log_to_file(f"Неавторизованный доступ: ID {message.from_user.id}, Username: @{message.from_user.username}")
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

    # Обновление IP
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

    # Обновление доменов
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
        if result.returncode != 0 and "iptables" not in cmd:  # Пропускаем ошибку iptables, если правило не существует
            await message.answer(f"Ошибка: {result.stderr}")
            log_to_file(f"Ошибка при выполнении {cmd}: {result.stderr}")
            return
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
        if result.returncode != 0 and cmd[1] != "-C":  # Пропускаем ошибку проверки iptables
            await message.answer(f"Ошибка: {result.stderr}")
            log_to_file(f"Ошибка при выполнении {cmd}: {result.stderr}")
            return
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
        if result.returncode != 0 and "iptables" not in cmd:  # Пропускаем ошибку iptables
            await message.answer(f"Ошибка: {result.stderr}")
            log_to_file(f"Ошибка при выполнении {cmd}: {result.stderr}")
            return
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

async def main():
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())