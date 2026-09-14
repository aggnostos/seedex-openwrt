# shellcheck shell=ash
# shellcheck source=files/usr/lib/seedex/service.sh
. /usr/lib/seedex/service.sh

LINK_RUNDIR="$SEEDEX_RUNDIR/link"

_link_section() {
	uci -q get "seedex-link.$1" >/dev/null 2>&1 || die "link '$1' not found"
}

_link_names() {
	uci -q show seedex-link 2>/dev/null | sed -n 's/^seedex-link\.\([^.]*\)=link$/\1/p'
}

_link_check_name() {
	case "$1" in
	"" | *[!A-Za-z0-9._-]* | -*) die "invalid link name '$1' — use letters, digits, dot, dash or underscore" ;;
	esac
}

_link_fetch() {
	local name="$1" out="$2" url token fp code
	url=$(uci -q get "seedex-link.$name.url")
	token=$(uci -q get "seedex-link.$name.token")
	fp=$(uci -q get "seedex-link.$name.fingerprint")
	code=$(curl -s -o "$out" -w '%{http_code}' --max-time 30 -k --pinnedpubkey "$fp" \
		-H "Authorization: Bearer $token" "$url/v1/configs" 2>/dev/null) || {
		echo "cannot reach $url"
		return 1
	}
	case "$code" in
	200) ;;
	401)
		echo "the link rejected the token — pair again"
		return 1
		;;
	*)
		echo "the link answered HTTP $code"
		return 1
		;;
	esac
	jq -e 'type == "object" and (.vpn | type) == "object" and (.proxy | type) == "object"' "$out" >/dev/null 2>&1 || {
		echo "the link answered with something other than configs"
		return 1
	}
}

_link_place() {
	local svc="$1" link="$2" file="$3" kind="$4"
	local name base sid dest reason
	base="${file##*/}"
	name="${base%.*}"
	reason=$(seedex_config_validate "$file" "$kind") || {
		warn "$base from $link: $reason"
		return 1
	}
	sid=$(_find_section_by_name "seedex-$svc" config "$name") || {
		_svc "$svc" --import "$file" >/dev/null || return 1
		sid=$(_find_section_by_name "seedex-$svc" config "$name") || return 1
		uci set "seedex-$svc.$sid.link=$link"
		echo "  + $svc $name"
		return 0
	}
	local owner
	owner=$(uci -q get "seedex-$svc.$sid.link")
	if [ -z "$owner" ]; then
		uci set "seedex-$svc.$sid.link=$link"
		echo "  = $svc $name (now managed by $link)"
	elif [ "$owner" != "$link" ]; then
		warn "$svc config '$name' belongs to $owner, skipping"
		return 1
	fi
	dest=$(uci -q get "seedex-$svc.$sid.config")
	if [ -f "$dest" ] && cmp -s "$file" "$dest"; then
		[ -z "$owner" ] && return 0
		return 2
	fi
	cp "$file" "$dest" && chmod 600 "$dest" || return 1
	echo "  ~ $svc $name"
}

_link_sweep() {
	local svc="$1" link="$2" keep="$3" idx=0 sid name removed=0
	while uci -q get "seedex-$svc.@config[$idx]" >/dev/null 2>&1; do
		sid=$(uci -q show "seedex-$svc.@config[$idx]" | head -1 | cut -d. -f2 | cut -d= -f1)
		name=$(uci -q get "seedex-$svc.$sid.name")
		idx=$((idx + 1))
		[ "$(uci -q get "seedex-$svc.$sid.link")" = "$link" ] || continue
		case " $keep " in
		*" $name "*) continue ;;
		esac
		uci delete "seedex-$svc.$sid"
		echo "  - $svc $name"
		removed=$((removed + 1))
	done
	[ "$removed" -gt 0 ]
}

_link_record() {
	mkdir -p "$LINK_RUNDIR"
	printf '%s %s\n' "$(date +%s)" "$2" >"$LINK_RUNDIR/$1"
}

_link_selected() {
	uci -q get "seedex-link.$1.config" 2>/dev/null
}

_link_wanted() {
	local selected="$1" name="$2"
	[ -z "$selected" ] && return 0
	case " $selected " in
	*" $name "*) return 0 ;;
	esac
	return 1
}

