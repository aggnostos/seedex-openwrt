# shellcheck shell=ash
SVC_NAME="router"
# shellcheck source=files/usr/lib/seedex/service.sh
. /usr/lib/seedex/service.sh
SVC_SECTION="rule"
SVC_CONFIG_KEYS="default_route kill_switch watchdog_interval watchdog_url watchdog_timeout"

SVC_ACTIONS="start stop restart show add update enable disable remove config changes apply revert export reset"

_reject_ctrl() {
	local nl='
'
	case "$1" in
	*"$(printf '\t')"* | *"$(printf '\r')"* | *"$nl"*)
		die "name must not contain tabs, newlines or carriage returns"
		;;
	esac
}

_check_mac() {
	case "$1" in
	[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ;;
	*) die "not a MAC address: $1 (expected aa:bb:cc:dd:ee:ff)" ;;
	esac
}

_check_client_ip() {
	case "$1" in
	"" | *[!0-9a-fA-F:./]* | */ | /*) die "not an IP address or CIDR: $1" ;;
	*::* | *:*:*:*:*:*:*:*) ;;
	*:*) die "not an IP address or CIDR: $1" ;;
	*[!0-9./]*) die "not an IP address or CIDR: $1" ;;
	*.*.*.*) ;;
	*) die "not an IP address or CIDR: $1" ;;
	esac
}

_check_iface() {
	local name="$1" svc
	for svc in vpn proxy; do
		_find_section_by_name "seedex-$svc" config "$name" >/dev/null 2>&1 && return 0
	done
	die "no vpn or proxy config named '$name' — see 'sdx vpn show' and 'sdx proxy show'"
}

_rule_kind() {
	local path="$1"
	if [ -n "$(uci -q get "${path}.client_mac")$(uci -q get "${path}.client_ip")" ]; then
		echo clients
	elif [ -n "$(uci -q get "${path}.domain")$(uci -q get "${path}.ip")$(uci -q get "${path}.list_url")$(uci -q get "${path}.list_path")" ]; then
		echo destinations
	fi
}

_rule_kind_allows() {
	local path="$1" want="$2" have
	have=$(_rule_kind "$path")
	[ -z "$have" ] || [ "$have" = "$want" ] ||
		die "a rule matches either clients (client_mac=, client_ip=) or destinations (domain=, ip=, list_*), not both"
}

_rule_list() {
	local path="$1" key="$2" op="$3" values="$4" v label adds=0
	[ "$op" = del ] || [ -z "$values" ] || adds=1
	case "$key" in
	client_mac | client_ip)
		[ "$adds" = 0 ] || {
			_rule_kind_allows "$path" clients
			[ "$(uci -q get "${path}.type")" != block ] || die "block rules match destinations, not clients"
		}
		;;
	*) [ "$adds" = 0 ] || _rule_kind_allows "$path" destinations ;;
	esac
	[ "$op" != set ] || uci -q delete "${path}.${key}"
	for v in $(printf '%s' "$values" | tr ',' ' '); do
		case "$key" in
		client_mac)
			_check_mac "$v"
			v=$(echo "$v" | tr 'A-F' 'a-f')
			;;
		client_ip) _check_client_ip "$v" ;;
		esac
		if [ "$op" = del ]; then
			uci del_list "${path}.${key}=${v}"
			echo "  - $key '$v'"
		else
			uci add_list "${path}.${key}=${v}"
			echo "  + $key '$v'"
		fi
	done
	[ "$op" != set ] || [ -n "$values" ] || echo "  - all ${key}s"
	changes=$((changes + 1))
}

_router_entry() {
	local subcmd="$1"
	shift

	case "$subcmd" in
	show)
		if [ $# -gt 1 ]; then
			local ref first=1
			for ref in "$@"; do
				[ "$first" = 1 ] || echo
				first=0
				_router_entry show "$ref"
			done
			return 0
		fi
		local idx="$1"
		if [ -z "$idx" ]; then
			printf "    %-4s %-20s %-7s %s\n" "#" "NAME" "TYPE" "SOURCE"

			idx=0
			while uci -q get "seedex-router.@rule[$idx]" >/dev/null 2>&1; do
				local name type enabled list_url list_path pin
				name=$(uci -q get "seedex-router.@rule[$idx].name")
				type=$(uci -q get "seedex-router.@rule[$idx].type")
				pin=$(uci -q get "seedex-router.@rule[$idx].iface")
				enabled=$(uci -q get "seedex-router.@rule[$idx].enabled")
				list_url=$(uci -q get "seedex-router.@rule[$idx].list_url")
				list_path=$(uci -q get "seedex-router.@rule[$idx].list_path")

				local state="[ ]"
				[ "$enabled" = "1" ] && state="[*]"

				local source=""
				local domains ips clients dcount=0 icount=0 ccount=0
				domains=$(uci -q get "seedex-router.@rule[$idx].domain" 2>/dev/null)
				ips=$(uci -q get "seedex-router.@rule[$idx].ip" 2>/dev/null)
				clients="$(uci -q get "seedex-router.@rule[$idx].client_mac" 2>/dev/null) $(uci -q get "seedex-router.@rule[$idx].client_ip" 2>/dev/null)"
				if [ -n "$domains" ]; then
					for _d in $domains; do dcount=$((dcount + 1)); done
				fi
				if [ -n "$ips" ]; then
					for _i in $ips; do icount=$((icount + 1)); done
				fi
				for _c in $clients; do ccount=$((ccount + 1)); done

				if [ "$ccount" -gt 0 ]; then
					source="${ccount} client(s)"
				elif [ "$dcount" -gt 0 ] || [ "$icount" -gt 0 ]; then
					source="${dcount}d/${icount}ip"
				fi
				if [ -n "$list_url" ]; then
					local url_short="$list_url"
					[ ${#list_url} -gt 40 ] && url_short="$(echo "$list_url" | cut -c1-37)..."
					source="${source:+${source} + }url: $url_short"
				fi
				if [ -n "$list_path" ]; then
					source="${source:+${source} + }path: $list_path"
				fi
				[ -z "$source" ] && source="(empty)"

				[ -z "$pin" ] || type="$pin"
				printf "%s %-4s %-20s %-7s %s\n" "$state" "$idx" "${name:--}" "$type" "$source"
				idx=$((idx + 1))
			done
			return 0
		fi
		local path
		path=$(_section_at seedex-router rule rule "$idx" "router show") || exit $?

		local rname enabled
		rname=$(uci -q get "${path}.name")
		enabled=$(uci -q get "${path}.enabled")
		field "Name:" "${rname:-${path#*.}}"
		field "State:" "$([ "$enabled" = "1" ] && echo "[*]" || echo "[ ]")"
		section "Config:"

		local rkey rval
		uci -N -q show "$path" 2>/dev/null | while IFS='=' read -r rkey rval; do
			rkey="${rkey##*.}"
			case "$rkey" in
			name | enabled) continue ;;
			esac
			echo "  ${rkey}=${rval}"
		done
		;;

	add)
		local name="$1"
		[ -n "$name" ] || usage "sdx router add <name> type=direct|overlay|block [iface=<config>] [...]"
		_reject_ctrl "$name"
		shift

		local type="" iface_name="" list_url="" list_path="" list_refresh=""
		local add_domains="" add_ips="" add_macs="" add_clients="" v

		for arg in "$@"; do
			case "$arg" in
			type=*) type="${arg#*=}" ;;
			iface=*) iface_name="${arg#*=}" ;;
			domain=*) add_domains="${add_domains} $(printf '%s' "${arg#*=}" | tr ',' ' ')" ;;
			ip=*) add_ips="${add_ips} $(printf '%s' "${arg#*=}" | tr ',' ' ')" ;;
			client_mac=*)
				for v in $(printf '%s' "${arg#*=}" | tr ',' ' '); do
					_check_mac "$v"
					add_macs="${add_macs} $(echo "$v" | tr 'A-F' 'a-f')"
				done
				;;
			client_ip=*)
				for v in $(printf '%s' "${arg#*=}" | tr ',' ' '); do
					_check_client_ip "$v"
					add_clients="${add_clients} $v"
				done
				;;
			list_url=*) list_url="${arg#*=}" ;;
			list_path=*) list_path="${arg#*=}" ;;
			list_refresh=*) list_refresh="${arg#*=}" ;;
			*)
				die "unknown param: $arg"
				;;
			esac
		done

		[ -z "$add_macs$add_clients" ] || [ -z "$add_domains$add_ips$list_url$list_path" ] ||
			die "a rule matches either clients (client_mac=, client_ip=) or destinations (domain=, ip=, list_*), not both"

		[ -z "$iface_name" ] || {
			_check_iface "$iface_name"
			[ -z "$type" ] || [ "$type" = overlay ] || die "iface= pins the rule to a tunnel, so its type is overlay"
			type=overlay
		}
		[ -n "$type" ] || die "type is required: direct, overlay or block"
		case "$type" in
		direct | overlay | block) ;;
		*)
			die "type must be 'direct', 'overlay' or 'block'"
			;;
		esac
		[ "$type" != block ] || [ -z "$add_macs$add_clients" ] || die "block rules match destinations, not clients"

		local sid existing
		sid=$(_uci_sanitize_id "$name")

		existing=$(uci -q get "seedex-router.${sid}.name" 2>/dev/null)
		if [ -n "$existing" ]; then
			die "rule '$existing' already occupies the UCI id '$sid'
use 'sdx router update' to change it, or pick another name"
		fi

		uci set "seedex-router.${sid}=rule" || die "cannot create UCI section '$sid'"
		uci set "seedex-router.${sid}.name=${name}"
		uci set "seedex-router.${sid}.type=${type}"
		uci set "seedex-router.${sid}.enabled=1"
		_uci_set_if "seedex-router.${sid}" iface "$iface_name"
		_uci_set_if "seedex-router.${sid}" list_url "$list_url"
		_uci_set_if "seedex-router.${sid}" list_path "$list_path"
		_uci_set_if "seedex-router.${sid}" list_refresh "$list_refresh"

		for d in $add_domains; do
			uci add_list "seedex-router.${sid}.domain=${d}"
		done
		for ip in $add_ips; do
			uci add_list "seedex-router.${sid}.ip=${ip}"
		done
		for m in $add_macs; do
			uci add_list "seedex-router.${sid}.client_mac=${m}"
		done
		for m in $add_clients; do
			uci add_list "seedex-router.${sid}.client_ip=${m}"
		done

		log_debug "router: added rule '$name' (type=$type)"
		echo "added rule '$name' (type=$type)"
		;;

	update)
		local idx="$1"
		shift
		local path
		path=$(_section_at seedex-router rule rule "$idx" "router update") || exit $?

		[ $# -gt 0 ] || die "no actions specified"
		local changes=0
		for arg in "$@"; do
			case "$arg" in
			domain=* | ip=* | client_mac=* | client_ip=*)
				_rule_list "$path" "${arg%%=*}" set "${arg#*=}"
				;;
			add-domain=* | add-ip=* | add-client_mac=* | add-client_ip=*)
				arg="${arg#add-}"
				_rule_list "$path" "${arg%%=*}" add "${arg#*=}"
				;;
			del-domain=* | del-ip=* | del-client_mac=* | del-client_ip=*)
				arg="${arg#del-}"
				_rule_list "$path" "${arg%%=*}" del "${arg#*=}"
				;;
			name=*)
				_reject_ctrl "${arg#*=}"
				uci set "${path}.name=${arg#*=}"
				echo "  name → ${arg#*=}"
				changes=$((changes + 1))
				;;
			iface=*)
				local newiface="${arg#*=}"
				if [ -z "$newiface" ]; then
					uci -q delete "${path}.iface"
					echo "  iface → (none)"
				else
					_check_iface "$newiface"
					uci set "${path}.iface=${newiface}"
					echo "  iface → $newiface"
					[ "$(uci -q get "${path}.type")" = overlay ] || {
						uci set "${path}.type=overlay"
						echo "  type → overlay"
					}
				fi
				changes=$((changes + 1))
				;;
			type=*)
				local newtype="${arg#*=}"
				case "$newtype" in
				direct | overlay | block) ;;
				*)
					die "type must be 'direct', 'overlay' or 'block'"
					;;
				esac
				[ "$newtype" != block ] || [ -z "$(uci -q get "${path}.client_mac")$(uci -q get "${path}.client_ip")" ] ||
					die "block rules match destinations, not clients"
				[ "$newtype" = overlay ] || [ -z "$(uci -q get "${path}.iface")" ] ||
					die "the rule is pinned to '$(uci -q get "${path}.iface")' — clear it with iface= first"
				uci set "${path}.type=${newtype}"
				echo "  type → $newtype"
				changes=$((changes + 1))
				;;
			list_url=*)
				_rule_kind_allows "$path" destinations
				uci set "${path}.list_url=${arg#*=}"
				echo "  list_url → ${arg#*=}"
				changes=$((changes + 1))
				;;
			list_path=*)
				_rule_kind_allows "$path" destinations
				uci set "${path}.list_path=${arg#*=}"
				echo "  list_path → ${arg#*=}"
				changes=$((changes + 1))
				;;
			list_refresh=*)
				uci set "${path}.list_refresh=${arg#*=}"
				echo "  list_refresh → ${arg#*=}"
				changes=$((changes + 1))
				;;
			list-url=*)
				_rule_kind_allows "$path" destinations
				uci set "${path}.list_url=${arg#*=}"
				echo "  list_url → ${arg#*=}"
				changes=$((changes + 1))
				;;
			del-url)
				if uci -q get "${path}.list_url" >/dev/null 2>&1; then
					uci delete "${path}.list_url" 2>/dev/null
					echo "  - list_url"
					changes=$((changes + 1))
				fi
				;;
			list-path=*)
				_rule_kind_allows "$path" destinations
				uci set "${path}.list_path=${arg#*=}"
				echo "  list_path → ${arg#*=}"
				changes=$((changes + 1))
				;;
			del-path)
				if uci -q get "${path}.list_path" >/dev/null 2>&1; then
					uci delete "${path}.list_path" 2>/dev/null
					echo "  - list_path"
					changes=$((changes + 1))
				fi
				;;
			list-refresh=*)
				uci set "${path}.list_refresh=${arg#*=}"
				echo "  list_refresh → ${arg#*=}"
				changes=$((changes + 1))
				;;
			del-refresh)
				if uci -q get "${path}.list_refresh" >/dev/null 2>&1; then
					uci delete "${path}.list_refresh" 2>/dev/null
					echo "  - list_refresh"
					changes=$((changes + 1))
				fi
				;;
			*)
				die "unknown action: $arg"
				;;
			esac
		done

		if [ "$changes" -gt 0 ]; then
			log_debug "router: updated rule #$idx ($changes change(s))"
			echo "rule #$idx updated ($changes change(s))"
		fi
		;;

	enable)
		_section_set_enabled seedex-router rule rule "router enable" 1 "$@"
		;;

	disable)
		_section_set_enabled seedex-router rule rule "router disable" 0 "$@"
		;;

	remove)
		_section_remove seedex-router rule rule "router remove" "$@"
		;;

	esac
}

svc_export() {
	local idx=0 name type enabled url lpath refresh domains ips macs clients iface
	{
		while uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx]" >/dev/null 2>&1; do
			name=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].name")
			type=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].type")
			enabled=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].enabled")
			url=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].list_url")
			lpath=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].list_path")
			refresh=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].list_refresh")
			domains=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].domain")
			ips=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].ip")
			macs=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].client_mac")
			clients=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].client_ip")
			iface=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].iface")
			idx=$((idx + 1))

			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$name" "$type" "$enabled" "$url" "$lpath" "$refresh" \
				"$domains" "$ips" "$macs" "$clients" "$iface"
		done
	} | jq -R -s '
		def words: split(" ") | map(select(length > 0));
		[ split("\n")[] | select(length > 0) | split("\t") as $f |
		    { name: $f[0], type: $f[1], enabled: ($f[2] != "0") }
		  + (if $f[10] != "" then { iface: $f[10] } else {} end)
		  + (if $f[3] != "" then { list_url: $f[3] } else {} end)
		  + (if $f[4] != "" then { list_path: $f[4] } else {} end)
		  + (if $f[5] != "" then { list_refresh: $f[5] } else {} end)
		  + (if $f[8] != "" or $f[9] != ""
		     then { client_mac: ($f[8] | words), client_ip: ($f[9] | words) }
		     else { domain: ($f[6] | words), ip: ($f[7] | words) } end) ]'
}

_import_check() {
	local file="$1" bad v name sid existing
	bad=$(jq -r '.[]?
		| select(((.client_mac // []) + (.client_ip // []) | length) > 0)
		| select(((.domain // []) + (.ip // []) | length) > 0 or (.list_url // "") != "" or (.list_path // "") != "")
		| .name' "$file" | tr '\n' ' ')
	[ -z "$bad" ] || die "a rule matches either clients or destinations, not both: ${bad% }"
	bad=$(jq -r '.[]? | select(.type == "block" and ((.client_mac // []) + (.client_ip // []) | length) > 0) | .name' "$file" | tr '\n' ' ')
	[ -z "$bad" ] || die "block rules match destinations, not clients: ${bad% }"
	bad=$(jq -r '.[]? | .name' "$file" | while IFS= read -r name; do
		printf '%s %s\n' "$(_uci_sanitize_id "$name")" "$name"
	done | awk -v q="'" '{
		id = $1; sub(/^[^ ]* /, "")
		names[id] = names[id] (cnt[id]++ ? ", " : "") q $0 q
	} END { for (id in cnt) if (cnt[id] > 1) print names[id] }')
	[ -z "$bad" ] || die "these rule names map to one UCI id, rename all but one: $bad"
	for v in $(jq -r '.[]? | .client_mac[]?' "$file"); do
		_check_mac "$v"
	done
	for v in $(jq -r '.[]? | .client_ip[]?' "$file"); do
		_check_client_ip "$v"
	done
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		sid=$(_uci_sanitize_id "$name")
		existing=$(uci -q get "${SVC_ID}.${sid}.name")
		[ -z "$existing" ] || [ "$existing" = "$name" ] ||
			die "rule '$name' collides with the existing rule '$existing' (both are UCI id '$sid')"
	done <<EOF
$(jq -r '.[]? | .name' "$file")
EOF
}

svc_import_file() {
	local file="$1" tab sep records pinned
	local name type enabled url lpath refresh domains ips macs clients iface sid d verb
	tab=$(printf '\t')
	sep=$(printf '\037')

	records=$(jq -r '
		def f($v): (($v // "") | tostring);
		.[]? |
		[ f(.name), f(.type),
		  (if .enabled == false then "0" else "1" end),
		  f(.list_url), f(.list_path), f(.list_refresh),
		  ((.domain // []) | map(tostring) | join(" ")),
		  ((.ip // []) | map(tostring) | join(" ")),
		  ((.client_mac // []) | map(tostring) | join(" ")),
		  ((.client_ip // []) | map(tostring) | join(" ")),
		  f(.iface) ] | @tsv
	' "$file" 2>/dev/null) || die "cannot parse '$file' — not a valid rules export"
	pinned=$(jq -r '.[]? | select((.iface // "") != "" and .type != "overlay") | .name' "$file" | tr '\n' ' ')
	[ -z "$pinned" ] || die "iface= pins a rule to a tunnel, so its type is overlay: ${pinned% }"
	_import_check "$file"

	# Refuse the whole file before touching anything, so an import never
	# leaves half of its rules applied.
	local taken="" taken_file
	taken_file=$(mktemp)
	printf '%s\n' "$records" | tr "$tab" "$sep" |
		while IFS="$sep" read -r name type enabled url lpath refresh domains ips macs clients iface; do
			[ -n "$name" ] || continue
			_find_section_by_name "$SVC_ID" "$SVC_SECTION" "$name" >/dev/null || continue
			printf '%s\n' "$name"
		done >"$taken_file"
	taken=$(tr '\n' ' ' <"$taken_file")
	rm -f "$taken_file"
	if [ -n "$(printf '%s' "$taken" | tr -d ' ')" ] && [ "${SEEDEX_IMPORT_FORCE:-0}" != 1 ]; then
		die "these rule names are already used:$(printf '%s' " $taken" | sed 's/ *$//')
replace them with 'sdx import --force', or remove them with 'sdx router remove'"
	fi

	printf '%s\n' "$records" | tr "$tab" "$sep" |
		while IFS="$sep" read -r name type enabled url lpath refresh domains ips macs clients iface; do
			[ -n "$name" ] || continue
			sid=$(_uci_sanitize_id "$name")
			verb="added"
			case " $taken " in
			*" $name "*) verb="replaced" ;;
			esac

			uci set "${SVC_ID}.${sid}=${SVC_SECTION}"
			uci set "${SVC_ID}.${sid}.name=${name}"
			uci set "${SVC_ID}.${sid}.type=${type}"
			uci set "${SVC_ID}.${sid}.enabled=${enabled}"

			for d in list_url list_path list_refresh domain ip client_mac client_ip iface; do
				uci -q delete "${SVC_ID}.${sid}.${d}"
			done
			_uci_set_if "${SVC_ID}.${sid}" iface "$iface"
			_uci_set_if "${SVC_ID}.${sid}" list_url "$url"
			_uci_set_if "${SVC_ID}.${sid}" list_path "$lpath"
			_uci_set_if "${SVC_ID}.${sid}" list_refresh "$refresh"

			for d in $domains; do
				uci add_list "${SVC_ID}.${sid}.domain=${d}"
			done
			for d in $ips; do
				uci add_list "${SVC_ID}.${sid}.ip=${d}"
			done
			for d in $(printf '%s' "$macs" | tr 'A-F' 'a-f'); do
				uci add_list "${SVC_ID}.${sid}.client_mac=${d}"
			done
			for d in $clients; do
				uci add_list "${SVC_ID}.${sid}.client_ip=${d}"
			done

			echo "$verb rule '$name' (type=$type)"
		done
}

svc_status() {
	local mode kill winterval idx name type pin enabled url lpath domains clients n src
	seedex_status_header router "Router"
	mode=$(uci -q get seedex-router.main.default_route)
	winterval=$(uci -q get seedex-router.main.watchdog_interval)
	kill=$(uci -q get seedex-router.main.kill_switch)
	printf '  %-13s %s\n' "Routing:" "${mode:-overlay}"
	printf '  %-13s %s\n' "Kill switch:" "$([ "${kill:-1}" = 0 ] && echo off || echo on)"
	printf '  %-13s every %ss\n' "Watchdog:" "${winterval:-30}"
	if ! uci -q get "seedex-router.@rule[0]" >/dev/null 2>&1; then
		printf '  %-13s none\n' "Rules:"
		return 0
	fi
	echo "  Rules:"
	idx=0
	while uci -q get "seedex-router.@rule[$idx]" >/dev/null 2>&1; do
		name=$(uci -q get "seedex-router.@rule[$idx].name")
		type=$(uci -q get "seedex-router.@rule[$idx].type")
		pin=$(uci -q get "seedex-router.@rule[$idx].iface")
		[ -z "$pin" ] || type="$pin"
		enabled=$(uci -q get "seedex-router.@rule[$idx].enabled")
		url=$(uci -q get "seedex-router.@rule[$idx].list_url")
		lpath=$(uci -q get "seedex-router.@rule[$idx].list_path")
		domains=$(uci -q get "seedex-router.@rule[$idx].domain")
		clients="$(uci -q get "seedex-router.@rule[$idx].client_mac") $(uci -q get "seedex-router.@rule[$idx].client_ip")"
		n=0
		for _ in $domains; do n=$((n + 1)); done
		src=""
		[ "$n" -eq 0 ] || src="$n domains"
		[ -z "$url$lpath" ] || src="${src:+$src + }list"
		n=0
		for _ in $clients; do n=$((n + 1)); done
		[ "$n" -eq 0 ] || src="$n clients"
		printf '    %s %-18s %-16s %s\n' "$(seedex_mark "$([ "$enabled" = 1 ] && echo 1 || echo 0)")" \
			"${name:-#$idx}" "$type" "$src"
		idx=$((idx + 1))
	done
}

svc_help() {
	cat <<EOF
start	Start the service
stop	Stop the service
restart	Restart the service
show [#|name ...]	List entries, or show some	List rules, or show the named ones with all their fields
add <name> k=v ...	Add a rule	Add a rule: type=direct|overlay|block, then domain=a,b ip= list_url= list_path= or client_mac= client_ip=; iface=<config> sends it through that tunnel
update <#|name> k=v ...	Modify an entry	Modify a rule: type= name= iface= list_*=; lists: domain=a,b replaces, add-domain= adds, del-domain= removes (same for ip, client_mac, client_ip)
enable [#|name ...]	Enable the service or entries	Enable the service, or the named rules
disable [#|name ...]	Disable the service or entries	Disable the service (also at boot), or the named rules
remove <#|name ...>	Remove entries	Remove rules
config	Manage service settings	Manage service settings: show, get <key>, set k=v ...
changes	Show pending UCI changes
apply	Save pending changes and restart
revert	Revert pending UCI changes
export	Print the configuration; restore it with 'sdx import'
reset	Drop every entry and its stored data
EOF
}

svc_dispatch() {
	local action="$1"
	shift

	case "$action" in
	enable | disable)
		if [ $# -eq 0 ]; then
			"svc_$action"
		else
			_router_entry "$action" "$@"
		fi
		;;
	show | add | update | remove) _router_entry "$action" "$@" ;;
	start) svc_start ;;
	status) svc_status ;;
	stop) svc_stop ;;
	restart) svc_restart ;;
	changes) svc_changes ;;
	apply) svc_apply ;;
	revert) svc_revert ;;
	config) svc_config "$@" ;;
	export) svc_export ;;
	reset) svc_reset ;;
	*) return 127 ;;
	esac
}
