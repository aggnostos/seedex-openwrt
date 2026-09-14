<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex" width="320">
  </picture>
</p>

<p align="center"><a href="README.md">English</a> | Русский</p>

Seedex превращает роутер на OpenWrt в слой приватности домашней сети: весь
трафик уходит через туннели к вашим собственным серверам, DNS по пути никто
не читает, а что куда идёт — по домену, по списку или по устройству — решаете
вы.

## Модули

**Туннели.** Соединения с вашими серверами по AmneziaWG (`vpn`) и sing-box
(`proxy`), сколько угодно одновременно. Роутер измеряет каждый туннель,
держит трафик на самом быстром живом и переключает его, когда туннель падает.

**Router.** Политика: что идёт через туннель, что напрямую к провайдеру, а
что блокируется — по домену, по загружаемому списку или по устройству.
Kill switch следит, чтобы при отсутствии живого туннеля трафик, который
должен был идти через него, не ушёл в открытую.

**DNS.** Приватный резолвер для всей сети: запросы уходят зашифрованными и
через туннель, когда он есть; устройства, которые пытаются резолвить сами,
всё равно отвечает роутер; домены рекламы и трекеров не резолвятся.

**Link.** Соедините роутер один раз с сервером, на котором стоит
[seedex-agent](https://github.com/aggnostos/seedex-agent), и дальше он сам
держит конфиги туннелей в актуальном состоянии — выберите нужные и забудьте
про копирование файлов.

## Как это выглядит

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
    [*] ads                block      list
    [*] tv                 overlay    1 client

[*] VPN:
  Configs:
    [ ] awg0        362 ms
    [ ] awg1        260 ms

[*] Proxy:
  Configs:
    [*] anytls         286 ms
    [ ] hysteria2
    [ ] vless

[*] DNS:
  Upstream:   encrypted
  Resolver:   cloudflare
  Intercept:  on

Link:
  [*] agent1        https://203.0.113.5:8447         2 vpn, 3 proxy, 4 min ago
```

Всё то же самое есть в LuCI: Services → Seedex.

## Установка

Нужен роутер с OpenWrt 25.x или новее и выходом в интернет.

```sh
wget -O install.sh https://aggnostos.github.io/seedex-openwrt/install.sh
sh install.sh
```

Скрипт подключает фид пакетов Seedex, ставит `seedex-box` с командой `sdx` и
`luci-app-seedex` для LuCI (`--no-luci`, чтобы пропустить) и запускает
DNS. Туннели и маршрутизация включаются, как только у роутера появится конфиг
с вашего сервера — вставленный через `sdx import` или полученный самим
роутером после `sdx link add`. Дальше — в [описании команд](docs/sdx_ru.md).

## Сервер

Seedex нужен собственный сервер, к которому идут туннели.
[seedex-agent](https://github.com/aggnostos/seedex-agent) поднимает его одной
командой; роутер соединяется с ним одной вставленной строкой и дальше сам
забирает конфиги. Любой другой сервер AmneziaWG или sing-box подойдёт так же —
роутер принимает их родные конфиги как есть, через `sdx import`.

## Лицензия

GPL-2.0.
