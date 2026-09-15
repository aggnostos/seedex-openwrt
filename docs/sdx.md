# sdx

English | [Русский](sdx_ru.md)

`sdx` is the command line of Seedex. It is built around four services —
`router`, `vpn`, `proxy`, `dns` — plus `link`, the connection to your
servers, and reads the same way everywhere:

```
sdx                         status of the box
sdx <service>               status of one service
sdx <service> <action>      one action on one service
sdx <action>                the same action on every service that has it
sdx <service> help          the actions of that service
```

Changes made with `sdx` — adding, removing, enabling, updating, settings — are
pending until `sdx apply`, which saves them and restarts the service; `sdx
revert` drops them, `sdx changes` shows them. Each works on one service
(`sdx vpn apply`) or on all. Underneath this is plain UCI: `uci changes`,
`uci commit`, and a `restart` picks pending changes up too. In LuCI each page
shows its unsaved changes with Apply and Revert; OpenWrt's own Save & Apply
does not see them.

Entries — VPN and proxy configs, router rules — are addressed by name, or by
their number in the `show` list; `show`, `enable`, `disable` and `remove`
take several at once.

## Every service

### `sdx <service> start` / `stop` / `restart`

Control the service now. Without a service — `sdx restart` — all four go down and up in the right
order: DNS first, then the tunnels, then the router once a tunnel is up.

### `sdx <service> changes` / `apply` / `revert`

Pending changes of the service: show them, save them and restart the service
so they take effect, or throw them away. `apply` also restarts a service that
runs with older settings than the saved ones.

### `sdx <service> enable` / `disable`

Whether the service comes up at boot. `disable` also stops it now, `enable`
also starts it; a disabled service shows `disabled` in the status. Without a
name after `enable` or `disable` the action is about the service; with one,
about an entry of it.

## Box

### `sdx`

Status of everything: the uplink, which tunnel carries the traffic and its
RTT, each service in turn, and the links to your servers.

### `sdx import <path>`

