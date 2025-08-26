import requests
import json
import subprocess

def fetch_and_block_domains():
    url = "https://github.com/1andrevich/Re-filter-lists/releases/download/13062025/ruleset-domain-refilter_domains.json"
    try:
        response = requests.get(url)
        response.raise_for_status()
        data = response.json()
    except requests.exceptions.RequestException as e:
        print(f"Ошибка при получении JSON: {e}")
        return
    except json.JSONDecodeError as e:
        print(f"Ошибка при парсинге JSON: {e}")
        return

    all_domains = []
    for rule in data.get("rules", []):
        domains = rule.get("domain", [])
        all_domains.extend([d for d in domains if '.' in d])
    
    unique_domains = set(all_domains)
    with open("/etc/unbound/blocked-domains.conf", "w") as f:
        for domain in unique_domains:
            f.write(f'local-zone: "{domain}." deny\n')

    try:
        print(f'Было обработано {unique_domains} доменов')
        subprocess.run(["systemctl", "reload", "unbound"], check=True)
        print("Unbound перезагружен.")
    except subprocess.CalledProcessError as e:
        print(f"Ошибка перезагрузки Unbound: {e}")

if __name__ == "__main__":
    fetch_and_block_domains()