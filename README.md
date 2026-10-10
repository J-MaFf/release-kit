# release-kit

A shared GitHub Actions workflow that turns a version tag into a release any script can trust and
update itself from. It publishes:

- **the files you list**, as release assets;
- **`release-manifest.json`**, which pins every asset by SHA-256 and size, and names the tag and
  commit it was built from;
- **a signed build-provenance attestation** for every asset and the manifest (public repositories),
  so anyone can prove a file came from this workflow, from your repository, at that commit.

The design follows the [ReSkate launcher's updater](https://github.com/Dingo-Shenanigans/ReSkate/blob/main/Launcher/updater.cpp):
one manifest per release, files compared by hash rather than by version number, and the newest
release found with a single API call.

## Use it in a repository

Add `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ['v*']

jobs:
  release:
    permissions:
      contents: write      # create the release
      id-token: write      # sign the attestations
      attestations: write  # store them
    uses: J-MaFf/release-kit/.github/workflows/release.yml@v1
    with:
      files: |
        my-tool.ps1
        rmm/helper.ps1
```

Then release by tagging:

1. Move the `[Unreleased]` entries in `CHANGELOG.md` under `## [1.2.0] - YYYY-MM-DD` and merge that.
2. `git tag v1.2.0 && git push origin v1.2.0` (sign it with `git tag -s` if you sign tags).

The job grants must be written out in the calling job: a called workflow can only use what its
caller allows.

### Inputs

| Input | Default | What it does |
|---|---|---|
| `files` | (required) | Newline-separated paths inside the repository. Each is uploaded under its file name, so two paths may not share one, and none may be called `release-manifest.json`. |
| `tag` | the pushed tag | The tag to release: `vMAJOR.MINOR.PATCH`, optionally `-prerelease`. A prerelease is published as one and never marked latest. |
| `changelog` | `CHANGELOG.md` | A [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) file. Its `## [VERSION]` section becomes the release notes, and the run fails when that section is missing or empty. Pass `''` for GitHub's generated notes. |
| `attest` | `true` | Attest every asset. GitHub Free and Pro only support attestations in **public** repositories, so set `false` in a private one. |
| `dry-run` | `false` | Build and check the manifest, then upload it and the assets as the `release-dry-run` workflow artifact, without attesting or publishing anything. |

The workflow's `manifest-sha256` output is the SHA-256 of the published manifest.

Checks to run before releasing (a build that must be in sync, a version number that must match the
tag) belong in a job of your own that the release job `needs:`.

## The manifest

```json
{
  "schema": 1,
  "repository": "J-MaFf/my-tool",
  "tag": "v1.2.0",
  "version": "1.2.0",
  "commit": "4f1c…40 hex digits",
  "files": {
    "my-tool.ps1": {
      "path": "my-tool.ps1",
      "url": "asset:my-tool.ps1",
      "sha256": "9b2e…64 lowercase hex digits",
      "size": 48213
    }
  }
}
```

- `schema` changes only when the format changes in a way an old reader would misread. A reader
  should refuse a schema it does not know and tell the user to update it by hand.
- `files` is keyed by asset name. `path` is where the file lives in the repository at `commit`.
  `url` is `asset:<name>`: the asset of that name in the same release.
- Each asset's bytes are the bytes git checked out at `commit` on Linux, so they match
  `git cat-file blob <commit>:<path>`. Keep line endings fixed with `.gitattributes`
  (`* text=auto eol=lf`), or a Windows checkout will hash differently.
- The manifest has no timestamp, so building it twice from one commit gives the same file.

## Verify a release

```powershell
gh release download v1.2.0 --repo J-MaFf/my-tool --dir rel
gh attestation verify rel/my-tool.ps1 --repo J-MaFf/my-tool `
    --signer-workflow J-MaFf/release-kit/.github/workflows/release.yml
```

`--signer-workflow` is what makes this worth doing: it proves the file was built by this workflow,
not just uploaded by someone who could push to the repository. The hashes in the manifest come from
the same release as the files, so they catch a damaged or incomplete download, but on their own they
cannot catch a release someone replaced on purpose. The attestation can.

## Consume a release

A consumer that keeps itself current does what the ReSkate launcher does:

1. Ask `https://api.github.com/repos/<owner>/<repo>/releases/latest` for the newest release. This is
   the only call GitHub rate-limits (60 an hour per IP without a token); everything else comes from
   the release's download links.
2. Download its `release-manifest.json`, and refuse an unknown `schema`.
3. For each file it uses, compare the local file's size and SHA-256 with the manifest. Equal means
   up to date, whatever the version numbers say. Different means replace it.
4. Download to `<file>.new`, check its size and SHA-256 (and its attestation, where `gh` is
   available), and only then move it over the old one in one step.
5. If any of that fails, keep running the files it has.

For a private repository the `releases/latest` call needs a token (`gh auth token`, or a read-only
fine-grained token); without one GitHub answers 404.

A shared PowerShell updater that does all of this is planned.

## Versions of release-kit

Releases of release-kit itself are tagged `vX.Y.Z`, and the major tag `v1` is moved to the newest
`v1.x.y`. Call `@v1` to get fixes without editing every repository, or a full commit SHA to pin
exactly. A change that would break a caller gets a new major tag.

## Develop

```powershell
pwsh -File tests/Test-ReleaseSteps.ps1   # needs git, pwsh 7, Python 3 + PyYAML
```

It runs every PowerShell step of `release.yml` in a throwaway repository, including the cases that
must fail. CI (`.github/workflows/ci.yml`) runs it, then runs `release.yml` as a dry run on
`tests/fixtures/` and checks the manifest it built with `sha256sum`, `stat` and `jq`.
