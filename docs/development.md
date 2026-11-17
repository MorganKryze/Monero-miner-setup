# Development

Read this when you change the project: what CI runs, how dependency updates land and how to send a pull request.

## CI

CI (`.github/workflows/ci.yml`) runs `shellcheck`, `hadolint`, the `make -n` dry runs, `make check` and the Docker build smoke test on amd64 and arm64. It runs on pushes and pull requests to `main`, and after a Dependabot merge. A pull request to `main` needs green CI to merge (the maintainer can still push directly). First-time contributor PRs require maintainer approval before workflows run.

## Dependabot

Dependabot opens weekly PRs for the `xmrig` and `bash-toolbox` submodules, the GitHub Actions, the Dockerfile's base image and Gluetun. Only Actions patch and minor bumps merge on their own, once CI is green; the rest wait for review.

## Contributing

Pull requests welcome. Fork, branch, run `make check`, open a PR.

## The docs checks

`make check` runs every `tests/*.sh`, the docs checks among them. They read the pages against the code, so a change to one without the other fails:

| Check | What it holds |
| --- | --- |
| `tests/docs-pages.sh` | every relative link and anchor of `README.md`, `CHANGELOG.md` and `docs/*.md` lands; each page starts with a `# ` title; no em dash and no stock phrase in the prose |
| `tests/docs-commands.sh` | every install command of the docs is in the guarded form: the installer fetched into a variable, stopped on an empty download |
| `tests/docs-defaults.sh` | the defaults the docs list are the ones the installers use |
| `tests/docs-root.sh` | [What runs as root](security.md#what-runs-as-root) names every command the Makefile and the scripts run through `sudo` |
| `tests/docs-sources.sh` | [What the installers fetch](security.md#what-the-installers-fetch) names every source the project fetches |
| `tests/docs-board-profiles.sh` | the board profiles table of `docs/boards.md` is the one `scripts/board_profiles.conf` holds |
| `tests/docs-first-boot.sh` | the card section of `docs/boards.md` names what the first-boot setup does |
| `tests/docs-host-tuning.sh` | the `--mode` section of `docs/boards.md` names what the host tuning installs and how to undo it |

`tests/docs-root-fixtures.sh` and `tests/docs-sources-fixtures.sh` plant a change in a copy of the tree and check that the two checks above fail on it.
