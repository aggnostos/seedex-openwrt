# shellcheck shell=ash

SEEDEX_URI_SCHEMES="vless trojan ss vmess hysteria2 hy2 tuic anytls"

seedex_is_uri() {
	local scheme
	case "$1" in
	*://*) ;;
	*) return 1 ;;
	esac
	scheme=$(printf '%s' "${1%%://*}" | tr 'A-Z' 'a-z')
	case " $SEEDEX_URI_SCHEMES " in
	*" $scheme "*) return 0 ;;
	esac
	return 1
}

_uri_decode() {
	printf '%b' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

_uri_b64d() {
	local s
	s=$(printf '%s' "$1" | tr -- '-_' '+/' | tr -d '\n\r= ')
	while [ $((${#s} % 4)) -ne 0 ]; do s="$s="; done
	printf '%s' "$s" | base64 -d 2>/dev/null
}

_uri_q() {
	local v
	v=$(printf '%s\n' "$URI_QUERY" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1)
	_uri_decode "$v"
}

_uri_fail() {
	printf '%s\n' "$*" >&2
	return 1
}

_uri_split() {
	local rest="$1"
	URI_SCHEME=$(printf '%s' "${rest%%://*}" | tr 'A-Z' 'a-z')
	rest="${rest#*://}"
	URI_FRAGMENT=""
	case "$rest" in
	*\#*)
		URI_FRAGMENT=$(_uri_decode "${rest#*#}")
		rest="${rest%%#*}"
		;;
	esac
	URI_QUERY=""
	case "$rest" in
	*\?*)
		URI_QUERY="${rest#*\?}"
		rest="${rest%%\?*}"
		;;
	esac
	rest="${rest%/}"
	URI_USERINFO=""
	case "$rest" in
	*@*)
		URI_USERINFO="${rest%@*}"
		rest="${rest##*@}"
		;;
	esac
	URI_HOSTPORT="$rest"
}

_uri_hostport() {
	case "$1" in
	\[*\]:*)
		URI_HOST="${1%%]*}"
		URI_HOST="${URI_HOST#[}"
		URI_PORT="${1##*:}"
		;;
	*:*)
		URI_HOST="${1%:*}"
		URI_PORT="${1##*:}"
		;;
	*) return 1 ;;
	esac
	[ -n "$URI_HOST" ] || return 1
	case "$URI_PORT" in
	"" | *[!0-9]*) return 1 ;;
	esac
	[ "$URI_PORT" -ge 1 ] && [ "$URI_PORT" -le 65535 ]
}

_uri_bool() {
	case "$1" in
	1 | true | True | TRUE) echo true ;;
	*) echo false ;;
	esac
}

_uri_transport() {
	local type="$1" path="$2" host="$3" service="$4"
	case "$type" in
	"" | tcp | raw) echo null ;;
	ws)
		jq -cn --arg path "${path:-/}" --arg host "$host" \
			'{type: "ws", path: $path} + (if $host != "" then {headers: {Host: $host}} else {} end)'
		;;
	grpc)
		jq -cn --arg s "$service" '{type: "grpc", service_name: $s}'
		;;
	http | h2)
		jq -cn --arg path "${path:-/}" --arg host "$host" \
			'{type: "http", path: $path} + (if $host != "" then {host: ($host | split(","))} else {} end)'
		;;
	*) return 1 ;;
	esac
}

_uri_tls() {
	local enabled="$1" sni="$2" fp="$3" insecure="$4" alpn="$5" pbk="$6" sid="$7"
	jq -cn --arg enabled "$enabled" --arg sni "$sni" --arg fp "$fp" --arg insecure "$insecure" \
		--arg alpn "$alpn" --arg pbk "$pbk" --arg sid "$sid" '
		if $enabled != "true" then null else
		{enabled: true, server_name: $sni}
		+ (if $insecure == "true" then {insecure: true} else {} end)
		+ (if $alpn != "" then {alpn: ($alpn | split(","))} else {} end)
		+ (if $fp != "" then {utls: {enabled: true, fingerprint: $fp}} else {} end)
		+ (if $pbk != "" then {reality: ({enabled: true, public_key: $pbk} + (if $sid != "" then {short_id: $sid} else {} end))} else {} end)
		end'
}

_uri_wrap() {
	local tag="$1" outbound="$2" tls="$3" transport="$4"
	jq -cn --arg tag "$tag" --argjson o "$outbound" --argjson tls "$tls" --argjson t "$transport" '
		{outbounds: [ $o + {tag: $tag}
		  + (if $tls != null then {tls: $tls} else {} end)
		  + (if $t != null then {transport: $t} else {} end) ]}'
}

