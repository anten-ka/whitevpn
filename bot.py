import asyncio
import subprocess
import os
import re
import time
import json
import logging
import ipaddress
from datetime import datetime, timedelta
from pathlib import Path
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from aiogram.types import (
    InlineKeyboardMarkup, InlineKeyboardButton, CallbackQuery,
    ReplyKeyboardMarkup, KeyboardButton, ReplyKeyboardRemove
)
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage

VERSION = "0.6"
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# === PATHS ===
CONFIG_FILE = "/etc/block-ips/bot_config.json"
SETTINGS_FILE = "/opt/block-traffic/bot_settings.json"
SYSTEM_DIR = "/opt/block-traffic"
DOCKER_RULES = os.path.join(SYSTEM_DIR, "docker_rules.sh")
VENV_PYTHON = os.path.join(SYSTEM_DIR, "venv", "bin", "python3")
WHITELIST_DIR = os.path.join(SYSTEM_DIR, "whitelist")
WHITELIST_CONF = os.path.join(WHITELIST_DIR, "whitelist.conf")
LOG_DIR = os.path.join(SYSTEM_DIR, "logs")
BLOCK_LOG = os.path.join(LOG_DIR, "block_access.log")
REFERRAL_FILE = os.path.join(LOG_DIR, "referral_shown.json")
UPDATE_LOG = os.path.join(LOG_DIR, "update_history.json")
MAX_BLOCK_LOG_SIZE = 30 * 1024 * 1024  # 30MB

# Whitelist source URLs (v2fly community domain lists)
WL_SOURCES = {
    "youtube": "https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/youtube",
    "telegram": "https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/telegram",
}

# Extra YouTube CDN domains that may not be in v2fly list
YOUTUBE_EXTRA_DOMAINS = [
    "googlevideo.com",
    "ytimg.com",
    "ggpht.com",
    "youtube.com",
    "youtu.be",
    "youtube-nocookie.com",
    "youtubei.googleapis.com",
    "youtube.googleapis.com",
    "youtube-ui.l.google.com",
    "ytimg.l.google.com",
    "ytstatic.l.google.com",
    "wide-youtube.l.google.com",
    "youtubeembedded-pa.googleapis.com",
    "yt-video-upload.l.google.com",
    "yt3.ggpht.com",
    "yt4.ggpht.com",
    "jnn-pa.googleapis.com",
    "youtube.l.google.com",
    "withyoutube.com",
    "youtubekids.com",
    "youtubeeducation.com",
    "youtubegaming.com",
]

TELEGRAM_EXTRA_DOMAINS = [
    "telegram.org",
    "t.me",
    "telegram.me",
    "core.telegram.org",
    "api.telegram.org",
    "web.telegram.org",
    "desktop.telegram.org",
    "updates.telegram.org",
    "static.telegram.org",
    "cdn.telegram.org",
    "venus.web.telegram.org",
    "pluto.web.telegram.org",
    "flora.web.telegram.org",
    "vesta.web.telegram.org",
    "telegram.dog",
    "telegra.ph",
    "graph.org",
    "contest.com",
    "fragment.com",
]

os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(WHITELIST_DIR, exist_ok=True)

BOT_LOG = os.path.join(LOG_DIR, f"bot-{datetime.now().strftime('%Y-%m-%d')}.log")

# === REFERRAL TEXT (fixed: clickable links, all promo codes) ===
REFERRAL_TEXT = (
    "💰 *Партнёрские хостинги*\n\n"
    "⭐ *Хостинг 1* — [vk.cc/ct29NQ](https://vk.cc/ct29NQ)\n"
    "  `OFF60` — 60% скидка на первый месяц\n"
    "  `antenka20` — 20% + 3% за 3 мес\n"
    "  `antenka6` — 15% + 5% за 6 мес\n\n"
    "⭐ *Хостинг 2* — [vk.cc/cUxAhj](https://vk.cc/cUxAhj)\n"
    "  `OFF60` — 60% скидка на первый месяц"
)


def log_to_file(msg):
    try:
        with open(BOT_LOG, "a") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} - {msg}\n")
    except Exception:
        pass


# === CONFIG ===
def load_config():
    try:
        with open(CONFIG_FILE, "r") as f:
            c = json.load(f)
        admin_raw = c.get("ADMIN_IDS", c.get("ADMIN_ID", 0))
        if isinstance(admin_raw, list):
            admins = [int(a) for a in admin_raw]
        else:
            admins = [int(admin_raw)]
        return c.get("BOT_TOKEN", ""), admins
    except Exception as e:
        logger.error(f"Config error: {e}")
        return os.getenv("BOT_TOKEN", ""), [int(os.getenv("ADMIN_ID", "0"))]


def load_settings():
    defaults = {
        "menu_mode": "inline",
        "block_log_notify": False,
        "menu_size": "full",  # "full" or "compact"
    }
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE, "r") as f:
                data = json.load(f)
            for k, v in defaults.items():
                data.setdefault(k, v)
            return data
    except Exception:
        pass
    return defaults


def save_settings(s):
    try:
        with open(SETTINGS_FILE, "w") as f:
            json.dump(s, f, indent=2, ensure_ascii=False)
    except Exception as e:
        logger.error(f"Settings save error: {e}")


BOT_TOKEN, ADMIN_IDS = load_config()
if not BOT_TOKEN:
    logger.critical("BOT_TOKEN not configured!")
    exit(1)

bot = Bot(token=BOT_TOKEN)
storage = MemoryStorage()
dp = Dispatcher(storage=storage)


# === FSM ===
class WLStates(StatesGroup):
    waiting_custom_add = State()
    waiting_custom_del = State()
    waiting_import = State()


# === ADMIN CHECK ===
async def is_admin(msg):
    if msg.from_user.id not in ADMIN_IDS:
        await msg.answer("⛔ Доступ запрещён.")
        return False
    return True


async def is_admin_cb(cb):
    if cb.from_user.id not in ADMIN_IDS:
        await cb.answer("⛔ Доступ запрещён.", show_alert=True)
        return False
    return True


# === UPDATE HISTORY LOG ===
def log_update_history(update_type, ip_count=0, domain_count=0, wl_updated=False):
    """Save last 5 update results to JSON."""
    history = []
    try:
        if os.path.exists(UPDATE_LOG):
            with open(UPDATE_LOG, "r") as f:
                history = json.load(f)
    except Exception:
        history = []
    entry = {
        "time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "type": update_type,
        "ips": ip_count,
        "domains": domain_count,
        "whitelist_updated": wl_updated,
    }
    history.append(entry)
    history = history[-5:]  # keep only last 5
    try:
        with open(UPDATE_LOG, "w") as f:
            json.dump(history, f, indent=2, ensure_ascii=False)
    except Exception:
        pass


def get_update_history():
    """Return last 5 update entries."""
    try:
        if os.path.exists(UPDATE_LOG):
            with open(UPDATE_LOG, "r") as f:
                return json.load(f)
    except Exception:
        pass
    return []


