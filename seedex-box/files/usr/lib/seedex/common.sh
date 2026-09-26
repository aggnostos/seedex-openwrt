# shellcheck shell=ash

TAG="${TAG:-seedex}"

log_info() { logger -p daemon.info -t "$TAG" "$@"; }
log_warn() { logger -p daemon.warn -t "$TAG" "$@"; }
log_err() { logger -p daemon.err -t "$TAG" "$@"; }
log_debug() { logger -p daemon.debug -t "$TAG" "$@"; }

die() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

warn() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
}

usage() {
	printf 'Usage: %s\n' "$*" >&2
	exit 2
}

usage_block() {
	local title="$1" row
	shift
	{
		printf 'Usage: %s\n\n' "$title"
		for row in "$@"; do
			if [ -n "$row" ]; then
				printf '  %s\n' "$row"
			else
				printf '\n'
			fi
		done
	} >&2
	exit 2
}

section() {
	printf '%s\n' "$1"
}

field() {
	printf '  %-15s %s\n' "$1" "$2"
}

indent() {
	sed 's/^/  /'
}

SEEDEX_DISABLED_DIR="/etc/seedex/disabled"

seedex_service_enabled() {
	[ ! -f "$SEEDEX_DISABLED_DIR/$1" ]
}

seedex_service_registered() {
	ubus call service list "{\"name\":\"seedex-$1\"}" 2>/dev/null | grep -q "\"seedex-$1\""
}

seedex_start_router() {
	local svc
	for svc in dns router; do
		seedex_service_enabled "$svc" || continue
		seedex_service_registered "$svc" && continue
		log_info "starting seedex-$svc for the tunnels"
		/etc/init.d/seedex-$svc start
	done
}

seedex_config_stamp() {
	mkdir -p "$SEEDEX_RUNDIR/$1"
	uci -q show "seedex-$1" 2>/dev/null | md5sum >"$SEEDEX_RUNDIR/$1/config.md5"
}

seedex_config_stale() {
	local stamp="$SEEDEX_RUNDIR/$1/config.md5"
	[ -f "$stamp" ] || return 1
	[ "$(uci -q show "seedex-$1" 2>/dev/null | md5sum)" != "$(cat "$stamp")" ]
}

seedex_status_header() {
	local svc="$1" label="$2" up=0 note=""
	seedex_service_up "$svc" && up=1
	if ! seedex_service_enabled "$svc"; then
		note=" disabled"
	elif seedex_config_stale "$svc"; then
		note=" restart needed"
	fi
	printf '%s %s:%s\n' "$(seedex_mark "$up")" "$label" "$note"
}

SEEDEX_VPN_DIR="/etc/seedex/vpn"
SEEDEX_PROXY_DIR="/etc/seedex/proxy"

seedex_config_dir_init() {
	local dir
	for dir in "$SEEDEX_VPN_DIR" "$SEEDEX_PROXY_DIR"; do
		[ -d "$dir" ] || mkdir -p "$dir"
		chmod 700 "$dir"
	done
}

seedex_config_kind() {
	local file="$1"
	[ -f "$file" ] || return 1

	if grep -qi '^[[:space:]]*\[Interface\]' "$file"; then
		echo vpn
	elif head -c 200 "$file" | grep -qE '^[[:space:]]*[a-z0-9]+://'; then
		echo links
	elif head -c 200 "$file" | grep -q '^[[:space:]]*\['; then
		echo rules
	elif head -c 200 "$file" | grep -q '^[[:space:]]*{'; then
		echo singbox
	else
		# shellcheck source=files/usr/lib/seedex/uri.sh
		. /usr/lib/seedex/uri.sh
		if seedex_links_decode <"$file" >/dev/null 2>&1; then
			echo links
		else
			echo unknown
		fi
	fi
}

SEEDEX_VPN_PROTOCOLS=""

seedex_vpn_load() {
	local module
	[ -z "$SEEDEX_VPN_PROTOCOLS" ] || return 0
	for module in /usr/lib/seedex/vpn/*.sh; do
		[ -f "$module" ] || continue
		# shellcheck disable=SC1090
		. "$module"
		module="${module##*/}"
		SEEDEX_VPN_PROTOCOLS="${SEEDEX_VPN_PROTOCOLS:+$SEEDEX_VPN_PROTOCOLS }${module%.sh}"
	done
}

