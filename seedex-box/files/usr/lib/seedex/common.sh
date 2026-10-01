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

# The router brings up dns itself.
seedex_start_router() {
	[ -z "${SEEDEX_BOOT:-}" ] || return 0
	seedex_service_enabled router || return 0
	seedex_service_registered router && return 0
	log_info "starting seedex-router for the tunnels"
	/etc/init.d/seedex-router start
}

_seedex_config_digest() {
	uci -q show "seedex-$1" 2>/dev/null | grep -v '\.\(priority\|reserved\)=' | md5sum
}

seedex_config_stamp() {
	mkdir -p "$SEEDEX_RUNDIR/$1"
	_seedex_config_digest "$1" >"$SEEDEX_RUNDIR/$1/config.md5"
}

seedex_config_touch() {
	local stamp="$SEEDEX_RUNDIR/$1/config.md5"
	[ ! -f "$stamp" ] || echo changed >"$stamp"
}

seedex_config_stale() {
	local stamp="$SEEDEX_RUNDIR/$1/config.md5"
	[ -f "$stamp" ] || return 1
	[ "$(_seedex_config_digest "$1")" != "$(cat "$stamp")" ]
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
SEEDEX_CONN_FILE="$SEEDEX_RUNDIR/router/connectivity.state"

SEEDEX_PINS_FILE="$SEEDEX_RUNDIR/router/pins"

SEEDEX_WATCHDOG_PID="$SEEDEX_RUNDIR/router/watchdog.pid"

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
	seedex_watchdog_wake
}

seedex_watchdog_wake() {
	local pid
	pid=$(cat "$SEEDEX_WATCHDOG_PID" 2>/dev/null)
	[ -n "$pid" ] && grep -q seedex-router-watchdog "/proc/$pid/cmdline" 2>/dev/null &&
		kill -USR1 "$pid" 2>/dev/null
	return 0
}

seedex_iface_set_reserved() {
	local iface="$1" flag="$2" owner name rest map="$SEEDEX_RUNDIR/proxy/ifaces"
	read -r owner name rest <"$SEEDEX_IFACE_DIR/$iface" 2>/dev/null || return 0
	_seedex_iface_write "$iface" "$owner $name $flag"
	[ -f "$map" ] || return 0
	awk -v i="$iface" -v f="$flag" '$1 == i { $3 = f } 1' "$map" >"$map.new" && mv "$map.new" "$map"
}

seedex_iface_name() {
	awk 'FNR == 1 { print $2 }' "$SEEDEX_IFACE_DIR/$1" 2>/dev/null
}

SEEDEX_PROXY_IFACE_PREFIX="proxy"
SEEDEX_PROXY_CONFIG="$SEEDEX_RUNDIR/proxy/config.json"
SEEDEX_PROXY_API="$SEEDEX_RUNDIR/proxy/api"
SEEDEX_PROXY_API_PORT=9095

# The outbound a config's urltest group keeps its traffic on, by the
# config's interface. A config with one outbound has no group: nothing.
seedex_proxy_now() {
	local n addr secret now
	n="${1#"$SEEDEX_PROXY_IFACE_PREFIX"}"
	read -r addr secret 2>/dev/null <"$SEEDEX_PROXY_API" || return 0
	now=$(curl -s --max-time 2 -H "Authorization: Bearer $secret" "http://$addr/proxies/auto-$n" 2>/dev/null |
		jsonfilter -e '@.now' 2>/dev/null)
	# Outbounds whose tag another config took first carry the suffix -<n>.
	[ -z "$now" ] || printf '%s\n' "${now%-"$n"}"
}

# The URL that every probe of a tunnel fetches: the watchdog's, and the one
# sing-box urltest measures the outbounds of a config against.
seedex_probe_url() {
	local url
	url=$(uci -q get seedex-router.main.watchdog_url)
	printf '%s\n' "${url:-$SEEDEX_PROBE_URL}"
}

# sing-box reads the URL once, when its config is assembled.
seedex_proxy_probe_stale() {
	local url
	url=$(jq -r '[.outbounds[]? | select(.type == "urltest") | .url][0] // empty' \
		"$SEEDEX_PROXY_CONFIG" 2>/dev/null)
	[ -n "$url" ] && [ "$url" != "$(seedex_probe_url)" ]
}

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
	seedex_watchdog_wake
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

SEEDEX_UCI_DELTA_DIR=/tmp/.uci