# === WHITELIST HELPERS ===
def load_wl_config():
    cfg = {"telegram": True, "youtube": True, "custom": True}
    if not os.path.exists(WHITELIST_CONF):
        return cfg
    try:
        with open(WHITELIST_CONF, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    k = k.strip().lower()
                    if k in cfg:
                        cfg[k] = v.strip() == "1"
    except Exception:
        pass
    return cfg


def save_wl_config(cfg):
    os.makedirs(WHITELIST_DIR, exist_ok=True)
    with open(WHITELIST_CONF, "w") as f:
        f.write("# WhiteVPN whitelist config\n")
        f.write(f"telegram={'1' if cfg.get('telegram') else '0'}\n")
        f.write(f"youtube={'1' if cfg.get('youtube') else '0'}\n")
        f.write(f"custom={'1' if cfg.get('custom') else '0'}\n")


def get_custom_entries():
    p = os.path.join(WHITELIST_DIR, "custom.txt")
    entries = []
    if not os.path.exists(p):
        return entries
    with open(p, "r") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                entries.append(line)
    return entries


def is_valid_entry(e):
    try:
        ipaddress.ip_network(e, strict=False)
        return True
    except ValueError:
        pass
    return bool(re.match(r'^[a-zA-Z0-9]([a-zA-Z0-9\-]*\.)*[a-zA-Z0-9\-]+\.[a-zA-Z]{2,}$', e))


def add_custom_entries(new_entries):
    p = os.path.join(WHITELIST_DIR, "custom.txt")
    os.makedirs(WHITELIST_DIR, exist_ok=True)
    existing = set(get_custom_entries())
    added, skipped = [], []
    for e in new_entries:
        e = e.strip()
        if not e or e.startswith("#"):
            continue
        if not is_valid_entry(e):
            skipped.append(e)
            continue
        if e not in existing:
            added.append(e)
            existing.add(e)
    if added:
        with open(p, "a", encoding="utf-8") as f:
            for e in added:
                f.write(f"{e}\n")
    return added, skipped


def delete_custom_entry(idx):
    entries = get_custom_entries()
    if 0 <= idx < len(entries):
        removed = entries.pop(idx)
        p = os.path.join(WHITELIST_DIR, "custom.txt")
        with open(p, "w", encoding="utf-8") as f:
            f.write("# WhiteVPN custom whitelist\n")
            for e in entries:
                f.write(f"{e}\n")
        return removed
    return None


def clear_custom():
    p = os.path.join(WHITELIST_DIR, "custom.txt")
    os.makedirs(WHITELIST_DIR, exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write("# WhiteVPN custom whitelist\n")


def export_whitelist():
    cfg = load_wl_config()
    lines = [f"# WhiteVPN Export ({datetime.now():%Y-%m-%d %H:%M})"]
    for cat in ["telegram", "youtube", "custom"]:
        fp = os.path.join(WHITELIST_DIR, f"{cat}.txt")
        if os.path.exists(fp):
            lines.append(f"\n# === {cat.title()} ({'ON' if cfg[cat] else 'OFF'}) ===")
            with open(fp, "r") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        lines.append(line)
    return "\n".join(lines)


# === WHITELIST UPDATE FROM V2FLY ===
def update_whitelist_from_sources():
    """Download fresh YouTube/Telegram domain lists from v2fly and merge with extras."""
    import urllib.request
    updated = False
    for cat, url in WL_SOURCES.items():
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "WhiteVPN/0.6"})
            resp = urllib.request.urlopen(req, timeout=30)
            raw = resp.read().decode("utf-8")
            domains = set()
            for line in raw.splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # v2fly format: domain lines may have tags like @cn
                parts = line.split()
                dom = parts[0]
                # skip include: directives and regexp: lines
                if dom.startswith("include:") or dom.startswith("regexp:"):
                    continue
                # remove prefix markers (domain:, full:, keyword:)
                for prefix in ("domain:", "full:", "keyword:"):
                    if dom.startswith(prefix):
                        dom = dom[len(prefix):]
                        break
                dom = dom.strip().lower()
                if dom and "." in dom:
                    domains.add(dom)
            # Merge extra hardcoded domains
            extras = YOUTUBE_EXTRA_DOMAINS if cat == "youtube" else TELEGRAM_EXTRA_DOMAINS
            for d in extras:
                domains.add(d.lower())
            # Write file
            fp = os.path.join(WHITELIST_DIR, f"{cat}.txt")
            with open(fp, "w", encoding="utf-8") as f:
                f.write(f"# WhiteVPN {cat} whitelist (auto-updated {datetime.now():%Y-%m-%d %H:%M})\n")
                for d in sorted(domains):
                    f.write(f"{d}\n")
            logger.info(f"Whitelist {cat}: {len(domains)} domains")
            updated = True
        except Exception as e:
            logger.error(f"Whitelist update {cat}: {e}")
    return updated


# === SYSTEM STATUS ===
def get_protection_status():
    r = subprocess.run(["systemctl", "is-active", "unbound"], capture_output=True, text=True, timeout=10)
    unbound_ok = r.stdout.strip() == "active"
    r = subprocess.run(
        ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        capture_output=True, text=True, timeout=10
    )
    ipt_ok = r.returncode == 0
    return unbound_ok and ipt_ok


def get_ipset_count():
    r = subprocess.run(["ipset", "list", "blocked_ips", "-t"], capture_output=True, text=True, timeout=10)
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            if "Number of entries" in line:
                parts = line.split(":")
                if len(parts) >= 2:
                    return int(parts[1].strip())
    return 0


def get_domains_count():
    p = "/etc/unbound/blocked-domains.conf"
    if os.path.exists(p):
        try:
            with open(p, "r") as f:
                return sum(1 for line in f if line.strip() and not line.startswith("#"))
        except Exception:
            pass
    return 0


def get_xui_status():
    r = subprocess.run(["systemctl", "is-active", "x-ui"], capture_output=True, text=True, timeout=10)
    return r.stdout.strip() == "active"


def get_docker_info():
    """Return (containers_list, is_protected)"""
    try:
        r = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True, timeout=10)
        containers = [c.strip() for c in r.stdout.splitlines() if c.strip()]
    except Exception:
        return [], False
    r2 = subprocess.run(
        ["iptables", "-L", "DOCKER-USER", "-n"], capture_output=True, text=True, timeout=10
    )
    protected = "blocked_ips" in r2.stdout
    return containers, protected


def get_uptime_str():
    try:
        with open("/proc/uptime", "r") as f:
            s = int(float(f.read().split()[0]))
        d, s = divmod(s, 86400)
        h, s = divmod(s, 3600)
        m = s // 60
        return f"{d}д {h}ч {m}м"
    except Exception:
        return "?"


# === BUILD STATUS ===
async def build_status_text():
    prot = await asyncio.to_thread(get_protection_status)
    ips = await asyncio.to_thread(get_ipset_count)
    doms = await asyncio.to_thread(get_domains_count)
    xui = await asyncio.to_thread(get_xui_status)
    containers, docker_prot = await asyncio.to_thread(get_docker_info)
    uptime = await asyncio.to_thread(get_uptime_str)
    wl = load_wl_config()
    custom_cnt = len(get_custom_entries())

    shield = "🟢 ВКЛ" if prot else "🔴 ВЫКЛ"
    xui_s = "🟢 Активна" if xui else "⚫ Не найдена"
    tg_s = "✅" if wl["telegram"] else "❌"
    yt_s = "✅" if wl["youtube"] else "❌"
    cu_s = "✅" if wl["custom"] else "❌"
    dock_s = "🟢" if docker_prot else "🔴"

    text = (
        f"🛡 *WhiteVPN v{VERSION}*\n\n"
        f"*Защита:* {shield}\n"
        f"📊 IP: `{ips}` | Доменов: `{doms}`\n\n"
        f"*Инфраструктура:*\n"
        f"  🖥 3x-ui: {xui_s}\n"
    )
    if containers:
        c_names = ", ".join(containers)
        text += f"  🐳 Docker: {dock_s} ({len(containers)} шт: {c_names})\n"
    else:
        text += "  🐳 Docker: нет контейнеров\n"

    text += (
        f"\n*Белый список:*\n"
        f"  📱 Telegram {tg_s} | 📺 YouTube {yt_s}\n"
        f"  📝 Свой {cu_s} ({custom_cnt} записей)\n\n"
        f"⏱ Uptime: {uptime}"
    )
    return text


