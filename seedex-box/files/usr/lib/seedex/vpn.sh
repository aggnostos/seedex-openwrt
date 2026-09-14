# shellcheck shell=ash
SVC_NAME="vpn"
# shellcheck source=files/usr/lib/seedex/service.sh
. /usr/lib/seedex/service.sh
SVC_SECTION="config"
SVC_STORE_DIR="$SEEDEX_VPN_DIR"

SVC_ACTIONS="start stop restart show enable disable remove changes apply revert export reset"

_vpn_entry() {
	local subcmd="$1"
	shift

	case "$subcmd" in
	show)
		local idx="$1"
		if [ -z "$idx" ]; then
			printf "    %-4s %-18s %-8s %s\n" "#" "NAME" "IFACE" "CONFIG"

			idx=0
			while uci -q get "seedex-vpn.@config[$idx]" >/dev/null 2>&1; do
				local name enabled config state iface
				name=$(uci -q get "seedex-vpn.@config[$idx].name")
				enabled=$(uci -q get "seedex-vpn.@config[$idx].enabled")
				config=$(uci -q get "seedex-vpn.@config[$idx].config")
				iface=$(seedex_iface_for_config vpn "$name")

				state="[ ]"
				[ "$enabled" = "1" ] && state="[*]"
				[ -f "$config" ] || config="${config:-none} (missing)"

				printf "%s %-4s %-18s %-8s %s\n" \
					"$state" "$idx" "${name:--}" "${iface:--}" "$config"
				idx=$((idx + 1))
			done
			return 0
		fi

		local path
		path=$(_section_at seedex-vpn config config "$idx" "vpn show") || exit $?

		local name enabled config
		name=$(uci -q get "${path}.name")
		enabled=$(uci -q get "${path}.enabled")
		config=$(uci -q get "${path}.config")

		field "Name:" "${name:--}"
		field "State:" "$([ "$enabled" = "1" ] && echo "[*]" || echo "[ ]")"
		local iface
		iface=$(seedex_iface_for_config vpn "$name")
		[ -z "$iface" ] || field "Interface:" "$iface"
		field "Config:" "$config"

		if [ -f "$config" ]; then
			section "Contents:"
			indent <"$config"
		else
			warn "config file is missing"
		fi
		;;

	enable)
		_section_set_enabled seedex-vpn config config "$1" "vpn enable" 1
		;;

	disable)
		_section_set_enabled seedex-vpn config config "$1" "vpn disable" 0
		;;

	remove)
		_section_remove seedex-vpn config config "$1" "vpn remove"
		;;

	esac
}

_import_awg() {
	local src="$1" name dest sid existing
	name=$(basename "$src" .conf)

	if _find_section_by_name seedex-vpn config "$name" >/dev/null; then
		die "config name '$name' is already used
remove it first with 'sdx vpn remove $name', or rename the file"
	fi
	sid=$(_uci_sanitize_id "$name")
	existing=$(uci -q get "seedex-vpn.${sid}.name" 2>/dev/null)
	if [ -n "$existing" ] && [ "$existing" != "$name" ]; then
		die "'$name' collides with the existing config '$existing' (both are UCI id '$sid')
rename one of the two config files"
	fi

	dest=$(_store_config "$src" "$SEEDEX_VPN_DIR") || exit $?

	uci set "seedex-vpn.${sid}=config" || die "cannot create UCI section '$sid'"
	uci set "seedex-vpn.${sid}.name=${name}"
	uci set "seedex-vpn.${sid}.enabled=1"
	uci set "seedex-vpn.${sid}.config=${dest}"

	echo "added VPN config '$name'"
}

svc_import_file() { _import_awg "$1"; }

svc_status() {
	seedex_status_header vpn "VPN"
	seedex_status_configs seedex-vpn config vpn
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
			_vpn_entry "$action" "$@"
		fi
		;;
	show | remove) _vpn_entry "$action" "$@" ;;
	start) svc_start ;;
	status) svc_status ;;
	stop) svc_stop ;;
	restart) svc_restart ;;
	changes) svc_changes ;;
	apply) svc_apply ;;
	revert) svc_revert ;;
	export) svc_export ;;
	reset) svc_reset ;;
	*) return 127 ;;
	esac
}
