import asyncio
import subprocess
import os
import re
import time
from datetime import datetime
from aiogram import Dispatcher, types, F
from aiogram.filters import Command
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton, CallbackQuery
from aiogram.client.session import aiohttp_session
import aiohttp
import logging

# Version constant
VERSION = "0.3"

# Logging setup
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration
ADMIN_IDS = [123456789]  # Replace with actual admin IDs
BOT_TOKEN = os.getenv("BOT_TOKEN", "YOUR_BOT_TOKEN")
DOCKER_RULES_SCRIPT = "/usr/local/bin/docker-block-rules.sh"

# Directories
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "logs")
DOCKER_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "docker")

# Ensure log directory exists
if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR, mode=0o755)

LOG_FILE = os.path.join(LOG_DIR, f"bot-{datetime.now().strftime('%Y-%m-%d')}.log")

def log_to_file(message: str):
    """Log message to file."""
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - {message}\n")
    except Exception as e:
        logger.error(f"Error writing to log file: {e}")

async def is_admin(message: types.Message) -> bool:
    """Check if user is admin."""
    if message.from_user.id not in ADMIN_IDS:
        await message.answer("Доступ запрещён. Только администраторы могут использовать эту команду.")
        return False
    return True

async def is_admin_callback(callback: CallbackQuery) -> bool:
    """Check if user is admin for callback query."""
    if callback.from_user.id not in ADMIN_IDS:
        await callback.answer("Доступ запрещён.", show_alert=True)
        return False
    return True

def get_main_menu() -> InlineKeyboardMarkup:
    """Get main menu keyboard."""
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="Обновить IP и домены", callback_data="update_domains")],
        [InlineKeyboardButton(text="Включить защиту", callback_data="enable_protection"),
         InlineKeyboardButton(text="Отключить защиту", callback_data="disable_protection_btn")],
        [InlineKeyboardButton(text="Перезапустить сервисы", callback_data="restart_services")],
        [InlineKeyboardButton(text="Состояние сервера", callback_data="server_status")],
        [InlineKeyboardButton(text="Скачать логи", callback_data="download_logs")],
        [InlineKeyboardButton(text="Docker-контейнеры", callback_data="docker_menu")],
    ])

async def show_ad_if_needed(message: types.Message):
    """Show ad if needed (placeholder for future implementation)."""
    pass

# Initialize dispatcher and bot
dp = Dispatcher()

# ============= MESSAGE HANDLERS =============

@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    """Handle /start command."""
    if not await is_admin(message):
        return
    await message.answer(
        f"WhiteVPN v{VERSION} — Управление блокировкой\n"
        "GitHub: https://github.com/anten-ka/whitevpn\n\n"
        "Выберите действие:",
        reply_markup=get_main_menu()
    )
    log_to_file(f"User {message.from_user.id} started bot")

@dp.message(Command("help"))
async def cmd_help(message: types.Message):
    """Handle /help command."""
    if not await is_admin(message):
        return
    help_text = (
        "WhiteVPN — команды и кнопки:\n\n"
        "/start — главное меню\n"
        "/help — эта справка\n"
        "/health — проверка работоспособности блокировки\n\n"
        "Кнопки:\n"
        "• Обновить IP и домены — обновить списки блокировки\n"
        "• Включить/Отключить защиту — управление блокировкой\n"
        "• Перезапустить сервисы — перезапуск Unbound и iptables\n"
        "• Состояние сервера — uptime, диск, память\n"
        "• Скачать логи — скачать лог-файл\n"
        "• Docker-контейнеры — управление Docker-блокировкой"
    )
    await message.answer(help_text)

