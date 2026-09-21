<p align="center">English | <a href="https://docs.seedex.net/ru/developer-guide/seedex-box#участие">Русский</a></p>

# Contributing to Seedex OpenWrt

Bug reports, suggestions, and pull requests are welcome. This page describes how to report a problem and how to get a change merged.

## Report a bug

Open an issue with:

* The OpenWrt version and the router model.
* The output of `sdx version`, `sdx`, and `sdx logs`.
* What you did, what you expected, and what happened instead.

Strip keys, tokens, certificate fingerprints, and public IP addresses from the output before posting it.

## Suggest a change

A small fix goes straight to a pull request. A new feature or a change in behavior starts with an issue, so that the approach is agreed on before you spend time on it.

## Set up

The build needs Docker. The lint needs shfmt 3.13 and shellcheck 0.11. Trying a build needs a router on OpenWrt 24.10.2 or later. The [developer guide](https://docs.seedex.net/developer-guide/seedex-box) describes the project structure, the build, and how to install a build on a router.

## Code style

* The router package runs on BusyBox `ash`. Write POSIX `sh`: no arrays, no `[[ ]]`, no `local` outside functions, nothing that `ash` lacks. `build.sh` is the one script that runs on the developer's machine, and it uses `bash`.
* Formatting is what shfmt produces and what `.editorconfig` sets: tabs in shell, two spaces elsewhere, lines up to 100 characters.
* Every shell file passes shellcheck with the rules in `.shellcheckrc`. Fix the warning rather than adding `# shellcheck disable`.
* The LuCI views are plain JavaScript that the browser runs as it is: no build step, no dependencies. The rpcd backend is a shell script like the rest.
* Match the surrounding code: naming, comment density, and the way errors are reported.

## Check

Run the lint before you push:

```sh
make lint
```

It runs shfmt and shellcheck over every shell file. It also checks the JavaScript syntax and validates the JSON. CI runs the same target on every push and pull request.

There is no automated test suite. Build the packages with `make build`, install them on a router, and exercise the change: the affected `sdx` commands, plus the LuCI page if the change touches it. Say in the pull request what you tested and on which OpenWrt version.

## Commits

* One topic per commit. A follow-up fix goes into the commit it fixes, not into a second one.
* The subject is lowercase, present tense, and prefixed with the area: `router: list matchers replace, add-, del-`, `link: menu keeps only offered configs`, `install: reinstall local ipk of the same version`. Areas: the services (`vpn`, `proxy`, `router`, `dns`, `link`), `import`, `install`, `package`, `luci`, and `docs`.
* Leave `version` alone. Maintainers bump it with `make bump` at release time; a `v*` tag builds the feed.

## Pull requests

* Target `main` and keep the change small enough to review in one sitting.
* Describe what the change does and why. Link the issue if there is one.
* A change in user-facing behavior also updates the documentation: the README here and the pages in [seedex-docs](https://github.com/aggnostos/seedex-docs), where the English page mirrors the Russian one.
* CI must pass.

## License

Contributions are accepted under the project's [GPL-2.0](LICENSE) license. The Seedex name and logo are covered by the [trademark policy](https://docs.seedex.net/trademark), not by the license.