_seedex_uci_stash() {
	case " ${SEEDEX_UCI_STASHED:-} " in
	*" $1 "*) return 0 ;;
	esac
	SEEDEX_UCI_STASHED="${SEEDEX_UCI_STASHED:-} $1"
	[ -s "$SEEDEX_UCI_DELTA_DIR/$1" ] || return 0
	mkdir -p "$SEEDEX_RUNDIR"
	mv "$SEEDEX_UCI_DELTA_DIR/$1" "$SEEDEX_RUNDIR/$1.delta"
}

_seedex_uci_unstash() {
	local c rest=""
	for c in ${SEEDEX_UCI_STASHED:-}; do
		[ "$c" = "$1" ] || rest="$rest $c"
	done
	SEEDEX_UCI_STASHED="$rest"
	[ -f "$SEEDEX_RUNDIR/$1.delta" ] || return 0
	mkdir -p "$SEEDEX_UCI_DELTA_DIR"
	mv "$SEEDEX_RUNDIR/$1.delta" "$SEEDEX_UCI_DELTA_DIR/$1"
}

_seedex_fw_add_device() {
	local iface="$1"
	local idx
	_seedex_uci_stash firewall
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
	_seedex_uci_stash firewall
	idx=$(_seedex_find_wan_zone) || return 0

	uci del_list "firewall.@zone[$idx].device=$iface" 2>/dev/null
	SEEDEX_FW_DIRTY=1
	log_debug "firewall: staged removal of $iface from wan zone"
}

_seedex_fw_apply() {
	if [ "${SEEDEX_FW_DIRTY:-0}" = 1 ]; then
		SEEDEX_FW_DIRTY=0
		uci commit firewall
		fw4 reload 2>/dev/null
		log_debug "firewall: applied"
	fi
	_seedex_uci_unstash firewall
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

seedex_fw_devices() {
	local idx
	idx=$(_seedex_find_wan_zone) || return 0
	uci -q get "firewall.@zone[$idx].device" | tr ' ' '\n'
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

# The provider's line for the status: the watchdog's last probe while its
# state is fresh, a probe now otherwise. Sets UPLINK_OK and UPLINK_RTT.
seedex_uplink_read() {
	UPLINK_OK=0
	UPLINK_RTT=""

	local cached=""
	if [ "$OVERLAY_FRESH" = 1 ]; then
		cached=$(awk '$1 == "uplink" { print $2, $3; exit }' "$SEEDEX_CONN_FILE")
	fi
	[ -n "$cached" ] || cached=$(seedex_probe_uplink)

	case "$cached" in
	"1 "*)
		UPLINK_OK=1
		UPLINK_RTT=${cached#1 }
		;;
	esac
}

# What the watchdog last wrote about the tunnels, for the status: sets
# OVERLAY_AVAIL with OVERLAY_ACTIVE, or OVERLAY_REASON.
seedex_overlay_read() {
	OVERLAY_FRESH=0
	OVERLAY_AVAIL=0
	OVERLAY_REASON=""
	OVERLAY_ACTIVE=""

	if [ ! -f "$SEEDEX_CONN_FILE" ]; then
		OVERLAY_REASON="router_stopped"
		return 0
	fi

	local interval
	interval=$(uci -q get seedex-router.main.watchdog_interval)
	[ "$interval" -gt 0 ] 2>/dev/null || interval=30

	local _ts=0 _n=0 _ok=0 _active="" _stale=0
	eval "$(awk -v now="$(date +%s)" -v fallback="$interval" '
		$1 == "ts"       { ts = $2 }
		$1 == "interval" { step = $2 }
		$1 == "active"   { active = $2 }
		$1 == "iface"    { n++; if ($3 == "1") ok++ }
		END {
			if (step + 0 <= 0) step = fallback
			printf "_ts=%d _n=%d _ok=%d _active=%s\n", ts + 0, n + 0, ok + 0, (active == "" ? "\"\"" : "\"" active "\"")
			printf "_stale=%d\n", (now - (ts + 0) > (step + 0) * 2) ? 1 : 0
		}' "$SEEDEX_CONN_FILE")"

	if [ "$_stale" = 1 ]; then
		OVERLAY_REASON="stale"
		return 0
	fi
	OVERLAY_FRESH=1
	if [ "$_n" -eq 0 ]; then
		OVERLAY_REASON="no_interfaces"
	elif [ "$_ok" -eq 0 ] || [ -z "$_active" ]; then
		OVERLAY_REASON="all_unreachable"
	else
		OVERLAY_AVAIL=1
		OVERLAY_ACTIVE="$_active"
	fi
}

seedex_iface_rtt() {
	awk -v want="$1" '$1 == "iface" && $2 == want && $3 == "1" { print $4; exit }' \
		"$SEEDEX_CONN_FILE" 2>/dev/null
}

seedex_config_states() {
	local config="$1" type="$2" owner="$3" idx=0 name enabled iface active rtt state is_active reserved priority via
	active=$(seedex_active_iface)
	while uci -q get "${config}.@${type}[$idx]" >/dev/null 2>&1; do
		name=$(uci -q get "${config}.@${type}[$idx].name")
		enabled=$(uci -q get "${config}.@${type}[$idx].enabled")
		reserved=$(uci -q get "${config}.@${type}[$idx].reserved")
		priority=$(uci -q get "${config}.@${type}[$idx].priority")
		name="${name:-#$idx}"
		idx=$((idx + 1))
		iface="" via=""
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
			[ "$owner" != proxy ] || via=$(seedex_proxy_now "$iface")
		fi
		printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$name" "$state" "$is_active" "$rtt" "${reserved:-0}" "${priority:-0}" "$via"
	done
}

seedex_status_configs() {
	local config="$1" type="$2" owner="$3" sep name state active rtt reserved priority via shown states
	states=$(seedex_config_states "$config" "$type" "$owner")
	[ -n "$states" ] || {
		printf '  %-10s none\n' "Configs:"
		return 0
	}
	echo "  Configs:"
	# A tab would collapse an empty field, such as the RTT of a tunnel that
	# does not answer, and shift the ones after it. A config name may hold
	# any printable character, so the fields are split on a control one.
	sep=$(printf '\037')
	while IFS="$sep" read -r name state active rtt reserved priority via; do
		[ -n "$name" ] || continue
		case "$state" in
		up) shown="${rtt:+$rtt ms}" ;;
		down) shown="" ;;
		*) shown="$state" ;;
		esac
		[ -z "$via" ] || name="$name ($via)"
		[ "$reserved" != 1 ] || shown="${shown:+$shown, }reserved"
		[ "${priority:-0}" = 0 ] || shown="${shown:+$shown, }priority $priority"
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

