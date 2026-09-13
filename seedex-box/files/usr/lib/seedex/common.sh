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

_uci_quote() {
	printf '%s' "$1" | sed "s/'/'\\\\''/g"
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

seedex_status_header() {
	local svc="$1" label="$2" up=0
	seedex_service_up "$svc" && up=1
	if seedex_service_enabled "$svc"; then
		printf '%s %s:\n' "$(seedex_mark "$up")" "$label"
	else
		printf '%s %s: disabled\n' "$(seedex_mark "$up")" "$label"
	fi
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
		echo awg
	elif head -c 200 "$file" | grep -q '^[[:space:]]*\['; then
		echo rules
	elif head -c 200 "$file" | grep -q '^[[:space:]]*{'; then
		echo singbox
	else
		echo unknown
	fi
}

seedex_awg_field() {
	local file="$1" key="$2"

	awk -v want="$key" '
		BEGIN { want = tolower(want) }
		/^[[:space:]]*\[/ {
			in_iface = (tolower($0) ~ /^[[:space:]]*\[interface\]/)
			next
		}
		!in_iface { next }
		{
			line = $0
			sub(/[[:space:]]*#.*$/, "", line)
			if (index(line, "=") == 0) next
			k = substr(line, 1, index(line, "=") - 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
			if (tolower(k) != want) next
			v = substr(line, index(line, "=") + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
			print v
			exit
		}' "$file" 2>/dev/null
}

seedex_config_endpoints() {
	local file="$1" kind="$2"
	[ -f "$file" ] || return 0

	case "$kind" in
	awg)
		awk '
			tolower($0) ~ /^[[:space:]]*endpoint[[:space:]]*=/ {
				v = substr($0, index($0, "=") + 1)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
				if (v ~ /^\[/) { sub(/^\[/, "", v); sub(/\].*$/, "", v) }
				else sub(/:[0-9]+$/, "", v)
				if (v != "") print v
			}' "$file"
		;;
	singbox)
		jq -r '.outbounds[]? | select(.server) | .server' "$file" 2>/dev/null
		;;
	esac
}

seedex_config_validate() {
	local file="$1" kind="$2"

	case "$kind" in
	awg)
		grep -qi '^[[:space:]]*\[Interface\]' "$file" ||
			{
				echo "no [Interface] section"
				return 1
			}
		[ -n "$(seedex_awg_field "$file" PrivateKey)" ] ||
			{
				echo "no PrivateKey in [Interface]"
				return 1
			}
		grep -qi '^[[:space:]]*\[Peer\]' "$file" ||
			{
				echo "no [Peer] section"
				return 1
			}
		grep -qiE '^[[:space:]]*PublicKey[[:space:]]*=' "$file" ||
			{
				echo "no PublicKey in [Peer]"
				return 1
			}
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

SEEDEX_IFACE_DIR="$SEEDEX_RUNDIR/ifaces.d"

_seedex_iface_write() {
	local iface="$1" body="$2"
	local tmp="$SEEDEX_IFACE_DIR/.${iface}.new"
	mkdir -p "$SEEDEX_IFACE_DIR"
	printf '%s\n' "$body" >"$tmp" && mv "$tmp" "$SEEDEX_IFACE_DIR/$iface"
}

seedex_register_iface() {
	local iface="$1" owner="$2" name="$3"
	_seedex_iface_write "$iface" "$owner $name"
}

seedex_iface_name() {
	local name
	name=$(awk 'FNR == 1 { print $2 }' "$SEEDEX_IFACE_DIR/$1" 2>/dev/null)
	[ "$name" = proxy ] || {
		printf '%s\n' "$name"
		return 0
	}
	name=$(seedex_proxy_probe | awk -F'\t' '$3 == 1 { print $1; exit }')
	printf '%s\n' "${name:-proxy}"
}

SEEDEX_PROXY_IFACE="proxy0"

SEEDEX_CLASH_API="127.0.0.1:9090"

seedex_proxy_probe() {
	local map="$SEEDEX_RUNDIR/proxy/tags"
	[ -s "$map" ] || return 1
	curl -s -m 2 "http://$SEEDEX_CLASH_API/proxies" 2>/dev/null |
		jq -r --rawfile map "$map" '
			($map | split("\n") | map(select(length > 0) | split(" ") | { key: .[0], value: .[1] })
			  | from_entries) as $names
			| (.proxies.auto.now // "") as $now
			| [ .proxies | to_entries[]
			    | select($names[.key] != null)
			    | { name: $names[.key], active: (.key == $now),
			        delay: ((.value.history // []) | last | .delay // 0) } ]
			| group_by(.name)
			| map({ name: .[0].name, active: (map(.active) | any),
			        delay: ((map(.delay) | map(select(. > 0)) | min) // 0) })
			| .[]
			| [ .name, (if .delay > 0 then "up" else "unreachable" end),
			    (if .active then "1" else "0" end), (if .delay > 0 then (.delay | tostring) else "" end) ]
			| @tsv'
}

seedex_iface_for_config() {
	local owner="$1" name="$2"
	seedex_all_ifaces | awk -v owner="$owner" -v name="$name" '
		$2 == owner && (owner == "proxy" || $3 == name) { print $1; exit }'
}

seedex_unregister_iface() {
	local iface="$1"
	seedex_probe_route_remove "$iface"
	rm -f "$SEEDEX_IFACE_DIR/$iface"
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

seedex_fw_add_device() {
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

seedex_fw_del_device() {
	local iface="$1"
	local idx
	idx=$(_seedex_find_wan_zone) || return 0

	uci del_list "firewall.@zone[$idx].device=$iface" 2>/dev/null
	SEEDEX_FW_DIRTY=1
	log_debug "firewall: staged removal of $iface from wan zone"
}

seedex_fw_apply() {
	[ "${SEEDEX_FW_DIRTY:-0}" = 1 ] || return 0
	SEEDEX_FW_DIRTY=0
	uci commit firewall
	fw4 reload 2>/dev/null
	log_debug "firewall: applied"
}

seedex_all_ifaces() {
	[ -d "$SEEDEX_IFACE_DIR" ] || return 0
	set -- "$SEEDEX_IFACE_DIR"/*
	[ -e "$1" ] || return 0
	awk 'FNR == 1 {
		n = FILENAME
		sub(/.*\//, "", n)
		print n, $1, $2
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
	cat "$SEEDEX_RUNDIR/router/active_iface" 2>/dev/null
}

seedex_iface_rtt() {
	awk -v want="$1" '$1 == "iface" && $2 == want && $3 == "1" { print $4; exit }' \
		"$SEEDEX_RUNDIR/router/connectivity.state" 2>/dev/null
}

seedex_config_states() {
	local config="$1" type="$2" owner="$3" idx=0 name enabled iface active rtt state probe="" line is_active
	active=$(seedex_active_iface)
	[ "$owner" != proxy ] || probe=$(seedex_proxy_probe)
	while uci -q get "${config}.@${type}[$idx]" >/dev/null 2>&1; do
		name=$(uci -q get "${config}.@${type}[$idx].name")
		enabled=$(uci -q get "${config}.@${type}[$idx].enabled")
		name="${name:-#$idx}"
		idx=$((idx + 1))
		iface=""
		[ "$enabled" = 1 ] && iface=$(seedex_iface_for_config "$owner" "$name")
		is_active=0
		[ -n "$iface" ] && [ "$iface" = "$active" ] && is_active=1
		rtt=""
		line=""
		[ -z "$probe" ] || line=$(printf '%s\n' "$probe" | awk -F'\t' -v n="$name" '$1 == n { print; exit }')
		if [ "$enabled" != 1 ]; then
			state=disabled
		elif [ -z "$iface" ]; then
			state=down
		elif [ -n "$line" ]; then
			state=$(printf '%s' "$line" | cut -f2)
			if [ "$(printf '%s' "$line" | cut -f3)" = 1 ]; then
				rtt=$(seedex_iface_rtt "$iface")
				[ -n "$rtt" ] || state=unreachable
			else
				is_active=0
			fi
		elif [ -n "$probe" ]; then
			state=down
		else
			rtt=$(seedex_iface_rtt "$iface")
			state=unreachable
			[ -z "$rtt" ] || state=up
		fi
		printf '%s\t%s\t%s\t%s\n' "$name" "$state" "$is_active" "$rtt"
	done
}

seedex_status_configs() {
	local config="$1" type="$2" owner="$3" tab name state active rtt shown states
	states=$(seedex_config_states "$config" "$type" "$owner")
	[ -n "$states" ] || {
		printf '  %-10s none\n' "Configs:"
		return 0
	}
	echo "  Configs:"
	tab=$(printf '\t')
	while IFS="$tab" read -r name state active rtt; do
		[ -n "$name" ] || continue
		case "$state" in
		up) shown="${rtt:+$rtt ms}" ;;
		down) shown="" ;;
		*) shown="$state" ;;
		esac
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

SEEDEX_PROBE_TABLE_BASE=100000

SEEDEX_PROBE_PRIO=998

seedex_iface_has_v6() {
	ip -6 addr show dev "$1" scope global 2>/dev/null | grep -q inet6
}

seedex_overlay_route6() {
	if seedex_iface_has_v6 "$1"; then
		ip -6 route replace default dev "$1" table "$SEEDEX_ROUTE_TABLE"
	else
		ip -6 route replace unreachable default table "$SEEDEX_ROUTE_TABLE"
	fi
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

seedex_dns_wait() {
	local seconds="${1:-15}" deadline
	deadline=$(($(date +%s) + seconds))
	while :; do
		[ -z "$(seedex_resolve example.com)" ] || return 0
		[ "$(date +%s)" -lt "$deadline" ] || break
		sleep 1
	done
	log_warn "dns not available after ${seconds}s, domains may fail to resolve"
	return 1
}

seedex_dnsmasq_confdir() {
	local dir
	dir="$(grep -s '^conf-dir=' /var/etc/dnsmasq.conf* 2>/dev/null | head -1 | cut -d= -f2)"
	printf '%s\n' "${dir:-/tmp/dnsmasq.d}"
}

seedex_dns_upstream_ips() {
	if [ -f "$SEEDEX_DNS_RUNDIR/upstream.ips" ]; then
		cat "$SEEDEX_DNS_RUNDIR/upstream.ips"
	else
		awk '$1 == "nameserver" { print $2 }' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null
	fi
}

seedex_dns_bootstrap_refresh() {
	nft list set inet seedex_router dns_bootstrap 2>/dev/null | grep -qF elements || return 0
	seedex_dns_bootstrap 1
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
	local url="${1:-https://www.gstatic.com/generate_204}"
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

seedex_probe_route_install() {
	local iface="$1" table
	table=$(_seedex_probe_table "$iface") || return 1
	ip route replace default dev "$iface" table "$table" 2>/dev/null
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
	return 0
}

seedex_probe_iface() {
	local iface="$1"
	local url="${2:-https://www.gstatic.com/generate_204}"
	local timeout="${3:-5}"

	seedex_iface_is_up "$iface" || return 1
	seedex_probe_route_install "$iface" || return 1

	local code
	code=$(curl --interface "$iface" \
		--max-time "$timeout" \
		--silent --output /dev/null \
		--write-out '%{http_code}' \
		"$url" 2>/dev/null)

	[ "$code" = "204" ]
}

seedex_probe_iface_rtt() {
	local iface="$1"
	local url="${2:-https://www.gstatic.com/generate_204}"
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

seedex_fastest_iface() {
	local best
	best=$(seedex_probe_all_ifaces "$@" | awk 'NF == 2 && (!found || $2 + 0 < min) { min = $2 + 0; iface = $1; found = 1 } END { print iface }')
	[ -n "$best" ] || return 1
	echo "$best"
}

_probe_all_serial() {
	local url="$1" timeout="$2" iface rtt
	for iface in $(seedex_active_ifaces); do
		rtt=$(seedex_probe_iface_rtt "$iface" "$url" "$timeout") || rtt=""
		echo "$iface $rtt"
	done
}

seedex_probe_all_ifaces() {
	local url="${1:-https://www.gstatic.com/generate_204}"
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
