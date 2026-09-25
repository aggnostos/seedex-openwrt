# shellcheck shell=ash
SVC_NOOP=3
SVC_ID="seedex-$SVC_NAME"

_uci_sanitize_id() {
	local id
	id=$(echo "$1" | sed 's/[^A-Za-z0-9_]/_/g')
	[ -n "$id" ] || id="unnamed"
	printf '%s\n' "$id"
}

_section_id_at() {
	uci -X -q show "${1}.@${2}[$3]" 2>/dev/null | head -1 | cut -d. -f2 | cut -d= -f1
}

_find_section_by_name() {
	local config="$1" type="$2" want="$3" idx=0
	while uci -q get "${config}.@${type}[$idx]" >/dev/null 2>&1; do
		if [ "$(uci -q get "${config}.@${type}[$idx].name")" = "$want" ]; then
			_section_id_at "$config" "$type" "$idx"
			return 0
		fi
		idx=$((idx + 1))
	done
	return 1
}

_uci_set_if() {
	local section="$1" key="$2" val="$3"
	[ -n "$val" ] && uci set "${section}.${key}=${val}"
}

_ref_label() {
	case "$1" in
	*[!0-9]*) printf "'%s'" "$1" ;;
	*) printf '#%s' "$1" ;;
	esac
}

_section_at() {
	local config="$1" type="$2" label="$3" ref="$4" cmd="$5" sid
	[ -n "$ref" ] || usage "sdx $cmd <#|name>"
	case "$ref" in
	*[!0-9]*)
		sid=$(_find_section_by_name "$config" "$type" "$ref") ||
			die "$label '$ref' not found"
		printf '%s\n' "${config}.${sid}"
		;;
	*)
		sid=$(_section_id_at "$config" "$type" "$ref")
		[ -n "$sid" ] || die "$label #$ref not found"
		printf '%s\n' "${config}.${sid}"
		;;
	esac
}

_sections_at() {
	local config="$1" type="$2" label="$3" cmd="$4" ref
	shift 4
	[ $# -gt 0 ] || usage "sdx $cmd <#|name> ..."
	for ref in "$@"; do
		_section_at "$config" "$type" "$label" "$ref" "$cmd" || exit $?
	done
}

_section_set_enabled() {
	local config="$1" type="$2" label="$3" cmd="$4" value="$5"
	shift 5
	local paths path ref word
	paths=$(_sections_at "$config" "$type" "$label" "$cmd" "$@") || exit $?
	[ "$value" = "1" ] && word=enabled || word=disabled
	for ref in "$@"; do
		path="${paths%%
*}"
		paths="${paths#*
}"
		uci set "${path}.enabled=${value}"
		echo "$label $(_ref_label "$ref") $word"
	done
}

_section_set() {
	local config="$1" type="$2" label="$3" ref="$4" cmd="$5" allowed="$6"
	shift 6

	local path
	path=$(_section_at "$config" "$type" "$label" "$ref" "$cmd") || exit $?
	[ $# -gt 0 ] || usage "sdx $cmd <#|name> key=value ..."

	local arg key val k ok changes=0
	for arg in "$@"; do
		key="${arg%%=*}"
		val="${arg#*=}"
		[ "$arg" != "$key" ] && [ -n "$key" ] || die "expected key=value, got: $arg"

		ok=0
		for k in $allowed; do [ "$k" = "$key" ] && ok=1; done
		[ "$ok" = "1" ] || die "cannot set '$key' here — it lives in the config file
settable: $allowed"

		uci set "${path}.${key}=${val}"
		echo "  $key=$val"
		changes=$((changes + 1))
	done

	echo "$label $(_ref_label "$ref") updated ($changes change(s))"
}

_section_remove() {
	local config="$1" type="$2" label="$3" cmd="$4"
	shift 4
	local paths path ref
	paths=$(_sections_at "$config" "$type" "$label" "$cmd" "$@") || exit $?
	for ref in "$@"; do
		path="${paths%%
*}"
		paths="${paths#*
}"
		uci delete "$path" 2>/dev/null
		log_debug "${label}: removed $(_ref_label "$ref")"
		echo "removed $label $(_ref_label "$ref")"
	done
}

