# Contributing

Thanks for wanting to help Radarchik. Issues and pull requests are welcome; every pull request is read and approved by the maintainer before it is merged — nothing lands in `main` without that review.

## Before you open a pull request

- For anything bigger than a small fix, open an issue first so we can agree on the idea.
- `make test` passes. Logic goes into `Sources/RadarchikCore` with tests next to it in `Tests/`.
- UI strings come in pairs, Russian first: `L("Настройки", "Settings")`.
- Screens you touched look right on the sheet: `.build/debug/Radarchik --render-screens <folder> --language en`. Attach the PNGs to the pull request.
- One topic per pull request, with a short note on what changed and why.

## Guard and the root helper

Changes to `Sources/RadarchikGuardHelper`, `Support/guard/` or anything that runs as root get an extra careful review and may take longer. Please explain what the change does to the helper’s contract and how you tested it.

## Security issues

Please don’t open a public issue — see [SECURITY.md](SECURITY.md).