_link_unpack() {
	local payload="$1" tmp="$2" svc ext f
	for svc in vpn proxy; do
		case "$svc" in
		vpn) ext=conf ;;
		*) ext=json ;;
		esac
		mkdir -p "$tmp/$svc"
		jq -r --arg ext ".$ext" ".$svc | keys[] | select(endswith(\$ext))" "$payload" | while IFS= read -r f; do
			case "$f" in
			*/* | .* | "") continue ;;
			esac
			if [ "$svc" = vpn ]; then
				jq -r --arg k "$f" ".vpn[\$k]" "$payload" >"$tmp/$svc/$f"
			else
				jq --arg k "$f" ".proxy[\$k]" "$payload" >"$tmp/$svc/$f"
			fi
		done
	done
}

_link_sync_one() {
	local name="$1" tmp payload changed=0 svc kind ext f keep rc err selected missing=0 seen c
	tmp=$(mktemp -d)
	payload="$tmp/configs.json"
	if ! err=$(_link_fetch "$name" "$payload"); then
		rm -rf "$tmp"
		_link_record "$name" "error: $err"
		warn "$name: $err"
		return 1
	fi
	_link_unpack "$payload" "$tmp"
	selected=$(_link_selected "$name")

	seen=""
	for svc in vpn proxy; do
		case "$svc" in
		vpn) kind=awg ext=conf ;;
		proxy) kind=singbox ext=json ;;
		esac
		keep=""
		for f in "$tmp/$svc"/*."$ext"; do
			[ -f "$f" ] || continue
			c="${f##*/}"
			c="${c%.*}"
			seen="$seen $c"
			_link_wanted "$selected" "$c" || continue
			_link_place "$svc" "$name" "$f" "$kind"
			rc=$?
			[ "$rc" = 1 ] && continue
			[ "$rc" = 0 ] && changed=1
			keep="$keep $c"
		done
		_link_sweep "$svc" "$name" "$keep" && changed=1
	done
	rm -rf "$tmp"
	for c in $selected; do
		case " $seen " in
		*" $c "*) ;;
		*) missing=$((missing + 1)) ;;
		esac
	done

	if [ "$changed" = 1 ]; then
		for svc in vpn proxy; do
			[ -n "$(uci changes "seedex-$svc" 2>/dev/null)" ] || continue
			_svc "$svc" apply >/dev/null
		done
		echo "$name: synced, services restarted"
	else
		echo "$name: up to date"
	fi
	if [ "$missing" -gt 0 ]; then
		_link_record "$name" "synced $missing"
		warn "$name: $missing selected config(s) not offered by the server"
	else
		_link_record "$name" "synced"
	fi
}

_link_host() {
	local url="$1"
	url="${url#*://}"
	url="${url%%/*}"
	case "$url" in
	\[*\]*)
		url="${url#[}"
		url="${url%%]*}"
		;;
	*) url="${url%%:*}" ;;
	esac
	printf '%s\n' "$url"
}

_link_expose() {
	local host ip
	host=$(_link_host "$1")
	nft list table inet seedex_router >/dev/null 2>&1 || return 0
	for ip in $(seedex_resolve "$host" 4) $(seedex_resolve "$host" 6); do
		case "$ip" in
		*:*) nft add element inet seedex_router endpoint_ips6 "{ $ip }" 2>/dev/null ;;
		*) nft add element inet seedex_router endpoint_ips "{ $ip }" 2>/dev/null ;;
		esac
	done
	case "$host" in
	*:*) nft add element inet seedex_router endpoint_ips6 "{ $host }" 2>/dev/null ;;
	*[0-9].[0-9]*) nft add element inet seedex_router endpoint_ips "{ $host }" 2>/dev/null ;;
	esac
}

link_add() {
	local name="$1" url="$2" token="$3" fp="$4"
	[ -n "$name" ] && [ -n "$url" ] && [ -n "$token" ] && [ -n "$fp" ] ||
		usage "sdx link add <name> <url> <token> <fingerprint>"
	_link_check_name "$name"
	case "$url" in
	https://*) ;;
	*) die "the url must start with https://" ;;
	esac
	case "$fp" in
	sha256//*) ;;
	*) die "the fingerprint must look like sha256//..." ;;
	esac
	uci -q get "seedex-link.$name" >/dev/null 2>&1 && die "link '$name' already exists
remove it first with: sdx link remove $name"

	uci set "seedex-link.$name=link"
	uci set "seedex-link.$name.url=${url%/}"
	uci set "seedex-link.$name.token=$token"
	uci set "seedex-link.$name.fingerprint=$fp"
	uci commit seedex-link
	_link_expose "$url"
	echo "added link '$name'"
	_link_sync_one "$name"
}

link_remove() {
	local name="$1" svc changed=0
	[ -n "$name" ] || usage "sdx link remove <name>"
	_link_section "$name"
	for svc in vpn proxy; do
		_link_sweep "$svc" "$name" "" && changed=1
	done
	uci delete "seedex-link.$name"
	uci commit seedex-link
	rm -f "$LINK_RUNDIR/$name"
	if [ "$changed" = 1 ]; then
		for svc in vpn proxy; do
			[ -n "$(uci changes "seedex-$svc" 2>/dev/null)" ] || continue
			_svc "$svc" apply >/dev/null
		done
	fi
	echo "removed link '$name'"
}

