#!/bin/sh

set -eu

SEEDEX_FEED="${SEEDEX_FEED:-https://aggnostos.github.io/seedex-openwrt}"
AWG_FEED="${AWG_FEED:-https://2grey.github.io/awg-openwrt}"

APK_KEYS_DIR=/etc/apk/keys
APK_REPOS_FILE=/etc/apk/repositories.d/seedex.list
OPKG_FEEDS_FILE=/etc/opkg/customfeeds.conf
SEEDEX_APK_KEY=seedex-feed.pem
SEEDEX_OPKG_KEY=seedex-feed.pub
AWG_APK_KEY=awg-openwrt-2grey.pem

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
if command -v apk >/dev/null 2>&1; then
	PM=apk
elif command -v opkg >/dev/null 2>&1; then
	PM=opkg
else
	die "neither apk nor opkg found — seedex needs OpenWrt 24.10 or newer"
fi

release=$(. /etc/openwrt_release 2>/dev/null && echo "${DISTRIB_RELEASE:-}")
target=$(. /etc/openwrt_release 2>/dev/null && echo "${DISTRIB_TARGET:-}")
if [ -z "$release" ] || [ -z "$target" ]; then
	die "cannot read /etc/openwrt_release"
fi

case "$PM" in
apk)
	SEEDEX_KEY_NAME="$SEEDEX_APK_KEY"
	PM_INSTALL="apk add"
	;;
opkg)
	SEEDEX_KEY_NAME="$SEEDEX_OPKG_KEY"
	PM_INSTALL="opkg install"
	;;
esac

if [ $# -gt 0 ]; then
	for f in "$@"; do
		[ -f "$f" ] || die "no such package file: $f"
		case "$PM:$f" in
		apk:*.apk | opkg:*.ipk) ;;
		*) die "$f is not a package for $PM" ;;
		esac
		f="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
		PKGS="$PKGS $f"
		LOCAL_KEY="${f%/*}/../keys/$SEEDEX_KEY_NAME"
	done
fi

fetch() {
	wget -q -O "$2" "$1" 2>/dev/null || {
		rm -f "$2"
		return 1
	}
}

apk_key() {
	local name="$1" url="$2" local_copy="$3"
	[ -s "$APK_KEYS_DIR/$name" ] && {
		echo "  $name already trusted"
		return 0
	}
	mkdir -p "$APK_KEYS_DIR"
	if [ -n "$local_copy" ] && [ -s "$local_copy" ]; then
		cp "$local_copy" "$APK_KEYS_DIR/$name"
	else
		fetch "$url" "$APK_KEYS_DIR/$name" || return 1
	fi
	chmod 644 "$APK_KEYS_DIR/$name"
	echo "  trusted $name"
}

opkg_key() {
	local name="$1" url="$2" local_copy="$3" tmp
	tmp="/tmp/$name.$$"
	if [ -n "$local_copy" ] && [ -s "$local_copy" ]; then
		cp "$local_copy" "$tmp"
	else
		fetch "$url" "$tmp" || return 1
	fi
	opkg-key add "$tmp" >/dev/null
	rm -f "$tmp"
	echo "  trusted $name"
}

log "installing signing keys"
awg_ok=1
seedex_key_ok=1
case "$PM" in
apk)
	if [ -s "$APK_KEYS_DIR/awg-openwrt-feed.pem" ]; then
		rm -f "$APK_KEYS_DIR/awg-openwrt-feed.pem"
		echo "  dropped awg-openwrt-feed.pem (the previous amneziawg feed)"
	fi
	apk_key "$AWG_APK_KEY" "$AWG_FEED/keys/awg-openwrt-feed.pem" "" || awg_ok=0
	if [ -s "$APK_KEYS_DIR/$SEEDEX_KEY_NAME" ] || [ -z "$PKGS" ] || [ -s "$LOCAL_KEY" ]; then
		apk_key "$SEEDEX_KEY_NAME" "$SEEDEX_FEED/keys/$SEEDEX_KEY_NAME" "$LOCAL_KEY" ||
			die "cannot fetch $SEEDEX_FEED/keys/$SEEDEX_KEY_NAME"
	else
		seedex_key_ok=0
	fi
	;;
