ARCH = $(shell sed -n 's/^ARCH="\([^"]*\)".*/\1/p' build.sh)
PART ?= patch

.PHONY: build install bump lint clean

build:
	./build.sh

install:
	sh install.sh build/$(ARCH)/*.apk

bump:
	@old=$$(cat version); \
	IFS=. read -r major minor patch <version; \
	case "$(PART)" in \
	major) major=$$((major + 1)); minor=0; patch=0 ;; \
	minor) minor=$$((minor + 1)); patch=0 ;; \
	patch) patch=$$((patch + 1)) ;; \
	*) echo "PART must be major, minor or patch" >&2; exit 1 ;; \
	esac; \
	new="$$major.$$minor.$$patch"; \
	printf '%s\n' "$$new" >version; \
	echo "$$old -> $$new"; \
	if git rev-parse --git-dir >/dev/null 2>&1; then \
		git add version && git commit -q -m "v$$new" && git tag "v$$new" && echo "tagged v$$new"; \
	fi

lint:
	shfmt -l -d build.sh install.sh seedex-box/files/usr/bin/* seedex-box/files/usr/lib/seedex/*.sh seedex-box/files/usr/lib/seedex/vpn/*.sh \
		seedex-box/files/etc/init.d/* seedex-box/files/etc/hotplug.d/*/* seedex-box/package/* \
		luci-app-seedex/files/usr/libexec/rpcd/* luci-app-seedex/package/*
	shellcheck -x build.sh install.sh seedex-box/files/usr/bin/* seedex-box/files/usr/lib/seedex/*.sh seedex-box/files/usr/lib/seedex/vpn/*.sh \
		seedex-box/files/etc/init.d/* seedex-box/files/etc/hotplug.d/*/* seedex-box/package/* \
		luci-app-seedex/files/usr/libexec/rpcd/* luci-app-seedex/package/*
	for f in luci-app-seedex/files/www/luci-static/resources/seedex/*.js \
		luci-app-seedex/files/www/luci-static/resources/view/seedex/*.js; do node --check "$$f" || exit 1; done
	for f in luci-app-seedex/files/usr/share/luci/menu.d/*.json luci-app-seedex/files/usr/share/rpcd/acl.d/*.json; do \
		jq -e . "$$f" >/dev/null || exit 1; done

clean:
	rm -rf build
