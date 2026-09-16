<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex logo" width="320">
  </picture>
</p>

<p align="center"><a href="README.md">English</a> | Русский</p>

# Seedex

Seedex — защитный слой сети для роутеров на OpenWrt: VPN и Proxy, удобная маршрутизация, защищённый DNS, управляемые одной командой или LuCI приложением.

## Требования

- Роутер на OpenWrt 24.10.2 или новее с выходом в интернет.
- Сервер с [seedex-agent](https://github.com/aggnostos/seedex-agent), AmneziaWG или sing-box.

> [!NOTE]
> Пакеты `noarch`. Подходит любая платформа OpenWrt: `apk` на 25.x и `opkg` на 24.10.

## Установка

### 1. Установите пакеты

На роутере запустите установщик от root:

```sh
wget -O - https://aggnostos.github.io/seedex-openwrt/install.sh | sh
```

Установщик подключает фид пакетов Seedex, ставит `seedex-box` с командой `sdx` и `luci-app-seedex` для LuCI и запускает DNS. Чтобы обойтись без LuCI, запустите установщик как `| sh -s -- --no-luci`.

### 2. Подключите сервер

Если вы используете [seedex-agent](https://github.com/aggnostos/seedex-agent), вставьте вывод команды `sdx link add <router>` на сервере и выберите конфигурационные файлы для импорта в открывшемся меню:

```sh
sdx link add agent https://203.0.113.5:8447 <token> <fingerprint>
```

Вы также можете импортировать нативные конфигурационные файлы AWG или sing-box:

```sh
sdx import awg.conf
sdx import sing-box.json
sdx apply
```

### 3. Проверьте статус

Запустите `sdx`:

```
$ sdx
seedex v0.1.0

Uplink:
    [*] Internet             118 ms
    [*] Overlay (anytls)     286 ms

[*] Router:
    Routing:      overlay
    Kill switch:  on
    Watchdog:     every 30s
    Rules:
    [*] ads                block    list
    [*] tv                 direct   1 client

[*] VPN:
    Configs:
    [ ] awg         362 ms

[*] Proxy:
    Configs:
    [*] anytls      286 ms
    [ ] vless

[*] DNS:
    Upstream:   encrypted
    Resolver:   cloudflare
    Intercept:  on

Link:
    [*] admin        https://203.0.113.5:8447         1 vpn, 2 proxy, 4 min ago
```

Раздел **Uplink** показывает туннель, который несёт трафик. В LuCI то же самое находится в **Services > Seedex**.

### 4. Если что-то не работает

Если роутер не маршрутизирует трафик используйте:

- `sdx logs` для просмотра сервисных логов.

- `sdx restart` для перезапуска сервисов в правильном порядке.

## Что дальше

- [Начало работы](https://docs.seedex.net/ru/getting-started) проводит через полную настройку, включая [seedex-agent](https://github.com/aggnostos/seedex-agent).
- [Руководство по seedex-box](https://docs.seedex.net/ru/user-guide/seedex-box) описывает каждую команду `sdx` и приложение для LuCI.
- [Для разработчиков](https://docs.seedex.net/ru/developer-guide/seedex-box) рассказывает о сборке, линте и структуре проекта.
## Участие

Сообщения об ошибках, предложения и pull request'ы приветствуются.
## Лицензия

GPL-2.0.