_module_config() {
	local uci_config="$1" section="$2" keys="$3" subcmd="$4"
	shift 4

	case "$subcmd" in
	show)
		for key in $keys; do
			local val
			val=$(uci -q get "${uci_config}.${section}.${key}")
			printf "%-20s %s\n" "$key" "${val:-(not set)}"
		done
		;;
	get)
		local key="$1"
		[ -n "$key" ] || {
			usage "sdx ${uci_config#seedex-} config get <key>"
		}
		local valid=0
		for k in $keys; do [ "$k" = "$key" ] && valid=1; done
		[ "$valid" = "1" ] || {
			warn "unknown key '$key'"
			return 1
		}
		local val
		val=$(uci -q get "${uci_config}.${section}.${key}")
		echo "${val:-(not set)}"
		;;
	set)
		[ $# -gt 0 ] || usage "sdx ${uci_config#seedex-} config set key=value ..."
		local arg key val k valid changes=0
		for arg in "$@"; do
			key="${arg%%=*}"
			val="${arg#*=}"
			[ "$arg" != "$key" ] && [ -n "$key" ] || die "expected key=value, got: $arg"

			valid=0
			for k in $keys; do [ "$k" = "$key" ] && valid=1; done
			[ "$valid" = "1" ] || die "unknown key '$key'
settable: $keys"

			uci set "${uci_config}.${section}.${key}=${val}"
			echo "  $key=$val"
			changes=$((changes + 1))
		done
		log_debug "config: ${uci_config} set $changes key(s)"
		;;
	*)
		set -- \
			"show                          Show all settings" \
			"get <key>                     Get a setting" \
			"set key=value ...             Set one or more settings" \
			"" \
			"Available keys:"
		for key in $keys; do
			local val
			val=$(uci -q get "${uci_config}.${section}.${key}")
			set -- "$@" "  $key (current: ${val:-(not set)})"
		done
		usage_block "sdx ${uci_config#seedex-} config <command> [options]" "$@"
		;;
	esac
}

_export_configs() {
	local uci_config="$1" type="$2" label="$3"
	local idx=0 emitted=0 name path

	while uci -q get "${uci_config}.@${type}[$idx]" >/dev/null 2>&1; do
		name=$(uci -q get "${uci_config}.@${type}[$idx].name")
		path=$(uci -q get "${uci_config}.@${type}[$idx].config")
		idx=$((idx + 1))

		[ -n "$path" ] || continue

		[ "$emitted" -gt 0 ] && echo
		emitted=$((emitted + 1))
		echo "# ${label}: ${name:-unnamed} (${path})"
		if [ -f "$path" ]; then
			cat "$path"
		else
			warn "config '$path' is missing"
		fi
	done

	[ "$emitted" -gt 0 ] || warn "no $label configs to export"
}

# Answers whether an import may replace the config that already carries this
# name: only with --force, never behind a link's back.
_import_may_replace() {
	local config="$1" sid="$2" name="$3" svc="$4" owner
	if [ "${SEEDEX_IMPORT_FORCE:-0}" != 1 ]; then
		die "config name '$name' is already used
replace it with 'sdx import --force', remove it with 'sdx $svc remove $name', or rename the file"
	fi
	owner=$(uci -q get "${config}.${sid}.link" 2>/dev/null)
	[ -z "$owner" ] || die "config '$name' is managed by link '$owner'
the next sync would overwrite your file; change it on the server instead"
}

# A replacement must not take effect before 'apply', so it is written beside
# the config as <name>.new and recorded in the pending section.
_stage_config() {
	local src="$1" dir="$2" base staged

	base=$(basename "$src")
	seedex_config_dir_init
	staged="$dir/$base.new"
	cp "$src" "$staged" || die "cannot write $staged"
	chmod 600 "$staged"
	printf '%s\n' "$staged"
}