SEEDEX_PIN_MARK_BASE=256
SEEDEX_PIN_MARK_MASK='0xff00'
SEEDEX_PIN_PRIO=99
SEEDEX_WG_FWMARK=0x200

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
	[ -f "$SEEDEX_CONN_FILE" ] || return 0
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
	local file="${1:-$SEEDEX_PINS_FILE}" n iface name
	[ -f "$file" ] || return 0
	while read -r n iface name; do
		[ -n "$n" ] || continue
		_seedex_pin_rules del "$(seedex_pin_mark "$n")" ""
	done <"$file"
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

seedex_overlay_release() {
	ip route replace throw default table "$SEEDEX_ROUTE_TABLE"
	ip -6 route replace throw default table "$SEEDEX_ROUTE_TABLE"
	rm -f "$SEEDEX_ROUTER_STATE"
}

_seedex_lan_has_gua() {
	local dev
	dev=$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
	ip -6 addr show dev "${dev:-br-lan}" scope global 2>/dev/null |
		awk '$1 == "inet6" && $2 !~ /^f[cd]/ { found = 1 } END { exit !found }'
}

_seedex_overlay_has_v6() {
	ip -6 route show default table "$SEEDEX_ROUTE_TABLE" 2>/dev/null |
		awk '$1 == "default" { found = 1 } END { exit !found }'
}

# Without native IPv6 odhcpd announces no default route, so clients never send
# IPv6 into the overlay. A ra_default the user set stays untouched.
seedex_lan_ra_sync() {
	local want=0 cur ours
	[ "${1:-}" = off ] || _seedex_lan_has_gua || ! _seedex_overlay_has_v6 || want=1
	uci -q get dhcp.lan >/dev/null || return 0
	cur=$(uci -q get dhcp.lan.ra_default)
	ours=$(uci -q get dhcp.lan.seedex_ra_default)
	if [ "$want" = 1 ]; then
		[ -z "$cur" ] || [ "$ours" = 1 ] || return 0
		[ "$cur" != 2 ] || return 0
		_seedex_uci_stash dhcp
		uci set dhcp.lan.ra_default=2
		uci set dhcp.lan.seedex_ra_default=1
		log_info "announcing an IPv6 default route to the LAN: the overlay carries IPv6"
	else
		[ "$ours" = 1 ] || return 0
		_seedex_uci_stash dhcp
		uci -q delete dhcp.lan.ra_default
		uci -q delete dhcp.lan.seedex_ra_default
		log_info "no longer announcing an IPv6 default route to the LAN"
	fi
	uci commit dhcp
	_seedex_uci_unstash dhcp
	/etc/init.d/odhcpd reload 2>/dev/null
}

