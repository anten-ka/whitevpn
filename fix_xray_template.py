#!/usr/bin/env python3
"""Patch x-ui database to set xray template with DNS->Unbound and UseIPv4."""
import json, sqlite3, subprocess, time

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

tpl_json = json.dumps(template)

db = sqlite3.connect("/etc/x-ui/x-ui.db")
cur = db.cursor()
cur.execute("SELECT COUNT(*) FROM settings WHERE key='xrayTemplateConfig'")
if cur.fetchone()[0] > 0:
    cur.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (tpl_json,))
    print("Updated existing template")
else:
    cur.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (tpl_json,))
    print("Inserted new template")
db.commit()
db.close()

print("Restarting x-ui...")
subprocess.run(["systemctl", "restart", "x-ui"], timeout=10)
time.sleep(4)

c = json.load(open("/usr/local/x-ui/bin/config.json"))
print(f"dns: {c.get('dns')}")
freedom_ds = [o["settings"].get("domainStrategy") for o in c["outbounds"] if o.get("protocol") == "freedom"]
print(f"freedom domainStrategy: {freedom_ds}")
print(f"routing domainStrategy: {c.get('routing', {}).get('domainStrategy')}")
print("Done!")
