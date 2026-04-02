import asyncio
import subprocess
import os
import re
import time
import json
import logging
import ipaddress
from datetime import datetime, timedelta
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from aiogram.types import (
    InlineKeyboardMarkup, InlineKeyboardButton, CallbackQuery,
    ReplyKeyboardMarkup, KeyboardButton
)
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage

# Version constant
VERSION = "0.4"

# Logging setup
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration
CONFIG_FILE = "/etc/block-ips/bot_config.json"
DOCKER_RULES_SCRIPT = "/opt/block-traffic/docker_rules.sh"
SYSTEM_INSTALL_DIR = "/opt/block-traffic"
VENV_PYTHON = os.path.join(SYSTEM_INSTALL_DIR, "venv", "bin", "python3")
WHITELIST_DIR = os.path.join(SYSTEM_INSTALL_DIR, "whitelist")
WHITELIST_CONF = os.path.join(WHITELIST_DIR, "whitelist.conf")

# Реферальные ссылки
REFERRAL_TEXT = (
    "━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    "💰 *Партнёрские предложения:*\n\n"
    "🖥 VPS хостинг со скидкой до 60%:\n"
    "👉 [Перейти](https://vk.cc/ct29NQ)\n"
    "Промокоды:\n"
    "• `OFF60` — 60% на первый месяц\n"
    "• `antenka20` — 20% + 3% за 3 мес.\n"
    "• `antenka6` — 15% + 5% за 6 мес.\n\n"
    "🌐 Бонус 15% по ссылке (24 часа):\n"
    "👉 [Перейти](https://vk.cc/cO0UaZ)\n"
    "━━━━━━━━━━━━━━━━━━━━━━━━━"
)

# Трекер показа рефералки (раз в сутки, persistent)
REFERRAL_LOG_FILE = None  # Инициализируется после LOG_DIR


def load_config():
    """Load bot configuration from JSON file."""
    try:
        with open(CONFIG_FILE, "r") as f:
            config = json.load(f)
        return config.get("BOT_TOKEN", ""), [int(config.get("ADMIN_ID", 0))]
    except (FileNotFoundError, json.JSONDecodeError, ValueError) as e:
        logging.error(f"Failed to load config from {CONFIG_FILE}: {e}")
        token = os.getenv("BOT_TOKEN", "")
        admin_id = int(os.getenv("ADMIN_ID", "0"))
        return token, [admin_id]


BOT_TOKEN, ADMIN_IDS = load_config()
if not BOT_TOKEN:
    logging.critical("BOT_TOKEN not configured. Check /etc/block-ips/bot_config.json")
    exit(1)

# Directories
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "logs")

if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR, mode=0o755)

LOG_FILE = os.path.join(LOG_DIR, f"bot-{datetime.now().strftime('%Y-%m-%d')}.log")
REFERRAL_LOG_FILE = os.path.join(LOG_DIR, "referral_shown.json")


def log_to_file(message: str):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - {message}\n")
    except Exception as e:
        logger.error(f"Error writing to log file: {e}")


# ============= FSM STATES =============

class WhitelistStates(StatesGroup):
    waiting_custom_domains = State()
    waiting_delete_index = State()
    waiting_import_file = State()


# ============= WHITELIST HELPERS =============