opkg)
	opkg_key awg-openwrt-feed.pub "$AWG_FEED/keys/awg-openwrt-feed.pub" "" || awg_ok=0
	opkg_key "$SEEDEX_KEY_NAME" "$SEEDEX_FEED/keys/$SEEDEX_KEY_NAME" "$LOCAL_KEY" || {
		[ -n "$PKGS" ] || die "cannot fetch $SEEDEX_FEED/keys/$SEEDEX_KEY_NAME"
		seedex_key_ok=0
	}
	;;
esac
[ "$awg_ok" = 1 ] || warn "cannot fetch the amneziawg feed key — skipping the amneziawg feed"
[ "$seedex_key_ok" = 1 ] || {
	warn "$SEEDEX_KEY_NAME is neither trusted on this box nor in keys/ beside the package directory;"
	warn "the local package will install without signature checks"
}

log "configuring feeds"
case "$PM" in
apk)
	if grep -q '/amneziawg\|slava-shchipunov' /etc/apk/repositories 2>/dev/null; then
		warn "removing a stale amneziawg line from /etc/apk/repositories"
		sed -i '/\/amneziawg\|slava-shchipunov/d' /etc/apk/repositories
	fi
	mkdir -p "${APK_REPOS_FILE%/*}"
	{
		[ "$awg_ok" = 0 ] || echo "$AWG_FEED/$release/$target/packages.adb"
		echo "$SEEDEX_FEED/noarch/packages.adb"
	} >"$APK_REPOS_FILE"
	sed 's/^/  /' "$APK_REPOS_FILE"
	;;
opkg)
	mkdir -p "${OPKG_FEEDS_FILE%/*}"
	[ -f "$OPKG_FEEDS_FILE" ] || : >"$OPKG_FEEDS_FILE"
	sed -i '/^src\/gz \(seedex\|awg\) /d' "$OPKG_FEEDS_FILE"
	{
		[ "$awg_ok" = 0 ] || echo "src/gz awg $AWG_FEED/$release/$target"
		echo "src/gz seedex $SEEDEX_FEED/noarch"
	} >>"$OPKG_FEEDS_FILE"
	grep '^src/gz \(seedex\|awg\) ' "$OPKG_FEEDS_FILE" | sed 's/^/  /'
	;;
esac

log "updating package lists"
$PM update || {
	[ -n "$PKGS" ] || die "$PM update failed — check the feed URLs above and outbound access"
	warn "$PM update failed — installing the local packages anyway, amneziawg may be skipped"
}

log "installing amneziawg"
if [ "$awg_ok" = 0 ]; then
	warn "amneziawg skipped — rerun once $AWG_FEED is reachable. VPN stays down until then."
else
	case "$PM" in
	apk) awg_cmd="apk add --upgrade --latest kmod-amneziawg amneziawg-tools" ;;
	opkg) awg_cmd="opkg install kmod-amneziawg amneziawg-tools" ;;
	esac
	$awg_cmd || {
		warn "could not install amneziawg for OpenWrt $release on $target."
		warn "The awg-openwrt feed may not have this release yet — see"
		warn "$AWG_FEED/ and rerun once it does. VPN stays down until then."
	}
fi

if [ "$PM" = opkg ] && opkg status dnsmasq 2>/dev/null | grep -q '^Status:.*installed' &&
	! opkg status dnsmasq-full 2>/dev/null | grep -q '^Status:.*installed'; then
	log "replacing dnsmasq with dnsmasq-full"
	rm -f /tmp/dnsmasq-full_*.ipk
	(cd /tmp && opkg download dnsmasq-full) || die "cannot download dnsmasq-full"
	opkg remove dnsmasq
	opkg install /tmp/dnsmasq-full_*.ipk || die "cannot install dnsmasq-full"
	rm -f /tmp/dnsmasq-full_*.ipk
fi

log "installing seedex-box"
if [ -n "$PKGS" ]; then
	# shellcheck disable=SC2086
	case "$PM:$seedex_key_ok" in
	apk:1) apk add $PKGS ;;
	apk:0) apk add --allow-untrusted $PKGS ;;
	opkg:*) opkg install $PKGS ;;
	esac
elif [ "$LUCI" = 1 ]; then
	$PM_INSTALL seedex-box luci-app-seedex
else
	$PM_INSTALL seedex-box
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

Nothing is started — the services are enabled but not running. Connect a
server, then bring them up:

  sdx link add <name> <url> <token> <fingerprint>
  sdx start

On an upgrade the running services keep the previous build until you
restart them: sdx restart

In LuCI the box lives under Services → Seedex:
  http://${UI_HOST}/cgi-bin/luci/admin/services/seedex
EOF