Import a config file — an AmneziaWG `.conf` for `vpn`, a sing-box `.json` for
`proxy`, a rules `.json` for `router` — or every config in a directory. The
file decides which service it goes to; the file name becomes the entry name,
and a name already in use is refused. With a server running seedex-agent
there is no file to carry: see [Link](#link).

### `sdx logs`

The Seedex lines of the system log. Arguments are passed to `logread`, so
`sdx logs -f` follows.

### `sdx version`

The installed package version.

## VPN

AmneziaWG tunnels. Each imported config becomes a tunnel of its own; the
router probes all of them and routes through the fastest live one, so several
configs mean failover, not a choice to make.

### `sdx vpn`

Whether the service runs, and every config with its state: the one carrying
traffic is marked `[*]`, reachable ones show their RTT, disabled ones say so.

### `sdx vpn show [name ...]`

Without a name, the configs with their tunnel interface and file. With names,
each config's details and the contents of its file.

### `sdx vpn enable <name ...>` / `disable <name ...>`

Switch configs on or off without removing them. A disabled config keeps its
file and comes back with `enable`.

### `sdx vpn remove <name ...>`

Remove configs. Their files are deleted the next time the service starts.

### `sdx vpn export`

Print every config file in a form `sdx import` accepts — the way to carry the
configs to another router.

### `sdx vpn reset`

Stop the service and drop every config together with its files.

## Proxy

A sing-box tunnel. Every imported config contributes its outbounds to one
sing-box instance, which picks the best of them itself by URL test; the
router sees the result as a single tunnel next to the VPN ones.

### `sdx proxy`

Whether the service runs, and every config: the outbound sing-box currently
uses shows the tunnel's RTT and is marked `[*]` when the router routes
through the proxy.

### `sdx proxy show [name ...]`

Without a name, the configs with their files. With names, each config's
outbounds.

### `sdx proxy enable <name ...>` / `disable <name ...>`

Switch configs on or off. sing-box is rebuilt from the enabled ones at the
next restart.

### `sdx proxy remove <name ...>`

Remove configs. Their files are deleted the next time the service starts.

### `sdx proxy config`

Service settings: `show` lists them, `get <key>` prints one,
`set key=value ...` changes them.

- `log_level` — sing-box verbosity: `error`, `warn`, `info`, `debug`, `trace`.
- `urltest_interval` — how often sing-box re-measures its outbounds, e.g. `1m`.

### `sdx proxy export`

Print every config file in a form `sdx import` accepts.

### `sdx proxy reset`

Stop the service and drop every config together with its files.

## Router

The policy: where traffic goes when no rule matches, and the rules that make
exceptions. A watchdog probes every tunnel and keeps the overlay on the
fastest live one; a kill switch drops overlay-bound traffic when no tunnel is
up instead of letting it out to the provider.

A rule has a `type` — what happens to matched traffic:

- `overlay` — through the tunnel
- `direct` — straight to the provider
- `block` — domains stop resolving, packets to the IPs are dropped

and matches either destinations (`domain`, `ip`, a list) or devices
(`client_mac`, `client_ip`),
never both. Device rules win over destination rules, so a device pinned to
`direct` stays direct even for domains other rules send through the tunnel.

### `sdx router`

Whether the service runs, the routing mode, the kill switch, the watchdog
interval, and the rules with their type and what they match.

### `sdx router show [name ...]`

Without a name, the rules. With names, every field of each rule.

### `sdx router add <name> type=... [matchers]`

Add a rule. Matchers, each as many times as needed:

- `domain=<domain>` — the domain and its subdomains
- `ip=<address or CIDR>`
- `list_url=<url>` — a text file with one domain or IP per line, downloaded
  when the service starts and then every `list_refresh` (e.g. `12h`, `1d`);
  hosts-style files (`0.0.0.0 domain`) are accepted as they are
- `list_path=<file>` — the same, from a file on the router
- `client_mac=<aa:bb:cc:dd:ee:ff>` — every packet from that device
- `client_ip=<address or CIDR>` — every packet from that address or subnet:
  a guest VLAN, a device with a static address, a client behind another
  router where its MAC is not visible

```sh
sdx router add youtube type=overlay domain=youtube.com domain=googlevideo.com
sdx router add ads type=block list_url=https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts list_refresh=1d
sdx router add tv type=direct client_mac=aa:bb:cc:dd:ee:ff
sdx router add guests type=direct client_ip=10.0.20.0/24
```

### `sdx router update <name> ...`

Change a rule: `type=`, `name=`, the list options, and for the matchers
`domain=` / `del-domain=` / `clear-domains`, `ip=` / `del-ip=` / `clear-ips`,
`client_mac=` / `del-client_mac=` / `clear-client_macs`,
`client_ip=` / `del-client_ip=` / `clear-client_ips`.

### `sdx router enable <name ...>` / `disable <name ...>`

Switch rules on or off.

### `sdx router remove <name ...>`

Remove rules.

### `sdx router config`

Service settings: `show`, `get <key>`, `set key=value ...`.

- `default_route` — where unmatched traffic goes: `overlay` or `direct`.
- `kill_switch` — `1` drops overlay-bound traffic when no tunnel is up, `0`
  lets it fall back to the provider.
- `watchdog_interval` — seconds between probes of the tunnels.
- `watchdog_url` — what the probes fetch.
- `watchdog_timeout` — seconds before a probe counts as failed.

### `sdx router export`

Print the rules as JSON that `sdx import` accepts.

### `sdx router reset`

Stop the service and drop every rule.

## DNS

The resolver of the whole network. Queries leave encrypted and through the
tunnel when one is up; devices that try to resolve on their own are answered
by the router anyway.

### `sdx dns`

Whether the service runs, the upstream, the resolver and whether interception
is on.

### `sdx dns config`

Service settings: `show`, `get <key>`, `set key=value ...`.

- `upstream` — where the router sends queries: `encrypted` (DNS-over-HTTPS to
  the resolver; through the tunnel when one is up, over the provider's line
  otherwise), `plain` (the resolver's classic DNS, same path) or `provider`
  (whatever the provider handed out, untouched).
- `resolver` — `cloudflare`, `quad9` or `google`; ignored with `provider`.
- `intercept` — `1` redirects every DNS query from the network into the
  router and refuses DNS-over-TLS, so a device with its own resolver still
  follows the rules; `0` leaves devices alone.

## Link

The connection to a server running [seedex-agent](https://github.com/aggnostos/seedex-agent).
Pair once, and from then on the router pulls its VPN and proxy configs from
the server by itself — every 30 minutes and on demand — so a new client, a
rotated credential or a new protocol on the server reaches the router without
copying anything. Configs a link delivers are ordinary entries of `vpn` and
`proxy`, marked as managed by that link: the link updates them, removes them
when the server drops them, and leaves configs imported by hand alone.

### `sdx link`

Every link: whether the last sync succeeded, its URL, how many configs it
manages, and when it last synced.

### `sdx link add <name> <url> <token> <fingerprint>`

Pair with a server. `sdx link add <router>` on the server prints the URL,
the token and the certificate fingerprint, and the exact command to paste
here. The fingerprint pins the server's certificate, so nothing in between can
impersonate it; the token identifies this router. Pairing imports every
config the server offers straight away.

### `sdx link show <name>`

What the server offers right now, by service, with `[*]` on the configs the
router has imported.

### `sdx link select <name> <config> ... | --all`

Choose which of the offered configs to import — a router does not have to
carry every client the server knows. The choice is kept and applied at once:
configs no longer selected are removed, newly selected ones are added.
`--all` returns to importing everything, the default after `add`.

### `sdx link sync [name]`

Pull now, for one link or all. Changed configs are replaced, new ones added,
dropped ones removed, and the services that changed are restarted. A cron job
runs it every 30 minutes.

### `sdx link <name> [<command> ...]`

Run the server's own `sdx` from the router: `sdx link nl1` is the server's
status, `sdx link nl1 vpn add phone` adds a client, `sdx link nl1 proxy add
vless 443` a protocol, `sdx link nl1 help` lists what the server offers. The
output and exit code come back as they are; when the command changed the
configs, the router syncs right away, so a new client is imported by the
time the prompt returns. The server accepts only `sdx` actions on `vpn` and
`proxy` plus `start`/`stop`/`restart` — its own `link` and `firewall` stay
out of reach.

### `sdx link remove <name>`

Unpair and drop every config the link delivered.
