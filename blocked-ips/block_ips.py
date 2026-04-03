import subprocess
import requests
import time
import os
import shutil
import ipaddress
from datetime import datetime

VERSION = "0.4"

# Определение директории логов
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
LOG_DIR = os.path.join(PROJECT_DIR, "logs")
LOG_FILE = os.path.join(LOG_DIR, f"block-ips-run-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.log")
IPSET_RULES_FILE = os.path.join(LOG_DIR, f"ipset_rules-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.txt")
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


def load_whitelist_networks():
    """Загрузить все IP/подсети из включённых категорий белого списка."""
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
                    # Берём только IP и подсети (не домены)
                    if line[0].isdigit() or line.startswith("2001:"):
                        try:
                            net = ipaddress.ip_network(line, strict=False)
                            whitelist_nets.append(net)
                        except ValueError:
                            pass
        except Exception as e:
            log_to_file(f"Ошибка чтения {cat_file}: {e}")

    log_to_file(f"Загружено {len(whitelist_nets)} IP/подсетей в белый список")
    return whitelist_nets


def is_ip_whitelisted(ip_str, whitelist_nets):
    """Проверить, попадает ли IP/подсеть в белый список.

    Только если блокируемая сеть ПОЛНОСТЬЮ внутри whitelist-сети.
    Не исключаем большие блокируемые подсети из-за маленького whitelist-диапазона.
    """
    try:
        check_net = ipaddress.ip_network(ip_str, strict=False)
        for wl_net in whitelist_nets:
            # Только если check_net является подсетью (или равен) whitelist-сети
            if check_net.subnet_of(wl_net):
                return True
    except (ValueError, TypeError):
        pass
    return False


def setup_ipset():
    desired_maxelem = 2097152
    set_name = 'blocked_ips'

    result = subprocess.run(['sudo', 'ipset', 'list', '-t', set_name], capture_output=True, text=True)
    if result.returncode == 0:
        header_line = [line for line in result.stdout.splitlines() if line.startswith('Header:')][0]
        current_maxelem = int(header_line.split('maxelem ')[1].split()[0])
        if current_maxelem < desired_maxelem or 'hash:ip' in header_line:
            subprocess.run(['sudo', 'iptables', '-D', 'OUTPUT', '-m', 'set', '--match-set', set_name, 'dst', '-j', 'DROP'], capture_output=True)
            subprocess.run(['sudo', 'ipset', 'destroy', set_name], capture_output=True)
            subprocess.run(['sudo', 'ipset', 'create', set_name, 'hash:net', 'maxelem', str(desired_maxelem)], capture_output=True)
            subprocess.run(['sudo', 'iptables', '-A', 'OUTPUT', '-m', 'set', '--match-set', set_name, 'dst', '-j', 'DROP'], capture_output=True)
        else:
            subprocess.run(['sudo', 'ipset', 'flush', set_name], capture_output=True)
    else:
        subprocess.run(['sudo', 'ipset', 'create', set_name, 'hash:net', 'maxelem', str(desired_maxelem)], capture_output=True)

    result = subprocess.run(['sudo', 'iptables', '-C', 'OUTPUT', '-m', 'set', '--match-set', set_name, 'dst', '-j', 'DROP'], capture_output=True)
    if result.returncode != 0:
        subprocess.run(['sudo', 'iptables', '-A', 'OUTPUT', '-m', 'set', '--match-set', set_name, 'dst', '-j', 'DROP'], capture_output=True)


def block_ips(ip_list, whitelist_nets):
    setup_ipset()
    new_ips = [ip.strip() for ip in ip_list if ip.strip()]

    if not new_ips:
        message = "Список IP пуст"
        print(message)
        return

    # Фильтрация: убираем IP из белого списка
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
        message = "После фильтрации белым списком нет IP для блокировки"
        print(message)
        log_to_file(message)
        return

    temp_ipset_file = "/tmp/ipset_rules.txt"
    with open(temp_ipset_file, "w") as f:
        for ip in filtered_ips:
            f.write(f"add blocked_ips {ip} -exist\n")

    with open(temp_ipset_file, "r") as f:
        ipset_data = f.read()
    result = subprocess.run(['sudo', 'ipset', 'restore'], input=ipset_data, text=True, capture_output=True)

    shutil.move(temp_ipset_file, IPSET_RULES_FILE)

    if result.returncode != 0:
        error_msg = f"Ошибка при добавлении IP в ipset: {result.stderr}"
        print(error_msg)
        log_to_file(error_msg)
        return

    message = f"Добавлено {len(filtered_ips)} подсетей/IP в blocked_ips (исключено {whitelisted_count} из белого списка)"
    print(message)


def fetch_and_block_ips(url):
    start_time = time.time()

    # Загрузка белого списка
    whitelist_nets = load_whitelist_networks()

    try:
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        ip_list = [ip.strip() for ip in response.text.splitlines() if ip.strip()]
        block_ips(ip_list, whitelist_nets)
    except requests.RequestException as e:
        error_msg = f"Ошибка загрузки списка IP: {e}"
        print(error_msg)
        log_to_file(error_msg)
        return None
    end_time = time.time()
    elapsed_time = end_time - start_time
    message = f"Время блокировки всех IP: {elapsed_time:.2f} секунд"
    print(message)

    return elapsed_time


if __name__ == "__main__":
    url = "https://antifilter.network/download/ip.lst"
    elapsed_time = fetch_and_block_ips(url)
    if elapsed_time is not None:
        print(f"Все IP заблокированы за {elapsed_time:.2f} секунд. Лог сохранён в {LOG_FILE}")
        print(f"Список IP сохранён в {IPSET_RULES_FILE}")
    else:
        print(f"Произошла ошибка. Проверьте лог: {LOG_FILE}")
