#!/usr/bin/env bash
# CI steps for the openclaw-tax image, shared by the pull_request and the
# publish job of .github/workflows/image.yml (and runnable locally).
#
#   ci.sh from                  parse the Dockerfile's FROM line; prints
#                               VERSION=, BASE_REF= (and appends to $GITHUB_ENV)
#   ci.sh base-revision         pull the base image, require its
#                               org.opencontainers.image.revision label to equal
#                               the commit of upstream tag v<VERSION> (GH_TOKEN)
#   ci.sh build <tag> <sha>     docker build -t <tag>, OCI labels for this repo
#   ci.sh smoke <image>         the OC-D9 smoke test
#   ci.sh trivy-os <image>      GATE: Debian packages, HIGH/CRITICAL with a fix
#   ci.sh trivy-lib <image>     REPORT ONLY: language packages (upstream's
#                               node_modules), same severity filter, never fails
#
# Env: VERSION / BASE_REF (from `from`), TRIVY_IMAGE (pinned by digest),
# GITHUB_STEP_SUMMARY / GITHUB_ENV when on Actions.
set -euo pipefail

UPSTREAM_REPO=openclaw/openclaw
UPSTREAM_IMAGE=ghcr.io/openclaw/openclaw
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
TRIVY_IMAGE=${TRIVY_IMAGE:-aquasec/trivy:0.69.3@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c}
TRIVY_CACHE=${TRIVY_CACHE:-${RUNNER_TEMP:-/tmp}/trivy-cache}

die() { echo "::error::$*" >&2; exit 1; }
here() { cd "$(dirname "$0")/.."; }

# The stable-tag grammar of wave OC 5.2 (no betas, -N re-releases, -rDATE
# refreshes, variants or leading zeros).
VERSION_RE='^[0-9]{4}\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

cmd_from() {
  here
  local froms line ref version digest
  froms=$(grep -cE '^[[:space:]]*FROM[[:space:]]' Dockerfile || true)
  [ "$froms" = 1 ] || die "Dockerfile must have exactly one FROM line (found $froms)"
  line=$(grep -E '^[[:space:]]*FROM[[:space:]]' Dockerfile)
  # Exactly: FROM ghcr.io/openclaw/openclaw:<stable version>@sha256:<64 hex>
  [[ "$line" =~ ^FROM\ ghcr\.io/openclaw/openclaw:([0-9.]+)@sha256:([0-9a-f]{64})$ ]] \
    || die "FROM must be '${UPSTREAM_IMAGE}:<version>@sha256:<digest>', got: $line"
  version=${BASH_REMATCH[1]}
  digest=sha256:${BASH_REMATCH[2]}
  [[ "$version" =~ $VERSION_RE ]] || die "FROM tag '$version' is not a stable upstream version"
  ref="${UPSTREAM_IMAGE}:${version}@${digest}"
  echo "VERSION=$version"
  echo "BASE_REF=$ref"
  if [ -n "${GITHUB_ENV:-}" ]; then
    { echo "VERSION=$version"; echo "BASE_REF=$ref"; } >> "$GITHUB_ENV"
  fi
}