seedex_router_load() {
	config_load seedex-router
	config_get DEFAULT_ROUTE main default_route 'overlay'
	config_get PROBE_URL main watchdog_url "$SEEDEX_PROBE_URL"
	config_get PROBE_TIMEOUT main watchdog_timeout '5'
	config_get WATCHDOG_INTERVAL main watchdog_interval '30'
	config_get_bool KILL_SWITCH main kill_switch 1
	config_get WATCHDOG_MODE main watchdog_mode 'fastest'
	config_get WATCHDOG_TOLERANCE main watchdog_tolerance '100'
	config_get WATCHDOG_CHECKS main watchdog_checks '3'
	[ -n "$PROBE_URL" ] || PROBE_URL="$SEEDEX_PROBE_URL"
	[ "$PROBE_TIMEOUT" -gt 0 ] 2>/dev/null || PROBE_TIMEOUT=5
	[ "$WATCHDOG_INTERVAL" -gt 0 ] 2>/dev/null || WATCHDOG_INTERVAL=30
	case "$WATCHDOG_MODE" in
	fastest | failover | priority) ;;
	*) WATCHDOG_MODE=fastest ;;
	esac
	[ "$WATCHDOG_TOLERANCE" -ge 0 ] 2>/dev/null || WATCHDOG_TOLERANCE=100
	[ "$WATCHDOG_CHECKS" -gt 0 ] 2>/dev/null || WATCHDOG_CHECKS=3
}

SEEDEX_RTT_HISTORY="$SEEDEX_RUNDIR/router/rtt"
SEEDEX_RTT_SAMPLES=3

seedex_rtt_medians() {
	awk '{
		n = NF - 1
		for (i = 1; i <= n; i++) v[i] = $(i + 1) + 0
		for (i = 2; i <= n; i++) {
			x = v[i]
			for (j = i - 1; j >= 1 && v[j] > x; j--) v[j + 1] = v[j]
			v[j + 1] = x
		}
		print $1, (n % 2) ? v[(n + 1) / 2] : int((v[n / 2] + v[n / 2 + 1]) / 2)
	}' "$SEEDEX_RTT_HISTORY" 2>/dev/null
}

seedex_rtt_update() {
	mkdir -p "${SEEDEX_RTT_HISTORY%/*}"
	printf '%s\n' "$1" | awk -v hist="$SEEDEX_RTT_HISTORY" -v keep="$SEEDEX_RTT_SAMPLES" '
		BEGIN {
			while ((getline line < hist) > 0) {
				n = split(line, f, " ")
				s = ""
				for (i = 2; i <= n; i++) s = s " " f[i]
				h[f[1]] = s
			}
			close(hist)
		}
		NF == 2 {
			n = split(h[$1] " " $2, v, " ")
			s = ""
			for (i = (n > keep ? n - keep + 1 : 1); i <= n; i++) s = s " " v[i]
			out[$1] = s
		}
		END {
			printf "" >hist
			for (k in out) print k out[k] >hist
		}'
	seedex_rtt_medians
}

seedex_priority_defaults() {
	local config sid
	for config in seedex-vpn seedex-proxy; do
		sid=$(uci -q show "$config" | awk -F'[.=]' '
			NF == 3 && $3 == "config" { s[$2] = 1 }
			$3 == "priority" { delete s[$2] }
			END { for (k in s) print k }')
		[ -n "$sid" ] || continue
		_seedex_uci_stash "$config"
		for sid in $sid; do
			uci set "$config.$sid.priority=0"
		done
		uci commit "$config"
		_seedex_uci_unstash "$config"
	done
}

seedex_config_priorities() {
	{
		uci -q show seedex-vpn
		uci -q show seedex-proxy
	} | awk '{
		eq = index($0, "=")
		split(substr($0, 1, eq - 1), k, ".")
		v = substr($0, eq + 1)
		gsub(/^\047|\047$/, "", v)
		sec = k[1] "." k[2]
		if (k[3] == "name") name[sec] = v
		if (k[3] == "priority") prio[sec] = v
	}
	END {
		for (sec in name) {
			owner = sec
			sub(/^seedex-/, "", owner)
			sub(/\..*/, "", owner)
			print owner, name[sec], (sec in prio) ? prio[sec] + 0 : 0
		}
	}'
}

