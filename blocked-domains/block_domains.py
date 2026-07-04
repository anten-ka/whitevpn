import requests
import json
import fcntl
import subprocess
import os
from datetime import datetime

VERSION = "0.9"

# Определение директорий
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
LOG_DIR = os.path.join(PROJECT_DIR, "logs")
LOG_FILE = os.path.join(LOG_DIR, f"block-domains-run-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.log")
WHITELIST_DIR = os.path.join(PROJECT_DIR, "whitelist")
WHITELIST_CONF = os.path.join(WHITELIST_DIR, "whitelist.conf")

UNBOUND_CONF = "/etc/unbound/unbound.conf"
BLOCKED_CONF = "/etc/unbound/blocked-domains.conf"
WHITELIST_ZONES_CONF = "/etc/unbound/whitelist-zones.conf"

# Максимум зон в конфиге Unbound. Проверено: 79k зон на 2ГБ VPS = ~43МБ RAM,
# резолв 2мс — лимит 50k был перестраховкой. Коллапс к родителям (см. ниже)
# ещё уменьшает список, так что обрезка при текущих списках не нужна.
MAX_UNBOUND_DOMAINS = 100000

if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)
    os.chmod(LOG_DIR, 0o755)


def log_to_file(message):
    with open(LOG_FILE, "a") as f:
        f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - {message}\n")


# Инфраструктура самого WhiteVPN — НИКОГДА не блокируется. Иначе авто-обновление
# ломает себя: api.github.com присутствует в refilter-блоклисте.
SYSTEM_WHITELIST_DOMAINS = {
    "github.com", "api.github.com", "codeload.github.com",
    "raw.githubusercontent.com", "objects.githubusercontent.com",
    "githubusercontent.com",
    "antifilter.network", "antifilter.download",
}


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


def load_whitelist_domains(config=None):
    """Загрузить домены из включённых категорий белого списка."""
    if config is None:
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
                    if "/" in line or line[0].isdigit() or "*" in line or ":" in line:
                        continue  # IP, подсети, wildcard — не домены
                    whitelist_domains.add(line.lower().rstrip("."))
        except Exception as e:
            log_to_file(f"Ошибка чтения {cat_file}: {e}")

    log_to_file(f"Загружено {len(whitelist_domains)} доменов в белый список")
    return whitelist_domains


# Домены для принудительной блокировки, когда категория ОТКЛЮЧЕНА в whitelist.
# Эти домены не входят в Re-filter-lists, поэтому добавляются явно.
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
        "youtubegaming.com", "googlevideo.com",
    ],
    "telegram": [
        "telegram.org", "web.telegram.org", "desktop.telegram.org",
        "t.me", "telegram.me",
    ],
}


def load_force_block_domains(config):
    """Если категория whitelist ОТКЛЮЧЕНА — её домены блокируются принудительно."""
    force_domains = set()
    for cat_name, domains in FORCE_BLOCK_DOMAINS.items():
        if not config.get(cat_name, True):
            for d in domains:
                force_domains.add(d.lower())
            log_to_file(f"Категория '{cat_name}' отключена -> {len(domains)} доменов в принудительную блокировку")
    return force_domains


def get_latest_release_url():
    """URL актуального списка доменов Re-filter-lists.

    Приоритет — прямая ссылка github.com/releases/latest/download (НЕ требует
    api.github.com, который сам в refilter-блоклисте). API — как запасной путь.
    """
    direct = ("https://github.com/1andrevich/Re-filter-lists/releases/latest/"
              "download/ruleset-domain-refilter_domains.json")
    try:
        r = requests.head(direct, timeout=15, allow_redirects=True)
        if r.status_code == 200:
            log_to_file(f"Прямая ссылка релиза доступна: {direct}")
            return direct
        log_to_file(f"Прямая ссылка вернула {r.status_code}, пробуем API")
    except Exception as e:
        log_to_file(f"Прямая ссылка недоступна ({e}), пробуем API")

    api_url = "https://api.github.com/repos/1andrevich/Re-filter-lists/releases/latest"
    try:
        response = requests.get(api_url, timeout=15)
        response.raise_for_status()
        release = response.json()
        for asset in release.get("assets", []):
            if "refilter_domains" in asset["name"] and asset["name"].endswith(".json"):
                log_to_file(f"Найден релиз: {release.get('tag_name', '?')}, файл: {asset['name']}")
                return asset["browser_download_url"]
        tag = release.get("tag_name", "")
        fallback_url = f"https://github.com/1andrevich/Re-filter-lists/releases/download/{tag}/ruleset-domain-refilter_domains.json"
        log_to_file(f"Asset не найден, fallback: {fallback_url}")
        return fallback_url
    except Exception as e:
        log_to_file(f"Ошибка получения релиза через API: {e}")
        return None


