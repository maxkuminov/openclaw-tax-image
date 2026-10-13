# OpenClaw tax gateway image = upstream's official image + Oksana's extras.
#
# The FROM line is the whole version policy: one upstream STABLE tag pinned by
# its multi-arch index digest. Renovate bumps tag and digest together
# (renovate.json); scripts/ci.sh refuses any other FROM shape and checks the
# base image's org.opencontainers.image.revision against upstream tag v<version>.
FROM ghcr.io/openclaw/openclaw:2026.8.2@sha256:5d25165995041caa6a7175bec82b25ad98c44eb269bb42435da8e27ec06e6be4

USER root
# - apt-get upgrade: the OS layer is ours to fix (the Trivy OS gate blocks on
#   HIGH/CRITICAL findings with a fix), so every rebuild takes Debian's fixes.
# - poppler-utils (pdftotext), python3-pip, python3-venv: the tax skills.
# - EXTERNALLY-MANAGED removed by GLOB, so a Debian/Python base change cannot
#   silently keep the marker (wave OC, OC-D9).
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get -y upgrade && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      poppler-utils python3-pip python3-venv && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /usr/lib/python3*/EXTERNALLY-MANAGED && \
    mkdir -p /home/node/.cache/pip && \
    chown node:node /home/node/.cache/pip
USER node
