![Version](https://img.shields.io/badge/version-0.7-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-Ubuntu%2022.04+-orange)

# WhiteVPN — система блокировки нежелательных ресурсов на VPN-сервере

[English version](README_EN.md)

WhiteVPN блокирует доступ к нежелательным сайтам и IP-адресам на уровне VPN-сервера. Работает с **прокси-VPN** (VLESS/Xray через 3X-UI) и **туннельными VPN** в Docker (AmneziaWG, WireGuard и др.).

---

## Содержание

1. [Архитектура](#архитектура)
2. [Как работает блокировка](#как-работает-блокировка)
3. [Установка](#установка)
4. [Управление](#управление)
5. [Telegram-бот](#telegram-бот)
6. [Белые списки](#белые-списки)
7. [Docker-защита](#docker-защита)
8. [VLESS/Xray (3X-UI)](#vlessxray-3x-ui)
9. [Автообновление](#автообновление)
10. [Структура файлов](#структура-файлов)
11. [Systemd-юниты](#systemd-юниты)
12. [Диагностика и решение проблем](#диагностика-и-решение-проблем)

---

## Архитектура

```
                              VPN-СЕРВЕР
                    ┌──────────────────────────┐
                    │                          │
  VLESS-клиент ───► │  Xray (3X-UI, на хосте)  │──► iptables OUTPUT ──► ipset DROP
                    │  DNS: Unbound 127.0.0.1  │              │
                    │                          │     Unbound DNS ──► deny (NXDOMAIN)
                    │                          │
  WG-клиент ──────► │  AmneziaWG (Docker)      │──► iptables DOCKER-USER ──► ipset DROP
                    │  DNS: DNAT → Unbound     │              │
                    │                          │     Unbound DNS ──► deny (NXDOMAIN)
                    └──────────────────────────┘
```

Система использует два уровня блокировки, которые работают одновременно: блокировка по IP-адресам через ipset/iptables и блокировка по доменам через DNS-сервер Unbound.

---

## Как работает блокировка

### Уровень 1: Блокировка по IP

Скрипт `block_ips.py` загружает список IP-адресов с [antifilter.network](https://antifilter.network/download/ip.lst) (~100 000 подсетей), применяет фильтр белого списка и загружает результат в ipset-множество `blocked_ips` формата `hash:net` (до 2 млн записей).

Iptables-правила перехватывают трафик в двух точках: цепочка `OUTPUT` отлавливает трафик от Xray (прокси-VPN), а цепочка `DOCKER-USER` — трафик из Docker-контейнеров. Пакеты на IP из `blocked_ips` сначала логируются с префиксом `WHITEVPN_BLOCK`, а затем дропаются.

### Уровень 2: Блокировка по доменам

Скрипт `block_domains.py` загружает список доменов из [Re-filter-lists](https://github.com/1andrevich/Re-filter-lists) (~81 000 доменов), применяет фильтр белого списка и записывает результат в файл `/etc/unbound/blocked-domains.conf` в формате `local-zone: "domain." deny`.

Unbound DNS работает на `127.0.0.1:53` и обслуживает DNS-запросы от сервера. При запросе заблокированного домена Unbound молча отбрасывает запрос (тип `deny`), что приводит к таймауту DNS у клиента. Для незаблокированных доменов Unbound работает как обычный рекурсивный резолвер.

### Принудительная блокировка (force-block)

Некоторые домены (youtube.com, telegram.org и др.) отсутствуют в Re-filter-lists, поскольку они не заблокированы на уровне DNS в источнике. Когда соответствующая категория белого списка **отключена** (например, `youtube=0`), скрипт `block_domains.py` принудительно добавляет эти домены в файл блокировки. Список принудительно блокируемых доменов хранится в словаре `FORCE_BLOCK_DOMAINS` и включает: youtube.com, www.youtube.com, m.youtube.com, youtubei.googleapis.com, i.ytimg.com и другие CDN-домены YouTube (22 домена), а также telegram.org, web.telegram.org, t.me и др. (5 доменов).

### Ограничение Unbound

На VPS с 2 ГБ RAM Unbound зависает при загрузке более ~50 000 доменных зон. Поэтому функция `trim_blocked_domains()` в боте ограничивает файл до 50 000 записей после каждого обновления.

---

## Установка

```bash
git clone https://github.com/anten-ka/whitevpn.git
cd whitevpn
sudo bash install.sh
```

Установщик автоматически: установит зависимости (ipset, iptables, unbound, python3), создаст директории и конфиги в `/opt/block-traffic/`, загрузит и применит списки IP и доменов, настроит systemd-таймеры для автообновления, установит CLI-меню `blockme`, обнаружит Docker и предложит выбрать контейнеры для защиты.

Если Docker не установлен, этап с контейнерами пропускается.

### Установка Telegram-бота

```bash
blockme   # выбрать пункт 6
```

Бот устанавливается отдельно. Потребуется: токен бота от @BotFather и Telegram ID администратора (можно узнать через @userinfobot).

---

## Управление

### CLI-меню

```bash
blockme
```

Пункты меню: обновить списки IP и доменов, удалить систему, отключить/включить защиту, перезапустить сервисы, установить/обновить Telegram-бот, Docker-блокировка (AmneziaWG).

### Прямые команды

```bash
# Docker-управление
/opt/block-traffic/docker_rules.sh scan          # сканировать контейнеры
/opt/block-traffic/docker_rules.sh auto-setup    # автонастройка
/opt/block-traffic/docker_rules.sh enable        # включить
/opt/block-traffic/docker_rules.sh disable       # отключить
/opt/block-traffic/docker_rules.sh status        # статус
/opt/block-traffic/docker_rules.sh cleanup       # полная очистка

# Ручное обновление списков
python3 /opt/block-traffic/blocked-domains/block_domains.py
python3 /opt/block-traffic/blocked-ips/block_ips.py
```

---

## Telegram-бот

Бот построен на **aiogram 3.5.0** (асинхронный, с FSM) и предоставляет полное удалённое управление сервером через Telegram.

### Команды

`/start` — главное меню, `/help` — справка, `/health` — диагностика, `/whitelist` — управление белыми списками.

### Главное меню

Бот поддерживает два режима меню (переключаются кнопкой): **Inline-кнопки** (под сообщением) и **Reply-клавиатура** (внизу экрана). Также доступен **компактный** и **полный** режим размера меню.

### Функции бота

**Статус сервера** — показывает uptime, нагрузку, память, диск, количество заблокированных IP и доменов, статус Unbound, iptables, 3X-UI, Docker-контейнеров.

**Обновление списков** — загружает свежие списки из источников, применяет белые списки, обрезает до лимита, перезагружает Unbound. Запись результата в историю обновлений (последние 5).

**Включение/отключение защиты** — запускает/останавливает Unbound, добавляет/удаляет правила iptables, настраивает/убирает DNAT для Docker-контейнеров, переключает resolv.conf между 127.0.0.1 и 8.8.8.8.

**Docker-управление** — включить/отключить/статус Docker-защиты. При отключении удаляются правила DOCKER-USER и DNAT-перенаправления DNS.

**Лог блокировок** — мониторинг journalctl в реальном времени на записи `WHITEVPN_BLOCK` и `deny` от Unbound. Ротация лога при 30 МБ. Опциональные уведомления о блокировках.

**Диагностика** — полный отчёт о состоянии всех компонентов: Unbound, iptables, ipset, Docker, 3X-UI, DNS-резолвинг, свободное место.

**Белые списки** — полное управление категориями (YouTube, Telegram, пользовательские). Подробнее в разделе ниже.

### Фоновые задачи

Бот запускает три фоновые задачи: **auto_update_lists** обновляет списки раз в 24 часа; **health_watchdog** проверяет работоспособность Unbound и iptables каждые 5 минут и уведомляет при сбоях; **monitor_block_log** отслеживает системный журнал в реальном времени.

---

## Белые списки

Белые списки позволяют исключать определённые ресурсы из блокировки. Система поддерживает три категории.

### Категории

**YouTube** (`youtube=1/0`) — при включении исключает ~600 доменов YouTube и CDN из блокировки. Источник: [v2fly domain-list-community](https://github.com/v2fly/domain-list-community/blob/master/data/youtube) плюс 22 дополнительных CDN-домена (googlevideo.com, ytimg.com, ggpht.com и др.). При **отключении** (`youtube=0`) эти домены принудительно добавляются в блокировку.

**Telegram** (`telegram=1/0`) — при включении исключает домены и IP-подсети Telegram (AS62041, AS59930, AS62014). Источник: [v2fly](https://github.com/v2fly/domain-list-community/blob/master/data/telegram) плюс 19 доп. доменов. При **отключении** домены telegram.org, t.me, web.telegram.org и др. принудительно блокируются.

**Пользовательские** (`custom=1/0`) — домены и IP-адреса, добавленные вручную через бот. Поддерживается добавление, удаление, очистка, импорт/экспорт.

### Конфигурация

Файл `/opt/block-traffic/whitelist/whitelist.conf`:
```
telegram=1
youtube=1
custom=1
```

Файлы доменов: `telegram.txt`, `youtube.txt`, `custom.txt` в директории `/opt/block-traffic/whitelist/`.

### Логика работы

При обновлении списков (`block_domains.py`): сначала загружаются все домены из Re-filter-lists, затем для каждого домена проверяется, входит ли он (или его родительский домен) в один из включённых белых списков — если да, домен исключается из блокировки. После фильтрации проверяются отключённые категории: если категория отключена (=0), её домены из словаря `FORCE_BLOCK_DOMAINS` принудительно добавляются в файл блокировки.

Для IP-блокировки (`block_ips.py`) аналогичная логика: включённые категории белого списка исключают IP-подсети из ipset.

### Управление через бот

Через меню "Белый список" доступны: переключение категорий (Telegram вкл/выкл, YouTube вкл/выкл, Custom вкл/выкл), добавление доменов и IP в пользовательский список, удаление записей по номеру, просмотр всех записей, очистка, экспорт в текст, импорт из текста или файла. После переключения категории бот автоматически пересобирает списки блокировки.

---

## Docker-защита

### Принцип работы

Docker-контейнеры (AmneziaWG, WireGuard и др.) работают в изолированных сетях. Их трафик проходит через цепочку `FORWARD`, а не `OUTPUT`, поэтому стандартные правила iptables не действуют. WhiteVPN использует цепочку `DOCKER-USER` (которую Docker не перезаписывает при рестарте) для блокировки трафика из контейнеров на IP из ipset `blocked_ips`.

### DNS для Docker

Клиенты VPN в Docker-контейнерах используют DNS-серверы, указанные в конфигурации контейнера (часто 1.1.1.1 или 8.8.8.8). Чтобы DNS-блокировка через Unbound работала, WhiteVPN перехватывает DNS-запросы из Docker-подсетей и перенаправляет их на Unbound через DNAT-правила в таблице NAT.

Функция `_setup_dns_dnat()` автоматически обнаруживает все Docker-сети (`docker network ls` + `docker network inspect`), определяет подсети и gateway-адреса, и для каждой подсети создаёт правила PREROUTING DNAT, перенаправляющие UDP и TCP порт 53 на gateway:53 (где слушает Unbound). Исключение — запросы на 127.0.0.1 (уже идут на Unbound).

При отключении защиты `_remove_dns_dnat()` удаляет все DNAT-правила (с повтором до 3 раз для удаления дубликатов), чтобы контейнеры снова использовали свои оригинальные DNS-серверы.

### Скрипт docker_rules.sh

Управляет iptables-правилами в цепочке `DOCKER-USER`. Поддерживает команды: `scan` (поиск контейнеров), `auto-setup` (автонастройка), `enable`/`disable` (вкл/выкл), `status`, `cleanup` (полная очистка). Конфигурация выбранных контейнеров хранится в `/etc/block-ips/docker_containers.conf`.

### Восстановление после рестарта Docker

При перезапуске Docker цепочка `DOCKER-USER` очищается. Systemd-сервис `docker-block-restore.service` автоматически восстанавливает правила.

### host network

Если контейнер работает с `--network host`, его трафик уже проходит через цепочку `OUTPUT` и блокируется стандартными правилами WhiteVPN без дополнительной настройки.

---

## VLESS/Xray (3X-UI)

### Проблема

Xray по умолчанию использует стратегию `AsIs` — разрешает домены на стороне клиента и передаёт трафик напрямую, минуя DNS-блокировку на сервере. Кроме того, 3X-UI перезаписывает конфигурационный файл `/usr/local/x-ui/bin/config.json` из своей базы данных при каждом рестарте, поэтому ручные правки конфига теряются.

### Решение

Скрипт `fix_xray_template.py` записывает шаблон конфигурации Xray напрямую в SQLite-базу 3X-UI (`/etc/x-ui/x-ui.db`) как настройку `xrayTemplateConfig`. Шаблон содержит: DNS-секцию, указывающую на `127.0.0.1:53` (Unbound), и стратегию `UseIPv4` в outbound, которая заставляет Xray разрешать домены через указанный DNS перед установкой соединения. Также включён `IPIfNonMatch` в routing для резолвинга доменов.

После записи в БД выполняется `systemctl restart x-ui`, и 3X-UI генерирует конфиг из шаблона — DNS-блокировка работает.

---

## Автообновление

Systemd-таймеры запускают обновление списков по расписанию. Бот дополнительно обновляет списки раз в 24 часа через фоновую задачу `auto_update_lists`. При каждом обновлении: загружаются свежие домены из v2fly (для белого списка), загружается список Re-filter-lists, применяется фильтрация, обрезается до 50 000 записей, Unbound перезагружается. Аналогично для IP — загружается список antifilter.network, фильтруется, загружается в ipset.

---

## Структура файлов

### Репозиторий

```
whitevpn/
├── install.sh                 # Основной установщик
├── install_bot.sh             # Установщик Telegram-бота
├── manage.sh                  # CLI-меню (→ /usr/local/bin/blockme)
├── bot.py                     # Telegram-бот (aiogram 3.5.0)
├── docker_rules.sh            # Управление Docker-блокировкой
├── fix_xray_template.py       # Патч DNS в 3X-UI для VLESS
├── blocked-ips/
│   └── block_ips.py           # Загрузка и применение IP-списка
├── blocked-domains/
│   └── block_domains.py       # Загрузка и применение списка доменов
└── whitelist/
    ├── whitelist.conf         # Конфигурация категорий
    ├── telegram.txt           # Домены и IP Telegram
    ├── youtube.txt            # Домены и IP YouTube
    └── custom.txt             # Пользовательские записи
```

### На сервере после установки

```
/opt/block-traffic/                    # Все файлы проекта
├── bot.py, manage.sh, docker_rules.sh, ...
├── logs/                              # Логи бота и обновлений
├── whitelist/                         # Белые списки
└── venv/                              # Python virtualenv для бота

/etc/block-ips/
├── config                             # Путь установки
├── bot_config.json                    # Токен бота и ID админа
└── docker_containers.conf             # Выбранные контейнеры

/etc/unbound/
├── unbound.conf                       # Конфигурация Unbound
└── blocked-domains.conf               # Заблокированные домены (до 50К)

/usr/local/bin/blockme                 # Симлинк на manage.sh
/etc/x-ui/x-ui.db                     # БД 3X-UI (xrayTemplateConfig)
```

---

## Systemd-юниты

| Юнит | Тип | Назначение |
|------|-----|------------|
| `block-ips.service` | oneshot | Обновление IP-списка |
| `block-ips.timer` | timer | Запуск по расписанию |
| `block-domains.service` | oneshot | Обновление списка доменов |
| `block-domains.timer` | timer | Запуск по расписанию |
| `block-ips-bot.service` | simple | Telegram-бот (автозапуск) |
| `docker-block-restore.service` | oneshot | Восстановление Docker-правил |

---

## Диагностика и решение проблем

### Проверка статуса

```bash
# Статус защиты
systemctl status unbound
iptables -L OUTPUT -n | grep blocked_ips
ipset list blocked_ips | head -5

# Статус Docker-защиты
iptables -L DOCKER-USER -n
iptables -t nat -L PREROUTING -n | grep DNAT

# DNS-тест (заблокированный домен → таймаут, разрешённый → IP)
dig @127.0.0.1 example-blocked.com +short +time=3
dig @127.0.0.1 google.com +short

# Количество записей
ipset list blocked_ips | grep "Number of entries"
wc -l /etc/unbound/blocked-domains.conf
```

### Частые проблемы

**Unbound не запускается** — проверьте `journalctl -u unbound -n 20`. Частая причина — слишком много доменов (более 50К). Обрежьте файл: `head -50000 /etc/unbound/blocked-domains.conf > /tmp/bd.conf && mv /tmp/bd.conf /etc/unbound/blocked-domains.conf && systemctl restart unbound`.

**YouTube не блокируется при youtube=0** — домены youtube.com не входят в Re-filter-lists. Убедитесь, что используется block_domains.py v0.7+, который содержит `FORCE_BLOCK_DOMAINS`.

**Docker-контейнер не блокируется** — проверьте, что контейнер выбран (`docker_rules.sh status`), правила DNAT на месте (`iptables -t nat -L PREROUTING -n`), и Unbound слушает на gateway-адресе Docker-сети.

**После отключения защиты сайты всё ещё блокируются** — проверьте, что DNAT-правила удалены (`iptables -t nat -L PREROUTING -n`). В v0.7 это исправлено — `_remove_dns_dnat()` вызывается при отключении.

**SSL-ошибка при обновлении списков** — VPS может иметь проблемы с TLS к api.github.com. Попробуйте `curl -v https://api.github.com` для диагностики. Проверьте `ca-certificates`: `apt install ca-certificates`.

---

## Лицензия

MIT License
