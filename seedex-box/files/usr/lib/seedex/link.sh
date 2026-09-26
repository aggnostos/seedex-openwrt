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
	add | remove | show | select | sync | help) die "'$1' is a link command, pick another name" ;;
	esac
}

_link_curl() {
	local name="$1" path="$2" url token fp
	shift 2
	url=$(uci -q get "seedex-link.$name.url")
	token=$(uci -q get "seedex-link.$name.token")
	fp=$(uci -q get "seedex-link.$name.fingerprint")
	curl -s -k --pinnedpubkey "$fp" -H "Authorization: Bearer $token" "$@" "$url$path"
}

_link_unreachable() {
	local url
	url=$(uci -q get "seedex-link.$1.url")
	if [ "$2" = 90 ]; then
		echo "$url presented a different certificate — if the server was reinstalled, pair again"
	else
		echo "cannot reach $url"
	fi
}

_link_fetch() {
	local name="$1" out="$2" code
	code=$(_link_curl "$name" /v1/configs -o "$out" -w '%{http_code}' --max-time 30 2>/dev/null) || {
		_link_unreachable "$name" $?
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
	[ "$svc" != vpn ] || [ -n "$(uci -q get "seedex-vpn.$sid.proto")" ] ||
		uci set "seedex-vpn.$sid.proto=$(seedex_vpn_detect "$file")"
	if [ -f "$dest" ] && cmp -s "$file" "$dest"; then
		[ -z "$owner" ] && return 0
		return 2
	fi
	cp "$file" "$dest" && chmod 600 "$dest" || return 1
	seedex_config_touch "$svc"
	echo "  ~ $svc $name"
}

_link_sweep() {
	local svc="$1" link="$2" keep="$3" idx=0 sids sid name removed=0
	sids=""
	while sid=$(_section_id_at "seedex-$svc" config "$idx") && [ -n "$sid" ]; do
		sids="$sids $sid"
		idx=$((idx + 1))
	done
	for sid in $sids; do
		[ "$(uci -q get "seedex-$svc.$sid.link")" = "$link" ] || continue
		name=$(uci -q get "seedex-$svc.$sid.name")
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
	case " $selected " in
	"  ") return 1 ;;
	*" * "*) return 0 ;;
	*" $name "*) return 0 ;;
	esac
	return 1
}

_link_offer() {
	local name="$1" tmp payload err svc ext f c
	tmp=$(mktemp -d)
	payload="$tmp/configs.json"
	if ! err=$(_link_fetch "$name" "$payload"); then
		rm -rf "$tmp"
		die "$name: $err"
	fi
	_link_unpack "$payload" "$tmp"
	for svc in vpn proxy; do
		case "$svc" in
		vpn) ext=conf ;;
		*) ext=json ;;
		esac
		for f in "$tmp/$svc"/*."$ext"; do
			[ -f "$f" ] || continue
			c="${f##*/}"
			printf '%s:%s\n' "$svc" "${c%.*}"
		done
	done
	rm -rf "$tmp"
}

_link_pick_draw() {
	local cursor="$1" selected="$2" i=0 item svc name last="" mark pointer
	shift 2
	for item in "$@"; do
		svc="${item%%:*}"
		name="${item#*:}"
		if [ "$svc" != "$last" ]; then
			printf '\033[2K%s:\r\n' "$svc"
			last="$svc"
		fi
		mark=' '
		case " $selected " in
		*" $name "*) mark=x ;;
		esac
		pointer=' '
		[ "$i" = "$cursor" ] && pointer='>'
		printf '\033[2K  %s [%s] %s\r\n' "$pointer" "$mark" "$name"
		i=$((i + 1))
	done
}

_link_pick() {
	local title="$1" selected="$2" cursor=0 count=$# lines key item name svc last=""
	shift 2
	count=$#
	lines=0
	for item in "$@"; do
		svc="${item%%:*}"
		[ "$svc" = "$last" ] || lines=$((lines + 1))
		last="$svc"
		lines=$((lines + 1))
	done
	exec 3<>/dev/tty
	LINK_PICK_STTY=$(stty -g <&3)
	trap '_link_pick_restore; exit 130' INT TERM
	trap _link_pick_restore EXIT
	stty raw -echo <&3
	printf '\033[?25l%s\r\n\r\n' "$title" >&3
	_link_pick_draw "$cursor" "$selected" "$@" >&3
	while :; do
		key=$(dd bs=1 count=1 2>/dev/null <&3)
		case "$key" in
		"$(printf '\033')")
			key=$(dd bs=1 count=2 2>/dev/null <&3)
			case "$key" in
			"[A") key=k ;;
			"[B") key=j ;;
			*) continue ;;
			esac
			;;
		esac
		case "$key" in
		k) [ "$cursor" -gt 0 ] && cursor=$((cursor - 1)) ;;
		j) [ "$cursor" -lt $((count - 1)) ] && cursor=$((cursor + 1)) ;;
		" ")
			i=0
			for item in "$@"; do
				if [ "$i" = "$cursor" ]; then
					name="${item#*:}"
					case " $selected " in
					*" $name "*) selected=$(printf '%s' " $selected " | sed "s/ $name / /; s/^ *//; s/ *$//") ;;
					*) selected="${selected:+$selected }$name" ;;
					esac
				fi
				i=$((i + 1))
			done
			;;
		a)
			selected=""
			for item in "$@"; do selected="${selected:+$selected }${item#*:}"; done
			;;
		n) selected="" ;;
		"" | "$(printf '\r')" | "$(printf '\n')") break ;;
		q | "$(printf '\003')")
			printf '\r\n' >&3
			_link_pick_restore
			trap - EXIT INT TERM
			return 1
			;;
		esac
		printf '\033[%sA' "$lines" >&3
		_link_pick_draw "$cursor" "$selected" "$@" >&3
	done
	printf '\r\n' >&3
	_link_pick_restore
	trap - EXIT INT TERM
	local picked=""
	for item in "$@"; do
		name="${item#*:}"
		case " $selected " in
		*" $name "*) picked="${picked:+$picked }$name" ;;
		esac
	done
	printf '%s\n' "$picked"
}