seedex_iface_priorities() {
	seedex_all_ifaces | awk -v prios="$(seedex_config_priorities | tr '\n' ';')" '
		BEGIN {
			n = split(prios, line, ";")
			for (i = 1; i <= n; i++) if (split(line[i], f, " ") == 3) prio[f[1] " " f[2]] = f[3]
		}
		{ print $1, (($2 " " $3) in prio) ? prio[$2 " " $3] : 0 }'
}

seedex_pick_candidate() {
	local allow prios=""
	allow=" $(seedex_overlay_ifaces | tr '\n' ' ')"
	[ "$WATCHDOG_MODE" = fastest ] || prios=$(seedex_iface_priorities | tr '\n' ' ')
	awk -v allow="$allow" -v prios="$prios" '
		BEGIN { n = split(prios, p, " "); for (i = 1; i < n; i += 2) prio[p[i]] = p[i + 1] + 0 }
		NF >= 2 && index(allow, " " $1 " ") {
			r = $2 + 0
			q = ($1 in prio) ? prio[$1] : 0
			if (!found || q > bestq || (q == bestq && r < min)) { best = $1; min = r; bestq = q; found = 1 }
		}
		END { if (found) print best, min, bestq }'
}

seedex_fetch() {
	curl -fsSL --max-time 30 --max-filesize 10485760 -o "$2" "$1" 2>/dev/null
}

SEEDEX_DNS_RUNDIR="$SEEDEX_RUNDIR/dns"

SEEDEX_ROUTER_DOMAINS_DIR="$SEEDEX_RUNDIR/router/domains"
SEEDEX_ROUTER_NFT_TABLE="seedex_router"
SEEDEX_ROUTER_OVERLAY_DYN="overlay_dyn"
SEEDEX_ROUTER_DIRECT_DYN="direct_dyn"

_SEEDEX_OCTET='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
SEEDEX_IPV4_RE="^$_SEEDEX_OCTET(\\.$_SEEDEX_OCTET){3}(/(3[0-2]|[12]?[0-9]))?\$"
SEEDEX_IPV6_RE='^[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*(/(12[0-8]|1[01][0-9]|[1-9]?[0-9]))?$'

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

# Servers the user gave dnsmasq in /etc/config/dhcp, the per-domain ones
# aside.
seedex_dnsmasq_servers() {
	uci -q show dhcp | sed -n "s/^dhcp\.[^.]*\.server=//p" | tr ' ' '\n' | tr -d "'" |
		grep -v / | sed 's/#.*//' | grep -E "$SEEDEX_IPV4_RE|$SEEDEX_IPV6_RE"
}

seedex_dns_upstream_ips() {
	{
		if [ -f "$SEEDEX_DNS_RUNDIR/upstream.ips" ]; then
			cat "$SEEDEX_DNS_RUNDIR/upstream.ips"
		else
			awk '$1 == "nameserver" { print $2 }' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null
		fi
		seedex_dnsmasq_servers
	} | sort -u
}

_seedex_addr_elements() {
	local set="$1" ip v4="" v6=""
	shift
	for ip in "$@"; do
		case "$ip" in
		*:*) v6="${v6:+$v6, }$ip" ;;
		*) v4="${v4:+$v4, }$ip" ;;
		esac
	done
	[ -z "$v4" ] || printf 'add element inet seedex_router %s { %s }\n' "$set" "$v4"
	[ -z "$v6" ] || printf 'add element inet seedex_router %s6 { %s }\n' "$set" "$v6"
}

_seedex_addr_set_fill() {
	_seedex_addr_elements "$@" | nft -f - 2>/dev/null
}

seedex_dns_bootstrap() {
	nft flush set inet seedex_router dns_bootstrap 2>/dev/null
	nft flush set inet seedex_router dns_bootstrap6 2>/dev/null
	[ "$1" = 1 ] || [ "$(uci -q get seedex-dns.main.upstream)" = provider ] || return 0
	# shellcheck disable=SC2046
	_seedex_addr_set_fill dns_bootstrap $(seedex_dns_upstream_ips)
}