link_show() {
	local name="$1" tmp payload err svc ext f c mark any
	[ -n "$name" ] || usage "sdx link show <name>"
	_link_section "$name"
	tmp=$(mktemp -d)
	payload="$tmp/configs.json"
	if ! err=$(_link_fetch "$name" "$payload"); then
		rm -rf "$tmp"
		die "$name: $err"
	fi
	_link_unpack "$payload" "$tmp"
	echo "$name:"
	for svc in vpn proxy; do
		case "$svc" in
		vpn) ext=conf ;;
		*) ext=json ;;
		esac
		any=0
		for f in "$tmp/$svc"/*."$ext"; do
			[ -f "$f" ] || continue
			[ "$any" = 1 ] || echo "  $svc"
			any=1
			c="${f##*/}"
			c="${c%.*}"
			mark=0
			[ "$(_owner_of "$svc" "$c")" = "$name" ] && mark=1
			echo "    $(seedex_mark "$mark") $c"
		done
		[ "$any" = 1 ] || echo "  $svc: none"
	done
	rm -rf "$tmp"
	[ -z "$(_link_selected "$name")" ] && echo "Selection: all (narrow it with 'sdx link select $name <config> ...')"
}

_owner_of() {
	local sid
	sid=$(_find_section_by_name "seedex-$1" config "$2") || return 0
	uci -q get "seedex-$1.$sid.link"
}

link_select() {
	local name="$1" c
	[ $# -ge 2 ] || usage "sdx link select <name> <config> ... | --all"
	shift
	_link_section "$name"
	uci -q delete "seedex-link.$name.config"
	if [ "$1" != "--all" ]; then
		for c in "$@"; do
			case "$c" in
			"" | *[!A-Za-z0-9._-]*) die "invalid config name '$c'" ;;
			esac
			uci add_list "seedex-link.$name.config=$c"
		done
	fi
	uci commit seedex-link
	if [ "$1" = "--all" ]; then
		echo "$name: importing every config"
	else
		echo "$name: importing only $*"
	fi
	_link_sync_one "$name" || echo "the selection is saved; the next sync will apply it"
}

link_sync() {
	local name="$1" n status=0
	if [ -n "$name" ]; then
		_link_section "$name"
		_link_sync_one "$name"
		return
	fi
	for n in $(_link_names); do
		_link_sync_one "$n" || status=1
	done
	return "$status"
}

link_status() {
	local n url state ts when mark n_vpn n_proxy any=0
	for n in $(_link_names); do
		[ "$any" = 1 ] || echo "Link:"
		any=1
		url=$(uci -q get "seedex-link.$n.url")
		mark=0
		when="never synced"
		if [ -f "$LINK_RUNDIR/$n" ]; then
			read -r ts state <"$LINK_RUNDIR/$n"
			when="$((($(date +%s) - ts) / 60)) min ago"
			case "$state" in
			synced) mark=1 ;;
			"synced "*) when="$when, ${state#synced } selected missing" ;;
			error:*) when="$when, ${state#error: }" ;;
			esac
		fi
		n_vpn=$(uci -q show seedex-vpn | grep -c "\.link='$n'")
		n_proxy=$(uci -q show seedex-proxy | grep -c "\.link='$n'")
		printf '  %s %-10s %-32s %s vpn, %s proxy, %s\n' "$(seedex_mark "$mark")" "$n" "$url" "$n_vpn" "$n_proxy" "$when"
	done
	[ "$any" = 1 ] || printf '%-10s none\n' "Link:"
}

cmd_link() {
	local sub="${1:-}"
	[ $# -eq 0 ] || shift
	case "$sub" in
	"") link_status ;;
	add) link_add "$@" ;;
	remove) link_remove "$@" ;;
	sync) link_sync "$@" ;;
	show) link_show "$@" ;;
	select) link_select "$@" ;;
	help | -h | --help)
		usage_block "sdx link <command> [options]" \
			"add <name> <url> <token> <fingerprint>   Pair with a server (the command 'sdx link add' prints)" \
			"remove <name>                            Unpair and drop the configs it delivered" \
			"show <name>                              List the configs the server offers" \
			"select <name> <config> ... | --all       Choose which of them to import" \
			"sync [<name>]                            Pull configs now (cron does it every 30 minutes)"
		;;
	*) die "unknown link command: $sub (add, remove, show, select, sync)" ;;
	esac
}
