#!/bin/sh

set -eu

SEEDEX_FEED="${SEEDEX_FEED:-}"
AWG_FEED="${AWG_FEED:-https://slava-shchipunov.github.io/awg-openwrt}"

KEYS_DIR=/etc/apk/keys
REPOS_FILE=/etc/apk/repositories.d/seedex.list
SEEDEX_KEY_NAME=seedex-feed.pem
AWG_KEY_NAME=awg-openwrt-feed.pem

LUCI=1
while [ $# -gt 0 ]; do
	case "$1" in
	--no-luci) LUCI=0 ;;
	-*) die "unknown option: $1" ;;
	*) break ;;
	esac
	shift
done
PKGS=""
LOCAL_KEY=""

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
	exit 1
}

[ "$(id -u)" = "0" ] || die "run as root"
command -v apk >/dev/null 2>&1 || die "apk not found — seedex needs OpenWrt 25.x or newer"

release=$(. /etc/openwrt_release 2>/dev/null && echo "${DISTRIB_RELEASE:-}")
target=$(. /etc/openwrt_release 2>/dev/null && echo "${DISTRIB_TARGET:-}")
[ -n "$release" ] && [ -n "$target" ] ||
	die "cannot read /etc/openwrt_release"

if [ $# -gt 0 ]; then
	for f in "$@"; do
		[ -f "$f" ] || die "no such package file: $f"
		f="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
		PKGS="$PKGS $f"
		LOCAL_KEY="${f%/*}/../keys/$SEEDEX_KEY_NAME"
	done
elif [ -z "$SEEDEX_FEED" ]; then
	die "no seedex feed configured.
Either pass package files:      $0 build/noarch/*.apk
or point SEEDEX_FEED at a feed: SEEDEX_FEED=https://example.org/seedex $0 [--no-luci]"
fi

fetch() {
	wget -q -O "$2" "$1" 2>/dev/null || {
		rm -f "$2"
		return 1
	}
}

install_key() {
	local name="$1" url="$2" local_copy="$3"
	[ -s "$KEYS_DIR/$name" ] && {
		echo "  $name already trusted"
		return 0
	}
	mkdir -p "$KEYS_DIR"
	if [ -n "$local_copy" ] && [ -s "$local_copy" ]; then
		cp "$local_copy" "$KEYS_DIR/$name"
	else
		fetch "$url" "$KEYS_DIR/$name" || return 1
	fi
	chmod 644 "$KEYS_DIR/$name"
	echo "  trusted $name"
}

log "installing signing keys"
awg_ok=1
install_key "$AWG_KEY_NAME" "$AWG_FEED/keys/$AWG_KEY_NAME" "" || {
	awg_ok=0
	warn "cannot fetch $AWG_FEED/keys/$AWG_KEY_NAME — skipping the amneziawg feed"
}
if [ -s "$KEYS_DIR/$SEEDEX_KEY_NAME" ] || [ -z "$PKGS" ] || [ -s "$LOCAL_KEY" ]; then
	install_key "$SEEDEX_KEY_NAME" "$SEEDEX_FEED/keys/$SEEDEX_KEY_NAME" "$LOCAL_KEY" ||
		die "cannot fetch $SEEDEX_FEED/keys/$SEEDEX_KEY_NAME"
else
	warn "$SEEDEX_KEY_NAME is neither trusted on this box nor in keys/ beside the package directory;"
	warn "the local package will install with --allow-untrusted"
fi

if grep -q '/amneziawg' /etc/apk/repositories 2>/dev/null; then
	warn "removing a stale amneziawg line from /etc/apk/repositories"
	sed -i '/\/amneziawg/d' /etc/apk/repositories
fi

log "configuring feeds"
mkdir -p "${REPOS_FILE%/*}"
{
	[ "$awg_ok" = 0 ] || echo "$AWG_FEED/$release/$target/packages.adb"
	[ -z "$SEEDEX_FEED" ] || echo "$SEEDEX_FEED/noarch/packages.adb"
} >"$REPOS_FILE"
[ -s "$REPOS_FILE" ] && sed 's/^/  /' "$REPOS_FILE" || echo "  (none beyond the stock OpenWrt feeds)"

log "updating package lists"
apk update || {
	[ -n "$PKGS" ] || die "apk update failed — check the feed URLs above and outbound access"
	warn "apk update failed — installing the local packages anyway, amneziawg may be skipped"
}

log "installing amneziawg"
if [ "$awg_ok" = 0 ]; then
	warn "amneziawg skipped — rerun once $AWG_FEED is reachable. VPN stays down until then."
elif apk add kmod-amneziawg amneziawg-tools; then
	:
else
	warn "could not install amneziawg for OpenWrt $release on $target."
	warn "The awg-openwrt feed may not have this release yet — see"
	warn "$AWG_FEED/ and rerun once it does. VPN stays down until then."
fi

log "installing seedex-box"
if [ -n "$PKGS" ]; then
	# shellcheck disable=SC2086
	if [ -s "$KEYS_DIR/$SEEDEX_KEY_NAME" ]; then
		apk add $PKGS
	else
		apk add --allow-untrusted $PKGS
	fi
elif [ "$LUCI" = 1 ]; then
	apk add seedex-box luci-app-seedex
else
	apk add seedex-box
fi

lan_ip() {
	local ip
	ip=$(ubus call network.interface.lan status 2>/dev/null |
		jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	[ -n "$ip" ] || ip=$(uci -q get network.lan.ipaddr 2>/dev/null | cut -d' ' -f1 | cut -d/ -f1)
	printf '%s' "$ip"
}
IP=$(lan_ip)
UI_HOST="${IP:-<LAN address of this router>}"

echo
log "done — seedex $(sdx version 2>/dev/null || echo '?') installed"
cat <<EOF

On a fresh install the services are started now. On an upgrade the running
services keep the previous build until you restart them:

  /etc/init.d/seedex restart

In LuCI the box lives under Services → Seedex:
  http://${UI_HOST}/cgi-bin/luci/admin/services/seedex
EOF
