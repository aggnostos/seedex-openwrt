<p align="center">English | <a href="https://docs.seedex.net/ru/developer-guide/contributing">Русский</a></p>

# Contributing to Seedex OpenWrt

Bug reports, suggestions, and pull requests are welcome. This page describes how to report a problem and how to get a change merged.

## Report a bug

Open an issue with:

* The OpenWrt version and the router model.
* The output of `sdx version`, `sdx`, and `sdx logs`.
* What you did, what you expected, and what happened instead.

Remove keys, tokens, certificate fingerprints, and public IP addresses from the output before you post it.

## Suggest a change

For a small fix, open a pull request. For a new feature or a change in behavior, open an issue first so that the approach is agreed on before you spend time on it.

## Set up

You need Docker for the build, shfmt 3.13 and shellcheck 0.11 for the lint, and a router running OpenWrt 24.10.2 or later to try a build. The [developer guide](https://docs.seedex.net/developer-guide/seedex-box) describes the project structure, the build, and how to install a build on a router.

## Code style

* The router package runs on BusyBox `ash`. Write POSIX `sh`: no arrays, no `[[ ]]`, no `local` outside functions, nothing that `ash` doesn't have. `build.sh` is the one script that runs on the developer's machine and uses `bash`.
* Formatting is what shfmt produces and what `.editorconfig` sets: tabs in shell, two spaces elsewhere, lines up to 100 characters.
* Every shell file passes shellcheck with the rules in `.shellcheckrc`. Don't add `# shellcheck disable` to silence a warning that has a fix.
* The LuCI views are plain JavaScript that the browser runs as it is: no build step, no dependencies. The rpcd backend is a shell script like the rest.
* Match the surrounding code: naming, comment density, and the way errors are reported.

## Lint and test

Run the lint before you push:

```sh
make lint
```

It runs shfmt and shellcheck over every shell file, checks the JavaScript syntax, and validates the JSON. CI runs the same target on every push and pull request.

There is no automated test suite. Build the packages with `make build`, install them on a router, and exercise the change: the affected `sdx` commands and the LuCI page if the change touches it. Say in the pull request what you tested and on which OpenWrt version.

## Commits

* One topic per commit. Fold follow-up fixes into the commit they fix rather than adding a second one.
* The subject is lowercase, in the present tense, and starts with the area: `router: list matchers replace, add-, del-`, `link: menu keeps only offered configs`, `install: reinstall local ipk of the same version`. Areas are the services (`vpn`, `proxy`, `router`, `dns`, `link`), `import`, `install`, `package`, `luci`, and `docs`.
* Don't change `version`. Maintainers bump it with `make bump` when they release; a `v*` tag builds the feed.

## Pull requests

* Target `main` and keep the change small enough to review in one sitting.
* Describe what the change does and why. Link the issue if there is one.
* A change in user-facing behavior updates the documentation too: the READMEs in this repository and the pages in [seedex-docs](https://github.com/aggnostos/seedex-docs), in both languages.
* CI must pass.

## License

Contributions are accepted under the [GPL-2.0](LICENSE) license of the project. The Seedex name and logo are covered by the [trademark policy](TRADEMARK.md), not by the license.
