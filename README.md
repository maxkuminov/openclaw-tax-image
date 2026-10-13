# openclaw-tax-image

The container image for Oksana's OpenClaw **tax** gateway on the homelab k3s cluster:
upstream's official OpenClaw image plus three Debian packages the tax skills need
(`poppler-utils` for `pdftotext`, `python3-pip`, `python3-venv`).

Published as **`ghcr.io/maxkuminov/openclaw-tax`** (public). Max's main gateway needs no
repository: it runs upstream's image `ghcr.io/openclaw/openclaw` directly.

Design of record: `maxkuminov/infra` `docs/homelab-wave-oc.md` (OC-D9 tax image, OC-D10
upgrades, OC-D14 monotonic pins, 5.2 rollback, L12/L14/L15) and
`docs/homelab-image-automation.md` (D1 tags).

## What is in the repository

| File | Purpose |
|---|---|
| `Dockerfile` | `FROM ghcr.io/openclaw/openclaw:<version>@sha256:<index digest>`, then `apt-get upgrade`, the three packages, `EXTERNALLY-MANAGED` removed by glob, `/home/node/.cache/pip` owned by `node`. Runs as `node`, entrypoint and command unchanged from upstream. |
| `.github/workflows/image.yml` | Build, checks, publish. GitHub-hosted `ubuntu-24.04` runners only. |
| `scripts/ci.sh` | The checks, shared by both workflow jobs and runnable locally. |
| `.trivyignore` | Empty. A line lands only by PR with a written reason (L12). |
| `renovate.json` | Bumps the `FROM` tag and digest. |

## Checks (every PR and every push to `main`)

1. **`FROM` shape**: exactly one `FROM`, exactly `ghcr.io/openclaw/openclaw:<stable>@sha256:<64 hex>`,
   where `<stable>` matches `^[0-9]{4}\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`.
2. **Base provenance**: the base image's `org.opencontainers.image.revision` label equals the
   commit of upstream tag `v<version>` (GitHub API). Upstream publishes no retrievable
   attestation, so the trust anchor is the `openclaw` GHCR namespace plus the digest pin (L15).
3. **Smoke test**: `openclaw --version` parses to the `FROM` version (upstream prints
   `OpenClaw 2026.8.2 (0965053)`), `pdftotext -v`, `python3 -m venv`, `python3 -m pip`,
   no `/usr/lib/python3*/EXTERNALLY-MANAGED`, `/home/node/.cache/pip` owned by `1000:1000`,
   image user `node`.
4. **Trivy OS gate**: Debian packages only (`--pkg-types os`), HIGH/CRITICAL with a fix
   (`--ignore-unfixed`) fail the job. The image runs `apt-get upgrade`, so these are ours to fix.
5. **Trivy library report**: the same filter on language packages, written to the job summary,
   **never gating**: those are upstream's `node_modules` and Node toolchain, which this
   repository does not build (L8). The daily homelab Trivy scan still reports them.

## Tags

`ghcr.io/maxkuminov/openclaw-tax:<version>-<shortsha>-<n>`, for example `2026.8.2-1a2b3c4-1`:

- `<version>`: the upstream OpenClaw version in the `FROM` tag. It pairs the tax image with the
  main gateway's upstream tag (same version stream; the tax gateway lags, never leads).
- `<shortsha>`: the 7-character commit of this repository that was built.
- `<n>`: `github.run_number`, strictly increasing, unchanged by a re-run.

One immutable tag per publish, no moving tags. A push publishes only if its commit is still the
tip of `main`; a re-run never re-pushes an existing tag. The cluster's admission policy accepts
only `^ghcr\.io/maxkuminov/openclaw-tax:[0-9]{4}\.[0-9]+\.[0-9]+-[0-9a-f]+-[0-9]+@sha256:[0-9a-f]{64}$`
and never lets the pin go to a lower `[year, minor, patch, n]` except to a reviewed hold (OC-D14).

## How upgrades flow

1. Upstream publishes a stable tag `2026.X.Y`. The main gateway follows it through Flux image
   automation within ~10-40 minutes.
2. Once that tag is **one day old**, Renovate opens a PR here bumping the `FROM` tag and digest,
   only between 9am and 8pm America/New_York. Only stable tags qualify (the wave OC 5.2 regex);
   a digest change under an unchanged tag is never proposed (that would be a moved tag).
3. The PR runs the checks. With automerge on, Renovate merges it when green, inside the same window.
4. The push to `main` publishes `<version>-<sha>-<n>`; Flux moves the tax pin within 10-20 minutes and
   the tax pod restarts on it. Its init container takes the create-once pre-upgrade backup first.

**Automerge is OFF until wave OC phase OC2** (the activation). Until then Renovate's PRs wait for a
human, and nothing in the cluster follows this package (the ImagePolicy is unlabelled).

A **rebuild of the same version** (`workflow_dispatch`, or a merged change to the Dockerfile,
`.trivyignore` or workflow) publishes the same `<version>` with a higher `<n>`, which takes
Debian's newest fixes through `apt-get upgrade`. After OC2 the tax pod rolls onto it.

## Holds and rollback

Rollbacks are driven from the infra repository (`docs/homelab-wave-oc.md` 5.2, script
`hosts/homelab/wave-oc/oc-rollback-upgrade.sh <ns> <prior tag@digest>`), always with the **full
prior pin value** (`tag@digest`) from `~/sysadmin/state/openclaw-pins.log` or the
`flux-image-updates` branch history, never a bare version:

- **Different OpenClaw version** (an upstream upgrade): hold PR on the prior tag, suspend, restore
  the init's create-once `config/backups/pre-<prior>-to-<bad>/` with every writer stopped, merge the
  hold, resume.
- **Same OpenClaw version** (a rebuild here went bad): hold on the prior full tax tag only, no state
  restore.

Whenever the main gateway is held, **turn automerge off here by PR** (set `"automerge": false` in the
`ghcr.io/openclaw/openclaw` rule of `renovate.json`): a hold on main freezes tax. To pause tax only,
do the same. Lifting a hold is a revert PR once a fixed release is out.

Old images stay pullable by digest from this public package for as long as they are not pruned
(the infra GHCR pruning rules, `docs/homelab-image-automation.md` D8, if this package is enrolled there).

## Exposure (L14)

This repository and its package are public. They reveal the OpenClaw version the tax gateway runs,
three Debian package names and the `.trivyignore`. No secret, configuration or user data is in the
image or the repository.
