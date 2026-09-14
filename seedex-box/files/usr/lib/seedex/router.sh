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

_rule_kind() {
	local path="$1"
	if [ -n "$(uci -q get "${path}.mac")" ]; then
		echo clients
	elif [ -n "$(uci -q get "${path}.domain")$(uci -q get "${path}.ip")$(uci -q get "${path}.list_url")$(uci -q get "${path}.list_path")" ]; then
		echo destinations
	fi
}

_rule_kind_allows() {
	local path="$1" want="$2" have
	have=$(_rule_kind "$path")
	[ -z "$have" ] || [ "$have" = "$want" ] ||
		die "a rule matches either clients (mac=) or destinations (domain=, ip=, list_*), not both"
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
			printf "    %-4s %-20s %-5s %s\n" "#" "NAME" "TYPE" "SOURCE"

			idx=0
			while uci -q get "seedex-router.@rule[$idx]" >/dev/null 2>&1; do
				local name type enabled list_url list_path
				name=$(uci -q get "seedex-router.@rule[$idx].name")
				type=$(uci -q get "seedex-router.@rule[$idx].type")
				enabled=$(uci -q get "seedex-router.@rule[$idx].enabled")
				list_url=$(uci -q get "seedex-router.@rule[$idx].list_url")
				list_path=$(uci -q get "seedex-router.@rule[$idx].list_path")

				local state="[ ]"
				[ "$enabled" = "1" ] && state="[*]"

				local source=""
				local domains ips clients dcount=0 icount=0 ccount=0
				domains=$(uci -q get "seedex-router.@rule[$idx].domain" 2>/dev/null)
				ips=$(uci -q get "seedex-router.@rule[$idx].ip" 2>/dev/null)
				clients=$(uci -q get "seedex-router.@rule[$idx].mac" 2>/dev/null)
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

				printf "%s %-4s %-20s %-5s %s\n" "$state" "$idx" "${name:--}" "$type" "$source"
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
		[ -n "$name" ] || usage "sdx router add <name> type=direct|overlay [...]"
		_reject_ctrl "$name"
		shift

		local type="" list_url="" list_path="" list_refresh=""
		local add_domains="" add_ips="" add_macs=""

		for arg in "$@"; do
			case "$arg" in
			type=*) type="${arg#*=}" ;;
			domain=*) add_domains="${add_domains} ${arg#*=}" ;;
			ip=*) add_ips="${add_ips} ${arg#*=}" ;;
			mac=*)
				_check_mac "${arg#*=}"
				add_macs="${add_macs} $(echo "${arg#*=}" | tr 'A-F' 'a-f')"
				;;
			list_url=*) list_url="${arg#*=}" ;;
			list_path=*) list_path="${arg#*=}" ;;
			list_refresh=*) list_refresh="${arg#*=}" ;;
			*)
				die "unknown param: $arg"
				;;
			esac
		done

		[ -z "$add_macs" ] || [ -z "$add_domains$add_ips$list_url$list_path" ] ||
			die "a rule matches either clients (mac=) or destinations (domain=, ip=, list_*), not both"

		[ -n "$type" ] || die "type is required: direct, overlay or block"
		case "$type" in
		direct | overlay | block) ;;
		*)
			die "type must be 'direct', 'overlay' or 'block'"
			;;
		esac
		[ "$type" != block ] || [ -z "$add_macs" ] || die "block rules match destinations, not clients"

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
			uci add_list "seedex-router.${sid}.mac=${m}"
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
			mac=*)
				_check_mac "${arg#*=}"
				_rule_kind_allows "$path" clients
				[ "$(uci -q get "${path}.type")" != block ] || die "block rules match destinations, not clients"
				uci add_list "${path}.mac=$(echo "${arg#*=}" | tr 'A-F' 'a-f')"
				echo "  + mac '${arg#*=}'"
				changes=$((changes + 1))
				;;
			del-mac=*)
				uci del_list "${path}.mac=$(echo "${arg#*=}" | tr 'A-F' 'a-f')"
				echo "  - mac '${arg#*=}'"
				changes=$((changes + 1))
				;;
			clear-macs)
				uci delete "${path}.mac" 2>/dev/null
				echo "  - all macs"
				changes=$((changes + 1))
				;;
			add-domain=*)
				_rule_kind_allows "$path" destinations
				uci add_list "${path}.domain=${arg#*=}"
				echo "  + domain '${arg#*=}'"
				changes=$((changes + 1))
				;;
			del-domain=*)
				uci del_list "${path}.domain=${arg#*=}"
				echo "  - domain '${arg#*=}'"
				changes=$((changes + 1))
				;;
			add-ip=*)
				_rule_kind_allows "$path" destinations
				uci add_list "${path}.ip=${arg#*=}"
				echo "  + ip '${arg#*=}'"
				changes=$((changes + 1))
				;;
			del-ip=*)
				uci del_list "${path}.ip=${arg#*=}"
				echo "  - ip '${arg#*=}'"
				changes=$((changes + 1))
				;;
			name=*)
				_reject_ctrl "${arg#*=}"
				uci set "${path}.name=${arg#*=}"
				echo "  name → ${arg#*=}"
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
				[ "$newtype" != block ] || [ -z "$(uci -q get "${path}.mac")" ] ||
					die "block rules match destinations, not clients"
				uci set "${path}.type=${newtype}"
				echo "  type → $newtype"
				changes=$((changes + 1))
				;;
			domain=*)
				_rule_kind_allows "$path" destinations
				uci add_list "${path}.domain=${arg#*=}"
				echo "  + domain '${arg#*=}'"
				changes=$((changes + 1))
				;;
			ip=*)
				_rule_kind_allows "$path" destinations
				uci add_list "${path}.ip=${arg#*=}"
				echo "  + ip '${arg#*=}'"
				changes=$((changes + 1))
				;;
			clear-domains)
				uci delete "${path}.domain" 2>/dev/null
				echo "  - all domains"
				changes=$((changes + 1))
				;;
			clear-ips)
				uci delete "${path}.ip" 2>/dev/null
				echo "  - all ips"
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
	local idx=0 name type enabled url lpath refresh domains ips macs
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
			macs=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].mac")
			idx=$((idx + 1))

			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$name" "$type" "$enabled" "$url" "$lpath" "$refresh" \
				"$domains" "$ips" "$macs"
		done
	} | jq -R -s '
		def words: split(" ") | map(select(length > 0));
		[ split("\n")[] | select(length > 0) | split("\t") as $f |
		    { name: $f[0], type: $f[1], enabled: ($f[2] != "0") }
		  + (if $f[3] != "" then { list_url: $f[3] } else {} end)
		  + (if $f[4] != "" then { list_path: $f[4] } else {} end)
		  + (if $f[5] != "" then { list_refresh: $f[5] } else {} end)
		  + (if $f[8] != ""
		     then { mac: ($f[8] | words) }
		     else { domain: ($f[6] | words), ip: ($f[7] | words) } end) ]'
}

