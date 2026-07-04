#!/usr/bin/env python3
"""WhiteVPN: настройка шаблона Xray в БД 3x-ui.

Что делает:
  • DNS Xray -> 127.0.0.1 (Unbound) — блокировка доменов работает для VLESS-клиентов
  • routing.domainStrategy = IPIfNonMatch — маршрутизация по резолву
  • freedom.domainStrategy = UseIPv4 — исходящие только по IPv4
    (iptables-фильтр v4; без этого клиент мог бы уйти по IPv6 мимо блокировки)

Старый шаблон сохраняется в /etc/block-ips/xray_template_backup.json
"""
import json
import os
import sqlite3
import subprocess
import sys
import time

DB_PATH = "/etc/x-ui/x-ui.db"
BACKUP_PATH = "/etc/block-ips/xray_template_backup.json"

template = {
    "log": {
        "access": "none",
        "dnsLog": False,
        "error": "",
        "loglevel": "warning",
        "maskAddress": ""
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
            {"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]},
            {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]}
        ]
    },
    "dns": {
        "servers": [
            {"address": "127.0.0.1", "port": 53}
        ]
    },
    "outbounds": [
        {
            "tag": "direct",
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4",
                "redirect": "",
                "noises": []
            }
        },
        {
            "tag": "blocked",
            "protocol": "blackhole",
            "settings": {}
        }
    ],
    "transport": None,
    "policy": {
        "levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
        "system": {
            "statsInboundDownlink": True,
            "statsInboundUplink": True,
            "statsOutboundDownlink": False,
            "statsOutboundUplink": False
        }
    },
    "api": {
        "tag": "api",
        "services": ["HandlerService", "LoggerService", "StatsService"]
    },
    "stats": {},
    "reverse": None,
    "fakedns": None,
    "observatory": None,
    "burstObservatory": None,
    "metrics": {"tag": "metrics_out", "listen": "127.0.0.1:11111"}
}


def main():
    if not os.path.exists(DB_PATH):
        print(f"БД 3x-ui не найдена: {DB_PATH}")
        sys.exit(1)

    tpl_json = json.dumps(template)

    db = sqlite3.connect(DB_PATH)
    cur = db.cursor()
    cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'")
    row = cur.fetchone()

    # Бэкап старого шаблона
    if row and row[0]:
        try:
            os.makedirs(os.path.dirname(BACKUP_PATH), exist_ok=True)
            if not os.path.exists(BACKUP_PATH):  # не затираем самый первый бэкап
                with open(BACKUP_PATH, "w") as f:
                    f.write(row[0])
                print(f"Старый шаблон сохранён: {BACKUP_PATH}")
        except IOError as e:
            print(f"Не удалось сохранить бэкап: {e}")

    if row is not None:
        cur.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (tpl_json,))
        print("Шаблон Xray обновлён")
    else:
        cur.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (tpl_json,))
        print("Шаблон Xray создан")
    db.commit()
    db.close()

    print("Перезапуск x-ui...")
    subprocess.run(["systemctl", "restart", "x-ui"], timeout=30)
    time.sleep(4)

    # Проверка применённого конфига
    cfg_path = "/usr/local/x-ui/bin/config.json"
    if os.path.exists(cfg_path):
        try:
            c = json.load(open(cfg_path))
            print(f"dns: {c.get('dns')}")
            freedom_ds = [o["settings"].get("domainStrategy")
                          for o in c.get("outbounds", []) if o.get("protocol") == "freedom"]
            print(f"freedom domainStrategy: {freedom_ds}")
            print(f"routing domainStrategy: {c.get('routing', {}).get('domainStrategy')}")
        except Exception as e:
            print(f"Не удалось проверить config.json: {e}")
    print("Готово!")


if __name__ == "__main__":
    main()
