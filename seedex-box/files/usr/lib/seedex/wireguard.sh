# shellcheck shell=ash

wg_is_family() {
	grep -qi '^[[:space:]]*\[Interface\]' "$1" 2>/dev/null
}

wg_has_params() {
	grep -qiE '^[[:space:]]*(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5])[[:space:]]*=' "$1"
}

wg_field() {
	local file="$1" key="$2" all="${3:-0}"
	awk -v want="$key" -v all="$all" '
		BEGIN { want = tolower(want) }
		/^[[:space:]]*\[/ { section = tolower($0) }
		{
			line = $0
			sub(/[[:space:]]*#.*$/, "", line)
			if (line !~ /=/) next
			k = line; sub(/[[:space:]]*=.*$/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
			if (tolower(k) != want) next
			v = line; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/[[:space:]]+$/, "", v)
			if (!all) { print v; exit }
			out = out (out == "" ? "" : ",") v
		}
		END { if (all && out != "") print out }' "$file"
}

wg_endpoints() {
	awk '
		tolower($0) ~ /^[[:space:]]*endpoint[[:space:]]*=/ {
			v = substr($0, index($0, "=") + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
			if (v ~ /^\[/) { sub(/^\[/, "", v); sub(/\].*$/, "", v) }
			else sub(/:[0-9]+$/, "", v)
			if (v != "") print v
		}' "$1"
}

# Prints the device a packet toward the host leaves by, with the route's own
# mtu when it sets one. A host name is not resolved here: the encrypted DNS may
# still be starting, so the default route stands in for it.
_wg_route() {
	local host="$1"
	case "$host" in
	*:*) ;;
	*[!0-9.]*) host=1.1.1.1 ;;
	esac
	ip route get "$host" mark "$SEEDEX_WG_FWMARK" 2>/dev/null | awk '
		{ for (i = 1; i < NF; i++) { if ($i == "dev") dev = $(i + 1); if ($i == "mtu") mtu = $(i + 1) } }
		END { if (dev != "") print dev, mtu }'
}

# Picks the tunnel MTU: the config's own option, then the file's MTU, then the
# service setting. auto takes the smallest uplink MTU toward the endpoints less
# 80 bytes of WireGuard over IPv6 and the S4 padding AmneziaWG adds to data.
wg_mtu() {
	local config="$1" name="$2" mtu="$3" fallback="$4" pad host dev route link=""
	[ -n "$mtu" ] || mtu=$(wg_field "$config" MTU)
	[ -n "$mtu" ] || mtu="$fallback"
	case "$mtu" in
	"" | auto) ;;
	*[!0-9]*)
		log_warn "config '$name': mtu '$mtu' is not a number, using auto"
		;;
	*)
		[ "$mtu" -ge 1280 ] || log_warn "config '$name': mtu $mtu is below 1280, IPv6 will not pass"
		echo "$mtu"
		return 0
		;;
	esac

	pad=$(wg_field "$config" S4)
	case "$pad" in "" | *[!0-9]*) pad=0 ;; esac
	for host in $(wg_endpoints "$config"); do
		route=$(_wg_route "$host")
		[ -n "$route" ] || continue
		dev=${route%% *}
		mtu=${route#"$dev"}
		mtu=${mtu# }
		[ -n "$mtu" ] || mtu=$(cat "/sys/class/net/$dev/mtu" 2>/dev/null)
		case "$mtu" in "" | *[!0-9]*) continue ;; esac
		[ -n "$link" ] && [ "$link" -le "$mtu" ] || link="$mtu"
	done
	[ -n "$link" ] || {
		log_debug "config '$name': no route to the endpoint yet, mtu from a 1500 uplink"
		link=1500
	}
	mtu=$((link - 80 - pad))
	[ "$mtu" -ge 1280 ] || mtu=1280
	echo "$mtu"
}

wg_validate() {
	local file="$1"
	wg_is_family "$file" || {
		echo "no [Interface] section"
		return 1
	}
	[ -n "$(wg_field "$file" PrivateKey)" ] || {
		echo "no PrivateKey in [Interface]"
		return 1
	}
	grep -qi '^[[:space:]]*\[Peer\]' "$file" || {
		echo "no [Peer] section"
		return 1
	}
	[ -n "$(wg_field "$file" Endpoint)" ] || {
		echo "no Endpoint in [Peer]"
		return 1
	}
}

wg_up() {
	local tool="$1" link_type="$2" iface="$3" config="$4" name="$5" want="${6:-}" fallback="${7:-}"
	local address mtu staged err one added=0

	command -v "$tool" >/dev/null 2>&1 || {
		log_err "config '$name': $tool not installed"
		return 1
	}
	address=$(wg_field "$config" Address 1)
	[ -n "$address" ] || {
		log_err "config '$name': no Address in '$config'"
		return 1
	}
	mtu=$(wg_mtu "$config" "$name" "$want" "$fallback")

	ip link delete "$iface" 2>/dev/null
	ip link add dev "$iface" type "$link_type" 2>/dev/null || {
		log_err "config '$name': cannot create $link_type interface '$iface'"
		return 1
	}

	staged=$(mktemp)
	sed -E '/^[[:space:]]*[AaMmDdTtPpSs][A-Za-z]*[[:space:]]*=/{
		/^[[:space:]]*([Aa]ddress|[Mm][Tt][Uu]|[Dd][Nn][Ss]|[Tt]able|[Pp]re[UuDd]|[Pp]ost[UuDd]|[Ss]ave[Cc]onfig)/d
	}' "$config" >"$staged"
	if ! err=$("$tool" setconf "$iface" "$staged" 2>&1); then
		err=$(printf '%s' "$err" | tr '\n' ' ')
		log_err "config '$name': $tool setconf failed${err:+: $err}"
		rm -f "$staged"
		ip link delete "$iface" 2>/dev/null
		return 1
	fi
	rm -f "$staged"
	"$tool" set "$iface" fwmark "$SEEDEX_WG_FWMARK"

	for one in $(printf '%s' "$address" | tr ',' ' '); do
		if ip addr add "$one" dev "$iface" 2>/dev/null; then
			added=$((added + 1))
		else
			log_warn "config '$name': cannot add address '$one'"
		fi
	done
	[ "$added" -gt 0 ] || {
		log_err "config '$name': no usable address in '$address'"
		ip link delete "$iface" 2>/dev/null
		return 1
	}
	ip link set "$iface" mtu "$mtu"
	ip link set "$iface" up
	log_debug "config '$name' up on $iface ($link_type, address=$address mtu=$mtu)"
}

wg_down() {
	ip link set "$1" down 2>/dev/null
	ip link delete "$1" 2>/dev/null
}