svc_import_file() {
	local file="$1" tab sep records
	local name type enabled url lpath refresh domains ips macs sid d
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
		  ((.mac // []) | map(tostring) | join(" ")) ] | @tsv
	' "$file" 2>/dev/null) || die "cannot parse '$file' — not a valid rules export"

	printf '%s\n' "$records" | tr "$tab" "$sep" |
		while IFS="$sep" read -r name type enabled url lpath refresh domains ips macs; do
			[ -n "$name" ] || continue
			sid=$(_uci_sanitize_id "$name")

			uci set "${SVC_ID}.${sid}=${SVC_SECTION}"
			uci set "${SVC_ID}.${sid}.name=${name}"
			uci set "${SVC_ID}.${sid}.type=${type}"
			uci set "${SVC_ID}.${sid}.enabled=${enabled}"

			for d in list_url list_path list_refresh domain ip mac; do
				uci -q delete "${SVC_ID}.${sid}.${d}"
			done
			_uci_set_if "${SVC_ID}.${sid}" list_url "$url"
			_uci_set_if "${SVC_ID}.${sid}" list_path "$lpath"
			_uci_set_if "${SVC_ID}.${sid}" list_refresh "$refresh"

			for d in $domains; do
				uci add_list "${SVC_ID}.${sid}.domain=${d}"
			done
			for d in $ips; do
				uci add_list "${SVC_ID}.${sid}.ip=${d}"
			done
			for d in $macs; do
				uci add_list "${SVC_ID}.${sid}.mac=${d}"
			done

			echo "added rule '$name' (type=$type)"
		done
}

svc_status() {
	local mode kill winterval idx name type enabled url lpath domains clients n src
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
		enabled=$(uci -q get "seedex-router.@rule[$idx].enabled")
		url=$(uci -q get "seedex-router.@rule[$idx].list_url")
		lpath=$(uci -q get "seedex-router.@rule[$idx].list_path")
		domains=$(uci -q get "seedex-router.@rule[$idx].domain")
		clients=$(uci -q get "seedex-router.@rule[$idx].mac")
		n=0
		for _ in $domains; do n=$((n + 1)); done
		src=""
		[ "$n" -eq 0 ] || src="$n domains"
		[ -z "$url$lpath" ] || src="${src:+$src + }list"
		n=0
		for _ in $clients; do n=$((n + 1)); done
		[ "$n" -eq 0 ] || src="$n clients"
		printf '    %s %-18s %-8s %s\n' "$(seedex_mark "$([ "$enabled" = 1 ] && echo 1 || echo 0)")" \
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
add <name> k=v ...	Add a rule	Add a rule: type=direct|overlay|block, then domain= ip= list_url= list_path= or mac=
update <#|name> k=v ...	Modify an entry	Modify a rule: key=value, domain= del-domain= ip= del-ip= mac= del-mac=
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