# === KEYBOARDS ===
def get_inline_menu():
    settings = load_settings()
    prot = get_protection_status()
    shield = "🟢" if prot else "🔴"
    notify = settings.get("block_log_notify", False)
    notify_icon = "🔔" if notify else "🔕"
    menu_size = settings.get("menu_size", "full")

    if menu_size == "compact":
        # Compact menu: fewer rows
        return InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text=f"{shield} Защита", callback_data="toggle_protection"),
             InlineKeyboardButton(text="📊 Статус", callback_data="show_status")],
            [InlineKeyboardButton(text="📋 Списки", callback_data="wl_menu"),
             InlineKeyboardButton(text="🔄 Обновить", callback_data="update_lists")],
            [InlineKeyboardButton(text="📐 Раскрыть меню", callback_data="toggle_menu_size"),
             InlineKeyboardButton(text="⚙️ Тип меню", callback_data="switch_menu")],
        ])
    else:
        # Full menu
        return InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text=f"{shield} Защита: {'ВКЛ' if prot else 'ВЫКЛ'}", callback_data="toggle_protection")],
            [InlineKeyboardButton(text="📊 Статус", callback_data="show_status"),
             InlineKeyboardButton(text="🔄 Обновить списки", callback_data="update_lists")],
            [InlineKeyboardButton(text="📋 Белый список", callback_data="wl_menu"),
             InlineKeyboardButton(text="🐳 Docker", callback_data="docker_menu")],
            [InlineKeyboardButton(text=f"📜 Лог {notify_icon}", callback_data="block_log_menu"),
             InlineKeyboardButton(text="🏥 Диагностика", callback_data="health_check")],
            [InlineKeyboardButton(text="📐 Свернуть меню", callback_data="toggle_menu_size"),
             InlineKeyboardButton(text="⚙️ Тип меню", callback_data="switch_menu")],
            [InlineKeyboardButton(text="💰 Партнёры", callback_data="show_referral"),
             InlineKeyboardButton(text="📈 Обновления", callback_data="show_update_log")],
        ])


def get_reply_menu():
    settings = load_settings()
    menu_size = settings.get("menu_size", "full")
    if menu_size == "compact":
        return ReplyKeyboardMarkup(keyboard=[
            [KeyboardButton(text="📊 Статус"), KeyboardButton(text="🛡 Защита")],
            [KeyboardButton(text="🔄 Обновить"), KeyboardButton(text="⚙️ Сменить меню")],
        ], resize_keyboard=True, is_persistent=True)
    else:
        return ReplyKeyboardMarkup(keyboard=[
            [KeyboardButton(text="📊 Статус"), KeyboardButton(text="🔄 Обновить списки")],
            [KeyboardButton(text="🛡 Защита"), KeyboardButton(text="📋 Белый список")],
            [KeyboardButton(text="🐳 Docker"), KeyboardButton(text="📜 Лог блокировок")],
            [KeyboardButton(text="🏥 Диагностика"), KeyboardButton(text="⚙️ Сменить меню")],
            [KeyboardButton(text="📐 Размер меню")],
        ], resize_keyboard=True, is_persistent=True)


def get_wl_menu():
    cfg = load_wl_config()
    tg = "✅" if cfg["telegram"] else "❌"
    yt = "✅" if cfg["youtube"] else "❌"
    cu = "✅" if cfg["custom"] else "❌"
    cnt = len(get_custom_entries())
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=f"📱 Telegram {tg}", callback_data="wl_toggle_tg"),
         InlineKeyboardButton(text=f"📺 YouTube {yt}", callback_data="wl_toggle_yt")],
        [InlineKeyboardButton(text=f"📝 Свой {cu} ({cnt})", callback_data="wl_toggle_custom")],
        [InlineKeyboardButton(text="➕ Добавить", callback_data="wl_add"),
         InlineKeyboardButton(text="➖ Удалить", callback_data="wl_del")],
        [InlineKeyboardButton(text="📄 Показать", callback_data="wl_show"),
         InlineKeyboardButton(text="🗑 Очистить", callback_data="wl_clear")],
        [InlineKeyboardButton(text="📤 Экспорт", callback_data="wl_export"),
         InlineKeyboardButton(text="📥 Импорт", callback_data="wl_import")],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")],
    ])


def get_block_log_menu():
    s = load_settings()
    notify = s.get("block_log_notify", False)
    icon = "🔔 Выкл уведомл" if notify else "🔕 Вкл уведомл"
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📄 Последние записи", callback_data="bl_recent")],
        [InlineKeyboardButton(text=icon, callback_data="bl_toggle_notify")],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")],
    ])


# === REFERRAL ===
def _load_ref():
    try:
        if os.path.exists(REFERRAL_FILE):
            with open(REFERRAL_FILE, "r") as f:
                return json.load(f)
    except Exception:
        pass
    return {}


def _save_ref(data):
    try:
        with open(REFERRAL_FILE, "w") as f:
            json.dump(data, f)
    except Exception:
        pass


async def maybe_show_referral(msg):
    uid = str(msg.from_user.id)
    history = _load_ref()
    last = history.get(uid)
    now = datetime.now()
    show = False
    if last is None:
        show = True
    else:
        try:
            if (now - datetime.fromisoformat(last)) > timedelta(hours=24):
                show = True
        except Exception:
            show = True
    if show:
        history[uid] = now.isoformat()
        _save_ref(history)
        await msg.answer(REFERRAL_TEXT, parse_mode="Markdown", disable_web_page_preview=True)


# === BLOCK LOG ===
def rotate_block_log():
    if not os.path.exists(BLOCK_LOG):
        return
    try:
        size = os.path.getsize(BLOCK_LOG)
        if size > MAX_BLOCK_LOG_SIZE:
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            os.rename(BLOCK_LOG, os.path.join(LOG_DIR, f"block_access_{ts}.log"))
        cutoff = time.time() - 30 * 86400
        for f in Path(LOG_DIR).glob("block_access_*.log"):
            if f.stat().st_mtime < cutoff:
                f.unlink()
    except Exception as e:
        logger.error(f"Log rotate error: {e}")


