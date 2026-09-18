#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"

BOX_DEPENDS="curl ca-bundle jq coreutils-stty nftables-json kmod-nft-core kmod-nft-fib
kmod-nft-nat kmod-nft-offload dnsmasq-full https-dns-proxy kmod-wireguard wireguard-tools"

IMAGE="${SEEDEX_APK_IMAGE:-alpine:edge}"
BUILD_IMAGE="seedex-build"
SIGN_KEY="${SEEDEX_APK_SIGN_KEY:-$HOME/.seedex/apk-sign.key}"
OPKG_SIGN_KEY="${SEEDEX_OPKG_SIGN_KEY:-$HOME/.seedex/opkg-sign.key}"
PUB_KEY_NAME="seedex-feed.pem"
OPKG_PUB_KEY_NAME="seedex-feed.pub"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die() {
	printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
	exit 1
}

ARCH="noarch"
SINGBOX_MIN="1.12.0"
SINGBOX_MAX="1.15"
FEED_DIR="$BUILD/$ARCH"

command -v docker >/dev/null 2>&1 || die "docker not found — it hosts the apk-tools that builds the packages"
docker info >/dev/null 2>&1 || die "the docker daemon is not running — start Docker Desktop and rerun"

prepare_image() {
	docker image inspect "$BUILD_IMAGE" >/dev/null 2>&1 && return 0
	log "preparing the $BUILD_IMAGE image (once)"
	printf 'FROM %s\nRUN apk add --no-cache signify\n' "$IMAGE" | docker build -q -t "$BUILD_IMAGE" - >/dev/null ||
		die "cannot build the $BUILD_IMAGE image — check outbound access and rerun"
}

resolve_version() {
	local version="${SEEDEX_VERSION:-}"
	[ -n "$version" ] || version="$(git -C "$ROOT" describe --tags --dirty 2>/dev/null || true)"
	[ -n "$version" ] || version="$(cat "$ROOT/version")"
	STAMP="$version"
	VERSION="$(printf '%s\n' "$version" | sed -n '1{s/^[vV]//;s/[^0-9.].*$//;p;}')"
	[ -n "$VERSION" ] || die "cannot derive a numeric package version from '$version'"
	local rev
	rev="$(printf '%s\n' "$version" | sed -n 's/^[^-]*-\([0-9]*\)-g[0-9a-f]*\(-dirty\)\{0,1\}$/\1/p')"
	[ -n "$rev" ] || case "$version" in *-dirty) rev=0 ;; esac
	APK_VERSION="$VERSION${rev:+-r$rev}"
	IPK_VERSION="$VERSION${rev:+-$rev}"
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
	if [ -s "$OPKG_SIGN_KEY" ] && [ -s "${OPKG_SIGN_KEY%.key}.pub" ]; then
		OPKG_SIGN_ARGS=(-v "$OPKG_SIGN_KEY:/opkg/seedex.sec:ro" -v "${OPKG_SIGN_KEY%.key}.pub:/opkg/seedex.pub:ro" -e "OPKG_SIGN=/opkg/seedex.sec")
		log "signing the opkg feed with ${OPKG_SIGN_KEY/#$HOME/~}"
	else
		warn "no opkg signing key pair at ${OPKG_SIGN_KEY%.key}.{key,pub} — the opkg feed will be unsigned"
		warn "OpenWrt 24.x will need 'option check_signature 0'; create one with:"
		printf '  docker run --rm -v %s:/k alpine sh -c "apk add -q signify && signify -G -n -c seedex -s /k/opkg-sign.key -p /k/opkg-sign.pub"\n' \
			"${OPKG_SIGN_KEY%/*}" >&2
		OPKG_SIGN_ARGS=(-e "OPKG_SIGN=")
	fi
}