def load_whitelist_config():
    """Загрузить конфигурацию белого списка."""
    config = {"telegram": True, "youtube": True, "custom": True}
    if not os.path.exists(WHITELIST_CONF):
        return config
    try:
        with open(WHITELIST_CONF, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, val = line.split("=", 1)
                    key = key.strip().lower()
                    val = val.strip()
                    if key in config:
                        config[key] = val == "1"
    except Exception:
        pass
    return config


def save_whitelist_config(config):
    """Сохранить конфигурацию белого списка."""
    os.makedirs(WHITELIST_DIR, exist_ok=True)
    try:
        with open(WHITELIST_CONF, "w") as f:
            f.write("# WhiteVPN — Конфигурация белого списка\n")
            f.write(f"telegram={'1' if config.get('telegram') else '0'}\n")
            f.write(f"youtube={'1' if config.get('youtube') else '0'}\n")
            f.write(f"custom={'1' if config.get('custom') else '0'}\n")
    except Exception as e:
        log_to_file(f"Ошибка сохранения whitelist.conf: {e}")


def get_custom_whitelist():
    """Получить список пользовательских записей."""
    custom_file = os.path.join(WHITELIST_DIR, "custom.txt")
    entries = []
    if not os.path.exists(custom_file):
        return entries
    try:
        with open(custom_file, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    entries.append(line)
    except Exception:
        pass
    return entries


def is_valid_domain_or_ip(entry):
    """Проверить, является ли запись валидным доменом или IP/подсетью."""
    # Проверяем IP/подсеть
    try:
        ipaddress.ip_network(entry, strict=False)
        return True
    except ValueError:
        pass
    # Проверяем домен
    domain_pattern = r'^[a-zA-Z0-9]([a-zA-Z0-9\-]*\.)*[a-zA-Z0-9\-]+\.[a-zA-Z]{2,}$'
    if re.match(domain_pattern, entry):
        return True
    return False


def add_custom_whitelist(new_entries):
    """Добавить записи в пользовательский белый список."""
    custom_file = os.path.join(WHITELIST_DIR, "custom.txt")
    os.makedirs(WHITELIST_DIR, exist_ok=True)

    existing = set(get_custom_whitelist())
    added = []
    skipped = []
    for entry in new_entries:
        entry = entry.strip()
        if not entry or entry.startswith("#"):
            continue
        if not is_valid_domain_or_ip(entry):
            skipped.append(entry)
            continue
        if entry not in existing:
            added.append(entry)
            existing.add(entry)

    if added:
        with open(custom_file, "a", encoding="utf-8") as f:
            for entry in added:
                f.write(f"{entry}\n")
    return added, skipped


def clear_custom_whitelist():
    """Очистить пользовательский белый список."""
    os.makedirs(WHITELIST_DIR, exist_ok=True)
    custom_file = os.path.join(WHITELIST_DIR, "custom.txt")
    with open(custom_file, "w", encoding="utf-8") as f:
        f.write("# WhiteVPN — Белый список: Пользовательский\n")
        f.write("# Добавляйте свои домены и IP для исключения из блокировки\n")


def delete_custom_entry(index):
    """Удалить запись из пользовательского списка по индексу (0-based)."""
    entries = get_custom_whitelist()
    if 0 <= index < len(entries):
        removed = entries.pop(index)
        custom_file = os.path.join(WHITELIST_DIR, "custom.txt")
        with open(custom_file, "w", encoding="utf-8") as f:
            f.write("# WhiteVPN — Белый список: Пользовательский\n")
            for e in entries:
                f.write(f"{e}\n")
        return removed
    return None


def export_whitelist_text():
    """Экспортировать весь белый список в текстовый формат."""
    config = load_whitelist_config()
    lines = [f"# WhiteVPN Whitelist Export ({datetime.now().strftime('%Y-%m-%d %H:%M')})"]
    lines.append(f"# telegram={'1' if config['telegram'] else '0'}")
    lines.append(f"# youtube={'1' if config['youtube'] else '0'}")
    lines.append(f"# custom={'1' if config['custom'] else '0'}")
    lines.append("")

    categories = {"telegram": "Telegram", "youtube": "YouTube", "custom": "Пользовательский"}
    for key, label in categories.items():
        cat_file = os.path.join(WHITELIST_DIR, f"{key}.txt")
        if os.path.exists(cat_file):
            lines.append(f"# === {label} ===")
            with open(cat_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        lines.append(line)
            lines.append("")
    return "\n".join(lines)


async def send_admin_alert(text):
    """Отправить алерт всем админам."""
    for admin_id in ADMIN_IDS:
        try:
            await bot.send_message(admin_id, f"🚨 *ALERT:* {text}", parse_mode="Markdown")
        except Exception as e:
            logger.error(f"Failed to send alert to {admin_id}: {e}")


def get_protection_status():
    """Получить статус защиты."""
    # Unbound
    result = subprocess.run(["systemctl", "is-active", "unbound"], capture_output=True, text=True)
    unbound_active = result.stdout.strip() == "active"

    # iptables
    result = subprocess.run(
        ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        capture_output=True, text=True
    )
    iptables_active = result.returncode == 0

    return unbound_active and iptables_active


# ============= AD / REFERRAL LOGIC =============

def _load_referral_history():
    """Загрузить историю показа рефералок."""
    try:
        if os.path.exists(REFERRAL_LOG_FILE):
            with open(REFERRAL_LOG_FILE, "r") as f:
                return json.load(f)
    except (json.JSONDecodeError, IOError):
        pass
    return {}


def _save_referral_history(data):
    """Сохранить историю показа рефералок."""
    try:
        with open(REFERRAL_LOG_FILE, "w") as f:
            json.dump(data, f)
    except IOError:
        pass


async def maybe_show_referral(message: types.Message):
    """Показать рефералку раз в сутки при команде (persistent)."""
    user_id = str(message.from_user.id)
    now = datetime.now()
    history = _load_referral_history()
    last_shown_str = history.get(user_id)

    show = False
    if last_shown_str is None:
        show = True
    else:
        try:
            last_dt = datetime.fromisoformat(last_shown_str)
            if (now - last_dt) > timedelta(hours=24):
                show = True
        except (ValueError, TypeError):
            show = True

    if show:
        history[user_id] = now.isoformat()
        _save_referral_history(history)
        await message.answer(REFERRAL_TEXT, parse_mode="Markdown", disable_web_page_preview=True)


# ============= KEYBOARDS =============

async def is_admin(message: types.Message) -> bool:
    if message.from_user.id not in ADMIN_IDS:
        await message.answer("⛔ Доступ запрещён.")
        return False
    return True


async def is_admin_callback(callback: CallbackQuery) -> bool:
    if callback.from_user.id not in ADMIN_IDS:
        await callback.answer("⛔ Доступ запрещён.", show_alert=True)
        return False
    return True


def get_persistent_keyboard():
    """Нижнее меню (ReplyKeyboard) — большие кнопки."""
    return ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(text="📊 Статус"), KeyboardButton(text="🔄 Обновить списки")],
            [KeyboardButton(text="🛡 Защита"), KeyboardButton(text="📋 Белый список")],
            [KeyboardButton(text="🐳 Docker"), KeyboardButton(text="📝 Логи")],
        ],
        resize_keyboard=True,
        is_persistent=True
    )


def get_main_inline_menu():
    """Верхнее inline-меню с эмодзи-статусами."""
    protection_on = get_protection_status()
    shield = "🟢" if protection_on else "🔴"

    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=f"{shield} Защита: {'ВКЛ' if protection_on else 'ВЫКЛ'}",
                              callback_data="toggle_protection")],
        [InlineKeyboardButton(text="📊 Статус", callback_data="server_status"),
         InlineKeyboardButton(text="🔄 Обновить", callback_data="update_domains"),
         InlineKeyboardButton(text="🔁 Перезапуск", callback_data="restart_services")],
        [InlineKeyboardButton(text="📋 Белый список", callback_data="whitelist_menu"),
         InlineKeyboardButton(text="🐳 Docker", callback_data="docker_menu")],
        [InlineKeyboardButton(text="🏥 Диагностика", callback_data="health_check"),
         InlineKeyboardButton(text="📝 Логи", callback_data="download_logs")],
    ])