async def monitor_block_log():
    """Background: read journal for WHITEVPN_BLOCK and unbound deny entries."""
    await asyncio.sleep(30)
    last_ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    while True:
        try:
            rotate_block_log()
            new_entries = []
            r = await asyncio.to_thread(
                subprocess.run,
                ["journalctl", "-k", "--since", last_ts, "--no-pager", "-q"],
                capture_output=True, text=True, timeout=10
            )
            if r.returncode == 0:
                for line in r.stdout.splitlines():
                    if "WHITEVPN_BLOCK" in line:
                        src = re.search(r'SRC=(\S+)', line)
                        dst = re.search(r'DST=(\S+)', line)
                        if src and dst:
                            entry = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] BLOCKED IP: {src.group(1)} -> {dst.group(1)}\n"
                            new_entries.append(entry)
            r2 = await asyncio.to_thread(
                subprocess.run,
                ["journalctl", "-u", "unbound", "--since", last_ts, "--no-pager", "-q"],
                capture_output=True, text=True, timeout=10
            )
            if r2.returncode == 0:
                for line in r2.stdout.splitlines():
                    if "deny" in line.lower() or "refused" in line.lower():
                        dm = re.search(r'info: ([^\s]+)', line)
                        domain = dm.group(1) if dm else "unknown"
                        entry = f"[{datetime.now():%Y-%m-%d %H:%M:%S}] BLOCKED DNS: {domain}\n"
                        new_entries.append(entry)
            last_ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            if new_entries:
                with open(BLOCK_LOG, "a") as f:
                    f.writelines(new_entries)
                s = load_settings()
                if s.get("block_log_notify", False):
                    summary = "".join(new_entries[-10:])
                    if len(summary) > 3500:
                        summary = summary[:3500] + "\n..."
                    for aid in ADMIN_IDS:
                        try:
                            await bot.send_message(
                                aid,
                                f"📜 *Новые блокировки:*\n```\n{summary}```",
                                parse_mode="Markdown"
                            )
                        except Exception:
                            pass
            await asyncio.sleep(30)
        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error(f"Block log monitor: {e}")
            await asyncio.sleep(30)


def get_recent_block_log(n=30):
    if not os.path.exists(BLOCK_LOG):
        return "Лог пуст."
    try:
        with open(BLOCK_LOG, "r") as f:
            lines = f.readlines()
        if not lines:
            return "Лог пуст."
        recent = lines[-n:]
        return "".join(recent)
    except Exception:
        return "Ошибка чтения лога."


# === SEND MENU ===
async def send_main_menu(target, text=None):
    s = load_settings()
    mode = s.get("menu_mode", "inline")
    if text is None:
        text = await build_status_text()
    if isinstance(target, CallbackQuery):
        msg = target.message
    else:
        msg = target
    if mode == "inline":
        try:
            if isinstance(target, CallbackQuery):
                await msg.edit_text(text, parse_mode="Markdown", reply_markup=get_inline_menu())
            else:
                await msg.answer(text, parse_mode="Markdown",
                                 reply_markup=ReplyKeyboardRemove())
                await msg.answer("Главное меню:", reply_markup=get_inline_menu())
        except Exception:
            await msg.answer(text, parse_mode="Markdown", reply_markup=get_inline_menu())
    else:
        if isinstance(target, CallbackQuery):
            await msg.delete()
        await msg.answer(text, parse_mode="Markdown", reply_markup=get_reply_menu())


# === HANDLERS: COMMANDS ===
@dp.message(Command("start"))
async def cmd_start(msg: types.Message, state: FSMContext):
    if not await is_admin(msg):
        return
    await state.clear()
    await maybe_show_referral(msg)
    await send_main_menu(msg)
    log_to_file(f"User {msg.from_user.id} /start")


@dp.message(Command("help"))
async def cmd_help(msg: types.Message):
    if not await is_admin(msg):
        return
    text = (
        f"🛡 *WhiteVPN v{VERSION} — Справка*\n\n"
        "*Команды:*\n"
        "/start — главное меню\n"
        "/help — справка\n"
        "/health — диагностика\n"
        "/whitelist — белый список\n\n"
        "*Белый список (3 категории):*\n"
        "  ✅ Telegram — по умолчанию ВКЛ\n"
        "  ✅ YouTube — по умолчанию ВКЛ\n"
        "  📝 Пользовательский — ваши домены/IP\n\n"
        "*Лог блокировок:*\n"
        "  📜 Фиксирует попытки перехода на запрещённые ресурсы\n"
        "  🔔 Можно включить авто-уведомления"
    )
    await msg.answer(text, parse_mode="Markdown")


@dp.message(Command("health"))
async def cmd_health(msg: types.Message):
    if not await is_admin(msg):
        return
    report = await asyncio.to_thread(build_health_report)
    await msg.answer(report, parse_mode="Markdown")


@dp.message(Command("whitelist"))
async def cmd_whitelist(msg: types.Message):
    if not await is_admin(msg):
        return
    cfg = load_wl_config()
    tg = "✅" if cfg["telegram"] else "❌"
    yt = "✅" if cfg["youtube"] else "❌"
    cu = "✅" if cfg["custom"] else "❌"
    cnt = len(get_custom_entries())
    text = (
        "📋 *Белый список*\n\n"
        f"  📱 Telegram: {tg}\n"
        f"  📺 YouTube: {yt}\n"
        f"  📝 Свой: {cu} ({cnt} записей)\n\n"
        "⚠️ Добавление доменов снижает защиту.\n"
        "Ответственность на пользователе."
    )
    await msg.answer(text, parse_mode="Markdown", reply_markup=get_wl_menu())


# === HANDLERS: REPLY KEYBOARD ===
@dp.message(F.text == "📊 Статус")
async def rk_status(msg: types.Message):
    if not await is_admin(msg):
        return
    text = await build_status_text()
    await msg.answer(text, parse_mode="Markdown")
    await maybe_show_referral(msg)


@dp.message(F.text.in_({"🔄 Обновить списки", "🔄 Обновить"}))
async def rk_update(msg: types.Message):
    if not await is_admin(msg):
        return
    await do_update_lists(msg)


@dp.message(F.text == "🛡 Защита")
async def rk_protection(msg: types.Message):
    if not await is_admin(msg):
        return
    prot = await asyncio.to_thread(get_protection_status)
    shield = "🟢" if prot else "🔴"
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(
            text="🔴 Выключить" if prot else "🟢 Включить",
            callback_data="toggle_protection"
        )],
    ])
    await msg.answer(f"{shield} Защита: *{'ВКЛЮЧЕНА' if prot else 'ВЫКЛЮЧЕНА'}*",
                     parse_mode="Markdown", reply_markup=kb)


@dp.message(F.text == "📋 Белый список")
async def rk_whitelist(msg: types.Message):
    if not await is_admin(msg):
        return
    await cmd_whitelist(msg)


@dp.message(F.text == "🐳 Docker")
async def rk_docker(msg: types.Message):
    if not await is_admin(msg):
        return
    await do_docker_menu(msg)


@dp.message(F.text == "📜 Лог блокировок")
async def rk_block_log(msg: types.Message):
    if not await is_admin(msg):
        return
    s = load_settings()
    notify = s.get("block_log_notify", False)
    icon = "🔔" if notify else "🔕"
    await msg.answer(
        f"📜 *Лог блокировок* {icon}\n\n"
        "Здесь фиксируются попытки перехода на запрещённые ресурсы.",
        parse_mode="Markdown", reply_markup=get_block_log_menu()
    )


@dp.message(F.text == "🏥 Диагностика")
async def rk_health(msg: types.Message):
    if not await is_admin(msg):
        return
    report = await asyncio.to_thread(build_health_report)
    await msg.answer(report, parse_mode="Markdown")


