# syntax=docker/dockerfile:1.7
#
# Multi-stage build with game baked in and optimized layer caching.
#
# Stages, in the order they layer:
#
#   fetch    - one-shot DepotDownloader stage, downloads game files (never published)
#   base     - vanilla dedicated server, game files baked in at build time
#   mods     - stages the 8-player mod overlay independently for cache efficiency
#   vanilla  - FROM base, adds entrypoint and configuration (vanilla 4-player server)
#   server   - FROM vanilla, adds the mod overlay (published 8-player default server)
#
#   podman build --target vanilla -t l4d2:vanilla .
#   podman build --target server  -t l4d2:latest  .
#
# Docs: docs/architecture.md, docs/configuration.md, docs/eight-players.md,
#       docs/troubleshooting.md, docs/maintenance.md

ARG DEBIAN_IMAGE=debian:trixie-slim
ARG SERVER_VERSION=dev

# ---------------------------------------------------------------------------
# Pins: upstream game depots, tools, and mod versions
# ---------------------------------------------------------------------------
ARG APP_ID=222860
# 222861 is the linux dedicated server: 116 977 files, ~9.5 GB. 222863 is 674
# files, the launcher. The SDK depot is not selected: -os linux never picks it.
ARG GAME_DEPOT=222861
ARG GAME_MANIFEST=4827977561765481436
ARG LAUNCHER_DEPOT=222863
ARG LAUNCHER_MANIFEST=868244163643826330

ARG DEPOT_DOWNLOADER_VERSION=3.4.0
ARG MAX_DOWNLOADS=16

# AlliedModders release branch for BOTH MetaMod:Source and SourceMod (1.12 stable)
ARG SOURCEMOD_BRANCH=1.12
ARG L4DTOOLZ_VERSION=2.5.1
ARG L4DTOOLZ_BUILD=2155
ARG LEFT4DHOOKS_SHA256=1536aac340787fe6d740a7ac2696c64a3b0fda160e57644a887f5b5481e12675
ARG L4D_PLUGINS_REF=35294df46f414a52f891d807c2fcadeb760acda4
ARG L4D_PLUGINS_REPO=https://raw.githubusercontent.com/fbef0102/L4D1_2-Plugins

# ===========================================================================
# fetch - one-shot downloader stage, never published
# ===========================================================================
FROM ${DEBIAN_IMAGE} AS fetch

ARG APP_ID
ARG GAME_DEPOT
ARG GAME_MANIFEST
ARG LAUNCHER_DEPOT
ARG LAUNCHER_MANIFEST
ARG DEPOT_DOWNLOADER_VERSION
ARG MAX_DOWNLOADS

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl unzip && \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    mkdir -p /opt/depotdownloader /opt/l4d2; \
    curl -fsSL "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOT_DOWNLOADER_VERSION}/DepotDownloader-linux-x64.zip" -o /tmp/dd.zip; \
    unzip -q /tmp/dd.zip -d /opt/depotdownloader; \
    chmod +x /opt/depotdownloader/DepotDownloader; \
    rm -f /tmp/dd.zip

# Pinned depot downloads into /opt/l4d2.
# Cache mount preserves manifest chunks across builds if re-run.
RUN --mount=type=cache,target=/root/.local/share/DepotDownloader \
    /opt/depotdownloader/DepotDownloader \
        -app "${APP_ID}" \
        -depot "${LAUNCHER_DEPOT}" \
        -manifest "${LAUNCHER_MANIFEST}" \
        -dir /opt/l4d2 \
        -max-downloads "${MAX_DOWNLOADS}" && \
    /opt/depotdownloader/DepotDownloader \
        -app "${APP_ID}" \
        -depot "${GAME_DEPOT}" \
        -manifest "${GAME_MANIFEST}" \
        -dir /opt/l4d2 \
        -max-downloads "${MAX_DOWNLOADS}" && \
    rm -rf /opt/l4d2/.DepotDownloader

