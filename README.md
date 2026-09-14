<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/logo-dark.svg">
    <img src=".github/assets/logo-light.svg" alt="Seedex" width="320">
  </picture>
</p>

Seedex turns an OpenWrt router into the privacy layer of a home network: all
traffic leaves through tunnels to servers you own, DNS is read by no one along
the way, and you decide per domain, per list or per device what goes where.

## Modules

**Tunnels.** Connections to your own servers over AmneziaWG (`vpn`) and
sing-box (`proxy`), as many as you like at once. The router measures every
tunnel, keeps the traffic on the fastest live one and moves it when a tunnel
fails.

**Router.** The policy: what goes through a tunnel, what goes straight to the
provider and what is blocked — by domain, by downloadable list or by device.
A kill switch makes sure that when no tunnel is up, traffic meant for a tunnel
goes nowhere rather than out in the open.

**DNS.** A private resolver for the whole network: queries leave encrypted and
through the tunnel when one is up, devices that try to resolve on their own
are answered by the router anyway, and ad and tracker domains never resolve.

**Link.** Pair the router once with a server running
[seedex-agent](https://github.com/aggnostos/seedex-agent), and it keeps its
tunnel configs in sync from there on — pick the ones you want, and forget
about copying files.

## What it looks like

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
    [*] ads                direct   list
    [*] tv                 direct   1 client

[*] VPN:
  Configs:
    [ ] awg0         362 ms
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

Everything above is also in LuCI under Services → Seedex.

## Install

You need a router running OpenWrt 25.x or newer with outbound internet access.

```sh
wget -O install.sh https://aggnostos.github.io/seedex-openwrt/install.sh
sh install.sh
```

This adds the Seedex package feed, installs `seedex-box` with the `sdx`
command and `luci-app-seedex` for LuCI (`--no-luci` to skip it), and starts
the DNS service. Tunnels and routing start once the router has a config from
your server — pasted with `sdx import`, or pulled on its own after `sdx link
add`. See [what to do next](docs/sdx.md).

## Server

Seedex needs a server of your own to tunnel to. [seedex-agent](https://github.com/aggnostos/seedex-agent)
sets one up with a single command; the router pairs with it by pasting one
line and pulls its configs from there on. Any other AmneziaWG or sing-box
server works just as well — the router takes their native configs as they
are, via `sdx import`.

## License

GPL-2.0.
