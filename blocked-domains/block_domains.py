import requests
import json
import subprocess
import os
from datetime import datetime

VERSION = "0.3"

# Определение директории логов
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "logs")
LOG_FILE = os.path.join(LOG_DIR, f"block-domains-run-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.log")

# Создание директории логов, если не существует
if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)
    os.chmod(LOG_DIR, 0o755)

def log_to_file(message):
    with open(LOG_FILE, "a") as f:
        f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - {message}\n")

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
        # Если asset не найден, ищем по имени в релизе
        tag = release.get("tag_name", "")
        fallback_url = f"https://github.com/1andrevich/Re-filter-lists/releases/download/{tag}/ruleset-domain-refilter_domains.json"
        log_to_file(f"Asset не найден, используем fallback URL: {fallback_url}")
        return fallback_url
    except Exception as e:
        log_to_file(f"Ошибка получения последнего релиза: {e}")
        # Fallback на известный URL формат
        return None

def fetch_and_block_domains():
    url = get_latest_release_url()
    if url is None:
        error_msg = "Не удалось определить URL списка доменов"
        print(error_msg)
        log_to_file(error_msg)
        return

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
    try:
        with open("/etc/unbound/blocked-domains.conf", "w") as f:
            for domain in unique_domains:
                f.write(f'local-zone: "{domain}." deny\n')
    except IOError as e:
        error_msg = f"Ошибка записи blocked-domains.conf: {e}"
        print(error_msg)
        log_to_file(error_msg)
        return

    try:
        message = f"Обработано {len(unique_domains)} доменов"
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
