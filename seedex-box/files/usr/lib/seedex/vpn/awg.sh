# shellcheck shell=ash
# shellcheck source=files/usr/lib/seedex/wireguard.sh
. /usr/lib/seedex/wireguard.sh

vpn_awg_detect() {
	wg_is_family "$1" && wg_has_params "$1"
}

vpn_awg_validate() { wg_validate "$1"; }
vpn_awg_endpoints() { wg_endpoints "$1"; }
vpn_awg_up() { wg_up awg amneziawg "$@"; }
vpn_awg_down() { wg_down "$1"; }
