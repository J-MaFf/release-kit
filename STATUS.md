# STATUS

## What This Is

`release-kit` holds one shared GitHub Actions workflow that any J-MaFf repository calls on a version
tag. It publishes the listed files as release assets, a `release-manifest.json` that pins each by
SHA-256 and size, and a signed build-provenance attestation for each, so scripts can find, check
and update themselves from releases. The design follows the ReSkate launcher's updater.

## Current State — 2026-10-10

The workflow is merged ([#2](https://github.com/J-MaFf/release-kit/pull/2)). `v1.0.0` is released
through release-kit's own `publish.yml` ([#3](https://github.com/J-MaFf/release-kit/issues/3)), and
the major tag `v1` points at it. The first outside caller is J-MaFf/winget-app-setup
(J-MaFf/winget-app-setup#287).

### Components

| File | Description |
|---|---|
| `.github/workflows/release.yml` | The shared workflow (`workflow_call`): resolve and check the tag, build the manifest, take the notes from the changelog, attest, publish; or a dry run |
| `.github/workflows/publish.yml` | Releases release-kit itself through `release.yml` on a `vX.Y.Z` tag (not on the moving `v1`) |
| `.github/workflows/ci.yml` | Runs the step tests, then a dry run on `tests/fixtures/` whose manifest a second job checks with `sha256sum`, `stat` and `jq` |
| `tests/Test-ReleaseSteps.ps1`, `tests/extract_steps.py` | Runs each pwsh step of `release.yml` in a throwaway repository, including the inputs it must refuse |
| `tests/fixtures/` | Files and a changelog the tests and the dry run release |

### Resolved Issues

| Issue | Description | PR |
|---|---|---|
| [#1](https://github.com/J-MaFf/release-kit/issues/1) | Add the shared release workflow (manifest + attestations) | [#2](https://github.com/J-MaFf/release-kit/pull/2) |

### Open Issues

| Issue | Description |
|---|---|
| [#3](https://github.com/J-MaFf/release-kit/issues/3) | Release release-kit itself through its own workflow (v1.0.0) |

## Natural Next Steps

- Cut J-MaFf/winget-app-setup's first release through it once J-MaFf/winget-app-setup#285 and #287 merge.
- A shared PowerShell updater (`Update-FromGitHubRelease`): latest release, manifest, hash compare,
  verified download, replace in one step, keep running on failure. Pilot it on a repository with
  something long-lived installed on machines.
- A tag ruleset here so only the owner can move `v1`.

## Prerequisites to Run

- To call it: a repository on GitHub, a `CHANGELOG.md` with a section per version (or `changelog: ''`).
- To test it locally: git, PowerShell 7 and Python 3 with PyYAML, then `pwsh -File tests/Test-ReleaseSteps.ps1`.
