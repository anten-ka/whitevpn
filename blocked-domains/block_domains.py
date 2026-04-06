import requests
import json
import subprocess
import os
import glob
import re
from datetime import datetime

VERSION = "0.7"

# Определение директории логов
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
LOG_DIR = os.path.join(PROJECT_DIR, "logs")
LOG_FILE = os.path.join(LOG_DIR, f"block-domains-run-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.log")
WHITELIST_DIR = os.path.join(PROJECT_DIR, "whitelist")
WHITELIST_CONF = os.path.join(WHITELIST_DIR, "whitelist.conf")

# Создание директории логов, если не существует
if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)
    os.chmod(LOG_DIR, 0o755)


def log_to_file(message):
    with open(LOG_FILE, "a") as f:
        f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - {message}\n")


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
    except Exception as e:
        log_to_file(f"Ошибка чтения whitelist.conf: {e}")
    return config


def load_whitelist_domains():
    """Загрузить все домены из включённых категорий белого списка."""
    config = load_whitelist_config()
    whitelist_domains = set()

    categories = {
        "telegram": os.path.join(WHITELIST_DIR, "telegram.txt"),
        "youtube": os.path.join(WHITELIST_DIR, "youtube.txt"),
        "custom": os.path.join(WHITELIST_DIR, "custom.txt"),
    }

    for cat_name, cat_file in categories.items():
        if not config.get(cat_name, False):
            log_to_file(f"Категория '{cat_name}' отключена, пропускаем")
            continue
        if not os.path.exists(cat_file):
            log_to_file(f"Файл категории '{cat_name}' не найден: {cat_file}")
            continue
        try:
            with open(cat_file, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    # Берём только домены (без IP/подсетей и wildcard)
                    if "/" in line or line[0].isdigit() or "*" in line:
                        continue
                    whitelist_domains.add(line.lower())
        except Exception as e:
            log_to_file(f"Ошибка чтения {cat_file}: {e}")

    log_to_file(f"Загружено {len(whitelist_domains)} доменов в белый список")
    return whitelist_domains


# Домены для принудительной блокировки, когда категория ОТКЛЮЧЕНА в whitelist.
# Эти домены НЕ входят в Re-filter-lists, поэтому их нужно добавлять явно.
FORCE_BLOCK_DOMAINS = {
    "youtube": [
        "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be",
        "youtubei.googleapis.com", "i.ytimg.com", "s.ytimg.com",
        "youtube-nocookie.com", "youtube-ui.l.google.com",
        "ytimg.l.google.com", "ytstatic.l.google.com",
        "wide-youtube.l.google.com", "youtubeembedded-pa.googleapis.com",
        "yt-video-upload.l.google.com", "yt3.ggpht.com", "yt4.ggpht.com",
        "jnn-pa.googleapis.com", "youtube.l.google.com",
        "withyoutube.com", "youtubekids.com", "youtubeeducation.com",
        "youtubegaming.com",
    ],
    "telegram": [
        "telegram.org", "web.telegram.org", "desktop.telegram.org",
        "t.me", "telegram.me",
    ],
}


def load_force_block_domains(config):
    """Если категория whitelist ОТКЛЮЧЕНА, вернуть домены для принудительной блокировки."""
    force_domains = set()
    for cat_name, domains in FORCE_BLOCK_DOMAINS.items():
        if not config.get(cat_name, True):
            # Категория отключена → добавляем домены в блокировку
            for d in domains:
                force_domains.add(d.lower())
            log_to_file(f"Категория '{cat_name}' отключена → добавлено {len(domains)} доменов в блокировку")
    return force_domains


def get_latest_release_url():
    """Получить URL последнего релиза Re-filter-lists через GitHub API."""
    api_url = "https://api.github.com/repos/1andrevich/Re-filter-lists/releases/latest"
    try:
        response = requests.get(api_url, timeout=15)
        response.raise_for_status()
        release = response.json()
        for asset in release.get("assets", []):
            if "refilter_domains" in asset["name"] and asset["name"].endswith(".json"):
                log_to_file(f"Найден последний релиз: {release.get('tag_name', '?')}, файл: {asset['name']}")
                return asset["browser_download_url"]
        tag = release.get("tag_name", "")
        fallback_url = f"https://github.com/1andrevich/Re-filter-lists/releases/download/{tag}/ruleset-domain-refilter_domains.json"
        log_to_file(f"Asset не найден, используем fallback URL: {fallback_url}")
        return fallback_url
    except Exception as e:
        log_to_file(f"Ошибка получения последнего релиза: {e}")
        return None


def is_subdomain_of_whitelist(domain, whitelist):
    """Проверить, является ли домен или его родитель в белом списке."""
    domain = domain.lower()
    if domain in whitelist:
        return True
    parts = domain.split(".")
    for i in range(1, len(parts)):
        parent = ".".join(parts[i:])
        if parent in whitelist:
            return True
    return False


def fetch_and_block_domains():
    url = get_latest_release_url()
    if url is None:
        error_msg = "Не удалось определить URL списка доменов"
        print(error_msg)
        log_to_file(error_msg)
        return

    # Загрузка белого списка и конфигурации
    config = load_whitelist_config()
    whitelist = load_whitelist_domains()
    force_block = load_force_block_domains(config)

    try:
        log_to_file(f"Загрузка списка доменов: {url}")
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        data = response.json()
    except requests.exceptions.RequestException as e:
        error_msg = f"Ошибка при получении JSON: {e}"
        print(error_msg)
        log_to_file(error_msg)
        return
    except json.JSONDecodeError as e:
        error_msg = f"Ошибка при парсинге JSON: {e}"
        print(error_msg)
        log_to_file(error_msg)
        return

    all_domains = []
    for rule in data.get("rules", []):
        domains = rule.get("domain", [])
        all_domains.extend([d for d in domains if '.' in d])

    unique_domains = set(all_domains)

    # Фильтрация: убираем домены из белого списка
    blocked_count_before = len(unique_domains)
    filtered_domains = set()
    whitelisted_count = 0
    for domain in unique_domains:
        if is_subdomain_of_whitelist(domain, whitelist):
            whitelisted_count += 1
        else:
            filtered_domains.add(domain)

    log_to_file(f"Исключено из блокировки (whitelist): {whitelisted_count} доменов")
    log_to_file(f"Осталось для блокировки: {len(filtered_domains)} доменов (было {blocked_count_before})")

    # Принудительная блокировка доменов для отключённых категорий
    if force_block:
        before_force = len(filtered_domains)
        filtered_domains.update(force_block)
        added = len(filtered_domains) - before_force
        log_to_file(f"Добавлено принудительно (force-block): {added} новых доменов")

    try:
        # Атомарная запись: сначала во временный файл, потом rename
        temp_conf = "/etc/unbound/blocked-domains.conf.tmp"
        target_conf = "/etc/unbound/blocked-domains.conf"
        with open(temp_conf, "w", encoding="utf-8") as f:
            for domain in filtered_domains:
                f.write(f'local-zone: "{domain}." deny\n')
        os.rename(temp_conf, target_conf)
    except IOError as e:
        error_msg = f"Ошибка записи blocked-domains.conf: {e}"
        print(error_msg)
        log_to_file(error_msg)
        return

    try:
        message = f"Обработано {len(filtered_domains)} доменов (исключено {whitelisted_count} из белого списка)"
        print(message)
        log_to_file(message)
        subprocess.run(["systemctl", "reload", "unbound"], check=True)
        success_msg = "Unbound перезагружен."
        print(success_msg)
        log_to_file(success_msg)
    except subprocess.CalledProcessError as e:
        error_msg = f"Ошибка перезагрузки Unbound: {e}"
        print(error_msg)
        log_to_file(error_msg)


if __name__ == "__main__":
    fetch_and_block_domains()
    print(f"Лог сохранён: {LOG_FILE}")