seedex_vpn_detect() {
	local proto
	seedex_vpn_load
	for proto in $SEEDEX_VPN_PROTOCOLS; do
		"vpn_${proto}_detect" "$1" && {
			echo "$proto"
			return 0
		}
	done
	return 1
}

seedex_config_validate() {
	local file="$1" kind="$2"

	case "$kind" in
	vpn)
		local proto
		seedex_vpn_load
		proto=$(seedex_vpn_detect "$file") || {
			echo "not a WireGuard or AmneziaWG config"
			return 1
		}
		"vpn_${proto}_validate" "$file"
		;;
	rules)
		jq empty "$file" 2>/dev/null || {
			echo "not valid JSON"
			return 1
		}
		[ "$(jq 'if type == "array" then length else 0 end' "$file" 2>/dev/null)" -gt 0 ] 2>/dev/null ||
			{
				echo "no rules"
				return 1
			}
		local bad
		bad=$(jq -r '
			map(select((.name // "") == "" or ((.type // "") | IN("direct", "overlay", "block") | not)))
			| length' "$file" 2>/dev/null)
		[ "$bad" = 0 ] ||
			{
				echo "$bad rule(s) without a name or with a type other than direct/overlay/block"
				return 1
			}
		;;
	singbox)
		jq empty "$file" 2>/dev/null || {
			echo "not valid JSON"
			return 1
		}
		[ "$(jq '.outbounds | length' "$file" 2>/dev/null)" -gt 0 ] 2>/dev/null ||
			{
				echo "no outbounds"
				return 1
			}

		if command -v sing-box >/dev/null 2>&1; then
			local err
			err=$(sing-box check -c "$file" 2>&1) || {
				echo "sing-box rejected it: $err"
				return 1
			}
		fi
		;;
	esac
	return 0
}

SEEDEX_RUNDIR="/var/run/seedex"

seedex_prune_configs() {
	local config="$1" type="$2" dir="$3" f idx path keep=""
	idx=0
	while uci -q get "${config}.@${type}[$idx]" >/dev/null 2>&1; do
		path=$(uci -q get "${config}.@${type}[$idx].config")
		keep="$keep ${path##*/}"
		path=$(uci -q get "${config}.@${type}[$idx].staged")
		[ -z "$path" ] || keep="$keep ${path##*/}"
		idx=$((idx + 1))
	done
	for f in "$dir"/*; do
		[ -f "$f" ] || continue
		case " $keep " in
		*" ${f##*/} "*) continue ;;
		esac
		grep -qF "'$f'" "/etc/config/$config" 2>/dev/null && continue
		rm -f "$f"
		log_info "removed unreferenced config ${f##*/}"
	done
}

SEEDEX_FWMARK='0x100'

SEEDEX_ROUTE_TABLE='100'

SEEDEX_PROBE_URL='https://www.gstatic.com/generate_204'

SEEDEX_ROUTER_STATE="$SEEDEX_RUNDIR/router/active_iface"

SEEDEX_PINS_FILE="$SEEDEX_RUNDIR/router/pins"

SEEDEX_IFACE_DIR="$SEEDEX_RUNDIR/ifaces.d"

_seedex_iface_write() {
	local iface="$1" body="$2"
	local tmp="$SEEDEX_IFACE_DIR/.${iface}.new"
	mkdir -p "$SEEDEX_IFACE_DIR"
	printf '%s\n' "$body" >"$tmp" && mv "$tmp" "$SEEDEX_IFACE_DIR/$iface"
}

seedex_register_iface() {
	local iface="$1" owner="$2" name="$3" reserved="${4:-0}"
	_seedex_iface_write "$iface" "$owner $name $reserved"
	nft add element inet seedex_router tunnels "{ $iface }" 2>/dev/null
}

seedex_iface_name() {
	awk 'FNR == 1 { print $2 }' "$SEEDEX_IFACE_DIR/$1" 2>/dev/null
}

SEEDEX_PROXY_IFACE_PREFIX="proxy"

seedex_iface_for_config() {
	local owner="$1" name="$2"
	seedex_all_ifaces | awk -v owner="$owner" -v name="$name" '
		$2 == owner && $3 == name { print $1; exit }'
}

seedex_iface_for_name() {
	seedex_all_ifaces | awk -v name="$1" '$3 == name { print $1; exit }'
}

seedex_unregister_iface() {
	local iface="$1"
	seedex_probe_route_remove "$iface"
	rm -f "$SEEDEX_IFACE_DIR/$iface"
	nft delete element inet seedex_router tunnels "{ $iface }" 2>/dev/null
}

_seedex_find_wan_zone() {
	local idx=0
	while uci -q get "firewall.@zone[$idx]" >/dev/null 2>&1; do
		local name
		name=$(uci -q get "firewall.@zone[$idx].name")
		if [ "$name" = "wan" ]; then
			echo "$idx"
			return 0
		fi
		idx=$((idx + 1))
	done
	return 1
}

_seedex_fw_add_device() {
	local iface="$1"
	local idx
	idx=$(_seedex_find_wan_zone) || {
		log_err "firewall: wan zone not found"
		return 1
	}
	local existing
	existing=$(uci -q show "firewall.@zone[$idx].device" 2>/dev/null)
	echo "$existing" | grep -q "'${iface}'" && return 0

	uci add_list "firewall.@zone[$idx].device=$iface"
	SEEDEX_FW_DIRTY=1
	log_debug "firewall: staged $iface for wan zone"
}

_seedex_fw_del_device() {
	local iface="$1"
	local idx
	idx=$(_seedex_find_wan_zone) || return 0

	uci del_list "firewall.@zone[$idx].device=$iface" 2>/dev/null
	SEEDEX_FW_DIRTY=1
	log_debug "firewall: staged removal of $iface from wan zone"
}

_seedex_fw_apply() {
	[ "${SEEDEX_FW_DIRTY:-0}" = 1 ] || return 0
	SEEDEX_FW_DIRTY=0
	uci commit firewall
	fw4 reload 2>/dev/null
	log_debug "firewall: applied"
}

seedex_nat_enable() {
	local table="$1" iface
	shift
	nft delete table inet "$table" 2>/dev/null
	if ! nft add table inet "$table" ||
		! nft add chain inet "$table" postrouting \
			'{ type nat hook postrouting priority srcnat; policy accept; }'; then
		log_err "nftables setup failed"
		nft delete table inet "$table" 2>/dev/null
		return 1
	fi
	for iface in "$@"; do
		if nft add rule inet "$table" postrouting oifname "\"$iface\"" masquerade; then
			_seedex_fw_add_device "$iface"
		else
			log_err "nft rule failed for $iface"
		fi
	done
	_seedex_fw_apply
	log_debug "nat enabled for: $*"
}

seedex_fw_forget() {
	local iface
	for iface in "$@"; do
		_seedex_fw_del_device "$iface"
	done
	_seedex_fw_apply
}

seedex_nat_disable() {
	local table="$1" iface
	shift
	nft delete table inet "$table" 2>/dev/null
	for iface in "$@"; do
		_seedex_fw_del_device "$iface"
	done
	_seedex_fw_apply
}

seedex_all_ifaces() {
	[ -d "$SEEDEX_IFACE_DIR" ] || return 0
	set -- "$SEEDEX_IFACE_DIR"/*
	[ -e "$1" ] || return 0
	awk 'FNR == 1 {
		n = FILENAME
		sub(/.*\//, "", n)
		print n, $1, $2, ($3 == "1" ? 1 : 0)
	}' "$@" | sort
}

seedex_mark() {
	[ "$1" = 1 ] && printf '[*]' || printf '[ ]'
}

seedex_service_up() {
	case "$1" in
	dns) [ -f "$SEEDEX_DNS_RUNDIR/upstream.ips" ] ;;
	vpn) [ -s "$SEEDEX_RUNDIR/vpn/active_ifaces" ] ;;
	proxy)
		[ "$(ubus call service list '{"name":"seedex-proxy"}' 2>/dev/null |
			jsonfilter -e '@["seedex-proxy"].instances["sing-box"].running' 2>/dev/null)" = true ]
		;;
	router) nft list table inet seedex_router >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

seedex_active_iface() {
	cat "$SEEDEX_ROUTER_STATE" 2>/dev/null
}

seedex_iface_rtt() {
	awk -v want="$1" '$1 == "iface" && $2 == want && $3 == "1" { print $4; exit }' \
		"$SEEDEX_RUNDIR/router/connectivity.state" 2>/dev/null
}

seedex_config_states() {
	local config="$1" type="$2" owner="$3" idx=0 name enabled iface active rtt state is_active reserved
	active=$(seedex_active_iface)
	while uci -q get "${config}.@${type}[$idx]" >/dev/null 2>&1; do
		name=$(uci -q get "${config}.@${type}[$idx].name")
		enabled=$(uci -q get "${config}.@${type}[$idx].enabled")
		reserved=$(uci -q get "${config}.@${type}[$idx].reserved")
		name="${name:-#$idx}"
		idx=$((idx + 1))
		iface=""
		[ "$enabled" = 1 ] && iface=$(seedex_iface_for_config "$owner" "$name")
		is_active=0
		[ -n "$iface" ] && [ "$iface" = "$active" ] && is_active=1
		if [ "$enabled" != 1 ]; then
			state=disabled
			rtt=""
		elif [ -z "$iface" ]; then
			state=down
			rtt=""
		else
			rtt=$(seedex_iface_rtt "$iface")
			state=unreachable
			[ -z "$rtt" ] || state=up
		fi
		printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$state" "$is_active" "$rtt" "${reserved:-0}"
	done
}

seedex_status_configs() {
	local config="$1" type="$2" owner="$3" tab name state active rtt reserved shown states
	states=$(seedex_config_states "$config" "$type" "$owner")
	[ -n "$states" ] || {
		printf '  %-10s none\n' "Configs:"
		return 0
	}
	echo "  Configs:"
	tab=$(printf '\t')
	while IFS="$tab" read -r name state active rtt reserved; do
		[ -n "$name" ] || continue
		case "$state" in
		up) shown="${rtt:+$rtt ms}" ;;
		down) shown="" ;;
		*) shown="$state" ;;
		esac
		[ "$reserved" != 1 ] || shown="${shown:+$shown, }reserved"
		if [ -n "$shown" ]; then
			printf '    %s %-18s %s\n' "$(seedex_mark "$active")" "$name" "$shown"
		else
			printf '    %s %s\n' "$(seedex_mark "$active")" "$name"
		fi
	done <<STATES
$states
STATES
}

seedex_active_ifaces() {
	seedex_all_ifaces | awk '{print $1}'
}

seedex_overlay_ifaces() {
	seedex_all_ifaces | awk '$4 != 1 { print $1 }'
}

seedex_iface_reserved() {
	seedex_all_ifaces | awk -v i="$1" '$1 == i && $4 == 1 { found = 1 } END { exit !found }'
}

seedex_best_iface() {
	local allow
	allow=" $(seedex_overlay_ifaces | tr '\n' ' ')"
	awk -v allow="$allow" '
		NF == 2 && index(allow, " " $1 " ") && (!found || $2 + 0 < min) { min = $2 + 0; line = $0; found = 1 }
		END { if (found) print line }'
}

SEEDEX_PIN_MARK_BASE=256
SEEDEX_PIN_MARK_MASK='0xff00'
SEEDEX_PIN_PRIO=99

seedex_pin_mark() {
	printf '0x%x\n' $((SEEDEX_PIN_MARK_BASE + $1))
}

_seedex_pin_rules() {
	local op="$1" mark="$2" table="$3"
	ip rule del fwmark "$mark" priority "$SEEDEX_PIN_PRIO" 2>/dev/null
	ip -6 rule del fwmark "$mark" priority "$SEEDEX_PIN_PRIO" 2>/dev/null
	ip rule del fwmark "$mark" priority "$((SEEDEX_PIN_PRIO + 2))" 2>/dev/null
	ip -6 rule del fwmark "$mark" priority "$((SEEDEX_PIN_PRIO + 2))" 2>/dev/null
	[ "$op" != del ] || return 0
	if [ "$op" = add ]; then
		ip rule add fwmark "$mark" table "$table" priority "$SEEDEX_PIN_PRIO" 2>/dev/null
		ip -6 rule add fwmark "$mark" table "$table" priority "$SEEDEX_PIN_PRIO" 2>/dev/null
	fi
	ip rule add fwmark "$mark" table "$SEEDEX_ROUTE_TABLE" priority "$((SEEDEX_PIN_PRIO + 2))" 2>/dev/null
	ip -6 rule add fwmark "$mark" table "$SEEDEX_ROUTE_TABLE" priority "$((SEEDEX_PIN_PRIO + 2))" 2>/dev/null
}

_seedex_iface_carries() {
	[ -f "$SEEDEX_RUNDIR/router/connectivity.state" ] || return 0
	[ -n "$(seedex_iface_rtt "$1")" ]
}

seedex_pin_sync() {
	local n iface name mark table
	[ -f "$SEEDEX_PINS_FILE" ] || return 0
	while read -r n iface name; do
		[ -n "$iface" ] || continue
		mark=$(seedex_pin_mark "$n")
		if _seedex_iface_carries "$iface" && table=$(seedex_iface_table "$iface"); then
			_seedex_pin_rules add "$mark" "$table"
		else
			_seedex_pin_rules fallback "$mark" ""
		fi
	done <"$SEEDEX_PINS_FILE"
}

seedex_pin_clear() {
	local n iface name
	[ -f "$SEEDEX_PINS_FILE" ] || return 0
	while read -r n iface name; do
		[ -n "$n" ] || continue
		_seedex_pin_rules del "$(seedex_pin_mark "$n")" ""
	done <"$SEEDEX_PINS_FILE"
}

SEEDEX_PROBE_TABLE_BASE=100000

SEEDEX_PROBE_PRIO=998

seedex_iface_has_v6() {
	ip -6 addr show dev "$1" scope global 2>/dev/null | grep -q inet6
}

seedex_overlay_route() {
	ip route replace default dev "$1" table "$SEEDEX_ROUTE_TABLE"
	if seedex_iface_has_v6 "$1"; then
		ip -6 route replace default dev "$1" table "$SEEDEX_ROUTE_TABLE"
	else
		ip -6 route replace unreachable default table "$SEEDEX_ROUTE_TABLE"
	fi
	mkdir -p "${SEEDEX_ROUTER_STATE%/*}"
	echo "$1" >"$SEEDEX_ROUTER_STATE"
}

seedex_router_load() {
	config_load seedex-router
	config_get DEFAULT_ROUTE main default_route 'direct'
	config_get PROBE_URL main watchdog_url "$SEEDEX_PROBE_URL"
	config_get PROBE_TIMEOUT main watchdog_timeout '5'
	config_get WATCHDOG_INTERVAL main watchdog_interval '30'
	config_get_bool KILL_SWITCH main kill_switch 1
	[ -n "$PROBE_URL" ] || PROBE_URL="$SEEDEX_PROBE_URL"
	[ "$PROBE_TIMEOUT" -gt 0 ] 2>/dev/null || PROBE_TIMEOUT=5
	[ "$WATCHDOG_INTERVAL" -gt 0 ] 2>/dev/null || WATCHDOG_INTERVAL=30
}

seedex_fetch() {
	curl -fsSL --max-time 30 --max-filesize 10485760 -o "$2" "$1" 2>/dev/null
}

SEEDEX_DNS_RUNDIR="$SEEDEX_RUNDIR/dns"

SEEDEX_ROUTER_DOMAINS_DIR="$SEEDEX_RUNDIR/router/domains"
SEEDEX_ROUTER_NFT_TABLE="seedex_router"
SEEDEX_ROUTER_OVERLAY_DYN="overlay_dyn"
SEEDEX_ROUTER_DIRECT_DYN="direct_dyn"

SEEDEX_IPV4_RE='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'
SEEDEX_IPV6_RE='^[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*(/[0-9]+)?$'

seedex_resolve() {
	local domain="$1" family="${2:-4}" re result
	[ "$family" = 6 ] && re="$SEEDEX_IPV6_RE" || re="$SEEDEX_IPV4_RE"
	if command -v resolveip >/dev/null 2>&1; then
		result=$(resolveip "-$family" "$domain" 2>/dev/null | grep -E "$re")
	else
		result=$(nslookup "$domain" 127.0.0.1 2>/dev/null |
			awk '/^Name:/,0 { if (/^Address:/) print $2 }' | grep -E "$re")
	fi
	echo "$result"
}

seedex_dns_upstream_ips() {
	if [ -f "$SEEDEX_DNS_RUNDIR/upstream.ips" ]; then
		cat "$SEEDEX_DNS_RUNDIR/upstream.ips"
	else
		awk '$1 == "nameserver" { print $2 }' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null
	fi
}

seedex_dns_bootstrap() {
	local ip v4="" v6=""
	nft flush set inet seedex_router dns_bootstrap 2>/dev/null
	nft flush set inet seedex_router dns_bootstrap6 2>/dev/null
	[ "$1" = 1 ] || return 0
	for ip in $(seedex_dns_upstream_ips); do
		case "$ip" in
		*:*) v6="${v6:+$v6, }$ip" ;;
		*) v4="${v4:+$v4, }$ip" ;;
		esac
	done
	[ -z "$v4" ] || nft add element inet seedex_router dns_bootstrap "{ $v4 }" 2>/dev/null
	[ -z "$v6" ] || nft add element inet seedex_router dns_bootstrap6 "{ $v6 }" 2>/dev/null
}

seedex_probe_uplink() {
	local url="${1:-$SEEDEX_PROBE_URL}"
	local timeout="${2:-5}"
	local out code secs
	out=$(curl -s -o /dev/null --max-time "$timeout" \
		-w '%{http_code} %{time_total}' "$url" 2>/dev/null)
	[ -n "$out" ] || {
		echo 0
		return 1
	}
	code=$(echo "$out" | awk '{print $1}')
	secs=$(echo "$out" | awk '{print $2}')
	[ "$code" = "204" ] || {
		echo 0
		return 1
	}
	echo "1 $(echo "$secs" | awk '{ printf "%d", $1 * 1000 }')"
}

seedex_iface_is_up() {
	ip link show dev "$1" 2>/dev/null | grep -q '[<,]UP[,>]'
}

_seedex_probe_table() {
	local idx
	idx=$(cat "/sys/class/net/$1/ifindex" 2>/dev/null) || return 1
	[ -n "$idx" ] || return 1
	echo $((SEEDEX_PROBE_TABLE_BASE + idx))
}

seedex_iface_table() { _seedex_probe_table "$1"; }

seedex_probe_route_install() {
	local iface="$1" table
	table=$(_seedex_probe_table "$iface") || return 1
	ip route replace default dev "$iface" table "$table" 2>/dev/null
	if seedex_iface_has_v6 "$iface"; then
		ip -6 route replace default dev "$iface" table "$table" 2>/dev/null
	else
		ip -6 route flush table "$table" 2>/dev/null
	fi
	ip rule del oif "$iface" table "$table" priority $SEEDEX_PROBE_PRIO 2>/dev/null
	ip rule add oif "$iface" table "$table" priority $SEEDEX_PROBE_PRIO 2>/dev/null
	return 0
}

seedex_probe_route_remove() {
	local iface="$1" table i=0
	while [ "$i" -lt 8 ]; do
		ip rule del oif "$iface" priority $SEEDEX_PROBE_PRIO 2>/dev/null || break
		i=$((i + 1))
	done
	table=$(_seedex_probe_table "$iface") || return 0
	ip route flush table "$table" 2>/dev/null
	ip -6 route flush table "$table" 2>/dev/null
	return 0
}

seedex_probe_iface_rtt() {
	local iface="$1"
	local url="${2:-$SEEDEX_PROBE_URL}"
	local timeout="${3:-5}"

	seedex_iface_is_up "$iface" || return 1
	seedex_probe_route_install "$iface" || return 1

	local out code secs
	out=$(curl --interface "$iface" \
		--max-time "$timeout" \
		--silent --output /dev/null \
		--write-out '%{http_code} %{time_total}' \
		"$url" 2>/dev/null)
	code=$(echo "$out" | awk '{print $1}')
	secs=$(echo "$out" | awk '{print $2}')

	[ "$code" = "204" ] && [ -n "$secs" ] || return 1
	echo "$secs" | awk '{ printf "%d", $1 * 1000 }'
}

_probe_all_serial() {
	local url="$1" timeout="$2" iface rtt
	for iface in $(seedex_active_ifaces); do
		rtt=$(seedex_probe_iface_rtt "$iface" "$url" "$timeout") || rtt=""
		echo "$iface $rtt"
	done
}

seedex_probe_all_ifaces() {
	local url="${1:-$SEEDEX_PROBE_URL}"
	local timeout="${2:-5}"
	local ifaces iface dir

	ifaces=$(seedex_active_ifaces)
	[ -n "$ifaces" ] || return 0

	mkdir -p "$SEEDEX_RUNDIR"
	dir=$(mktemp -d "$SEEDEX_RUNDIR/probe.XXXXXX" 2>/dev/null) || {
		_probe_all_serial "$url" "$timeout"
		return 0
	}

	for iface in $ifaces; do
		seedex_probe_iface_rtt "$iface" "$url" "$timeout" >"$dir/$iface" 2>/dev/null &
	done
	wait

	for iface in $ifaces; do
		printf '%s %s\n' "$iface" "$(cat "$dir/$iface" 2>/dev/null)"
	done
	rm -rf "$dir"
}
