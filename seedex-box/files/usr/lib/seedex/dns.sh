# shellcheck shell=ash
SVC_NAME="dns"
# shellcheck source=files/usr/lib/seedex/service.sh
. /usr/lib/seedex/service.sh
SVC_CONFIG_KEYS="upstream resolver intercept"

SVC_ACTIONS="start stop restart enable disable config changes apply revert"

svc_status() {
	local upstream resolver intercept
	seedex_status_header dns "DNS"
	upstream=$(uci -q get seedex-dns.main.upstream)
	resolver=$(uci -q get seedex-dns.main.resolver)
	intercept=$(uci -q get seedex-dns.main.intercept)
	printf '  %-11s %s\n' "Upstream:" "${upstream:-encrypted}"
	[ "${upstream:-encrypted}" = provider ] || printf '  %-11s %s\n' "Resolver:" "${resolver:-cloudflare}"
	printf '  %-11s %s\n' "Intercept:" "$([ "${intercept:-1}" = 0 ] && echo off || echo on)"
	if [ -d "$SEEDEX_ROUTER_DOMAINS_DIR" ]; then
		printf '  %-11s %s overlay, %s direct, %s blocked\n' "Domains:" \
			"$(wc -l <"$SEEDEX_ROUTER_DOMAINS_DIR/overlay" 2>/dev/null || echo 0)" \
			"$(wc -l <"$SEEDEX_ROUTER_DOMAINS_DIR/direct" 2>/dev/null || echo 0)" \
			"$(wc -l <"$SEEDEX_ROUTER_DOMAINS_DIR/block" 2>/dev/null || echo 0)"
	fi
}

svc_help() {
	cat <<EOH
start	Start the service
stop	Stop the service
restart	Restart the service
enable	Enable the service
disable	Disable the service (also at boot)
config	Manage service settings	Manage service settings: show, get <key>, set k=v ...
changes	Show pending UCI changes
apply	Save pending changes and restart
revert	Revert pending UCI changes
EOH
}

svc_dispatch() {
	local action="$1"
	shift

	case "$action" in
	start) svc_start ;;
	status) svc_status ;;
	stop) svc_stop ;;
	restart) svc_restart ;;
	changes) svc_changes ;;
	apply) svc_apply ;;
	revert) svc_revert ;;
	enable) svc_enable ;;
	disable) svc_disable ;;
	config) svc_config "$@" ;;
	*) return 127 ;;
	esac
}