_swap_staged() {
	local idx=0 path staged
	while uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx]" >/dev/null 2>&1; do
		staged=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].staged")
		path=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].config")
		idx=$((idx + 1))
		[ -n "$staged" ] || continue
		uci -q delete "${SVC_ID}.@${SVC_SECTION}[$((idx - 1))].staged"
		[ -f "$staged" ] || continue
		mv "$staged" "$path" || die "cannot replace $path"
		chmod 600 "$path"
	done
}

_drop_staged() {
	local idx=0 staged
	while uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx]" >/dev/null 2>&1; do
		staged=$(uci -q get "${SVC_ID}.@${SVC_SECTION}[$idx].staged")
		[ -z "$staged" ] || rm -f "$staged"
		idx=$((idx + 1))
	done
}

_store_config() {
	local src="$1" dir="$2" dest base

	base=$(basename "$src")

	case "$base" in
	*[!A-Za-z0-9._-]*)
		die "config name '$base' contains unsupported characters
use letters, digits, dot, dash or underscore"
		;;
	esac

	seedex_config_dir_init
	dest="$dir/$base"
	cp "$src" "$dest" || die "cannot write $dest"
	chmod 600 "$dest"
	printf '%s\n' "$dest"
}

_reset_sections() {
	local config="$1"
	shift

	local type i line
	for type in "$@"; do
		i=0
		while [ "$i" -lt 100 ] && uci -q get "${config}.@${type}[0]" >/dev/null 2>&1; do
			uci delete "${config}.@${type}[0]"
			i=$((i + 1))
		done

		i=0
		while [ "$i" -lt 100 ]; do
			line=$(uci -N -q show "$config" 2>/dev/null | grep "=${type}\$" | head -1)
			[ -n "$line" ] || break
			uci delete "${line%%=*}"
			i=$((i + 1))
		done
	done

	uci commit "$config"
}

_svc_registered() {
	seedex_service_registered "$SVC_NAME"
}

svc_start() { /etc/init.d/"$SVC_ID" start; }

svc_enable() {
	rm -f "$SEEDEX_DISABLED_DIR/$SVC_NAME"
	echo "$SVC_NAME enabled"
	svc_start
}

svc_disable() {
	mkdir -p "$SEEDEX_DISABLED_DIR"
	: >"$SEEDEX_DISABLED_DIR/$SVC_NAME"
	echo "$SVC_NAME disabled"
	svc_stop
}

svc_stop() {
	_svc_registered || {
		echo "$SVC_NAME is not running"
		return 0
	}
	/etc/init.d/"$SVC_ID" stop
}

svc_restart() {
	if _svc_registered; then
		/etc/init.d/"$SVC_ID" restart
	else
		svc_start
	fi
}

svc_config() {
	_module_config "$SVC_ID" main "$SVC_CONFIG_KEYS" "$@"
}

svc_changes() {
	local diff
	diff=$(uci changes "$SVC_ID" 2>/dev/null)
	[ -n "$diff" ] || return "$SVC_NOOP"
	printf '%s\n' "$diff"
}

svc_apply() {
	local pending
	pending=$(uci changes "$SVC_ID" 2>/dev/null)
	[ -n "$pending" ] || seedex_config_stale "$SVC_NAME" || return "$SVC_NOOP"
	if [ -n "$pending" ]; then
		_swap_staged
		uci commit "$SVC_ID"
		echo "saved $SVC_ID"
	fi
	svc_restart
}

svc_revert() {
	[ -n "$(uci changes "$SVC_ID" 2>/dev/null)" ] || return "$SVC_NOOP"
	_drop_staged
	uci revert "$SVC_ID"
	echo "reverted $SVC_ID"
}

svc_export() {
	_export_configs "$SVC_ID" "$SVC_SECTION" "$SVC_NAME"
}

svc_reset() {
	/etc/init.d/"$SVC_ID" stop 2>/dev/null
	_reset_sections "$SVC_ID" "$SVC_SECTION"
	[ -z "${SVC_STORE_DIR:-}" ] || rm -f "$SVC_STORE_DIR"/*
	log_info "$SVC_NAME: config reset"
	echo "$SVC_NAME: config reset"
}
