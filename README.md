# Seedex

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
```

Everything above is also in LuCI under Services → Seedex.

## Install

You need a router running OpenWrt 25.x or newer with outbound internet access.

```sh
wget -O install.sh https://<feed>/install.sh
SEEDEX_FEED=https://<feed> sh install.sh
```

This adds the Seedex package feed, installs `seedex-box` with the `sdx`
command and `luci-app-seedex` for LuCI (`--no-luci` to skip it), and starts
the DNS service. Tunnels and routing start once you import a config from your
server:

```sh
sdx import my-server.conf
uci commit
sdx restart
```

## Server

Seedex needs a server of your own to tunnel to. [seedex-agent](https://github.com/aggnostos/seedex-agent)
sets one up with a single command and exports client configs ready for
`sdx import`; any other AmneziaWG or sing-box server works just as well — the
router takes their native configs as they are.

## License

GPL-2.0-only.
