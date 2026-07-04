import subprocess
import requests
import time
import os
import shutil
import ipaddress
from datetime import datetime

VERSION = "0.8"

# Определение директорий
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
LOG_DIR = os.path.join(PROJECT_DIR, "logs")
LOG_FILE = os.path.join(LOG_DIR, f"block-ips-run-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.log")
IPSET_RULES_FILE = os.path.join(LOG_DIR, f"ipset_rules-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.txt")
WHITELIST_DIR = os.path.join(PROJECT_DIR, "whitelist")
WHITELIST_CONF = os.path.join(WHITELIST_DIR, "whitelist.conf")
APPLY_FIREWALL = os.path.join(PROJECT_DIR, "apply_firewall.sh")

BLOCK_SET = "blocked_ips"
ALLOW_SET = "whitevpn_allow"
MAXELEM = 2097152

# Источники списка заблокированных IP (основной + резервные)
IP_LIST_URLS = [
    "https://antifilter.network/download/ip.lst",
    "https://antifilter.download/list/ip.lst",
]

if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)
    os.chmod(LOG_DIR, 0o755)


def log_to_file(message):
    with open(LOG_FILE, "a") as f:
        f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - {message}\n")


def run(cmd, **kw):
    """Запуск команды без sudo (скрипт работает от root)."""
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# IP-диапазоны инфраструктуры WhiteVPN (GitHub) — всегда в allow, никогда не блокируются.
# Иначе OUTPUT DROP режет api.github.com (авто-обновление доменов сломается).
SYSTEM_ALLOW_NETS = [
    "140.82.112.0/20",   # github.com, api.github.com
    "143.55.64.0/20",    # github
    "185.199.108.0/22",  # *.githubusercontent.com
    "192.30.252.0/22",   # github
]


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


def load_whitelist_networks():
    """Загрузить IPv4-подсети из включённых категорий белого списка."""
    config = load_whitelist_config()
    whitelist_nets = []

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
                    if not line[0].isdigit():
                        continue  # домены пропускаем
                    try:
                        net = ipaddress.ip_network(line, strict=False)
                        if net.version == 4:
                            whitelist_nets.append(net)
                    except ValueError:
                        pass
        except Exception as e:
            log_to_file(f"Ошибка чтения {cat_file}: {e}")

    for net_str in SYSTEM_ALLOW_NETS:
        try:
            whitelist_nets.append(ipaddress.ip_network(net_str, strict=False))
        except ValueError:
            pass
    log_to_file(f"Загружено {len(whitelist_nets)} IPv4-подсетей в белый список (вкл. инфраструктуру)")
    return whitelist_nets


def is_ip_whitelisted(ip_str, whitelist_nets):
    """Блокируемая сеть исключается, только если она целиком внутри whitelist-сети.

    Пересечения «большая блокируемая сеть накрывает маленькую whitelist-сеть»
    решаются отдельным ipset whitevpn_allow с правилом ACCEPT (см. apply_firewall.sh).
    """
    try:
        check_net = ipaddress.ip_network(ip_str, strict=False)
        for wl_net in whitelist_nets:
            if check_net.version == wl_net.version and check_net.subnet_of(wl_net):
                return True
    except (ValueError, TypeError):
        pass
    return False


def swap_set(set_name, entries, maxelem):
    """Атомарно заменить содержимое ipset через временный набор и swap.

    Нет окна «без защиты»: старый набор работает, пока наполняется временный.
    """
    tmp = f"{set_name}_tmp"
    run(["ipset", "destroy", tmp])  # на случай мусора от прошлого запуска
    r = run(["ipset", "create", tmp, "hash:net", "maxelem", str(maxelem)])
    if r.returncode != 0:
        log_to_file(f"Не удалось создать временный ipset {tmp}: {r.stderr}")
        return False

    lines = "".join(f"add {tmp} {e} -exist\n" for e in entries)
    r = subprocess.run(["ipset", "restore"], input=lines, text=True, capture_output=True)
    if r.returncode != 0:
        log_to_file(f"Ошибка наполнения {tmp}: {r.stderr}")
        run(["ipset", "destroy", tmp])
        return False

    # Основной набор должен существовать до swap
    run(["ipset", "create", set_name, "hash:net", "maxelem", str(maxelem), "-exist"])
    r = run(["ipset", "swap", tmp, set_name])
    if r.returncode != 0:
        log_to_file(f"Ошибка swap {tmp} <-> {set_name}: {r.stderr}")
        run(["ipset", "destroy", tmp])
        return False
    run(["ipset", "destroy", tmp])
    return True