# ===========================================================================
# base - the vanilla server install baked in
# ===========================================================================
FROM ${DEBIAN_IMAGE} AS base

ARG SERVER_VERSION

LABEL maintainer="Homelab Admin"
LABEL description="Left 4 Dead 2 Dedicated Server, game files baked in at build time"
LABEL org.opencontainers.image.version="${SERVER_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# Install 32-bit runtime dependencies for Source Engine
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        lib32gcc-s1 \
        lib32stdc++6 \
        libc6:i386 \
        libcurl4-gnutls-dev:i386 \
        locales \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# The steam user is created *before* the install lands, so the COPY can set
# ownership directly. A recursive chown afterwards would restamp all metadata
# and duplicate the entire ~10 GB tree into a second layer.
RUN useradd -m -u 1000 -s /bin/bash steam && \
    mkdir -p /data

COPY --from=fetch --chown=steam:steam /opt/l4d2 /opt/l4d2

USER steam
WORKDIR /data

EXPOSE 27015/tcp 27015/udp 26901/udp

# ===========================================================================
# mods - downloads and stages the 8-player mod overlay independently
# ===========================================================================
FROM ${DEBIAN_IMAGE} AS mods

ARG SOURCEMOD_BRANCH
ARG L4DTOOLZ_VERSION
ARG L4DTOOLZ_BUILD
ARG LEFT4DHOOKS_SHA256
ARG L4D_PLUGINS_REF
ARG L4D_PLUGINS_REPO

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl tar unzip && \
    rm -rf /var/lib/apt/lists/*

# MetaMod:Source + SourceMod (branch 1.12 stable)
RUN set -eux; \
    ovl=/opt/l4d2-overlay/left4dead2; \
    mkdir -p "${ovl}/addons" "${ovl}/cfg/sourcemod"; \
    cd /tmp; \
    mm="$(curl -fsSL "https://mms.alliedmods.net/mmsdrop/${SOURCEMOD_BRANCH}/mmsource-latest-linux")"; \
    curl -fsSL "https://mms.alliedmods.net/mmsdrop/${SOURCEMOD_BRANCH}/${mm}" -o mmsource.tar.gz; \
    sm="$(curl -fsSL "https://sm.alliedmods.net/smdrop/${SOURCEMOD_BRANCH}/sourcemod-latest-linux")"; \
    curl -fsSL "https://sm.alliedmods.net/smdrop/${SOURCEMOD_BRANCH}/${sm}" -o sourcemod.tar.gz; \
    mkdir -p mm sm; \
    tar -xzf mmsource.tar.gz -C mm; \
    tar -xzf sourcemod.tar.gz -C sm; \
    cp -a mm/addons/. "${ovl}/addons/"; \
    cp -a sm/addons/. "${ovl}/addons/"; \
    cp -a sm/cfg/. "${ovl}/cfg/"; \
    rm -rf mm sm mmsource.tar.gz sourcemod.tar.gz; \
    mkdir -p "${ovl}/addons/sourcemod/plugins/disabled"; \
    mv -f "${ovl}/addons/sourcemod/plugins/nextmap.smx" \
          "${ovl}/addons/sourcemod/plugins/disabled/"; \
    rm -rf "${ovl}/addons/metamod/bin/linux64"

# l4dtoolz
RUN set -eux; \
    ovl=/opt/l4d2-overlay/left4dead2; \
    curl -fsSL "https://github.com/lakwsh/l4dtoolz/releases/download/${L4DTOOLZ_VERSION}/l4dtoolz-${L4DTOOLZ_VERSION}-${L4DTOOLZ_BUILD}.zip" -o /tmp/l4dtoolz.zip; \
    unzip -q /tmp/l4dtoolz.zip -d /tmp/l4dtoolz; \
    install -m 0644 /tmp/l4dtoolz/l4dtoolz.so "${ovl}/addons/l4dtoolz.so"; \
    install -m 0644 /tmp/l4dtoolz/l4dtoolz.vdf "${ovl}/addons/l4dtoolz.vdf"; \
    rm -rf /tmp/l4dtoolz /tmp/l4dtoolz.zip

# Left 4 DHooks and 5+ survivor stack
COPY assets/left4dhooks.zip /tmp/left4dhooks.zip

RUN set -eux; \
    ovl=/opt/l4d2-overlay/left4dead2; \
    sm="${ovl}/addons/sourcemod"; \
    echo "${LEFT4DHOOKS_SHA256}  /tmp/left4dhooks.zip" | sha256sum -c -; \
    unzip -q /tmp/left4dhooks.zip -d /tmp; \
    cp -r /tmp/sourcemod/. "${sm}/"; \
    fetch() { \
        for dir in l4dmultislots l4d_CreateSurvivorBot l4d_unreservelobby; do \
            curl -fsSL "${L4D_PLUGINS_REPO}/${L4D_PLUGINS_REF}/${dir}/$1" -o /tmp/dl && return 0; \
        done; \
        echo "could not fetch $1" >&2; return 1; \
    }; \
    fetch plugins/l4d_unreservelobby.smx        && mv /tmp/dl "${sm}/plugins/l4d_unreservelobby.smx"; \
    fetch plugins/l4dmultislots.smx             && mv /tmp/dl "${sm}/plugins/l4dmultislots.smx"; \
    fetch plugins/l4d_CreateSurvivorBot.smx     && mv /tmp/dl "${sm}/plugins/l4d_CreateSurvivorBot.smx"; \
    fetch gamedata/l4d_CreateSurvivorBot.txt    && mv /tmp/dl "${sm}/gamedata/l4d_CreateSurvivorBot.txt"; \
    fetch translations/l4dmultislots.phrases.txt && mv /tmp/dl "${sm}/translations/l4dmultislots.phrases.txt"; \
    rm -rf /tmp/sourcemod /tmp/left4dhooks.zip /tmp/dl

# Multi-Colors include
RUN set -eux; \
    sm=/opt/l4d2-overlay/left4dead2/addons/sourcemod; \
    curl -fsSL -o /tmp/mc.zip \
        "https://github.com/fbef0102/L4D1_2-Plugins/releases/download/Multi-Colors/multicolors.zip"; \
    unzip -q /tmp/mc.zip -d /tmp/mc; \
    cp -r /tmp/mc/scripting/include/. "${sm}/scripting/include/"; \
    rm -rf /tmp/mc /tmp/mc.zip

COPY l4dmultislots.cfg /opt/l4d2-overlay/left4dead2/cfg/sourcemod/l4dmultislots.cfg

# ===========================================================================
# vanilla - base + entrypoint + config template (clean 4-player vanilla)
# ===========================================================================
FROM base AS vanilla

ARG SERVER_VERSION

LABEL description="Left 4 Dead 2 Dedicated Server, vanilla 4-player"
LABEL org.opencontainers.image.version="${SERVER_VERSION}"

USER root

COPY entrypoint.py /entrypoint.py
COPY server.cfg.template /defaults/server.cfg.template
RUN chmod +x /entrypoint.py

USER steam
WORKDIR /data

ENTRYPOINT ["/entrypoint.py"]

# ===========================================================================
# server - vanilla + 8-player mod overlay (published default image)
# ===========================================================================
FROM vanilla AS server

ARG SERVER_VERSION

LABEL description="Left 4 Dead 2 Dedicated Server with SourceMod/MetaMod, l4dtoolz and 8 player slots"
LABEL org.opencontainers.image.version="${SERVER_VERSION}"

USER root

COPY --from=mods --chown=steam:steam /opt/l4d2-overlay /opt/l4d2-overlay
COPY server_custom.cfg /defaults/server_custom.cfg

USER steam
WORKDIR /data

ENTRYPOINT ["/entrypoint.py"]