def collapse_to_parents(domains):
    """Убрать домены, чей родитель тоже в наборе: local-zone always_nxdomain в
    Unbound покрывает и все поддомены. Уменьшает список (часто ниже лимита) и
    улучшает покрытие по сравнению с алфавитной обрезкой."""
    dset = set(domains)
    result = set()
    for d in dset:
        parts = d.split(".")
        covered = False
        for i in range(1, len(parts)):
            if ".".join(parts[i:]) in dset:
                covered = True
                break
        if not covered:
            result.add(d)
    return result


def is_subdomain_of_whitelist(domain, whitelist):
    """Домен или его родитель есть в белом списке?"""
    domain = domain.lower()
    if domain in whitelist:
        return True
    parts = domain.split(".")
    for i in range(1, len(parts)):
        parent = ".".join(parts[i:])
        if parent in whitelist:
            return True
    return False


def write_whitelist_zones(whitelist):
    """Записать transparent-зоны для белого списка.

    Зачем: если в блок-листе оказался РОДИТЕЛЬ whitelist-домена (например,
    ggpht.com при белом yt3.ggpht.com), запрет родителя перекрыл бы поддомен.
    Более специфичная local-zone transparent «пробивает» родительский запрет.
    """
    try:
        tmp = WHITELIST_ZONES_CONF + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(f"# WhiteVPN whitelist zones (auto-generated {datetime.now():%Y-%m-%d %H:%M})\n")
            for domain in sorted(whitelist):
                f.write(f'local-zone: "{domain}." transparent\n')
        os.rename(tmp, WHITELIST_ZONES_CONF)
        log_to_file(f"whitelist-zones.conf: {len(whitelist)} transparent-зон")
        return True
    except IOError as e:
        log_to_file(f"Ошибка записи whitelist-zones.conf: {e}")
        return False


def ensure_unbound_conf():
    """Идемпотентно убедиться, что unbound.conf подключает наши файлы
    и логирует срабатывания local-zone (для статистики блокировок)."""
    try:
        with open(UNBOUND_CONF, "r") as f:
            conf = f.read()
        changed = False
        if "whitelist-zones.conf" not in conf:
            conf = conf.replace(
                'include: "/etc/unbound/blocked-domains.conf"',
                'include: "/etc/unbound/whitelist-zones.conf"\n'
                '    include: "/etc/unbound/blocked-domains.conf"'
            )
            changed = True
        if "log-local-actions" not in conf:
            conf = conf.replace(
                "server:",
                "server:\n    log-local-actions: yes\n    use-syslog: yes", 1
            )
            changed = True
        if changed:
            with open(UNBOUND_CONF, "w") as f:
                f.write(conf)
            log_to_file("unbound.conf обновлён (include whitelist-zones, log-local-actions)")
    except IOError as e:
        log_to_file(f"Не удалось обновить unbound.conf: {e}")
    # Файлы должны существовать, иначе unbound не стартует
    for p in (WHITELIST_ZONES_CONF, BLOCKED_CONF):
        if not os.path.exists(p):
            open(p, "w").close()