cmd_base_revision() {
  : "${VERSION:?run 'ci.sh from' first}" "${BASE_REF:?run 'ci.sh from' first}"
  command -v gh >/dev/null || die "gh CLI required"
  local type obj commit label
  read -r type obj < <(gh api "repos/${UPSTREAM_REPO}/git/ref/tags/v${VERSION}" \
                         --jq '.object.type + " " + .object.sha') \
    || die "upstream tag v${VERSION} not found in ${UPSTREAM_REPO}"
  if [ "$type" = tag ]; then  # annotated tag: dereference to its commit
    read -r type obj < <(gh api "repos/${UPSTREAM_REPO}/git/tags/${obj}" \
                           --jq '.object.type + " " + .object.sha')
  fi
  [ "$type" = commit ] || die "upstream tag v${VERSION} does not point at a commit ($type)"
  [[ "$obj" =~ ^[0-9a-f]{40}$ ]] || die "bad upstream commit '$obj'"
  commit=$obj

  docker pull --quiet "$BASE_REF" >/dev/null
  label=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$BASE_REF")
  {
    echo "### Base image provenance"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| FROM | \`${BASE_REF}\` |"
    echo "| upstream tag \`v${VERSION}\` | \`${commit}\` |"
    echo "| base label \`org.opencontainers.image.revision\` | \`${label:-<missing>}\` |"
    echo
  } >> "$SUMMARY"
  [ "$label" = "$commit" ] \
    || die "base revision label '${label:-<missing>}' != upstream v${VERSION} commit ${commit}"
  echo "base revision OK: v${VERSION} = ${commit}"
}

cmd_build() {
  local tag=${1:?image tag} sha=${2:?git sha}
  : "${VERSION:?run 'ci.sh from' first}" "${BASE_REF:?run 'ci.sh from' first}"
  here
  # The base image's OCI labels (source, revision, version) describe UPSTREAM;
  # override them so the published image names this repository and commit,
  # and keep the upstream reference in base.name / base.digest.
  docker build --pull \
    --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-maxkuminov/openclaw-tax-image}" \
    --label "org.opencontainers.image.revision=${sha}" \
    --label "org.opencontainers.image.version=${VERSION}" \
    --label "org.opencontainers.image.title=OpenClaw tax gateway" \
    --label "org.opencontainers.image.description=OpenClaw ${VERSION} (official upstream image) + poppler-utils, python3-pip, python3-venv" \
    --label "org.opencontainers.image.base.name=${BASE_REF%@*}" \
    --label "org.opencontainers.image.base.digest=${BASE_REF#*@}" \
    -t "$tag" .
}

cmd_smoke() {
  local img=${1:?image}
  : "${VERSION:?run 'ci.sh from' first}"
  local out parsed pdf owner user
  run() { docker run --rm --network none "$@"; }

  # 1. openclaw --version parses to the FROM tag's version. Upstream prints
  #    "OpenClaw 2026.8.2 (0965053)"; compare the parsed version only (G2).
  out=$(run --entrypoint node "$img" openclaw.mjs --version)
  parsed=$(sed -nE 's/^OpenClaw ([0-9]{4}\.[0-9]+\.[0-9]+)([[:space:]].*)?$/\1/p' <<<"$out" | head -n1)
  [ "$parsed" = "$VERSION" ] || die "openclaw --version printed '$out' (parsed '$parsed'), want $VERSION"

  # 2. the extras
  pdf=$(run --entrypoint pdftotext "$img" -v 2>&1 | head -n1)
  [[ "$pdf" == pdftotext\ version* ]] || die "pdftotext -v: $pdf"
  run --entrypoint python3 "$img" -m venv /tmp/smoke-venv \
    || die "python3 -m venv failed"
  run --entrypoint python3 "$img" -m pip --version >/dev/null \
    || die "python3 -m pip failed"

  # 3. no EXTERNALLY-MANAGED marker under any python3* directory
  run --entrypoint sh "$img" -c \
    'for f in /usr/lib/python3*/EXTERNALLY-MANAGED; do if [ -e "$f" ]; then echo "$f present"; exit 1; fi; done' \
    || die "EXTERNALLY-MANAGED marker present"

  # 4. pip cache owned by uid 1000 (node), and the image still runs as node
  owner=$(run --entrypoint stat "$img" -c '%u:%g' /home/node/.cache/pip)
  [ "$owner" = "1000:1000" ] || die "/home/node/.cache/pip owned by $owner, want 1000:1000"
  user=$(docker inspect --format '{{.Config.User}}' "$img")
  [ "$user" = node ] || die "image user is '$user', want node"

  {
    echo "### Smoke test: PASS"
    echo
    echo "| check | result |"
    echo "|---|---|"
    echo "| \`openclaw --version\` | \`${out}\` (= ${VERSION}) |"
    echo "| \`pdftotext -v\` | \`${pdf}\` |"
    echo "| \`python3 -m venv\`, \`python3 -m pip\` | ok |"
    echo "| \`/usr/lib/python3*/EXTERNALLY-MANAGED\` | absent |"
    echo "| \`/home/node/.cache/pip\` | ${owner} |"
    echo "| image user | ${user} |"
    echo
  } >> "$SUMMARY"
  echo "smoke OK: $out; $pdf"
}

# trivy <pkg-types> <json-out>: HIGH/CRITICAL with an available fix, vuln
# scanner only, .trivyignore honoured; never fails by itself.
trivy_json() {
  local types=$1 out=$2 img=$3
  here
  mkdir -p "$TRIVY_CACHE" "$(dirname "$out")"
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v "$PWD:/src:ro" \
    -v "$TRIVY_CACHE:/cache" \
    -v "$(dirname "$out"):/out" \
    "$TRIVY_IMAGE" image \
      --cache-dir /cache \
      --severity HIGH,CRITICAL --ignore-unfixed --exit-code 0 \
      --pkg-types "$types" --scanners vuln --no-progress \
      --ignorefile /src/.trivyignore \
      --format json --output "/out/$(basename "$out")" \
      "$img"
}

summarise() {  # summarise <json> <title>; prints the finding count
  local json=$1 title=$2 n
  n=$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$json")
  {
    echo "### ${title}: ${n} finding(s)"
    echo
    if [ "$n" -gt 0 ]; then
      jq -r '[.Results[]?.Vulnerabilities[]?] | group_by(.Severity) | map("- \(.[0].Severity): \(length)") | .[]' "$json"
      echo
      echo "<details><summary>findings</summary>"
      echo
      echo "| severity | id | package | installed | fixed |"
      echo "|---|---|---|---|---|"
      jq -r '[.Results[]?.Vulnerabilities[]?] | sort_by(.Severity, .VulnerabilityID) | .[:300][]
             | "| \(.Severity) | \(.VulnerabilityID) | \(.PkgName) | \(.InstalledVersion) | \(.FixedVersion // "") |"' "$json"
      echo
      echo "</details>"
      echo
    fi
  } >> "$SUMMARY"
  echo "$n"
}

cmd_trivy_os() {
  local img=${1:?image} json n
  json=${RUNNER_TEMP:-/tmp}/trivy-out/os.json
  trivy_json os "$json" "$img"
  n=$(summarise "$json" "Trivy OS gate (Debian packages, HIGH/CRITICAL with a fix)")
  if [ "$n" -gt 0 ]; then
    jq -r '[.Results[]?.Vulnerabilities[]?] | .[] | "\(.Severity) \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)"' "$json" | sort -u
    die "Trivy OS gate: $n HIGH/CRITICAL finding(s) with a fix"
  fi
  echo "Trivy OS gate: PASS (0 findings)"
}

cmd_trivy_lib() {
  local img=${1:?image} json n
  json=${RUNNER_TEMP:-/tmp}/trivy-out/lib.json
  # Report only: these are upstream's node_modules and the Node toolchain,
  # which this repository does not build (wave OC L8).
  trivy_json library "$json" "$img" || { echo "::warning::Trivy library report failed"; return 0; }
  n=$(summarise "$json" "Trivy library report (NOT gating: upstream node_modules)")
  echo "Trivy library report: $n finding(s), not gating"
}

case "${1:-}" in
  from)           cmd_from ;;
  base-revision)  cmd_base_revision ;;
  build)          shift; cmd_build "$@" ;;
  smoke)          shift; cmd_smoke "$@" ;;
  trivy-os)       shift; cmd_trivy_os "$@" ;;
  trivy-lib)      shift; cmd_trivy_lib "$@" ;;
  *) echo "usage: $0 from|base-revision|build <tag> <sha>|smoke <img>|trivy-os <img>|trivy-lib <img>" >&2; exit 2 ;;
esac