@dp.message(Command("health"))
async def cmd_health(message: types.Message):
    """Handle /health command - check blocking functionality."""
    if not await is_admin(message):
        return
    await message.answer("Проверка здоровья блокировки...")

    checks = []

    # Check Unbound
    result = subprocess.run(["systemctl", "is-active", "unbound"], capture_output=True, text=True)
    unbound_ok = result.stdout.strip() == "active"
    checks.append(f"{'✓' if unbound_ok else '✗'} Unbound: {result.stdout.strip()}")

    # Check ipset
    result = subprocess.run(["ipset", "list", "blocked_ips", "-t"], capture_output=True, text=True)
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            if "Number of entries" in line:
                count = line.split(":")[1].strip()
                checks.append(f"✓ ipset blocked_ips: {count} записей")
                break
    else:
        checks.append("✗ ipset blocked_ips: не найден")

    # Check iptables OUTPUT rule
    result = subprocess.run(
        ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        capture_output=True, text=True
    )
    ipt_ok = result.returncode == 0
    checks.append(f"{'✓' if ipt_ok else '✗'} iptables OUTPUT: {'активно' if ipt_ok else 'не найдено'}")

    # Check DNS resolution of a known blocked domain
    try:
        result = subprocess.run(["dig", "@127.0.0.1", "google.com", "+short"],
                              capture_output=True, text=True, timeout=5)
        dns_ok = bool(result.stdout.strip())
        checks.append(f"{'✓' if dns_ok else '✗'} DNS (google.com): {'работает' if dns_ok else 'не отвечает'}")
    except subprocess.TimeoutExpired:
        checks.append("✗ DNS (google.com): timeout")

    # Check resolv.conf
    try:
        with open("/etc/resolv.conf", "r") as f:
            resolv = f.read().strip()
        resolv_ok = "127.0.0.1" in resolv
        checks.append(f"{'✓' if resolv_ok else '✗'} resolv.conf: {'127.0.0.1' if resolv_ok else resolv[:50]}")
    except Exception:
        checks.append("✗ resolv.conf: не удалось прочитать")

    # Docker check
    if os.path.exists(DOCKER_RULES_SCRIPT):
        result = subprocess.run(
            ["iptables", "-L", "DOCKER-USER", "-n"],
            capture_output=True, text=True
        )
        docker_rules = "blocked_ips" in result.stdout
        checks.append(f"{'✓' if docker_rules else '✗'} Docker DOCKER-USER: {'активно' if docker_rules else 'нет правил'}")

    report = "Проверка здоровья:\n\n" + "\n".join(checks)
    await message.answer(report)
    log_to_file("Health check выполнен")

# ============= CALLBACK HANDLERS =============

@dp.callback_query(F.data == "update_domains")
async def update_domains(callback: CallbackQuery):
    """Update IP and domain lists."""
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("Обновление списков доменов и IP...")

    try:
        # Run the block-domains script
        subprocess.run(["/usr/local/bin/block-domains.py"],
                      capture_output=True, text=True, timeout=120)

        # Run the block-ips script
        subprocess.run(["/usr/local/bin/block-ips.py"],
                      capture_output=True, text=True, timeout=120)

        await callback.message.edit_text("✓ Списки успешно обновлены.")
        log_to_file("Списки доменов и IP обновлены")
    except subprocess.TimeoutExpired:
        await callback.message.edit_text("✗ Ошибка: время ожидания истекло.")
        log_to_file("Ошибка при обновлении: timeout")
    except Exception as e:
        await callback.message.edit_text(f"✗ Ошибка обновления: {str(e)}")
        log_to_file(f"Ошибка обновления: {e}")

    await callback.answer()

@dp.callback_query(F.data == "disable_protection_btn")
async def disable_blocking_btn(callback: CallbackQuery):
    """Show confirmation for disabling protection."""
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("Вы уверены, что хотите отключить защиту?\n"
                                     "Все правила iptables и DNS-блокировка будут деактивированы.",
                                     reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                                         [InlineKeyboardButton(text="Да, отключить", callback_data="confirm_disable"),
                                          InlineKeyboardButton(text="Отмена", callback_data="cancel_disable")],
                                     ]))
    await callback.answer()

@dp.callback_query(F.data == "confirm_disable")
async def confirm_disable_callback(callback: CallbackQuery):
    """Confirm and disable protection."""
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("Отключение защиты...")

    try:
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

        await callback.message.edit_text("Защита отключена.")
        log_to_file("Защита отключена")
    except Exception as e:
        await callback.message.edit_text(f"Ошибка при отключении: {str(e)}")
        log_to_file(f"Ошибка отключения: {str(e)}")
    await callback.answer()