def fetch_and_block_domains():
    config = load_whitelist_config()
    whitelist = load_whitelist_domains(config)
    whitelist |= SYSTEM_WHITELIST_DOMAINS  # инфраструктура WhiteVPN — всегда исключена
    force_block = load_force_block_domains(config)

    # Bootstrap: сразу пишем whitelist-зоны (transparent), чтобы инфраструктура
    # (github и т.п.) резолвилась даже если её ранее заблокировали — иначе фетч
    # не сможет достучаться до источника.
    write_whitelist_zones(whitelist)
    ensure_unbound_conf()
    subprocess.run(["systemctl", "reload", "unbound"], capture_output=True)

    url = get_latest_release_url()
    if url is None:
        print("Не удалось определить URL списка доменов (источник недоступен)")
        log_to_file("Не удалось определить URL списка доменов")
        return

    try:
        log_to_file(f"Загрузка списка доменов: {url}")
        response = requests.get(url, timeout=60)
        response.raise_for_status()
        data = response.json()
    except requests.exceptions.RequestException as e:
        print(f"Ошибка при получении JSON: {e}")
        log_to_file(f"Ошибка при получении JSON: {e}")
        return
    except json.JSONDecodeError as e:
        print(f"Ошибка при парсинге JSON: {e}")
        log_to_file(f"Ошибка при парсинге JSON: {e}")
        return

    all_domains = []
    for rule in data.get("rules", []):
        domains = rule.get("domain", [])
        all_domains.extend([d for d in domains if "." in d])

    unique_domains = set(d.lower().rstrip(".") for d in all_domains)

    # Фильтрация по белому списку
    blocked_count_before = len(unique_domains)
    filtered_domains = set()
    whitelisted_count = 0
    for domain in unique_domains:
        if is_subdomain_of_whitelist(domain, whitelist):
            whitelisted_count += 1
        else:
            filtered_domains.add(domain)

    log_to_file(f"Исключено из блокировки (whitelist): {whitelisted_count} доменов")
    log_to_file(f"Осталось для блокировки: {len(filtered_domains)} (было {blocked_count_before})")

    # Коллапс к родителям (always_nxdomain покрывает поддомены) — меньше и полнее
    before_collapse = len(filtered_domains)
    filtered_domains = collapse_to_parents(filtered_domains)
    log_to_file(f"После коллапса к родителям: {len(filtered_domains)} (было {before_collapse})")

    # Детерминированный лимит: сортируем и режем, force-block — всегда в списке
    domains_sorted = sorted(filtered_domains)
    if len(domains_sorted) > MAX_UNBOUND_DOMAINS:
        domains_sorted = domains_sorted[:MAX_UNBOUND_DOMAINS]
        log_to_file(f"Список доменов ограничен до {MAX_UNBOUND_DOMAINS} (детерминированно)")

    final_domains = set(domains_sorted)
    if force_block:
        before_force = len(final_domains)
        final_domains.update(force_block)
        log_to_file(f"Добавлено принудительно (force-block): {len(final_domains) - before_force} доменов")

    # Белый список имеет приоритет над force-block пересечениями
    final_domains -= set(d for d in final_domains if is_subdomain_of_whitelist(d, whitelist))

    try:
        # Атомарная запись
        temp_conf = BLOCKED_CONF + ".tmp"
        with open(temp_conf, "w", encoding="utf-8") as f:
            for domain in sorted(final_domains):
                f.write(f'local-zone: "{domain}." always_nxdomain\n')
        os.rename(temp_conf, BLOCKED_CONF)
    except IOError as e:
        print(f"Ошибка записи blocked-domains.conf: {e}")
        log_to_file(f"Ошибка записи blocked-domains.conf: {e}")
        return

    write_whitelist_zones(whitelist)
    ensure_unbound_conf()

    message = f"Обработано {len(final_domains)} доменов (исключено {whitelisted_count} по белому списку)"
    print(message)
    log_to_file(message)

    try:
        r = subprocess.run(["unbound-checkconf"], capture_output=True, text=True)
        if r.returncode != 0:
            log_to_file(f"unbound-checkconf: ОШИБКА: {r.stderr or r.stdout}")
            print("Ошибка конфигурации Unbound — перезагрузка отменена")
            return
        subprocess.run(["systemctl", "reload", "unbound"], check=True)
        print("Unbound перезагружен.")
        log_to_file("Unbound перезагружен (reload)")
    except subprocess.CalledProcessError:
        try:
            subprocess.run(["systemctl", "restart", "unbound"], check=True)
            print("Unbound перезапущен.")
            log_to_file("Unbound перезапущен (restart)")
        except subprocess.CalledProcessError as e:
            print(f"Ошибка перезагрузки Unbound: {e}")
            log_to_file(f"Ошибка перезагрузки Unbound: {e}")


LOCK_FILE = "/tmp/whitevpn-blockdomains.lock"

if __name__ == "__main__":
    _lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(_lock, fcntl.LOCK_EX)
    except Exception:
        pass
    fetch_and_block_domains()
    print(f"Лог сохранён: {LOG_FILE}")
