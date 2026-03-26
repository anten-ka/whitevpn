# WhiteVPN — блокировка нежелательных ресурсов на VPN-сервере

[English version](README_EN.md)

Скрипт блокирует доступ к нежелательным сайтам и IP-адресам на уровне VPN-сервера. Работает с **прокси-VPN** (VLESS/Xray через 3X-UI) и **туннельными VPN** в Docker (AmneziaWG, WireGuard и др.).

## Возможности

- Блокировка IP-адресов через `ipset` + `iptables`
- Блокировка доменов через `Unbound DNS`
- Блокировка для Docker-контейнеров (AmneziaWG и др.) через `DOCKER-USER`
- Автообновление списков раз в сутки (systemd timers)
- CLI-меню управления (`blockme`)
- Telegram-бот для удалённого управления
- Автовосстановление Docker-правил после перезапуска

## Как работает

```
                         VPN-СЕРВЕР

  VPN-клиент ──> Xray/VLESS (прокси) ──> iptables OUTPUT
                                              |
                   ipset blocked_ips ─────> DROP
                                              |
                   Unbound DNS ──────────> NXDOMAIN

  WG-клиент ───> AmneziaWG (Docker) ──> iptables DOCKER-USER
                                              |
                   ipset blocked_ips ─────> DROP
                                              |
                   Unbound DNS (0.0.0.0) ─> NXDOMAIN
```

### Два уровня блокировки

| Уровень | Механизм | Источник |
|---------|----------|----------|
| IP | `ipset` (hash:net) + `iptables` DROP | [antifilter.network](https://antifilter.network/download/ip.lst) |
| DNS | Unbound `local-zone: "domain" deny` | [Re-filter-lists](https://github.com/1andrevich/Re-filter-lists) |

### Для прокси-VPN (VLESS/Xray)

Трафик клиента обрабатывается процессом Xray на сервере -> цепочка `OUTPUT` -> правило ipset срабатывает.

### Для Docker-контейнеров (AmneziaWG)

Трафик клиента маршрутизируется ядром -> цепочка `FORWARD` / `DOCKER-USER` -> правило ipset срабатывает. Правила применяются **только к выбранным контейнерам**.

## Установка

```bash
git clone https://github.com/anten-ka/whitevpn.git
cd whitevpn
sudo bash install.sh
```

В конце установки скрипт автоматически:
1. Обнаружит Docker (если установлен)
2. Покажет список запущенных контейнеров
3. Предложит выбрать контейнеры для блокировки
4. Применит правила

Если Docker не установлен — этот шаг пропускается без ошибок.

## Управление

### CLI-меню

```bash
blockme
```

```
Меню управления:
0. Выход
1. Запустить обновление списка IP и доменов
2. Деинсталлировать проект
3. Отключить защиту
4. Включить защиту
5. Перезагрузить сервисы
6. Установить/обновить Telegram-бот
7. Docker-блокировка (AmneziaWG)
```

### Docker-подменю (пункт 7)

```
1. Выбрать контейнеры для блокировки
2. Включить Docker-блокировку
3. Отключить Docker-блокировку
4. Статус Docker-блокировки
5. Переконфигурировать Unbound для Docker
0. Назад
```

### Telegram-бот

Установка: `blockme` -> пункт 6

Кнопки:
- **Обновить IP и домены** — обновить списки блокировки
- **Включить/Отключить защиту** — управление всей защитой
- **Перезапустить сервисы** — перезапуск Unbound и iptables
- **Состояние сервера** — uptime, диск, память, статус сервисов
- **Скачать логи** — скачать лог-файл бота
- **Docker: статус** — статус Docker-блокировки
- **Docker: вкл / Docker: выкл** — управление Docker-блокировкой

### CLI напрямую

```bash
# Docker-блокировка
/opt/block-traffic/docker_rules.sh select       # выбрать контейнеры
/opt/block-traffic/docker_rules.sh enable       # включить
/opt/block-traffic/docker_rules.sh disable      # отключить
/opt/block-traffic/docker_rules.sh status       # статус
/opt/block-traffic/docker_rules.sh cleanup      # полная очистка
```

## Docker: важные замечания

### DNS контейнера

Контейнеру нужно явно указать DNS хоста, иначе DNS-блокировка не сработает:

**docker-compose.yml:**
```yaml
services:
  amneziawg:
    dns:
      - 172.17.0.1    # IP Docker gateway
```

**docker run:**
```bash
docker run --dns 172.17.0.1 ...
```

### Перезапуск Docker

При рестарте Docker правила `DOCKER-USER` сбрасываются. Скрипт создаёт systemd-сервис `docker-block-restore.service`, который автоматически восстанавливает правила.

### host network

Если контейнер запущен с `--network host`, его трафик уже проходит через цепочку `OUTPUT` и блокируется стандартными правилами WhiteVPN без дополнительных настроек.

## Структура файлов

```
whitevpn/
├── install.sh                  # Установщик
├── install_bot.sh              # Установщик Telegram-бота
├── manage.sh                   # CLI-меню (-> /usr/local/bin/blockme)
├── bot.py                      # Telegram-бот
├── docker_rules.sh             # Docker-блокировка
├── blocked-ips/
│   └── block_ips.py            # Скачивание и применение IP-списка
└── blocked-domains/
    └── block_domains.py        # Скачивание и применение доменного списка
```

### Файлы на сервере после установки

```
/opt/block-traffic/             # Все файлы проекта
/etc/block-ips/config           # Путь к INSTALL_DIR
/etc/block-ips/bot_config.json  # Токен бота и ID админа
/etc/block-ips/docker_containers.conf  # Список контейнеров
/etc/unbound/unbound.conf       # Конфигурация DNS
/etc/unbound/blocked-domains.conf      # Заблокированные домены
/usr/local/bin/blockme          # Команда меню
```

### Systemd-юниты

| Юнит | Тип | Описание |
|------|-----|----------|
| `block-ips.service` | oneshot | Обновление IP-списка |
| `block-ips.timer` | timer | Ежедневно в полночь |
| `block-domains.service` | oneshot | Обновление доменов |
| `block-domains.timer` | timer | Ежедневно в полночь |
| `block-ips-bot.service` | simple | Telegram-бот |
| `docker-block-restore.service` | oneshot | Восстановление Docker-правил |

## Лицензия

MIT License