mkpkg() {
	local name="$1" description="$2" depends="$3" scripts="$4"
	local out="$FEED_DIR/${name}-${APK_VERSION}.apk" script_args="" s
	for s in post-install post-upgrade pre-deinstall post-deinstall; do
		[ -f "$ROOT/$scripts/$s" ] && script_args="$script_args --script $s:$scripts/$s"
	done
	log "packaging $name $APK_VERSION ($ARCH)"
	docker run --rm -v "$ROOT:/seedex" -w /seedex "${SIGN_ARGS[@]}" \
		-e "NAME=$name" -e "VERSION=$APK_VERSION" -e "ARCH=$ARCH" \
		-e "DESCRIPTION=$description" -e "DEPENDS=$depends" -e "SCRIPT_ARGS=$script_args" \
		-e "OUT=/seedex/${out#"$ROOT/"}" \
		"$BUILD_IMAGE" sh -euc '
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

mkipk() {
	local name="$1" description="$2" depends="$3" scripts="$4"
	local out="$FEED_DIR/${name}_${IPK_VERSION}_all.ipk"
	log "packaging $name $IPK_VERSION (ipk)"
	docker run --rm -v "$ROOT:/seedex" -w /seedex \
		-e "NAME=$name" -e "VERSION=$IPK_VERSION" -e "DESCRIPTION=$description" -e "DEPENDS=$depends" \
		-e "SCRIPTS=$scripts" -e "OUT=/seedex/${out#"$ROOT/"}" \
		"$BUILD_IMAGE" sh -euc '
			work=$(mktemp -d)
			payload="build/payload/$NAME"
			info="/usr/lib/opkg/info/$NAME"
			marker="/tmp/.seedex-upgrade-$NAME"
			deps=$(printf "%s" "$DEPENDS" | tr " " "\n" | sed "/^$/d;
				s/^\([^<>=]*\)>=\(.*\)$/\1 (>= \2)/;
				s/^\([^<>=]*\)<\(.*\)$/\1 (<< \2)/;
				s/^\([^<>=]*\)=\(.*\)$/\1 (= \2)/" | paste -sd, - | sed "s/,/, /g")
			mkdir -p "$work/control"
			{
				echo "Package: $NAME"
				echo "Version: $VERSION"
				echo "Depends: $deps"
				echo "Source: https://github.com/aggnostos/seedex-openwrt"
				echo "SourceName: $NAME"
				echo "License: GPL-2.0-only"
				echo "Section: net"
				echo "Architecture: all"
				echo "Installed-Size: $(du -sk "$payload" | cut -f1)"
				echo "Description: $DESCRIPTION"
			} >"$work/control/control"
			[ ! -d "$payload/etc/config" ] ||
				find "$payload/etc/config" -type f | sed "s|^$payload||" >"$work/control/conffiles"
			body() { tail -n +2 "$SCRIPTS/$1"; }
			if [ -f "$SCRIPTS/post-install" ]; then
				{ echo "#!/bin/sh"; body post-install; } >"$work/control/install"
				if [ -f "$SCRIPTS/post-upgrade" ]; then
					{ echo "#!/bin/sh"; body post-upgrade; } >"$work/control/upgrade"
				fi
				{
					echo "#!/bin/sh"
					echo "if [ -f $marker ]; then rm -f $marker; exec sh $info.upgrade; fi"
					echo "exec sh $info.install"
				} >"$work/control/postinst"
			fi
			if [ -f "$SCRIPTS/pre-deinstall" ]; then
				{
					echo "#!/bin/sh"
					echo "[ \"\${1:-}\" != upgrade ] || { touch $marker; exit 0; }"
					body pre-deinstall
				} >"$work/control/prerm"
			fi
			if [ -f "$SCRIPTS/post-deinstall" ]; then
				{
					echo "#!/bin/sh"
					echo "[ \"\${1:-}\" != upgrade ] || exit 0"
					body post-deinstall
				} >"$work/control/postrm"
			fi
			chmod 0755 "$work"/control/*
			echo "2.0" >"$work/debian-binary"
			tar -C "$work/control" -czf "$work/control.tar.gz" .
			tar -C "$payload" -czf "$work/data.tar.gz" .
			mkdir -p "$(dirname "$OUT")"
			tar -C "$work" -czf "$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz
		'
}

mkopkgindex() {
	docker run --rm -v "$ROOT:/seedex" -w /seedex "${OPKG_SIGN_ARGS[@]}" \
		-e "FEED=/seedex/${FEED_DIR#"$ROOT/"}" -e "PUB=/seedex/build/keys/$OPKG_PUB_KEY_NAME" "$BUILD_IMAGE" sh -euc '
			cd "$FEED"
			rm -f Packages Packages.gz Packages.sig
			for f in *.ipk; do
				tar -xzOf "$f" ./control.tar.gz | tar -xzOf - ./control
				echo "Filename: $f"
				echo "Size: $(stat -c %s "$f")"
				echo "SHA256sum: $(sha256sum "$f" | cut -d" " -f1)"
				echo
			done >Packages
			gzip -9c Packages >Packages.gz
			[ -z "$OPKG_SIGN" ] || {
				signify -S -s "$OPKG_SIGN" -m Packages -x Packages.sig
				mkdir -p "$(dirname "$PUB")"
				cp /opkg/seedex.pub "$PUB"
			}
		'
}

mkindex() {
	docker run --rm -v "$ROOT:/seedex" -w /seedex "${SIGN_ARGS[@]}" \
		-e "INDEX=/seedex/${FEED_DIR#"$ROOT/"}/packages.adb" -e "FEED=/seedex/${FEED_DIR#"$ROOT/"}" \
		"$BUILD_IMAGE" sh -euc '
			[ -z "$SIGN" ] || { cp build/keys/*.pem /etc/apk/keys/; set -- --sign-key "$SIGN"; }
			apk mkndx "$@" --output "$INDEX" "$FEED"/*.apk
		'
}

resolve_version
prepare_image
log "version $STAMP (apk $APK_VERSION, ipk $IPK_VERSION)"
stage seedex-box
stage luci-app-seedex
mkdir -p "$FEED_DIR"
rm -f "$FEED_DIR"/*.apk "$FEED_DIR/packages.adb" "$FEED_DIR"/*.ipk "$FEED_DIR"/Packages*
prepare_signing
BOX_DEPS="$(printf '%s' "$BOX_DEPENDS" | tr '\n' ' ') sing-box>=${SINGBOX_MIN} sing-box<${SINGBOX_MAX}"
mkpkg seedex-box "Seedex router: CLI, VPN, proxy and policy routing" "$BOX_DEPS" seedex-box/package
mkpkg luci-app-seedex "Seedex LuCI interface" "seedex-box=$APK_VERSION luci-base" luci-app-seedex/package
mkindex
mkipk seedex-box "Seedex router: CLI, VPN, proxy and policy routing" "$BOX_DEPS" seedex-box/package
mkipk luci-app-seedex "Seedex LuCI interface" "seedex-box=$IPK_VERSION luci-base" luci-app-seedex/package
mkopkgindex
log "feeds ready in build/:"
(cd "$BUILD" && find . -type f ! -path './payload/*' | sort | sed 's|^\./|  |')