@dp.message(F.text == "⚙️ Сменить меню")
async def rk_switch(msg: types.Message):
    if not await is_admin(msg):
        return
    s = load_settings()
    current = s.get("menu_mode", "inline")
    s["menu_mode"] = "reply" if current == "inline" else "inline"
    save_settings(s)
    new = s["menu_mode"]
    await msg.answer(
        f"⚙️ Меню переключено: *{new.upper()}*",
        parse_mode="Markdown",
        reply_markup=ReplyKeyboardRemove() if new == "inline" else None
    )
    await send_main_menu(msg)


@dp.message(F.text == "📐 Размер меню")
async def rk_toggle_size(msg: types.Message):
    if not await is_admin(msg):
        return
    s = load_settings()
    current = s.get("menu_size", "full")
    s["menu_size"] = "compact" if current == "full" else "full"
    save_settings(s)
    new = s["menu_size"]
    label = "компактное" if new == "compact" else "полное"
    await msg.answer(f"📐 Меню: *{label}*", parse_mode="Markdown")
    await send_main_menu(msg)


# === INLINE CALLBACKS ===
@dp.callback_query(F.data == "show_status")
async def cb_status(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    text = await build_status_text()
    await cb.message.edit_text(text, parse_mode="Markdown", reply_markup=get_inline_menu())
    await cb.answer()


@dp.callback_query(F.data == "back_main")
async def cb_back_main(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    await send_main_menu(cb)
    await cb.answer()


@dp.callback_query(F.data == "toggle_protection")
async def cb_toggle_prot(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    prot = await asyncio.to_thread(get_protection_status)
    if prot:
        await cb.message.edit_text(
            "⚠️ *Отключить защиту?*\n"
            "Все правила блокировки будут деактивированы.",
            parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="🔴 Да, отключить", callback_data="confirm_disable"),
                 InlineKeyboardButton(text="◀️ Отмена", callback_data="back_main")],
            ])
        )
    else:
        await cb.message.edit_text("🟢 Включение защиты...")
        await asyncio.to_thread(enable_protection)
        text = await build_status_text()
        await cb.message.edit_text(text, parse_mode="Markdown", reply_markup=get_inline_menu())
        log_to_file("Protection enabled via bot")
    await cb.answer()