@dp.callback_query(F.data == "cancel_disable")
async def cancel_disable_callback(callback: CallbackQuery):
    """Cancel disabling protection."""
    await callback.message.edit_text("Отключение отменено.")
    await callback.answer()

@dp.callback_query(F.data == "enable_protection")
async def enable_protection(callback: CallbackQuery):
    """Enable protection."""
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("Включение защиты...")

    try:
        commands = [
            ["systemctl", "start", "unbound"],
            ["systemctl", "start", "block-ips.service"],
            ["systemctl", "start", "block-domains.service"],
            ["sh", "-c", "echo 'nameserver 127.0.0.1' > /etc/resolv.conf"],
            ["iptables", "-A", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        ]

        for cmd in commands:
            subprocess.run(cmd, capture_output=True, text=True)

        if os.path.exists(DOCKER_RULES_SCRIPT):
            subprocess.run(["bash", DOCKER_RULES_SCRIPT, "enable"],
                           capture_output=True, text=True, timeout=30)

        await callback.message.edit_text("✓ Защита включена.")
        log_to_file("Защита включена")
    except Exception as e:
        await callback.message.edit_text(f"✗ Ошибка: {str(e)}")
        log_to_file(f"Ошибка включения защиты: {e}")

    await callback.answer()

@dp.callback_query(F.data == "restart_services")
async def restart_services(callback: CallbackQuery):
    """Restart services."""
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("Перезапуск сервисов...")

    try:
        services = ["unbound", "block-ips.service", "block-domains.service"]
        for service in services:
            subprocess.run(["systemctl", "restart", service], capture_output=True, text=True)

        await callback.message.edit_text("✓ Сервисы перезапущены.")
        log_to_file("Сервисы перезапущены")
    except Exception as e:
        await callback.message.edit_text(f"✗ Ошибка: {str(e)}")
        log_to_file(f"Ошибка перезапуска: {e}")

    await callback.answer()

@dp.callback_query(F.data == "server_status")
async def server_status(callback: CallbackQuery):
    """Get server status."""
    if not await is_admin_callback(callback):
        return

    try:
        # Get uptime
        with open("/proc/uptime", "r") as f:
            uptime_seconds = int(float(f.read().split()[0]))
        days = uptime_seconds // 86400
        hours = (uptime_seconds % 86400) // 3600
        minutes = (uptime_seconds % 3600) // 60

        # Get disk usage
        result = subprocess.run(["df", "-h", "/"], capture_output=True, text=True)
        disk_lines = result.stdout.strip().split('\n')
        disk_info = disk_lines[1] if len(disk_lines) > 1 else "N/A"

        # Get memory usage
        result = subprocess.run(["free", "-h"], capture_output=True, text=True)
        memory_lines = result.stdout.strip().split('\n')
        memory_info = memory_lines[1] if len(memory_lines) > 1 else "N/A"

        status_text = (
            f"Uptime: {days}d {hours}h {minutes}m\n"
            f"Диск: {disk_info}\n"
            f"Память: {memory_info}"
        )

        await callback.message.edit_text(f"Состояние сервера:\n\n{status_text}")
    except Exception as e:
        await callback.message.edit_text(f"✗ Ошибка получения статуса: {str(e)}")

    await callback.answer()

@dp.callback_query(F.data == "download_logs")
async def download_logs(callback: CallbackQuery):
    """Download logs (placeholder)."""
    if not await is_admin_callback(callback):
        return

    if os.path.exists(LOG_FILE):
        try:
            with open(LOG_FILE, "r") as f:
                logs = f.read()

            if len(logs) <= 4096:
                await callback.message.answer(f"Логи:\n\n{logs}")
            else:
                # Send truncated version
                await callback.message.answer(f"Логи (последние 1000 символов):\n\n{logs[-1000:]}")

            log_to_file("Логи скачаны")
        except Exception as e:
            await callback.message.edit_text(f"✗ Ошибка: {str(e)}")
    else:
        await callback.message.edit_text("Логи не найдены.")

    await callback.answer()

@dp.callback_query(F.data == "docker_menu")
async def docker_menu(callback: CallbackQuery):
    """Show Docker menu."""
    if not await is_admin_callback(callback):
        return

    docker_kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="Включить Docker-блокировку", callback_data="docker_enable")],
        [InlineKeyboardButton(text="Отключить Docker-блокировку", callback_data="docker_disable")],
        [InlineKeyboardButton(text="Статус Docker-блокировки", callback_data="docker_status")],
        [InlineKeyboardButton(text="Назад", callback_data="back_to_menu")],
    ])

    await callback.message.edit_text("Docker-контейнеры:", reply_markup=docker_kb)
    await callback.answer()

