# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-10

### Added

- Added the shared release workflow, `.github/workflows/release.yml`: from a version tag it
  publishes the listed files, a `release-manifest.json` pinning each by SHA-256 and size, and a
  build-provenance attestation for each, with release notes from the changelog and a dry-run mode
  ([#2](https://github.com/J-MaFf/release-kit/pull/2)).
- Added CI that tests every step of the workflow, including the inputs it must refuse, and checks a
  dry run's manifest with independent tools ([#2](https://github.com/J-MaFf/release-kit/pull/2)).
- Added `.github/workflows/publish.yml`, which releases release-kit itself through `release.yml`, so
  each of its releases runs the publish and attestation steps for real
  ([#3](https://github.com/J-MaFf/release-kit/issues/3)).