def get_whitelist_menu():
    """Меню белого списка с переключателями."""
    config = load_whitelist_config()

    tg_icon = "✅" if config["telegram"] else "❌"
    yt_icon = "✅" if config["youtube"] else "❌"
    custom_icon = "✅" if config["custom"] else "❌"
    custom_count = len(get_custom_whitelist())

    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=f"{tg_icon} Telegram", callback_data="wl_toggle_telegram"),
         InlineKeyboardButton(text=f"{yt_icon} YouTube", callback_data="wl_toggle_youtube")],
        [InlineKeyboardButton(text=f"{custom_icon} Пользовательский ({custom_count})",
                              callback_data="wl_toggle_custom")],
        [InlineKeyboardButton(text="➕ Добавить", callback_data="wl_add_custom"),
         InlineKeyboardButton(text="➖ Удалить", callback_data="wl_delete_custom")],
        [InlineKeyboardButton(text="📄 Показать", callback_data="wl_show_custom"),
         InlineKeyboardButton(text="🗑 Очистить", callback_data="wl_clear_custom")],
        [InlineKeyboardButton(text="📤 Экспорт", callback_data="wl_export"),
         InlineKeyboardButton(text="📥 Импорт", callback_data="wl_import")],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_to_menu")],
    ])


# ============= HANDLERS =============

storage = MemoryStorage()
bot = Bot(token=BOT_TOKEN)
dp = Dispatcher(storage=storage)


# --- /start ---
@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    if not await is_admin(message):
        return

    # Показать рефералку при первом запуске (persistent, раз в сутки)
    await maybe_show_referral(message)

    await message.answer(
        f"🛡 *WhiteVPN v{VERSION}*\n"
        f"Управление блокировкой трафика\n\n"
        f"[GitHub](https://github.com/anten-ka/whitevpn)\n\n"
        f"Используйте кнопки ниже или inline-меню:",
        parse_mode="Markdown",
        reply_markup=get_persistent_keyboard(),
        disable_web_page_preview=True
    )
    await message.answer("Главное меню:", reply_markup=get_main_inline_menu())
    log_to_file(f"User {message.from_user.id} started bot")


# --- /help ---
@dp.message(Command("help"))
async def cmd_help(message: types.Message):
    if not await is_admin(message):
        return
    help_text = (
        "🛡 *WhiteVPN v{ver}* — Справка\n\n"
        "*Команды:*\n"
        "/start — главное меню\n"
        "/help — справка\n"
        "/health — диагностика\n"
        "/whitelist — белый список\n\n"
        "*Кнопки внизу (быстрый доступ):*\n"
        "📊 Статус — состояние сервера\n"
        "🔄 Обновить списки — обновить блокировки\n"
        "🛡 Защита — вкл/выкл\n"
        "📋 Белый список — исключения\n"
        "🐳 Docker — контейнеры\n"
        "📝 Логи — журнал\n\n"
        "*Белый список (3 категории):*\n"
        "✅ Telegram — по умолчанию ВКЛ\n"
        "✅ YouTube — по умолчанию ВКЛ\n"
        "📝 Пользовательский — ваши домены/IP"
    ).format(ver=VERSION)
    await message.answer(help_text, parse_mode="Markdown")
    await maybe_show_referral(message)


# --- /health ---
@dp.message(Command("health"))
async def cmd_health(message: types.Message):
    if not await is_admin(message):
        return
    await do_health_check(message)
    await maybe_show_referral(message)


# --- /whitelist ---
@dp.message(Command("whitelist"))
async def cmd_whitelist(message: types.Message):
    if not await is_admin(message):
        return

    config = load_whitelist_config()
    tg = "✅" if config["telegram"] else "❌"
    yt = "✅" if config["youtube"] else "❌"
    cu = "✅" if config["custom"] else "❌"
    custom_count = len(get_custom_whitelist())

    text = (
        "📋 *Белый список (исключения)*\n\n"
        f"{tg} Telegram — домены и IP\n"
        f"{yt} YouTube — домены и IP Google Video\n"
        f"{cu} Пользовательский — {custom_count} записей\n\n"
        "⚠️ *Внимание:* Добавление доменов в белый список "
        "снижает уровень защиты. Ответственность за "
        "использование белого списка полностью лежит на пользователе."
    )
    await message.answer(text, parse_mode="Markdown", reply_markup=get_whitelist_menu())
    await maybe_show_referral(message)


# --- Reply keyboard handlers ---
@dp.message(F.text == "📊 Статус")
async def reply_status(message: types.Message):
    if not await is_admin(message):
        return
    await do_server_status(message)
    await maybe_show_referral(message)


@dp.message(F.text == "🔄 Обновить списки")
async def reply_update(message: types.Message):
    if not await is_admin(message):
        return
    await do_update_lists(message)
    await maybe_show_referral(message)


@dp.message(F.text == "🛡 Защита")
async def reply_protection(message: types.Message):
    if not await is_admin(message):
        return
    protection_on = get_protection_status()
    shield = "🟢" if protection_on else "🔴"
    text = f"{shield} Защита сейчас: *{'ВКЛЮЧЕНА' if protection_on else 'ВЫКЛЮЧЕНА'}*"

    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(
            text="🔴 Выключить защиту" if protection_on else "🟢 Включить защиту",
            callback_data="toggle_protection"
        )],
    ])
    await message.answer(text, parse_mode="Markdown", reply_markup=kb)
    await maybe_show_referral(message)


@dp.message(F.text == "📋 Белый список")
async def reply_whitelist(message: types.Message):
    if not await is_admin(message):
        return
    await cmd_whitelist(message)


