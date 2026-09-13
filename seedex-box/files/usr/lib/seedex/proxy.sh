# shellcheck shell=ash
SVC_NAME="proxy"
# shellcheck source=files/usr/lib/seedex/service.sh
. /usr/lib/seedex/service.sh
SVC_SECTION="config"
SVC_CONFIG_KEYS="log_level urltest_interval"
SVC_STORE_DIR="$SEEDEX_PROXY_DIR"

SVC_ACTIONS="start stop restart show enable disable remove config export reset"

_proxy_entry() {
	local subcmd="$1"
	shift

	case "$subcmd" in
	show)
		local idx="$1"
		if [ -z "$idx" ]; then
			printf "    %-4s %-22s %s\n" "#" "NAME" "CONFIG"

			idx=0
			while uci -q get "seedex-proxy.@config[$idx]" >/dev/null 2>&1; do
				local name enabled config state
				name=$(uci -q get "seedex-proxy.@config[$idx].name")
				enabled=$(uci -q get "seedex-proxy.@config[$idx].enabled")
				config=$(uci -q get "seedex-proxy.@config[$idx].config")

				state="[ ]"
				[ "$enabled" = "1" ] && state="[*]"
				[ -f "$config" ] || config="${config:-none} (missing)"

				printf "%s %-4s %-22s %s\n" "$state" "$idx" "${name:--}" "$config"
				idx=$((idx + 1))
			done
			return 0
		fi

		local path
		path=$(_section_at seedex-proxy config config "$idx" "proxy show") || exit $?

		local name enabled config
		name=$(uci -q get "${path}.name")
		enabled=$(uci -q get "${path}.enabled")
		config=$(uci -q get "${path}.config")

		field "Name:" "${name:--}"
		field "State:" "$([ "$enabled" = "1" ] && echo "[*]" || echo "[ ]")"
		field "Config:" "$config"

		if [ -f "$config" ]; then
			section "Outbounds:"
			jq -r '.outbounds[] | "  \(.tag)  (\(.type))"' "$config" 2>/dev/null ||
				warn "could not parse $config"
		else
			warn "config file is missing"
		fi
		;;

	enable)
		_section_set_enabled seedex-proxy config config "$1" "proxy enable" 1
		;;

	disable)
		_section_set_enabled seedex-proxy config config "$1" "proxy disable" 0
		;;

	remove)
		_section_remove seedex-proxy config config "$1" "proxy remove"
		;;

	esac
}

_import_singbox() {
	local src="$1" name dest sid existing
	name=$(basename "$src" .json)

	if _find_section_by_name seedex-proxy config "$name" >/dev/null; then
		die "config name '$name' is already used
remove it first with 'sdx proxy remove $name', or rename the file"
	fi
	sid=$(_uci_sanitize_id "$name")
	existing=$(uci -q get "seedex-proxy.${sid}.name" 2>/dev/null)
	if [ -n "$existing" ] && [ "$existing" != "$name" ]; then
		die "'$name' collides with the existing config '$existing' (both are UCI id '$sid')
rename one of the two config files"
	fi

	dest=$(_store_config "$src" "$SEEDEX_PROXY_DIR") || exit $?

	uci set "seedex-proxy.${sid}=config" || die "cannot create UCI section '$sid'"
	uci set "seedex-proxy.${sid}.name=${name}"
	uci set "seedex-proxy.${sid}.enabled=1"
	uci set "seedex-proxy.${sid}.config=${dest}"

	echo "added proxy config '$name'"
}

svc_import_file() { _import_singbox "$1"; }

svc_status() {
	seedex_status_header proxy "Proxy"
	seedex_status_configs seedex-proxy config proxy
}

svc_help() {
	cat <<EOF
start	Start the service
stop	Stop the service
restart	Restart the service
show [#|name]	List entries, or show one	List configs, or show one with its file
enable [#|name]	Enable the service or an entry	Enable the service, or one config
disable [#|name]	Disable the service or an entry	Disable the service (also at boot), or one config
remove <#|name>	Remove an entry	Remove a config and stage its file for removal
config	Manage service settings	Manage service settings: show, get <key>, set k=v ...
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
			_proxy_entry "$action" "$@"
		fi
		;;
	show | remove) _proxy_entry "$action" "$@" ;;
	start) svc_start ;;
	status) svc_status ;;
	stop) svc_stop ;;
	restart) svc_restart ;;
	config) svc_config "$@" ;;
	export) svc_export ;;
	reset) svc_reset ;;
	*) return 127 ;;
	esac
}
