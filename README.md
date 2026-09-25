<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex logo" width="320">
  </picture>
</p>

<p align="center">English | <a href="https://docs.seedex.net/ru">Русский</a></p>

<p align="center">
  <a href="https://github.com/aggnostos/seedex-openwrt/releases/latest"><img src="https://img.shields.io/github/v/release/aggnostos/seedex-openwrt" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--2.0-blue" alt="License: GPL-2.0"></a>
</p>

# Seedex OpenWrt

Seedex is a secure network privacy layer for OpenWrt routers: VPN and Proxy, convenient routing, secured DNS, managed with a single command or the LuCI app.

> [!WARNING]
> Seedex is under active development. Bugs are likely. Commands, settings, and behavior may change between versions. Read the release notes before you update.

## Features

- **One command for everything** — `sdx` installs, configures, diagnoses. Every service answers the same `sdx <service> <action>` shape, so nothing has to be memorised twice.
- **Any server you already have** — import a WireGuard or AmneziaWG `.conf`, a sing-box `.json`, or a `vless://`-style share link. A whole directory of configs works as well as a single file.
- **Automatic failover** — a watchdog probes every tunnel, keeping traffic on the fastest live one. A kill switch holds tunnel traffic back while none is up, so nothing leaks to the provider in the clear.
- **Routing you can read** — rules match domains, addresses, subnets, downloaded lists, or individual devices by MAC or IP. Each match goes through the tunnel, straight to the provider, or nowhere at all.
- **Ready-made lists** — point a rule at a URL with one domain or address per line, refreshed on the schedule you set. Hosts-format files are accepted as they are.
- **Encrypted DNS for the whole network** — DNS-over-HTTPS through the tunnel, with interception for devices that insist on resolving by themselves.
- **LuCI app** — every part of `sdx` has a page in the router's web interface, pending changes included.
- **Paired with your own server** — linked to [seedex-agent](https://github.com/aggnostos/seedex-agent), the router pulls new configs by itself and runs the server's `sdx` remotely.
- **Plain OpenWrt underneath** — UCI config, procd services, nftables sets, the system log. Nothing to learn beyond what the router already does.
- **noarch packages** — every OpenWrt target works, with `apk` on 25.x and `opkg` on 24.10.

## Requirements

- A router running OpenWrt 24.10.2 or later with outbound internet access.
- A server running [seedex-agent](https://github.com/aggnostos/seedex-agent), WireGuard, AmneziaWG, or sing-box.

## Installation

### 1. Install the packages

On the router, run the installer as root:

```sh
wget -O - https://feed.seedex.net/install.sh | sh
```

The installer adds the Seedex package feed, then installs `seedex-box` with the `sdx` command plus `luci-app-seedex` for LuCI. Nothing is started until you apply the first config. To skip LuCI, run the installer with `| sh -s -- --no-luci`.

### 2. Connect the server

If you use [seedex-agent](https://github.com/aggnostos/seedex-agent), paste the output of the `sdx link add <router>` command, pick the configs to import in the menu that opens, and then apply them:

```sh
sdx link add agent https://203.0.113.5:8282 <token> <fingerprint>
sdx apply
```

You can also import native configuration files, a proxy URI, or a subscription:

```sh
sdx import awg.conf         # AWG
sdx import wg.conf          # WG
sdx import sing-box.json    # sing-box
sdx import 'vless://...'    # Supported proxy URI
sdx import 'https://...'    # Subscription: proxy URIs, plain or base64
sdx apply
```

`sdx apply` saves the configs and starts the services.

### 3. Check the status

Run `sdx`:

```
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
        [ ] wg          324 ms

[*] Proxy:
    Configs:
        [*] anytls      286 ms
        [ ] vless       311 ms

[*] DNS:
    Upstream:   encrypted
    Resolver:   cloudflare
    Intercept:  on

Link:
    [*] agent        https://203.0.113.5:8282         2 vpn, 2 proxy, 4 min ago
```

The **Uplink** section shows the tunnel that carries the traffic. In LuCI, the same information is under **Services > Seedex**.

### 4. Troubleshoot

If the router doesn't route traffic, use:

- `sdx logs` to see the service logs.
- `sdx restart` to restart services in the right order.

## Where to go next

- [Getting started](https://docs.seedex.net/getting-started) walks you through the full setup, including [seedex-agent](https://github.com/aggnostos/seedex-agent).
- [seedex-box user guide](https://docs.seedex.net/user-guide/seedex-box) describes every `sdx` command and the LuCI app.
- [Developer guide](https://docs.seedex.net/developer-guide/seedex-box) covers building, linting, and the project structure.

## Contributing

Bug reports, suggestions, and pull requests are welcome.

## License

GPL-2.0. The Seedex name and logo are covered by the [trademark policy](https://docs.seedex.net/trademark), not by the license.
