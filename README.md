<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex logo" width="320">
  </picture>
</p>

<p align="center">English | <a href="https://docs.seedex.net/ru">Русский</a></p>

# Seedex OpenWrt

Seedex is a secure network privacy layer for OpenWrt routers: VPN and Proxy, convenient routing, secured DNS, managed with a single command or the LuCI app.

## Requirements

- A router running OpenWrt 24.10.2 or later with outbound internet access.
- A server running [seedex-agent](https://github.com/aggnostos/seedex-agent), WireGuard, AmneziaWG, or sing-box.

> [!NOTE]
> The packages are `noarch`. Every OpenWrt target works, with `apk` on 25.x and `opkg` on 24.10.

## Installation

### 1. Install the packages

On the router, run the installer as root:

```sh
wget -O - https://aggnostos.github.io/seedex-openwrt/install.sh | sh
```

The installer adds the Seedex package feed and installs `seedex-box` with the `sdx` command and `luci-app-seedex` for LuCI. Nothing is started until you apply the first config. To skip LuCI, run the installer with `| sh -s -- --no-luci`.

### 2. Connect the server

If you use [seedex-agent](https://github.com/aggnostos/seedex-agent), paste the output of the `sdx link add <router>` command, pick the configs to import in the menu that opens, and then apply them:

```sh
sdx link add agent https://203.0.113.5:8447 <token> <fingerprint>
sdx apply
```

You can also import native WG, AWG, or sing-box configuration files, or a proxy URI:

```sh
sdx import awg.conf
sdx import wg.conf
sdx import sing-box.json
sdx import 'vless://...'
sdx apply
```

`sdx apply` saves the configs and starts the services.

### 3. Check the status

Run `sdx`:

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
    [ ] wg          324 ms

[*] Proxy:
    Configs:
    [*] anytls      286 ms
    [ ] vless

[*] DNS:
    Upstream:   encrypted
    Resolver:   cloudflare
    Intercept:  on

Link:
    [*] admin        https://203.0.113.5:8447         2 vpn, 2 proxy, 4 min ago
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

GPL-2.0.