# The box's own DNS goes through the tunnel in either routing mode, so the
# provider can neither block nor rewrite it: the resolver seedex-dns talks
# to, and every query dnsmasq sends out, its servers from /etc/config/dhcp
# included. dns_bootstrap, checked before this chain, lets DNS out directly
# while no tunnel answers. The provider's own DNS stays direct: it answers
# only its own users. seedex-dns and the router both call this, as either
# comes and goes.
seedex_dns_upstream_sync() {
	nft list chain inet seedex_router dns_out >/dev/null 2>&1 || return 0
	{
		echo "flush chain inet seedex_router dns_out"
		echo "flush set inet seedex_router dns_upstream"
		echo "flush set inet seedex_router dns_upstream6"
		seedex_dns_upstream_nft
	} | nft -f -
}

# The commands behind seedex_dns_upstream_sync, which the router also builds
# into a new table.
seedex_dns_upstream_nft() {
	[ -f "$SEEDEX_DNS_RUNDIR/upstream.ips" ] || return 0
	[ "$(uci -q get seedex-dns.main.upstream)" != provider ] || return 0
	# shellcheck disable=SC2046
	_seedex_addr_elements dns_upstream $(cat "$SEEDEX_DNS_RUNDIR/upstream.ips")
	echo "add rule inet seedex_router dns_out ip daddr @dns_upstream meta mark set $SEEDEX_FWMARK accept"
	echo "add rule inet seedex_router dns_out ip6 daddr @dns_upstream6 meta mark set $SEEDEX_FWMARK accept"
	grep -q '^dnsmasq:' /etc/passwd || return 0
	echo "add rule inet seedex_router dns_out meta skuid dnsmasq" \
		"meta l4proto { tcp, udp } th dport { 53, 853 } meta mark set $SEEDEX_FWMARK accept"
}

seedex_probe_uplink() {
	local url="${1:-$SEEDEX_PROBE_URL}"
	local timeout="${2:-5}"
	local out code secs host port ip
	host=$(printf '%s\n' "$url" | sed 's|^[A-Za-z]*://||;s|[/?#].*||')
	case "$host" in
	*:*) port="${host##*:}" host="${host%%:*}" ;;
	*) case "$url" in https:*) port=443 ;; *) port=80 ;; esac ;;
	esac
	if printf '%s\n' "$host" | grep -qE "$SEEDEX_IPV4_RE"; then
		ip="$host"
	else
		ip=$(seedex_resolve "$host" | head -1)
	fi
	[ -n "$ip" ] || {
		echo 0
		return 1
	}
	nft add element inet "$SEEDEX_ROUTER_NFT_TABLE" uplink_probe "{ $ip }" 2>/dev/null
	out=$(curl -s -o /dev/null --max-time "$timeout" --resolve "$host:$port:$ip" \
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

# Probes the overlay candidates at once and returns as soon as the choice is
# settled: probes that started together finish in RTT order, so the first
# answer wins unless a higher-priority candidate is still out. Prints the
# finished probes as "iface rtt".
seedex_probe_race() {
	local url="${1:-$SEEDEX_PROBE_URL}" timeout="${2:-5}"
	local ifaces iface dir pids="" prios deadline

	ifaces=$(seedex_overlay_ifaces | tr '\n' ' ')
	[ -n "${ifaces% }" ] || return 0
	mkdir -p "$SEEDEX_RUNDIR"
	dir=$(mktemp -d "$SEEDEX_RUNDIR/probe.XXXXXX") || return 1

	for iface in $ifaces; do
		(
			rtt=$(seedex_probe_iface_rtt "$iface" "$url" "$timeout")
			printf '%s %s\n' "$iface" "$rtt" >"$dir/.$iface"
			mv "$dir/.$iface" "$dir/$iface"
		) &
		pids="$pids $!"
	done

	prios=""
	[ "$WATCHDOG_MODE" = fastest ] || prios=$(seedex_iface_priorities | tr '\n' ' ')
	deadline=$(($(date +%s) + timeout + 2))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		cat "$dir"/* 2>/dev/null | awk -v all="$ifaces" -v prios="$prios" '
			BEGIN {
				n = split(prios, p, " ")
				for (i = 1; i < n; i += 2) prio[p[i]] = p[i + 1] + 0
			}
			{ done[$1] = 1 }
			NF >= 2 {
				q = prio[$1] + 0
				if (!found || q > bestq) { bestq = q; found = 1 }
			}
			END {
				split(all, a, " ")
				for (i in a) if (!(a[i] in done) && (!found || prio[a[i]] + 0 > bestq)) exit 1
			}' && break
		sleep 0.2 2>/dev/null || sleep 1
	done

	# shellcheck disable=SC2086
	kill $pids 2>/dev/null
	cat "$dir"/* 2>/dev/null
	rm -rf "$dir"
}
