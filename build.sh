#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"

BOX_DEPENDS="curl ca-bundle jq nftables-json kmod-nft-core kmod-nft-fib
kmod-nft-nat kmod-nft-offload dnsmasq-full https-dns-proxy"

IMAGE="${SEEDEX_APK_IMAGE:-alpine:edge}"
SIGN_KEY="${SEEDEX_APK_SIGN_KEY:-$HOME/.seedex/apk-sign.key}"
PUB_KEY_NAME="seedex-feed.pem"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
	exit 1
}

ARCH="noarch"
SINGBOX_MIN="1.13.21"
SINGBOX_MAX="1.15"
FEED_DIR="$BUILD/$ARCH"

command -v docker >/dev/null 2>&1 || die "docker not found — it hosts the apk-tools that builds the packages"
docker info >/dev/null 2>&1 || die "the docker daemon is not running — start Docker Desktop and rerun"

resolve_version() {
	local version="${SEEDEX_VERSION:-}"
	[ -n "$version" ] || version="$(git -C "$ROOT" describe --tags --dirty 2>/dev/null || true)"
	[ -n "$version" ] || version="$(cat "$ROOT/version")"
	STAMP="$version"
	VERSION="$(printf '%s\n' "$version" | sed -n '1{s/^[vV]//;s/[^0-9.].*$//;p;}')"
	[ -n "$VERSION" ] || die "cannot derive a numeric package version from '$version'"
}

normalize() {
	local root="$1"
	find "$root" -type d -exec chmod 0755 {} +
	find "$root" -type f -exec chmod 0644 {} +
	[ ! -d "$root/usr/bin" ] || chmod 0755 "$root"/usr/bin/*
	[ ! -d "$root/usr/libexec/rpcd" ] || chmod 0755 "$root"/usr/libexec/rpcd/*
	[ ! -d "$root/etc/init.d" ] || chmod 0755 "$root"/etc/init.d/*
	[ ! -d "$root/etc/hotplug.d" ] || chmod 0644 "$root"/etc/hotplug.d/*/*
	[ ! -d "$root/etc/config" ] || chmod 0600 "$root"/etc/config/*
}

stage() {
	local name="$1" root="$BUILD/payload/$1"
	rm -rf "$root"
	mkdir -p "$root"
	cp -a "$ROOT/$name/files/." "$root/"
	normalize "$root"
}

SIGN_ARGS=()
prepare_signing() {
	if [ -s "$SIGN_KEY" ]; then
		mkdir -p "$BUILD/keys"
		openssl pkey -in "$SIGN_KEY" -pubout -out "$BUILD/keys/$PUB_KEY_NAME" 2>/dev/null ||
			die "cannot derive the public key from $SIGN_KEY"
		SIGN_ARGS=(-v "$SIGN_KEY:/sign.key:ro" -e "SIGN=/sign.key")
		log "signing with ${SIGN_KEY/#$HOME/~}"
	else
		warn "no signing key at $SIGN_KEY — the packages will be unsigned"
		warn "installing them will need --allow-untrusted; create one with:"
		printf '  mkdir -p %s && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out %s && chmod 600 %s\n' \
			"${SIGN_KEY%/*}" "$SIGN_KEY" "$SIGN_KEY" >&2
		SIGN_ARGS=(-e "SIGN=")
	fi
}

mkpkg() {
	local name="$1" description="$2" depends="$3" scripts="$4"
	local out="$FEED_DIR/${name}-${VERSION}.apk" script_args="" s
	for s in post-install post-upgrade pre-deinstall post-deinstall; do
		[ -f "$ROOT/$scripts/$s" ] && script_args="$script_args --script $s:$scripts/$s"
	done
	log "packaging $name $VERSION ($ARCH)"
	docker run --rm -v "$ROOT:/seedex" -w /seedex "${SIGN_ARGS[@]}" \
		-e "NAME=$name" -e "VERSION=$VERSION" -e "ARCH=$ARCH" \
		-e "DESCRIPTION=$description" -e "DEPENDS=$depends" -e "SCRIPT_ARGS=$script_args" \
		-e "OUT=/seedex/${out#"$ROOT/"}" \
		"$IMAGE" sh -euc '
			apk mkpkg --help 2>&1 | grep -q "apk mkpkg" || {
				echo "apk in '"$IMAGE"' has no mkpkg (needs apk-tools 3)" >&2
				exit 1
			}
			[ -z "$SIGN" ] || set -- --sign-key "$SIGN"
			# shellcheck disable=SC2086
			apk mkpkg "$@" \
				--info "name:$NAME" \
				--info "version:$VERSION" \
				--info "arch:$ARCH" \
				--info "license:GPL-2.0-only" \
				--info "description:$DESCRIPTION" \
				--info "url:https://github.com/aggnostos/seedex-openwrt" \
				--info "depends:$DEPENDS" \
				$SCRIPT_ARGS \
				--files "build/payload/$NAME" \
				--output "$OUT"
		'
}

mkindex() {
	docker run --rm -v "$ROOT:/seedex" -w /seedex "${SIGN_ARGS[@]}" \
		-e "INDEX=/seedex/${FEED_DIR#"$ROOT/"}/packages.adb" -e "FEED=/seedex/${FEED_DIR#"$ROOT/"}" \
		"$IMAGE" sh -euc '
			[ -z "$SIGN" ] || { cp build/keys/*.pem /etc/apk/keys/; set -- --sign-key "$SIGN"; }
			apk mkndx "$@" --output "$INDEX" "$FEED"/*.apk
		'
	log "feed ready in build/:"
	(cd "$BUILD" && find . -type f ! -path './payload/*' | sort | sed 's|^\./|  |')
}

resolve_version
log "version $STAMP${VERSION:+$([ "$STAMP" = "$VERSION" ] || echo " (package $VERSION)")}"
stage seedex-box
stage luci-app-seedex
mkdir -p "$FEED_DIR"
rm -f "$FEED_DIR"/*.apk "$FEED_DIR/packages.adb"
prepare_signing
mkpkg seedex-box "Seedex router: CLI, VPN, proxy and policy routing" \
	"$(printf '%s' "$BOX_DEPENDS" | tr '\n' ' ') sing-box>=${SINGBOX_MIN} sing-box<${SINGBOX_MAX}" seedex-box/package
mkpkg luci-app-seedex "Seedex LuCI interface" "seedex-box=$VERSION luci-base" luci-app-seedex/package
mkindex