seedex_uri_name() {
	local name="$URI_FRAGMENT"
	[ -n "$name" ] || name="$URI_SCHEME-$URI_HOST"
	name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//; s/--*/-/g')
	printf '%s\n' "${name:-$URI_SCHEME}"
}

seedex_uri_outbound() {
	local uri="$1" sec sni fp insecure flow type path host service pbk sid tls transport ob decoded
	URI_VMESS=""
	_uri_split "$uri"
	case "$URI_SCHEME" in
	ss | vmess)
		case "$URI_HOSTPORT" in
		*:*) ;;
		*)
			decoded=$(_uri_b64d "$URI_HOSTPORT") || return 1
			[ -n "$decoded" ] || _uri_fail "cannot decode the $URI_SCHEME link" || return 1
			if [ "$URI_SCHEME" = vmess ]; then
				URI_VMESS="$decoded"
			else
				URI_USERINFO="${decoded%@*}"
				URI_HOSTPORT="${decoded##*@}"
			fi
			;;
		esac
		;;
	esac
	if [ "$URI_SCHEME" = vmess ]; then
		[ -n "${URI_VMESS:-}" ] || _uri_fail "vmess links must be base64 of a JSON object" || return 1
		URI_HOSTPORT="$(printf '%s' "$URI_VMESS" | jq -r '"\(.add):\(.port)"' 2>/dev/null)"
	fi
	_uri_hostport "$URI_HOSTPORT" || _uri_fail "no host:port in the link" || return 1

	sni=$(_uri_q sni)
	[ -n "$sni" ] || sni=$(_uri_q host)
	[ -n "$sni" ] || sni="$URI_HOST"
	fp=$(_uri_q fp)
	insecure=$(_uri_bool "$(_uri_q allowInsecure)$(_uri_q insecure)$(_uri_q allow_insecure)")
	type=$(_uri_q type)
	path=$(_uri_q path)
	host=$(_uri_q host)
	service=$(_uri_q serviceName)
	tls=null
	transport=null

	case "$URI_SCHEME" in
	vless)
		[ -n "$URI_USERINFO" ] || _uri_fail "vless link has no uuid" || return 1
		sec=$(_uri_q security)
		flow=$(_uri_q flow)
		pbk=""
		sid=""
		case "$sec" in
		reality)
			pbk=$(_uri_q pbk)
			[ -n "$pbk" ] || _uri_fail "reality link has no pbk (public key)" || return 1
			sid=$(_uri_q sid)
			tls=$(_uri_tls true "$sni" "${fp:-chrome}" false "" "$pbk" "$sid")
			;;
		tls | xtls) tls=$(_uri_tls true "$sni" "${fp:-chrome}" "$insecure" "$(_uri_q alpn)" "" "") ;;
		"" | none) [ -z "$flow" ] || _uri_fail "flow needs security=tls or reality" || return 1 ;;
		*) _uri_fail "unsupported security '$sec'" || return 1 ;;
		esac
		transport=$(_uri_transport "$type" "$path" "$host" "$service") ||
			_uri_fail "unsupported transport '$type'" || return 1
		ob=$(jq -cn --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg uuid "$(_uri_decode "$URI_USERINFO")" --arg flow "$flow" '
			{type: "vless", server: $s, server_port: $p, uuid: $uuid, packet_encoding: "xudp"}
			+ (if $flow != "" then {flow: $flow} else {} end)')
		;;
	trojan)
		[ -n "$URI_USERINFO" ] || _uri_fail "trojan link has no password" || return 1
		sec=$(_uri_q security)
		case "$sec" in
		"" | tls) tls=$(_uri_tls true "$sni" "$fp" "$insecure" "$(_uri_q alpn)" "" "") ;;
		none) ;;
		*) _uri_fail "unsupported security '$sec'" || return 1 ;;
		esac
		transport=$(_uri_transport "$type" "$path" "$host" "$service") ||
			_uri_fail "unsupported transport '$type'" || return 1
		ob=$(jq -cn --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg pw "$(_uri_decode "$URI_USERINFO")" \
			'{type: "trojan", server: $s, server_port: $p, password: $pw}')
		;;
	ss)
		[ -z "$(_uri_q plugin)" ] || _uri_fail "shadowsocks plugins are not supported" || return 1
		decoded=$(_uri_decode "$URI_USERINFO")
		case "$decoded" in
		*:*) ;;
		*)
			decoded=$(_uri_b64d "$URI_USERINFO")
			case "$decoded" in
			*:*) ;;
			*) _uri_fail "cannot read method:password from the ss link" || return 1 ;;
			esac
			;;
		esac
		ob=$(jq -cn --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg m "${decoded%%:*}" --arg pw "${decoded#*:}" \
			'{type: "shadowsocks", server: $s, server_port: $p, method: $m, password: $pw}')
		;;
	vmess)
		local v
		v=$(printf '%s' "$URI_VMESS" | jq -c '{id, aid: (.aid // 0 | tostring), scy: (.scy // "auto"),
			net: (.net // "tcp"), htype: (.type // "none"), host: (.host // ""), path: (.path // ""),
			tls: (.tls // ""), sni: (.sni // ""), fp: (.fp // ""), alpn: (.alpn // ""),
			insecure: ((.allowInsecure // .insecure // false) | tostring), ps: (.ps // "")}' 2>/dev/null) ||
			_uri_fail "vmess link is not valid JSON" || return 1
		[ "$(printf '%s' "$v" | jq -r .id)" != null ] || _uri_fail "vmess link has no id" || return 1
		[ "$(printf '%s' "$v" | jq -r .htype)" = none ] || _uri_fail "vmess header obfuscation is not supported" || return 1
		[ -n "$URI_FRAGMENT" ] || URI_FRAGMENT=$(printf '%s' "$v" | jq -r .ps)
		type=$(printf '%s' "$v" | jq -r .net)
		host=$(printf '%s' "$v" | jq -r .host)
		path=$(printf '%s' "$v" | jq -r .path)
		sni=$(printf '%s' "$v" | jq -r .sni)
		[ -n "$sni" ] || sni="${host:-$URI_HOST}"
		[ "$(printf '%s' "$v" | jq -r .tls)" != tls ] ||
			tls=$(_uri_tls true "$sni" "$(printf '%s' "$v" | jq -r .fp)" \
				"$(_uri_bool "$(printf '%s' "$v" | jq -r .insecure)")" "$(printf '%s' "$v" | jq -r .alpn)" "" "")
		transport=$(_uri_transport "$type" "$path" "$host" "$path") ||
			_uri_fail "unsupported transport '$type'" || return 1
		ob=$(printf '%s' "$v" | jq -c --arg s "$URI_HOST" --argjson p "$URI_PORT" \
			'{type: "vmess", server: $s, server_port: $p, uuid: .id, security: .scy, alter_id: (.aid | tonumber)}')
		;;
	hysteria2 | hy2)
		[ -n "$URI_USERINFO" ] || _uri_fail "hysteria2 link has no password" || return 1
		[ -z "$(_uri_q pinSHA256)" ] || _uri_fail "pinSHA256 is not supported — use insecure=1 or the JSON export" || return 1
		case "$(_uri_q mport)$URI_PORT" in
		*,* | *-*) _uri_fail "port ranges are not supported" || return 1 ;;
		esac
		tls=$(_uri_tls true "$sni" "" "$insecure" "" "" "")
		ob=$(jq -cn --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg pw "$(_uri_decode "$URI_USERINFO")" \
			--arg obfs "$(_uri_q obfs)" --arg opw "$(_uri_q obfs-password)" '
			{type: "hysteria2", server: $s, server_port: $p, password: $pw}
			+ (if $obfs != "" then {obfs: {type: $obfs, password: $opw}} else {} end)')
		;;
	tuic)
		case "$URI_USERINFO" in
		*:*) ;;
		*) _uri_fail "tuic link needs uuid:password" || return 1 ;;
		esac
		tls=$(_uri_tls true "$sni" "" "$insecure" "$(_uri_q alpn)" "" "")
		ob=$(jq -cn --arg s "$URI_HOST" --argjson p "$URI_PORT" \
			--arg uuid "$(_uri_decode "${URI_USERINFO%%:*}")" --arg pw "$(_uri_decode "${URI_USERINFO#*:}")" \
			--arg cc "$(_uri_q congestion_control)" --arg relay "$(_uri_q udp_relay_mode)" '
			{type: "tuic", server: $s, server_port: $p, uuid: $uuid, password: $pw,
			 congestion_control: (if $cc != "" then $cc else "bbr" end)}
			+ (if $relay != "" then {udp_relay_mode: $relay} else {} end)')
		;;
	anytls)
		[ -n "$URI_USERINFO" ] || _uri_fail "anytls link has no password" || return 1
		tls=$(_uri_tls true "$sni" "" "$insecure" "" "" "")
		ob=$(jq -cn --arg s "$URI_HOST" --argjson p "$URI_PORT" --arg pw "$(_uri_decode "$URI_USERINFO")" \
			'{type: "anytls", server: $s, server_port: $p, password: $pw}')
		;;
	*) _uri_fail "unsupported link scheme '$URI_SCHEME'" || return 1 ;;
	esac
	_uri_wrap "$(seedex_uri_name)" "$ob" "$tls" "$transport"
}