_link_pick_restore() {
	[ -n "${LINK_PICK_STTY:-}" ] || return 0
	stty "$LINK_PICK_STTY" <&3 2>/dev/null
	printf '\033[?25h' >&3 2>/dev/null
	exec 3>&-
	LINK_PICK_STTY=""
}

_link_pick_or_die() {
	[ -t 0 ] && [ -t 1 ] || die "no terminal — pass the configs by name: sdx link select $1 <config> ... | --all"
	command -v stty >/dev/null 2>&1 || die "stty not found — install the coreutils-stty package"
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
		vpn) kind=vpn ext=conf ;;
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
		[ "$c" != "*" ] || continue
		case " $seen " in
		*" $c "*) ;;
		*) missing=$((missing + 1)) ;;
		esac
	done

	if [ "$changed" = 1 ] && [ "${LINK_NO_APPLY:-0}" = 1 ]; then
		echo "$name: synced; the changes are pending until 'sdx apply'"
	elif [ "$changed" = 1 ]; then
		for svc in vpn proxy; do
			[ -n "$(uci changes "seedex-$svc" 2>/dev/null)" ] || seedex_config_stale "$svc" || continue
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
	local name="$1" url="$2" token="$3" fp="$4" offered
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
	offered=$(_link_offer "$name") || exit $?
	if [ -z "$offered" ]; then
		echo "$name offers no configs yet — add some on the server, then: sdx link select $name"
	elif [ -t 0 ] && [ -t 1 ]; then
		link_select "$name"
	else
		echo "pick the configs to import with: sdx link select $name"
	fi
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
			[ -n "$(uci changes "seedex-$svc" 2>/dev/null)" ] || seedex_config_stale "$svc" || continue
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
	case "$(_link_selected "$name")" in
	"*") echo "Selection: all" ;;
	"") echo "Selection: none (pick with 'sdx link select $name')" ;;
	esac
}

_owner_of() {
	local sid
	sid=$(_find_section_by_name "seedex-$1" config "$2") || return 0
	uci -q get "seedex-$1.$sid.link"
}

link_select() {
	local name="$1" c offered picked
	[ -n "$name" ] || usage "sdx link select <name> [<config> ... | --all]"
	shift
	_link_section "$name"
	if [ $# -eq 0 ]; then
		_link_pick_or_die "$name"
		offered=$(_link_offer "$name") || exit $?
		[ -n "$offered" ] || die "$name offers no configs yet"
		picked=$(_link_selected "$name")
		[ "$picked" = "*" ] && picked=$(printf '%s\n' "$offered" | sed 's/^[^:]*://' | tr '\n' ' ')
		# shellcheck disable=SC2086
		picked=$(_link_pick "$name — space: toggle, enter: confirm, a: all, n: none, q: cancel" "$picked" $offered) || {
			echo "$name: selection unchanged"
			return 0
		}
		# shellcheck disable=SC2086
		set -- $picked
	fi
	uci -q delete "seedex-link.$name.config"
	if [ "${1:-}" = "--all" ]; then
		uci add_list "seedex-link.$name.config=*"
		echo "$name: importing every config"
	else
		for c in "$@"; do
			case "$c" in
			"" | *[!A-Za-z0-9._-]*) die "invalid config name '$c'" ;;
			esac
			uci add_list "seedex-link.$name.config=$c"
		done
		if [ $# -eq 0 ]; then
			echo "$name: importing nothing"
		else
			echo "$name: importing $*"
		fi
	fi
	uci commit seedex-link
	LINK_NO_APPLY=1
	_link_sync_one "$name" || echo "the selection is saved; the next sync will apply it"
}

link_run() {
	local name="$1" tmp code body rc
	shift
	tmp=$(mktemp)
	code=$(jq -n --args '{args: $ARGS.positional}' -- "$@" |
		_link_curl "$name" /v1/run -o "$tmp" -w '%{http_code}' --max-time 130 \
			-H 'Content-Type: application/json' --data-binary @- 2>/dev/null) || {
		rc=$?
		rm -f "$tmp"
		die "$(_link_unreachable "$name" "$rc")"
	}
	body=$(cat "$tmp")
	rm -f "$tmp"
	case "$code" in
	200) ;;
	401) die "$name rejected the token — pair again" ;;
	403) die "$name: $body" ;;
	404) die "$name does not support commands — update seedex-agent" ;;
	*) die "$name answered HTTP $code" ;;
	esac
	printf '%s' "$body" | jq -r '.output // empty | select(length > 0)'
	printf '%s' "$body" | jq -r '.error // empty | select(length > 0)' >&2
	rc=$(printf '%s' "$body" | jq -r '.code // 1')
	if [ "$(printf '%s' "$body" | jq -r '.changed')" = true ]; then
		echo
		_link_sync_one "$name"
	fi
	return "$rc"
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
			"select <name> [<config> ... | --all]     Choose which of them to import (a menu without names)" \
			"sync [<name>]                            Pull configs now (cron does it every 30 minutes)" \
			"<name> [<command> ...]                   Run the server's sdx: status, vpn add, proxy add ..."
		;;
	*)
		uci -q get "seedex-link.$sub" >/dev/null 2>&1 || die "unknown link command: $sub (add, remove, show, select, sync, or a link name)"
		link_run "$sub" "$@"
		;;
	esac
}