@dp.callback_query(F.data == "confirm_disable")
async def cb_confirm_disable(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    await cb.message.edit_text("🔴 Отключение защиты...")
    await asyncio.to_thread(disable_protection)
    text = await build_status_text()
    await cb.message.edit_text(text, parse_mode="Markdown", reply_markup=get_inline_menu())
    log_to_file("Protection disabled via bot")
    await cb.answer()


@dp.callback_query(F.data == "toggle_menu_size")
async def cb_toggle_menu_size(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    s = load_settings()
    current = s.get("menu_size", "full")
    s["menu_size"] = "compact" if current == "full" else "full"
    save_settings(s)
    new = s["menu_size"]
    label = "компактное" if new == "compact" else "полное"
    await cb.answer(f"Меню: {label}", show_alert=False)
    text = await build_status_text()
    await cb.message.edit_text(text, parse_mode="Markdown", reply_markup=get_inline_menu())


@dp.callback_query(F.data == "show_update_log")
async def cb_show_update_log(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    history = get_update_history()
    if not history:
        await cb.message.edit_text(
            "📈 *История обновлений*\n\nПока нет записей.",
            parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")],
            ])
        )
    else:
        lines = []
        for h in history:
            t = h.get("time", "?")
            tp = h.get("type", "?")
            ips = h.get("ips", 0)
            doms = h.get("domains", 0)
            wl = "✅" if h.get("whitelist_updated") else "—"
            lines.append(f"  {t}\n    {tp} | IP: {ips} | Dom: {doms} | WL: {wl}")
        text = "📈 *Последние 5 обновлений:*\n\n" + "\n\n".join(lines)
        await cb.message.edit_text(
            text, parse_mode="Markdown",
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[
                [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")],
            ])
        )
    await cb.answer()


def enable_protection():
    subprocess.run(["systemctl", "start", "unbound"], capture_output=True, timeout=10)
    with open("/etc/resolv.conf", "w") as f:
        f.write("nameserver 127.0.0.1\n")
    r_log = subprocess.run(
        ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst",
         "-j", "LOG", "--log-prefix", "WHITEVPN_BLOCK: ", "--log-level", "4"],
        capture_output=True, timeout=10
    )
    if r_log.returncode != 0:
        subprocess.run(
            ["iptables", "-A", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst",
             "-j", "LOG", "--log-prefix", "WHITEVPN_BLOCK: ", "--log-level", "4"],
            capture_output=True, timeout=10
        )
    r_drop = subprocess.run(
        ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        capture_output=True, timeout=10
    )
    if r_drop.returncode != 0:
        subprocess.run(
            ["iptables", "-A", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
            capture_output=True, timeout=10
        )
    if os.path.exists(DOCKER_RULES):
        subprocess.run(["bash", DOCKER_RULES, "enable"], capture_output=True, timeout=30)


def disable_protection():
    subprocess.run(
        ["iptables", "-D", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst",
         "-j", "LOG", "--log-prefix", "WHITEVPN_BLOCK: ", "--log-level", "4"],
        capture_output=True, timeout=10
    )
    subprocess.run(
        ["iptables", "-D", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        capture_output=True, timeout=10
    )
    subprocess.run(["systemctl", "stop", "unbound"], capture_output=True, timeout=10)
    with open("/etc/resolv.conf", "w") as f:
        f.write("nameserver 8.8.8.8\n")
    if os.path.exists(DOCKER_RULES):
        subprocess.run(["bash", DOCKER_RULES, "disable"], capture_output=True, timeout=30)


# === UPDATE LISTS ===
@dp.callback_query(F.data == "update_lists")
async def cb_update(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    await cb.message.edit_text("🔄 Обновление списков...")
    await do_update_inline(cb)
    await cb.answer()


async def do_update_lists(msg):
    await msg.answer("🔄 Обновление списков...")
    errors = []
    ip_count = 0
    dom_count = 0
    try:
        # Update whitelist sources first
        wl_ok = await asyncio.to_thread(update_whitelist_from_sources)
        r1 = await asyncio.to_thread(
            subprocess.run,
            [VENV_PYTHON, os.path.join(SYSTEM_DIR, "blocked-domains", "block_domains.py")],
            capture_output=True, text=True, timeout=120
        )
        if r1.returncode != 0:
            errors.append(f"domains: {r1.stderr[:200]}")
        r2 = await asyncio.to_thread(
            subprocess.run,
            [VENV_PYTHON, os.path.join(SYSTEM_DIR, "blocked-ips", "block_ips.py")],
            capture_output=True, text=True, timeout=120
        )
        if r2.returncode != 0:
            errors.append(f"ips: {r2.stderr[:200]}")
        ip_count = await asyncio.to_thread(get_ipset_count)
        dom_count = await asyncio.to_thread(get_domains_count)
    except Exception as e:
        errors.append(str(e))
        wl_ok = False
    log_update_history("manual", ip_count, dom_count, wl_ok)
    if errors:
        await msg.answer(f"⚠️ Ошибки:\n`{'  '.join(errors)}`", parse_mode="Markdown")
    else:
        await msg.answer(f"✅ Списки обновлены\nIP: {ip_count} | Доменов: {dom_count}")
    log_to_file(f"Lists updated. Errors: {errors}")


async def do_update_inline(cb):
    errors = []
    ip_count = 0
    dom_count = 0
    try:
        wl_ok = await asyncio.to_thread(update_whitelist_from_sources)
        r1 = await asyncio.to_thread(
            subprocess.run,
            [VENV_PYTHON, os.path.join(SYSTEM_DIR, "blocked-domains", "block_domains.py")],
            capture_output=True, text=True, timeout=120
        )
        if r1.returncode != 0:
            errors.append(f"domains: {r1.stderr[:200]}")
        r2 = await asyncio.to_thread(
            subprocess.run,
            [VENV_PYTHON, os.path.join(SYSTEM_DIR, "blocked-ips", "block_ips.py")],
            capture_output=True, text=True, timeout=120
        )
        if r2.returncode != 0:
            errors.append(f"ips: {r2.stderr[:200]}")
        ip_count = await asyncio.to_thread(get_ipset_count)
        dom_count = await asyncio.to_thread(get_domains_count)
    except Exception as e:
        errors.append(str(e))
        wl_ok = False
    log_update_history("manual", ip_count, dom_count, wl_ok)
    if errors:
        await cb.message.edit_text(f"⚠️ Ошибки:\n`{'  '.join(errors)}`",
                                   parse_mode="Markdown", reply_markup=get_inline_menu())
    else:
        text = await build_status_text()
        await cb.message.edit_text(text + f"\n\n✅ Обновлено | IP: {ip_count} | Dom: {dom_count}",
                                   parse_mode="Markdown", reply_markup=get_inline_menu())


# === SWITCH MENU ===
@dp.callback_query(F.data == "switch_menu")
async def cb_switch_menu(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    s = load_settings()
    current = s.get("menu_mode", "inline")
    s["menu_mode"] = "reply" if current == "inline" else "inline"
    save_settings(s)
    new = s["menu_mode"]
    await cb.answer(f"Меню: {new.upper()}", show_alert=False)
    chat_id = cb.message.chat.id
    if new == "reply":
        await cb.message.delete()
        text = await build_status_text()
        await bot.send_message(chat_id, text, parse_mode="Markdown", reply_markup=get_reply_menu())
    else:
        text = await build_status_text()
        await bot.send_message(chat_id, text, parse_mode="Markdown",
                               reply_markup=ReplyKeyboardRemove())
        await bot.send_message(chat_id, "Главное меню:", reply_markup=get_inline_menu())


# === REFERRAL ===
@dp.callback_query(F.data == "show_referral")
async def cb_referral(cb: CallbackQuery):
    await cb.message.answer(REFERRAL_TEXT, parse_mode="Markdown", disable_web_page_preview=True)
    await cb.answer()


# === WHITELIST CALLBACKS ===
@dp.callback_query(F.data == "wl_menu")
async def cb_wl_menu(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    cfg = load_wl_config()
    tg = "✅" if cfg["telegram"] else "❌"
    yt = "✅" if cfg["youtube"] else "❌"
    cu = "✅" if cfg["custom"] else "❌"
    cnt = len(get_custom_entries())
    text = (
        "📋 *Белый список*\n\n"
        f"  📱 Telegram: {tg}\n"
        f"  📺 YouTube: {yt}\n"
        f"  📝 Свой: {cu} ({cnt})\n\n"
        "⚠️ Ответственность на пользователе."
    )
    await cb.message.edit_text(text, parse_mode="Markdown", reply_markup=get_wl_menu())
    await cb.answer()


@dp.callback_query(F.data == "wl_toggle_tg")
async def cb_wl_tg(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    cfg = load_wl_config()
    cfg["telegram"] = not cfg["telegram"]
    save_wl_config(cfg)
    await cb.answer(f"Telegram: {'✅' if cfg['telegram'] else '❌'}")
    await cb.message.edit_reply_markup(reply_markup=get_wl_menu())


@dp.callback_query(F.data == "wl_toggle_yt")
async def cb_wl_yt(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    cfg = load_wl_config()
    cfg["youtube"] = not cfg["youtube"]
    save_wl_config(cfg)
    await cb.answer(f"YouTube: {'✅' if cfg['youtube'] else '❌'}")
    await cb.message.edit_reply_markup(reply_markup=get_wl_menu())


@dp.callback_query(F.data == "wl_toggle_custom")
async def cb_wl_cu(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    cfg = load_wl_config()
    cfg["custom"] = not cfg["custom"]
    save_wl_config(cfg)
    await cb.answer(f"Свой: {'✅' if cfg['custom'] else '❌'}")
    await cb.message.edit_reply_markup(reply_markup=get_wl_menu())


@dp.callback_query(F.data == "wl_add")
async def cb_wl_add(cb: CallbackQuery, state: FSMContext):
    if not await is_admin_cb(cb):
        return
    await cb.message.edit_text(
        "📝 *Добавление в белый список*\n\n"
        "Отправьте домены/IP, каждый с новой строки.\n"
        "Пример:\n`example.com\n1.2.3.4\n10.0.0.0/24`\n\n"
        "⚠️ Ответственность на вас.\n"
        "/cancel для отмены",
        parse_mode="Markdown"
    )
    await state.set_state(WLStates.waiting_custom_add)
    await cb.answer()


@dp.message(WLStates.waiting_custom_add)
async def fsm_add(msg: types.Message, state: FSMContext):
    if not await is_admin(msg):
        await state.clear()
        return
    if msg.text and msg.text.strip() == "/cancel":
        await state.clear()
        await msg.answer("❌ Отменено.")
        return
    if not msg.text:
        await state.clear()
        await msg.answer("Отправьте текст.")
        return
    entries = [l.strip() for l in msg.text.split("\n") if l.strip()]
    added, skipped = add_custom_entries(entries)
    await state.clear()
    parts = []
    if added:
        parts.append(f"✅ Добавлено: *{len(added)}*")
    if skipped:
        parts.append(f"⚠️ Пропущено: *{len(skipped)}*")
    if parts:
        parts.append("\n🔄 Обновите списки для применения.")
        await msg.answer("\n".join(parts), parse_mode="Markdown")
    else:
        await msg.answer("ℹ️ Нечего добавлять.")


@dp.callback_query(F.data == "wl_del")
async def cb_wl_del(cb: CallbackQuery, state: FSMContext):
    if not await is_admin_cb(cb):
        return
    entries = get_custom_entries()
    if not entries:
        await cb.answer("Список пуст", show_alert=True)
        return
    lines = [f"`{i+1}.` {e}" for i, e in enumerate(entries[:30])]
    await cb.message.edit_text(
        "➖ *Удаление*\n\n" + "\n".join(lines) + "\n\nОтправьте номер или /cancel",
        parse_mode="Markdown"
    )
    await state.set_state(WLStates.waiting_custom_del)
    await cb.answer()


@dp.message(WLStates.waiting_custom_del)
async def fsm_del(msg: types.Message, state: FSMContext):
    if not await is_admin(msg):
        await state.clear()
        return
    if msg.text and msg.text.strip() == "/cancel":
        await state.clear()
        await msg.answer("❌ Отменено.")
        return
    try:
        idx = int(msg.text.strip()) - 1
        removed = delete_custom_entry(idx)
        await state.clear()
        if removed:
            await msg.answer(f"✅ Удалено: `{removed}`", parse_mode="Markdown")
        else:
            await msg.answer("❌ Неверный номер.")
    except ValueError:
        await state.clear()
        await msg.answer("Введите число или /cancel.")


@dp.callback_query(F.data == "wl_show")
async def cb_wl_show(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    entries = get_custom_entries()
    if entries:
        text = "\n".join(entries[:50])
        if len(entries) > 50:
            text += f"\n\n... и ещё {len(entries)-50}"
        await cb.message.answer(f"📄 *Свой список ({len(entries)}):*\n\n`{text}`", parse_mode="Markdown")
    else:
        await cb.message.answer("📄 Список пуст.")
    await cb.answer()


@dp.callback_query(F.data == "wl_clear")
async def cb_wl_clear(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    await cb.message.edit_text(
        "🗑 Очистить *весь* пользовательский список?",
        parse_mode="Markdown",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🗑 Да", callback_data="wl_clear_confirm"),
             InlineKeyboardButton(text="◀️ Отмена", callback_data="wl_menu")],
        ])
    )
    await cb.answer()


@dp.callback_query(F.data == "wl_clear_confirm")
async def cb_wl_clear_confirm(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    clear_custom()
    await cb.message.edit_text("🗑 Список очищен.", reply_markup=get_wl_menu())
    await cb.answer()


@dp.callback_query(F.data == "wl_export")
async def cb_wl_export(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    text = export_whitelist()
    p = os.path.join(LOG_DIR, "whitelist_export.txt")
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    try:
        from aiogram.types import FSInputFile
        doc = FSInputFile(p, filename="whitelist_export.txt")
        await cb.message.answer_document(doc, caption="📤 Экспорт белого списка")
    except Exception:
        if len(text) <= 4000:
            await cb.message.answer(f"📤 *Экспорт:*\n\n`{text}`", parse_mode="Markdown")
    await cb.answer()


@dp.callback_query(F.data == "wl_import")
async def cb_wl_import(cb: CallbackQuery, state: FSMContext):
    if not await is_admin_cb(cb):
        return
    await cb.message.edit_text(
        "📥 *Импорт*\n\nОтправьте домены/IP текстом или файлом .txt\n/cancel для отмены",
        parse_mode="Markdown"
    )
    await state.set_state(WLStates.waiting_import)
    await cb.answer()


@dp.message(WLStates.waiting_import)
async def fsm_import(msg: types.Message, state: FSMContext):
    if not await is_admin(msg):
        await state.clear()
        return
    if msg.text and msg.text.strip() == "/cancel":
        await state.clear()
        await msg.answer("❌ Отменено.")
        return
    entries = []
    if msg.document:
        try:
            file = await bot.get_file(msg.document.file_id)
            dl = await bot.download_file(file.file_path)
            content = dl.read().decode("utf-8")
            entries = [l.strip() for l in content.splitlines() if l.strip() and not l.startswith("#")]
        except Exception as e:
            await state.clear()
            await msg.answer(f"❌ Ошибка: {e}")
            return
    elif msg.text:
        entries = [l.strip() for l in msg.text.split("\n") if l.strip()]
    if not entries:
        await state.clear()
        await msg.answer("ℹ️ Пустой список.")
        return
    added, skipped = add_custom_entries(entries)
    await state.clear()
    parts = []
    if added:
        parts.append(f"✅ Импортировано: *{len(added)}*")
    if skipped:
        parts.append(f"⚠️ Пропущено: *{len(skipped)}*")
    await msg.answer("\n".join(parts) if parts else "ℹ️ Нечего импортировать.", parse_mode="Markdown")


# === DOCKER ===
@dp.callback_query(F.data == "docker_menu")
async def cb_docker_menu(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    await do_docker_inline(cb)


async def do_docker_menu(msg):
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🟢 Включить", callback_data="docker_enable"),
         InlineKeyboardButton(text="🔴 Отключить", callback_data="docker_disable")],
        [InlineKeyboardButton(text="📊 Статус", callback_data="docker_status")],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")],
    ])
    containers, prot = await asyncio.to_thread(get_docker_info)
    icon = "🟢" if prot else "🔴"
    c_text = ", ".join(containers) if containers else "нет"
    await msg.answer(
        f"🐳 *Docker*\n\nЗащита: {icon}\nКонтейнеры: {c_text}",
        parse_mode="Markdown", reply_markup=kb
    )


async def do_docker_inline(cb):
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🟢 Включить", callback_data="docker_enable"),
         InlineKeyboardButton(text="🔴 Отключить", callback_data="docker_disable")],
        [InlineKeyboardButton(text="📊 Статус", callback_data="docker_status")],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")],
    ])
    containers, prot = await asyncio.to_thread(get_docker_info)
    icon = "🟢" if prot else "🔴"
    c_text = ", ".join(containers) if containers else "нет"
    await cb.message.edit_text(
        f"🐳 *Docker*\n\nЗащита: {icon}\nКонтейнеры: {c_text}",
        parse_mode="Markdown", reply_markup=kb
    )
    await cb.answer()


@dp.callback_query(F.data == "docker_enable")
async def cb_docker_enable(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    if os.path.exists(DOCKER_RULES):
        await asyncio.to_thread(subprocess.run, ["bash", DOCKER_RULES, "enable"],
                                capture_output=True, timeout=30)
        await cb.message.edit_text("✅ Docker-защита включена.")
    else:
        await cb.message.edit_text("❌ docker_rules.sh не найден.")
    await cb.answer()


@dp.callback_query(F.data == "docker_disable")
async def cb_docker_disable(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    if os.path.exists(DOCKER_RULES):
        await asyncio.to_thread(subprocess.run, ["bash", DOCKER_RULES, "disable"],
                                capture_output=True, timeout=30)
        await cb.message.edit_text("✅ Docker-защита отключена.")
    else:
        await cb.message.edit_text("❌ docker_rules.sh не найден.")
    await cb.answer()


@dp.callback_query(F.data == "docker_status")
async def cb_docker_status(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    containers, prot = await asyncio.to_thread(get_docker_info)
    icon = "🟢 Активна" if prot else "🔴 Неактивна"
    c_text = "\n".join(f"  • {c}" for c in containers) if containers else "  нет"
    await cb.message.edit_text(
        f"🐳 *Docker статус:*\n\nЗащита: {icon}\n\nКонтейнеры:\n{c_text}",
        parse_mode="Markdown"
    )
    await cb.answer()


# === BLOCK LOG ===
@dp.callback_query(F.data == "block_log_menu")
async def cb_block_log(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    s = load_settings()
    notify = s.get("block_log_notify", False)
    icon = "🔔" if notify else "🔕"
    await cb.message.edit_text(
        f"📜 *Лог блокировок* {icon}\n\n"
        "Фиксируются попытки перехода на запрещённые ресурсы\n"
        "и запросы к заблокированным доменам.",
        parse_mode="Markdown", reply_markup=get_block_log_menu()
    )
    await cb.answer()


@dp.callback_query(F.data == "bl_recent")
async def cb_bl_recent(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    text = get_recent_block_log(20)
    if len(text) > 3500:
        text = text[-3500:]
    await cb.message.answer(f"📜 *Последние записи:*\n\n```\n{text}```", parse_mode="Markdown")
    await cb.answer()


@dp.callback_query(F.data == "bl_toggle_notify")
async def cb_bl_toggle(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    s = load_settings()
    s["block_log_notify"] = not s.get("block_log_notify", False)
    save_settings(s)
    icon = "🔔 Включены" if s["block_log_notify"] else "🔕 Выключены"
    await cb.answer(f"Уведомления: {icon}", show_alert=True)
    await cb.message.edit_reply_markup(reply_markup=get_block_log_menu())


# === HEALTH CHECK ===
@dp.callback_query(F.data == "health_check")
async def cb_health(cb: CallbackQuery):
    if not await is_admin_cb(cb):
        return
    await cb.message.edit_text("🏥 Диагностика...")
    report = await asyncio.to_thread(build_health_report)
    await cb.message.edit_text(report, parse_mode="Markdown", reply_markup=get_inline_menu())
    await cb.answer()


def build_health_report():
    checks = []
    r = subprocess.run(["systemctl", "is-active", "unbound"], capture_output=True, text=True, timeout=5)
    ok = r.stdout.strip() == "active"
    checks.append(f"{'🟢' if ok else '🔴'} Unbound: {r.stdout.strip()}")

    r = subprocess.run(["ipset", "list", "blocked_ips", "-t"], capture_output=True, text=True, timeout=5)
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            if "Number of entries" in line:
                parts = line.split(":")
                if len(parts) >= 2:
                    checks.append(f"🟢 ipset: {parts[1].strip()} записей")
                break
    else:
        checks.append("🔴 ipset: не найден")

    r = subprocess.run(
        ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
        capture_output=True, timeout=5
    )
    checks.append(f"{'🟢' if r.returncode == 0 else '🔴'} iptables DROP: {'да' if r.returncode == 0 else 'нет'}")

    r = subprocess.run(
        ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst",
         "-j", "LOG", "--log-prefix", "WHITEVPN_BLOCK: ", "--log-level", "4"],
        capture_output=True, timeout=5
    )
    checks.append(f"{'🟢' if r.returncode == 0 else '🔴'} iptables LOG: {'да' if r.returncode == 0 else 'нет'}")

    try:
        r = subprocess.run(["dig", "@127.0.0.1", "google.com", "+short"],
                           capture_output=True, text=True, timeout=5)
        ok = bool(r.stdout.strip())
        checks.append(f"{'🟢' if ok else '🔴'} DNS: {'ОК' if ok else 'нет'}")
    except Exception:
        checks.append("🔴 DNS: timeout")

    try:
        with open("/etc/resolv.conf", "r") as f:
            ok = "127.0.0.1" in f.read()
        checks.append(f"{'🟢' if ok else '🔴'} resolv.conf: {'127.0.0.1' if ok else '???'}")
    except Exception:
        checks.append("🔴 resolv.conf: ошибка")

    r = subprocess.run(["systemctl", "is-active", "x-ui"], capture_output=True, text=True, timeout=5)
    checks.append(f"{'🟢' if r.stdout.strip() == 'active' else '⚫'} 3x-ui: {r.stdout.strip()}")

    containers, prot = get_docker_info()
    if containers:
        checks.append(f"{'🟢' if prot else '🔴'} Docker: {len(containers)} шт, защита {'ВКЛ' if prot else 'ВЫКЛ'}")

    cfg = load_wl_config()
    tg = "✅" if cfg["telegram"] else "❌"
    yt = "✅" if cfg["youtube"] else "❌"
    cu = "✅" if cfg["custom"] else "❌"
    checks.append(f"\n📋 Whitelist: TG{tg} YT{yt} Custom{cu}")

    # Last update info
    history = get_update_history()
    if history:
        last = history[-1]
        checks.append(f"\n📈 Последнее обновление: {last.get('time', '?')}")

    return "🏥 *Диагностика:*\n\n" + "\n".join(checks)


# === FALLBACK ===
@dp.message()
async def handle_unknown(msg: types.Message):
    if msg.from_user.id not in ADMIN_IDS:
        return
    await msg.answer("ℹ️ Неизвестная команда. /help")


# === BACKGROUND TASKS ===
AUTO_UPDATE_INTERVAL = 24 * 3600  # once per day


async def auto_update_lists():
    await asyncio.sleep(60)
    while True:
        try:
            log_to_file("Auto-update lists...")
            # Update whitelist sources
            wl_ok = await asyncio.to_thread(update_whitelist_from_sources)
            r1 = await asyncio.to_thread(
                subprocess.run,
                [VENV_PYTHON, os.path.join(SYSTEM_DIR, "blocked-domains", "block_domains.py")],
                capture_output=True, text=True, timeout=120
            )
            r2 = await asyncio.to_thread(
                subprocess.run,
                [VENV_PYTHON, os.path.join(SYSTEM_DIR, "blocked-ips", "block_ips.py")],
                capture_output=True, text=True, timeout=120
            )
            ip_count = await asyncio.to_thread(get_ipset_count)
            dom_count = await asyncio.to_thread(get_domains_count)
            errors = []
            if r1.returncode != 0:
                errors.append(r1.stderr[:200])
            if r2.returncode != 0:
                errors.append(r2.stderr[:200])
            log_update_history("auto", ip_count, dom_count, wl_ok)
            if errors:
                for aid in ADMIN_IDS:
                    try:
                        await bot.send_message(aid, f"⚠️ Автообновление с ошибками:\n{chr(10).join(errors)}")
                    except Exception:
                        pass
            log_to_file(f"Auto-update done. IP:{ip_count} Dom:{dom_count} Errors: {errors}")
        except asyncio.CancelledError:
            break
        except Exception as e:
            log_to_file(f"Auto-update error: {e}")
        await asyncio.sleep(AUTO_UPDATE_INTERVAL)


async def health_watchdog():
    await asyncio.sleep(300)
    while True:
        try:
            r = await asyncio.to_thread(
                subprocess.run, ["systemctl", "is-active", "unbound"],
                capture_output=True, text=True, timeout=5
            )
            if r.stdout.strip() != "active":
                for aid in ADMIN_IDS:
                    try:
                        await bot.send_message(aid, "🚨 Unbound НЕ АКТИВЕН!")
                    except Exception:
                        pass
            r = await asyncio.to_thread(
                subprocess.run,
                ["iptables", "-C", "OUTPUT", "-m", "set", "--match-set", "blocked_ips", "dst", "-j", "DROP"],
                capture_output=True, text=True, timeout=5
            )
            if r.returncode != 0:
                for aid in ADMIN_IDS:
                    try:
                        await bot.send_message(aid, "🚨 iptables правило НЕ НАЙДЕНО!")
                    except Exception:
                        pass
        except asyncio.CancelledError:
            break
        except Exception as e:
            log_to_file(f"Watchdog error: {e}")
        await asyncio.sleep(1800)


# === MAIN ===
async def main():
    logger.info(f"WhiteVPN Bot v{VERSION} starting...")
    log_to_file(f"Bot started (v{VERSION})")
    tasks = [
        asyncio.create_task(auto_update_lists()),
        asyncio.create_task(health_watchdog()),
        asyncio.create_task(monitor_block_log()),
    ]
    try:
        await dp.start_polling(bot)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


if __name__ == "__main__":
    asyncio.run(main())