def update_allow_set(whitelist_nets):
    """Наполнить ipset белого списка (whitevpn_allow)."""
    entries = [str(n) for n in whitelist_nets]
    if swap_set(ALLOW_SET, entries, 65536):
        log_to_file(f"ipset {ALLOW_SET}: {len(entries)} подсетей")
        return True
    return False


def block_ips(ip_list, whitelist_nets):
    new_ips = [ip.strip() for ip in ip_list if ip.strip() and not ip.startswith("#")]

    if not new_ips:
        print("Список IP пуст")
        log_to_file("Список IP пуст — ipset не обновлён")
        return False

    # Фильтрация: убираем подсети, целиком входящие в белый список
    filtered_ips = []
    whitelisted_count = 0
    for ip in new_ips:
        if is_ip_whitelisted(ip, whitelist_nets):
            whitelisted_count += 1
        else:
            filtered_ips.append(ip)

    log_to_file(f"Исключено из блокировки (whitelist): {whitelisted_count} IP/подсетей")
    log_to_file(f"Осталось для блокировки: {len(filtered_ips)} (было {len(new_ips)})")

    if not filtered_ips:
        print("После фильтрации белым списком нет IP для блокировки")
        return False

    if not swap_set(BLOCK_SET, filtered_ips, MAXELEM):
        print("Ошибка обновления ipset (подробности в логе)")
        return False

    # Сохраняем применённый список для истории
    try:
        with open(IPSET_RULES_FILE, "w") as f:
            f.write("\n".join(filtered_ips) + "\n")
    except IOError:
        pass

    message = (f"Добавлено {len(filtered_ips)} подсетей/IP в {BLOCK_SET} "
               f"(исключено {whitelisted_count} по белому списку)")
    print(message)
    log_to_file(message)
    return True


def ensure_rules_and_persist():
    """Убедиться, что правила iptables на месте (если защита не выключена
    вручную) и сохранить ipset для восстановления после перезагрузки."""
    if os.path.exists(APPLY_FIREWALL):
        r = run(["bash", APPLY_FIREWALL, "boot"])
        log_to_file(f"apply_firewall boot: rc={r.returncode}")
        r = run(["bash", APPLY_FIREWALL, "save"])
        log_to_file(f"apply_firewall save: rc={r.returncode}")
    else:
        log_to_file("apply_firewall.sh не найден — правила не проверены")


def fetch_ip_list():
    """Скачать список IP с основного или резервного источника."""
    for url in IP_LIST_URLS:
        try:
            log_to_file(f"Загрузка списка IP: {url}")
            response = requests.get(url, timeout=30)
            response.raise_for_status()
            ip_list = [ip.strip() for ip in response.text.splitlines() if ip.strip()]
            if len(ip_list) < 1000:
                log_to_file(f"Источник {url} вернул подозрительно мало записей "
                            f"({len(ip_list)}) — пробуем следующий")
                continue
            log_to_file(f"Получено {len(ip_list)} записей из {url}")
            return ip_list
        except requests.RequestException as e:
            log_to_file(f"Ошибка загрузки {url}: {e}")
    return None


def fetch_and_block_ips():
    start_time = time.time()

    whitelist_nets = load_whitelist_networks()

    # Белый список обновляем всегда (даже если блок-лист недоступен)
    update_allow_set(whitelist_nets)

    ip_list = fetch_ip_list()
    if ip_list is None:
        print("Не удалось скачать список IP ни с одного источника")
        log_to_file("Все источники IP-списка недоступны")
        # Правила всё равно проверяем: старый ipset продолжает защищать
        ensure_rules_and_persist()
        return None

    if not block_ips(ip_list, whitelist_nets):
        ensure_rules_and_persist()
        return None

    ensure_rules_and_persist()

    elapsed_time = time.time() - start_time
    print(f"Время блокировки всех IP: {elapsed_time:.2f} секунд")
    return elapsed_time


if __name__ == "__main__":
    elapsed_time = fetch_and_block_ips()
    if elapsed_time is not None:
        print(f"Все IP заблокированы за {elapsed_time:.2f} секунд. Лог: {LOG_FILE}")
    else:
        print(f"Произошла ошибка. Проверьте лог: {LOG_FILE}")
