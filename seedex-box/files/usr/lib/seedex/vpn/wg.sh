# shellcheck shell=ash
# shellcheck source=files/usr/lib/seedex/wireguard.sh
. /usr/lib/seedex/wireguard.sh

vpn_wg_detect() {
	wg_is_family "$1" && ! wg_has_params "$1"
}

vpn_wg_validate() { wg_validate "$1"; }
vpn_wg_endpoints() { wg_endpoints "$1"; }
vpn_wg_up() { wg_up wg wireguard "$@"; }
vpn_wg_down() { wg_down "$1"; }