@dp.message(F.text == "🐳 Docker")
async def reply_docker(message: types.Message):
    if not await is_admin(message):
        return
    await do_docker_menu(message)
    await maybe_show_referral(message)


@dp.message(F.text == "📝 Логи")
async def reply_logs(message: types.Message):
    if not await is_admin(message):
        return
    await do_download_logs(message)
    await maybe_show_referral(message)


# ============= INLINE CALLBACKS =============

@dp.callback_query(F.data == "toggle_protection")
async def toggle_protection(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    protection_on = get_protection_status()

    if protection_on:
        # Отключение — запросить подтверждение
        await callback.message.edit_text(
            "⚠️ Вы уверены, что хотите *отключить* защиту?\n"
            "Все правила iptables и DNS-блокировка будут деактивированы.",
            parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="🔴 Да, отключить", callback_data="confirm_disable"),
                 InlineKeyboardButton(text="◀️ Отмена", callback_data="back_to_menu")],
            ])
        )
    else:
        # Включение
        await callback.message.edit_text("🟢 Включение защиты...")
        try:
            commands = [
                ["systemctl", "start", "unbound"],
                ["systemctl", "start", "block-ips.service"],
                ["systemctl", "start", "block-domains.service"],
                ["sh", "-c", "echo 'nameserver 127.0.0.1' > /etc/resolv.conf"],
            ]
            for cmd in commands:
                subprocess.run(cmd, capture_output=True, text=True)

            # Добавляем iptables правило только если его ещё нет (избегаем дублей)
            check = subprocess.run(
                ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
                capture_output=True, text=True
            )
            if check.returncode != 0:
                subprocess.run(
                    ["iptables", "-A", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
                    capture_output=True, text=True
                )

            if os.path.exists(DOCKER_RULES_SCRIPT):
                subprocess.run(["bash", DOCKER_RULES_SCRIPT, "enable"],
                               capture_output=True, text=True, timeout=30)

            await callback.message.edit_text("🟢 Защита *включена*.", parse_mode="Markdown",
                                             reply_markup=get_main_inline_menu())
            log_to_file("Защита включена (через бота)")
        except Exception as e:
            await callback.message.edit_text(f"❌ Ошибка: {str(e)}")
            log_to_file(f"Ошибка включения защиты: {e}")
    await callback.answer()


@dp.callback_query(F.data == "confirm_disable")
async def confirm_disable(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("🔴 Отключение защиты...")
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

        await callback.message.edit_text("🔴 Защита *отключена*.", parse_mode="Markdown",
                                         reply_markup=get_main_inline_menu())
        log_to_file("Защита отключена (через бота)")
    except Exception as e:
        await callback.message.edit_text(f"❌ Ошибка: {str(e)}")
    await callback.answer()


@dp.callback_query(F.data == "update_domains")
async def update_domains(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("🔄 Обновление списков...")
    errors = []
    try:
        r1 = subprocess.run([VENV_PYTHON, os.path.join(SYSTEM_INSTALL_DIR, "blocked-domains", "block_domains.py")],
                            capture_output=True, text=True, timeout=120)
        if r1.returncode != 0:
            errors.append(f"block_domains: {r1.stderr[:200]}")

        r2 = subprocess.run([VENV_PYTHON, os.path.join(SYSTEM_INSTALL_DIR, "blocked-ips", "block_ips.py")],
                            capture_output=True, text=True, timeout=120)
        if r2.returncode != 0:
            errors.append(f"block_ips: {r2.stderr[:200]}")

        if errors:
            error_text = "\n".join(errors)
            await callback.message.edit_text(f"⚠️ Обновлено с ошибками:\n`{error_text}`",
                                             parse_mode="Markdown", reply_markup=get_main_inline_menu())
            await send_admin_alert(f"Ошибки при обновлении списков:\n{error_text}")
            log_to_file(f"Обновление с ошибками: {error_text}")
        else:
            await callback.message.edit_text("✅ Списки обновлены.", reply_markup=get_main_inline_menu())
            log_to_file("Списки обновлены (через бота)")
    except subprocess.TimeoutExpired:
        await callback.message.edit_text("❌ Таймаут при обновлении.")
        await send_admin_alert("Таймаут при обновлении списков блокировки!")
    except Exception as e:
        await callback.message.edit_text(f"❌ Ошибка: {str(e)}")
        await send_admin_alert(f"Ошибка обновления: {str(e)}")
    await callback.answer()


@dp.callback_query(F.data == "restart_services")
async def restart_services(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("🔁 Перезапуск сервисов...")
    try:
        for svc in ["unbound", "block-ips.service", "block-domains.service"]:
            subprocess.run(["systemctl", "restart", svc], capture_output=True, text=True)
        await callback.message.edit_text("✅ Сервисы перезапущены.", reply_markup=get_main_inline_menu())
        log_to_file("Сервисы перезапущены (через бота)")
    except Exception as e:
        await callback.message.edit_text(f"❌ Ошибка: {str(e)}")
    await callback.answer()


@dp.callback_query(F.data == "health_check")
async def health_check_cb(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("🏥 Диагностика...")
    report = build_health_report()
    await callback.message.edit_text(report, reply_markup=get_main_inline_menu())
    await callback.answer()


@dp.callback_query(F.data == "server_status")
async def server_status_cb(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    text = build_server_status()
    await callback.message.edit_text(text, reply_markup=get_main_inline_menu())
    await callback.answer()


@dp.callback_query(F.data == "download_logs")
async def download_logs_cb(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    if os.path.exists(LOG_FILE):
        try:
            with open(LOG_FILE, "r") as f:
                logs = f.read()
            if len(logs) <= 4000:
                await callback.message.answer(f"📝 *Логи:*\n\n`{logs}`", parse_mode="Markdown")
            else:
                await callback.message.answer(f"📝 *Последние записи:*\n\n`{logs[-3500:]}`", parse_mode="Markdown")
        except Exception as e:
            await callback.message.edit_text(f"❌ Ошибка: {str(e)}")
    else:
        await callback.message.edit_text("📝 Логи не найдены.")
    await callback.answer()


@dp.callback_query(F.data == "back_to_menu")
async def back_to_menu(callback: CallbackQuery):
    await callback.message.edit_text("Главное меню:", reply_markup=get_main_inline_menu())
    await callback.answer()


# ============= WHITELIST CALLBACKS =============

@dp.callback_query(F.data == "whitelist_menu")
async def whitelist_menu_cb(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    config = load_whitelist_config()
    tg = "✅" if config["telegram"] else "❌"
    yt = "✅" if config["youtube"] else "❌"
    cu = "✅" if config["custom"] else "❌"

    text = (
        "📋 *Белый список (исключения)*\n\n"
        f"{tg} Telegram\n{yt} YouTube\n{cu} Пользовательский\n\n"
        "⚠️ *Внимание:* Управление белым списком "
        "полностью на вашей ответственности. "
        "Исключённые домены/IP не будут блокироваться."
    )
    await callback.message.edit_text(text, parse_mode="Markdown", reply_markup=get_whitelist_menu())
    await callback.answer()


@dp.callback_query(F.data == "wl_toggle_telegram")
async def wl_toggle_telegram(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    config = load_whitelist_config()
    config["telegram"] = not config["telegram"]
    save_whitelist_config(config)
    icon = "✅" if config["telegram"] else "❌"
    await callback.answer(f"Telegram: {icon}", show_alert=False)
    await callback.message.edit_reply_markup(reply_markup=get_whitelist_menu())


@dp.callback_query(F.data == "wl_toggle_youtube")
async def wl_toggle_youtube(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    config = load_whitelist_config()
    config["youtube"] = not config["youtube"]
    save_whitelist_config(config)
    icon = "✅" if config["youtube"] else "❌"
    await callback.answer(f"YouTube: {icon}", show_alert=False)
    await callback.message.edit_reply_markup(reply_markup=get_whitelist_menu())


@dp.callback_query(F.data == "wl_toggle_custom")
async def wl_toggle_custom(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    config = load_whitelist_config()
    config["custom"] = not config["custom"]
    save_whitelist_config(config)
    icon = "✅" if config["custom"] else "❌"
    await callback.answer(f"Пользовательский: {icon}", show_alert=False)
    await callback.message.edit_reply_markup(reply_markup=get_whitelist_menu())


@dp.callback_query(F.data == "wl_add_custom")
async def wl_add_custom(callback: CallbackQuery, state: FSMContext):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text(
        "📝 *Добавление в белый список*\n\n"
        "Отправьте домены и/или IP-адреса, "
        "каждый с новой строки.\n\n"
        "Пример:\n"
        "`example.com\n"
        "1.2.3.4\n"
        "10.0.0.0/24`\n\n"
        "⚠️ *Внимание:* Добавление доменов в белый список "
        "исключает их из блокировки. Вся ответственность "
        "за последствия лежит на вас.\n\n"
        "Отправьте /cancel для отмены.",
        parse_mode="Markdown"
    )
    await state.set_state(WhitelistStates.waiting_custom_domains)
    await callback.answer()


@dp.message(WhitelistStates.waiting_custom_domains)
async def process_custom_domains(message: types.Message, state: FSMContext):
    if not await is_admin(message):
        return

    if message.text and message.text.strip() == "/cancel":
        await state.clear()
        await message.answer("❌ Отменено.", reply_markup=get_persistent_keyboard())
        return

    if not message.text:
        await message.answer("Отправьте текстовое сообщение с доменами/IP.")
        return

    entries = [line.strip() for line in message.text.strip().split("\n") if line.strip()]
    if not entries:
        await message.answer("Список пуст. Попробуйте снова или /cancel.")
        return

    added, skipped = add_custom_whitelist(entries)
    await state.clear()

    response_parts = []
    if added:
        added_text = "\n".join(added[:20])
        if len(added) > 20:
            added_text += f"\n... и ещё {len(added) - 20}"
        response_parts.append(f"✅ Добавлено *{len(added)}* записей:\n\n`{added_text}`")

    if skipped:
        skipped_text = "\n".join(skipped[:10])
        response_parts.append(f"⚠️ Пропущено *{len(skipped)}* (невалидный формат):\n`{skipped_text}`")

    if response_parts:
        response_parts.append(
            "\nНе забудьте обновить списки блокировки (🔄), "
            "чтобы изменения вступили в силу."
        )
        await message.answer(
            "\n\n".join(response_parts),
            parse_mode="Markdown",
            reply_markup=get_persistent_keyboard()
        )
    else:
        await message.answer("ℹ️ Все записи уже есть в списке или невалидны.",
                             reply_markup=get_persistent_keyboard())
    log_to_file(f"Добавлено {len(added)} записей в пользовательский whitelist")


@dp.callback_query(F.data == "wl_show_custom")
async def wl_show_custom(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    entries = get_custom_whitelist()
    if entries:
        text = "\n".join(entries[:50])
        if len(entries) > 50:
            text += f"\n\n... и ещё {len(entries) - 50}"
        await callback.message.answer(f"📄 *Пользовательский список ({len(entries)}):*\n\n`{text}`",
                                      parse_mode="Markdown")
    else:
        await callback.message.answer("📄 Пользовательский список пуст.")
    await callback.answer()


@dp.callback_query(F.data == "wl_clear_custom")
async def wl_clear_custom(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text(
        "🗑 Очистить *весь* пользовательский белый список?",
        parse_mode="Markdown",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🗑 Да, очистить", callback_data="wl_clear_confirm"),
             InlineKeyboardButton(text="◀️ Отмена", callback_data="whitelist_menu")],
        ])
    )
    await callback.answer()


@dp.callback_query(F.data == "wl_clear_confirm")
async def wl_clear_confirm(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    clear_custom_whitelist()
    await callback.message.edit_text("🗑 Пользовательский список очищен.",
                                     reply_markup=get_whitelist_menu())
    log_to_file("Пользовательский whitelist очищен")
    await callback.answer()


# --- Удаление конкретной записи ---
@dp.callback_query(F.data == "wl_delete_custom")
async def wl_delete_custom(callback: CallbackQuery, state: FSMContext):
    if not await is_admin_callback(callback):
        return
    entries = get_custom_whitelist()
    if not entries:
        await callback.answer("Список пуст", show_alert=True)
        return

    # Показать список с номерами
    lines = [f"`{i+1}.` {e}" for i, e in enumerate(entries[:30])]
    text = (
        "➖ *Удаление записи*\n\n"
        + "\n".join(lines)
        + "\n\nОтправьте номер записи для удаления или /cancel"
    )
    await callback.message.edit_text(text, parse_mode="Markdown")
    await state.set_state(WhitelistStates.waiting_delete_index)
    await callback.answer()


@dp.message(WhitelistStates.waiting_delete_index)
async def process_delete_index(message: types.Message, state: FSMContext):
    if not await is_admin(message):
        return
    if message.text and message.text.strip() == "/cancel":
        await state.clear()
        await message.answer("❌ Отменено.", reply_markup=get_persistent_keyboard())
        return

    try:
        idx = int(message.text.strip()) - 1
        removed = delete_custom_entry(idx)
        await state.clear()
        if removed:
            await message.answer(
                f"✅ Удалено: `{removed}`\n\n"
                "Обновите списки (🔄), чтобы изменения вступили в силу.",
                parse_mode="Markdown",
                reply_markup=get_persistent_keyboard()
            )
            log_to_file(f"Удалена запись whitelist: {removed}")
        else:
            await message.answer("❌ Неверный номер.", reply_markup=get_persistent_keyboard())
    except ValueError:
        await message.answer("Введите число или /cancel. Попробуйте ещё раз:")


# --- Экспорт whitelist ---
@dp.callback_query(F.data == "wl_export")
async def wl_export(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    export_text = export_whitelist_text()
    # Отправим как файл
    export_file = os.path.join(LOG_DIR, "whitelist_export.txt")
    with open(export_file, "w", encoding="utf-8") as f:
        f.write(export_text)

    try:
        from aiogram.types import FSInputFile
        doc = FSInputFile(export_file, filename="whitelist_export.txt")
        await callback.message.answer_document(doc, caption="📤 Экспорт белого списка")
    except Exception as e:
        # Fallback: отправить как текст
        if len(export_text) <= 4000:
            await callback.message.answer(f"📤 *Экспорт:*\n\n`{export_text}`", parse_mode="Markdown")
        else:
            await callback.message.answer(f"📤 Экспорт слишком большой. Ошибка: {e}")
    await callback.answer()


# --- Импорт whitelist ---
@dp.callback_query(F.data == "wl_import")
async def wl_import(callback: CallbackQuery, state: FSMContext):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text(
        "📥 *Импорт белого списка*\n\n"
        "Отправьте домены и IP (каждый с новой строки) "
        "как текстовое сообщение или файл .txt\n\n"
        "⚠️ Записи будут *добавлены* к текущему пользовательскому списку.\n"
        "Отправьте /cancel для отмены.",
        parse_mode="Markdown"
    )
    await state.set_state(WhitelistStates.waiting_import_file)
    await callback.answer()


@dp.message(WhitelistStates.waiting_import_file)
async def process_import(message: types.Message, state: FSMContext):
    if not await is_admin(message):
        return
    if message.text and message.text.strip() == "/cancel":
        await state.clear()
        await message.answer("❌ Отменено.", reply_markup=get_persistent_keyboard())
        return

    entries = []
    if message.document:
        # Файл
        try:
            file = await bot.get_file(message.document.file_id)
            downloaded = await bot.download_file(file.file_path)
            content = downloaded.read().decode("utf-8")
            entries = [l.strip() for l in content.splitlines() if l.strip() and not l.strip().startswith("#")]
        except Exception as e:
            await message.answer(f"❌ Ошибка чтения файла: {e}")
            return
    elif message.text:
        entries = [l.strip() for l in message.text.strip().split("\n") if l.strip()]

    if not entries:
        await message.answer("Список пуст. Попробуйте снова или /cancel.")
        return

    added, skipped = add_custom_whitelist(entries)
    await state.clear()

    parts = []
    if added:
        parts.append(f"✅ Импортировано *{len(added)}* записей")
    if skipped:
        parts.append(f"⚠️ Пропущено *{len(skipped)}* (невалидный формат)")
    if not added and not skipped:
        parts.append("ℹ️ Все записи уже существуют")

    await message.answer("\n".join(parts), parse_mode="Markdown", reply_markup=get_persistent_keyboard())
    log_to_file(f"Импорт whitelist: добавлено {len(added)}, пропущено {len(skipped)}")

# ============= DOCKER CALLBACKS =============

@dp.callback_query(F.data == "docker_menu")
async def docker_menu_cb(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    await do_docker_menu_inline(callback)


@dp.callback_query(F.data == "docker_enable")
async def docker_enable_cb(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("🐳 Включение Docker-блокировки...")
    try:
        if os.path.exists(DOCKER_RULES_SCRIPT):
            subprocess.run(["bash", DOCKER_RULES_SCRIPT, "enable"],
                           capture_output=True, text=True, timeout=30)
            await callback.message.edit_text("✅ Docker-блокировка включена.")
        else:
            await callback.message.edit_text("❌ Скрипт Docker не найден.")
    except Exception as e:
        await callback.message.edit_text(f"❌ Ошибка: {str(e)}")
    await callback.answer()


@dp.callback_query(F.data == "docker_disable")
async def docker_disable_cb(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    await callback.message.edit_text("🐳 Отключение Docker-блокировки...")
    try:
        if os.path.exists(DOCKER_RULES_SCRIPT):
            subprocess.run(["bash", DOCKER_RULES_SCRIPT, "disable"],
                           capture_output=True, text=True, timeout=30)
            await callback.message.edit_text("✅ Docker-блокировка отключена.")
        else:
            await callback.message.edit_text("❌ Скрипт Docker не найден.")
    except Exception as e:
        await callback.message.edit_text(f"❌ Ошибка: {str(e)}")
    await callback.answer()


@dp.callback_query(F.data == "docker_status")
async def docker_status_cb(callback: CallbackQuery):
    if not await is_admin_callback(callback):
        return
    try:
        result = subprocess.run(["iptables", "-L", "DOCKER-USER", "-n"],
                                capture_output=True, text=True)
        if result.returncode == 0:
            active = "blocked_ips" in result.stdout
            icon = "🟢" if active else "🔴"
            await callback.message.edit_text(f"{icon} Docker-блокировка: {'активна' if active else 'неактивна'}")
        else:
            await callback.message.edit_text("❌ Не удалось проверить статус.")
    except Exception as e:
        await callback.message.edit_text(f"❌ Ошибка: {str(e)}")
    await callback.answer()


# ============= HELPER FUNCTIONS =============

def build_health_report():
    checks = []
    # Unbound
    result = subprocess.run(["systemctl", "is-active", "unbound"], capture_output=True, text=True)
    ok = result.stdout.strip() == "active"
    checks.append(f"{'🟢' if ok else '🔴'} Unbound: {result.stdout.strip()}")

    # ipset
    result = subprocess.run(["ipset", "list", "blocked_ips", "-t"], capture_output=True, text=True)
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            if "Number of entries" in line:
                count = line.split(":")[1].strip()
                checks.append(f"🟢 ipset: {count} записей")
                break
    else:
        checks.append("🔴 ipset: не найден")

    # iptables
    result = subprocess.run(
        ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        capture_output=True, text=True
    )
    ok = result.returncode == 0
    checks.append(f"{'🟢' if ok else '🔴'} iptables OUTPUT: {'активно' if ok else 'нет'}")

    # DNS
    try:
        result = subprocess.run(["dig", "@127.0.0.1", "google.com", "+short"],
                                capture_output=True, text=True, timeout=5)
        ok = bool(result.stdout.strip())
        checks.append(f"{'🟢' if ok else '🔴'} DNS: {'работает' if ok else 'не отвечает'}")
    except subprocess.TimeoutExpired:
        checks.append("🔴 DNS: timeout")

    # resolv.conf
    try:
        with open("/etc/resolv.conf", "r") as f:
            resolv = f.read().strip()
        ok = "127.0.0.1" in resolv
        checks.append(f"{'🟢' if ok else '🔴'} resolv.conf: {'127.0.0.1' if ok else resolv[:30]}")
    except Exception:
        checks.append("🔴 resolv.conf: ошибка")

    # Whitelist
    config = load_whitelist_config()
    tg = "✅" if config["telegram"] else "❌"
    yt = "✅" if config["youtube"] else "❌"
    cu = "✅" if config["custom"] else "❌"
    checks.append(f"\n📋 Белый список: TG{tg} YT{yt} User{cu}")

    # Docker
    if os.path.exists(DOCKER_RULES_SCRIPT):
        result = subprocess.run(["iptables", "-L", "DOCKER-USER", "-n"], capture_output=True, text=True)
        ok = "blocked_ips" in result.stdout
        checks.append(f"{'🟢' if ok else '🔴'} Docker DOCKER-USER: {'активно' if ok else 'нет'}")

    return "🏥 *Диагностика:*\n\n" + "\n".join(checks)


def build_server_status():
    try:
        with open("/proc/uptime", "r") as f:
            uptime_s = int(float(f.read().split()[0]))
        days = uptime_s // 86400
        hours = (uptime_s % 86400) // 3600
        mins = (uptime_s % 3600) // 60

        result = subprocess.run(["df", "-h", "/"], capture_output=True, text=True)
        disk = result.stdout.strip().split('\n')[1] if result.returncode == 0 else "N/A"

        result = subprocess.run(["free", "-h"], capture_output=True, text=True)
        mem = result.stdout.strip().split('\n')[1] if result.returncode == 0 else "N/A"

        protection_on = get_protection_status()
        shield = "🟢 ВКЛ" if protection_on else "🔴 ВЫКЛ"

        return (
            f"📊 *Состояние сервера*\n\n"
            f"🛡 Защита: *{shield}*\n"
            f"⏱ Uptime: {days}д {hours}ч {mins}м\n"
            f"💾 Диск: `{disk}`\n"
            f"🧠 Память: `{mem}`"
        )
    except Exception as e:
        return f"❌ Ошибка: {str(e)}"


async def do_health_check(message: types.Message):
    await message.answer("🏥 Диагностика...")
    report = build_health_report()
    await message.answer(report, parse_mode="Markdown")


async def do_server_status(message: types.Message):
    text = build_server_status()
    await message.answer(text, parse_mode="Markdown")


async def do_update_lists(message: types.Message):
    await message.answer("🔄 Обновление списков...")
    try:
        subprocess.run([VENV_PYTHON, os.path.join(SYSTEM_INSTALL_DIR, "blocked-domains", "block_domains.py")], capture_output=True, text=True, timeout=120)
        subprocess.run([VENV_PYTHON, os.path.join(SYSTEM_INSTALL_DIR, "blocked-ips", "block_ips.py")], capture_output=True, text=True, timeout=120)
        await message.answer("✅ Списки обновлены.")
        log_to_file("Списки обновлены")
    except Exception as e:
        await message.answer(f"❌ Ошибка: {str(e)}")


async def do_download_logs(message: types.Message):
    if os.path.exists(LOG_FILE):
        try:
            with open(LOG_FILE, "r") as f:
                logs = f.read()
            if len(logs) <= 4000:
                await message.answer(f"📝 *Логи:*\n\n`{logs}`", parse_mode="Markdown")
            else:
                await message.answer(f"📝 *Последние записи:*\n\n`{logs[-3500:]}`", parse_mode="Markdown")
        except Exception as e:
            await message.answer(f"❌ Ошибка: {str(e)}")
    else:
        await message.answer("📝 Логи не найдены.")


async def do_docker_menu(message: types.Message):
    docker_kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🟢 Включить", callback_data="docker_enable"),
         InlineKeyboardButton(text="🔴 Отключить", callback_data="docker_disable")],
        [InlineKeyboardButton(text="📊 Статус", callback_data="docker_status")],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_to_menu")],
    ])
    await message.answer("🐳 *Docker-контейнеры:*", parse_mode="Markdown", reply_markup=docker_kb)


async def do_docker_menu_inline(callback: CallbackQuery):
    docker_kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🟢 Включить", callback_data="docker_enable"),
         InlineKeyboardButton(text="🔴 Отключить", callback_data="docker_disable")],
        [InlineKeyboardButton(text="📊 Статус", callback_data="docker_status")],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_to_menu")],
    ])
    await callback.message.edit_text("🐳 *Docker-контейнеры:*", parse_mode="Markdown", reply_markup=docker_kb)
    await callback.answer()


# ============= FALLBACK HANDLER =============

@dp.message()
async def handle_unknown(message: types.Message):
    """Обработка неизвестных сообщений."""
    if message.from_user.id not in ADMIN_IDS:
        return
    await message.answer(
        "ℹ️ Неизвестная команда.\nИспользуйте кнопки меню или /help",
        reply_markup=get_persistent_keyboard()
    )


# ============= AUTO-UPDATE TASK =============

AUTO_UPDATE_INTERVAL = 6 * 3600  # 6 часов


async def auto_update_lists():
    """Фоновая задача: автообновление списков каждые 6 часов."""
    await asyncio.sleep(60)  # Подождать минуту после старта
    while True:
        try:
            log_to_file("Автообновление списков...")
            r1 = await asyncio.to_thread(
                subprocess.run,
                [VENV_PYTHON, os.path.join(SYSTEM_INSTALL_DIR, "blocked-domains", "block_domains.py")],
                capture_output=True, text=True, timeout=120
            )
            r2 = await asyncio.to_thread(
                subprocess.run,
                [VENV_PYTHON, os.path.join(SYSTEM_INSTALL_DIR, "blocked-ips", "block_ips.py")],
                capture_output=True, text=True, timeout=120
            )

            errors = []
            if r1.returncode != 0:
                errors.append(f"block_domains: {r1.stderr[:200]}")
            if r2.returncode != 0:
                errors.append(f"block_ips: {r2.stderr[:200]}")

            if errors:
                error_text = "\n".join(errors)
                await send_admin_alert(f"Ошибки автообновления:\n{error_text}")
                log_to_file(f"Автообновление с ошибками: {error_text}")
            else:
                log_to_file("Автообновление завершено успешно")

        except subprocess.TimeoutExpired:
            await send_admin_alert("Таймаут автообновления списков!")
            log_to_file("Автообновление: таймаут")
        except Exception as e:
            await send_admin_alert(f"Ошибка автообновления: {str(e)}")
            log_to_file(f"Автообновление ошибка: {e}")

        await asyncio.sleep(AUTO_UPDATE_INTERVAL)


# ============= SERVICE HEALTH WATCHDOG =============

async def health_watchdog():
    """Фоновая задача: проверка здоровья сервисов каждые 30 минут."""
    await asyncio.sleep(300)  # 5 минут после старта
    while True:
        try:
            # Проверяем Unbound (неблокирующий вызов)
            r = await asyncio.to_thread(
                subprocess.run, ["systemctl", "is-active", "unbound"],
                capture_output=True, text=True
            )
            if r.stdout.strip() != "active":
                await send_admin_alert("Unbound НЕ АКТИВЕН! Защита может быть нарушена.")
                log_to_file("ALERT: Unbound не активен")

            # Проверяем iptables (неблокирующий вызов)
            r = await asyncio.to_thread(
                subprocess.run,
                ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
                capture_output=True, text=True
            )
            if r.returncode != 0:
                await send_admin_alert("iptables правило blocked_ips НЕ НАЙДЕНО! Защита может быть нарушена.")
                log_to_file("ALERT: iptables правило не найдено")

        except Exception as e:
            log_to_file(f"Health watchdog ошибка: {e}")

        await asyncio.sleep(1800)  # 30 минут


# ============= MAIN =============

async def main():
    logger.info(f"Starting WhiteVPN Bot v{VERSION}")
    log_to_file(f"Bot started (v{VERSION})")

    # Запускаем фоновые задачи
    asyncio.create_task(auto_update_lists())
    asyncio.create_task(health_watchdog())

    await dp.start_polling(bot)


if __name__ == "__main__":
    logger.info(f"WhiteVPN Bot v{VERSION} initialized")
    asyncio.run(main())