@dp.callback_query(F.data == "docker_enable")
async def docker_enable(callback: CallbackQuery):
    """Enable Docker blocking."""
    if not await is_admin_callback(callback):
        return

    await callback.message.edit_text("Включение Docker-блокировки...")

    try:
        if os.path.exists(DOCKER_RULES_SCRIPT):
            subprocess.run(["bash", DOCKER_RULES_SCRIPT, "enable"],
                           capture_output=True, text=True, timeout=30)
            await callback.message.edit_text("✓ Docker-блокировка включена.")
            log_to_file("Docker-блокировка включена")
        else:
            await callback.message.edit_text("✗ Скрипт Docker не найден.")
    except Exception as e:
        await callback.message.edit_text(f"✗ Ошибка: {str(e)}")
        log_to_file(f"Ошибка включения Docker-блокировки: {e}")

    await callback.answer()

@dp.callback_query(F.data == "docker_disable")
async def docker_disable(callback: CallbackQuery):
    """Disable Docker blocking."""
    if not await is_admin_callback(callback):
        return

    await callback.message.edit_text("Отключение Docker-блокировки...")

    try:
        if os.path.exists(DOCKER_RULES_SCRIPT):
            subprocess.run(["bash", DOCKER_RULES_SCRIPT, "disable"],
                           capture_output=True, text=True, timeout=30)
            await callback.message.edit_text("✓ Docker-блокировка отключена.")
            log_to_file("Docker-блокировка отключена")
        else:
            await callback.message.edit_text("✗ Скрипт Docker не найден.")
    except Exception as e:
        await callback.message.edit_text(f"✗ Ошибка: {str(e)}")
        log_to_file(f"Ошибка отключения Docker-блокировки: {e}")

    await callback.answer()

@dp.callback_query(F.data == "docker_status")
async def docker_status(callback: CallbackQuery):
    """Check Docker blocking status."""
    if not await is_admin_callback(callback):
        return

    try:
        result = subprocess.run(
            ["iptables", "-L", "DOCKER-USER", "-n"],
            capture_output=True, text=True
        )

        if result.returncode == 0:
            docker_rules = "blocked_ips" in result.stdout
            status = "✓ активна" if docker_rules else "✗ неактивна"
            await callback.message.edit_text(f"Docker-блокировка: {status}")
        else:
            await callback.message.edit_text("✗ Не удалось проверить статус.")
    except Exception as e:
        await callback.message.edit_text(f"✗ Ошибка: {str(e)}")

    await callback.answer()

@dp.callback_query(F.data == "back_to_menu")
async def back_to_menu(callback: CallbackQuery):
    """Go back to main menu."""
    await callback.message.edit_text(
        f"WhiteVPN v{VERSION} — Управление блокировкой\n"
        "GitHub: https://github.com/anten-ka/whitevpn\n\n"
        "Выберите действие:",
        reply_markup=get_main_menu()
    )
    await callback.answer()

# ============= MAIN =============

async def main():
    """Main entry point."""
    logger.info(f"Starting WhiteVPN Bot v{VERSION}")
    log_to_file(f"Bot started (v{VERSION})")

    # Start polling (this is a placeholder - actual bot setup depends on your framework)
    # await dp.start_polling()

if __name__ == "__main__":
    logger.info(f"WhiteVPN Bot v{VERSION} initialized")
