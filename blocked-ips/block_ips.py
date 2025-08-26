import subprocess
import requests
import time
import os
import shutil
from datetime import datetime

# Определение директории логов
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "logs")
LOG_FILE = os.path.join(LOG_DIR, f"block-ips-run-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.log")
IPSET_RULES_FILE = os.path.join(LOG_DIR, f"ipset_rules-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.txt")

# Создание директории логов, если не существует
if not os.path.exists(LOG_DIR):
    os.makedirs(LOG_DIR)
    os.chmod(LOG_DIR, 0o755)

# Функция для логирования
def log_to_file(message):
    with open(LOG_FILE, "a") as f:
        f.write(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - {message}\n")

def setup_ipset():
    desired_maxelem = 2097152
    set_name = 'blocked_ips'
    
    # Проверка существования набора
    result = subprocess.run(['sudo', 'ipset', 'list', '-t', set_name], capture_output=True, text=True)
    if result.returncode == 0:
        # Набор существует, проверка maxelem
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
    
    # Проверка правила iptables
    result = subprocess.run(['sudo', 'iptables', '-C', 'OUTPUT', '-m', 'set', '--match-set', set_name, 'dst', '-j', 'DROP'], capture_output=True)
    if result.returncode != 0:
        subprocess.run(['sudo', 'iptables', '-A', 'OUTPUT', '-m', 'set', '--match-set', set_name, 'dst', '-j', 'DROP'], capture_output=True)

def block_ips(ip_list):
    setup_ipset()
    new_ips = [ip.strip() for ip in ip_list if ip.strip()]
    
    if not new_ips:
        message = "Список IP пуст"
        print(message)
        return
    
    # Создание временного файла для пакетной загрузки IP
    temp_ipset_file = "/tmp/ipset_rules.txt"
    with open(temp_ipset_file, "w") as f:
        for ip in new_ips:
            f.write(f"add blocked_ips {ip} -exist\n")
    
    # Пакетное применение IP через ipset restore
    result = subprocess.run(['sudo', 'ipset', 'restore'], input=open(temp_ipset_file, "r").read(), text=True, capture_output=True)
    
    # Перемещение временного файла в директорию логов
    shutil.move(temp_ipset_file, IPSET_RULES_FILE)
    
    if result.returncode != 0:
        error_msg = f"Ошибка при добавлении IP в ipset: {result.stderr}"
        print(error_msg)
        log_to_file(error_msg)
        return
    
    message = f"Добавлено {len(new_ips)} подсетей/IP в blocked_ips"
    print(message)

def fetch_and_block_ips(url):
    start_time = time.time()
    try:
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        ip_list = [ip.strip() for ip in response.text.splitlines() if ip.strip()]
        block_ips(ip_list)
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