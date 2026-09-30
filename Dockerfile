# syntax=docker/dockerfile:1.7
#
# Targets, in the order they layer:
#
#   fetch  - one-shot DepotDownloader stage, never published
#   base   - vanilla dedicated server, downloaded at BUILD time and baked in.
#            No entrypoint, no config, no mods, no runtime download: the game
#            files are exactly what DepotDownloader pulled from Valve's depots.
#            A build stage only - it is not pushed.
#   qol    - FROM base, adds MetaMod:Source + SourceMod, the entrypoint, the
#            config template and a server locked to 8 player slots.
#   coop8  - FROM qol, adds l4dtoolz and the cvars that lift L4D2's 4-survivor
#            cap on co-op campaigns.
#
#   podman build --target qol   -t l4d2:1.0.3-qol   .
#   podman build --target coop8 -t l4d2:1.0.3-coop8 .
#
# The ~10 GB game payload is downloaded once, in the `fetch` stage, so the
# downloader never ends up inside a published image.
#
# Docs: docs/architecture.md, docs/configuration.md, docs/eight-players.md,
#       docs/troubleshooting.md, docs/maintenance.md

ARG DEBIAN_IMAGE=debian:trixie-slim
ARG SERVER_VERSION=dev

# ===========================================================================
# fetch - one-shot downloader stage, never published
# ===========================================================================
FROM ${DEBIAN_IMAGE} AS fetch

ARG DEPOT_DOWNLOADER_VERSION=3.4.0
ARG APP_ID=222860
# DepotDownloader splits each depot manifest into chunks and downloads
# `-max-downloads` of them concurrently. 8 is the tool's own default and
# saturates a normal uplink; raise it for a fat pipe.
ARG MAX_DOWNLOADS=16

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl unzip && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/depotdownloader /opt/l4d2 && \
    curl -sSL "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOT_DOWNLOADER_VERSION}/DepotDownloader-linux-x64.zip" -o /tmp/dd.zip && \
    unzip -q /tmp/dd.zip -d /opt/depotdownloader && \
    chmod +x /opt/depotdownloader/DepotDownloader && \
    rm -f /tmp/dd.zip

# Anonymous login, dedicated-server subscription, linux depot set.
#
# The tool drops its `.DepotDownloader` bookkeeping - manifest copies and a
# staging area - into the install directory, so it is removed afterwards: the
# published image carries game files and nothing else.
WORKDIR /opt
RUN /opt/depotdownloader/DepotDownloader \
        -app "${APP_ID}" \
        -os linux \
        -dir /opt/l4d2 \
        -max-downloads "${MAX_DOWNLOADS}" && \
    rm -rf /opt/l4d2/.DepotDownloader

# ===========================================================================
# base - the published vanilla server
# ===========================================================================
FROM ${DEBIAN_IMAGE} AS base

ARG SERVER_VERSION

LABEL maintainer="Homelab Admin"
LABEL description="Left 4 Dead 2 Dedicated Server, game files baked in at build time (no customizations)"
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
    && rm -rf /var/lib/apt/lists/*

# The steam user is created *before* the install lands, so the COPY can set the
# ownership itself. A `chown -R` afterwards would restamp all 20 GB of metadata
# and copy the entire tree into a second 10 GB layer.
RUN useradd -m -u 1000 -s /bin/bash steam && \
    mkdir -p /data

COPY --from=fetch --chown=steam:steam /opt/l4d2 /opt/l4d2

USER steam
WORKDIR /data

EXPOSE 27015/tcp 27015/udp 26901/udp

# ===========================================================================
# qol - base + SourceMod/MetaMod + entrypoint, locked to 8 players
# ===========================================================================
FROM base AS qol

ARG SERVER_VERSION

LABEL description="Left 4 Dead 2 Dedicated Server with SourceMod/MetaMod and templated configuration, locked to 8 players"
LABEL org.opencontainers.image.version="${SERVER_VERSION}"

# AlliedModders release branch for BOTH MetaMod:Source and SourceMod. 1.12 is
# the current branch; 1.11 was the last stable one. 1.12 is what the 5+/8-player
# plugin ecosystem is compiled against - on 1.11 the likes of l4dmultislots fail
# to load with "unsupported feature set; code is too new".
ARG SOURCEMOD_BRANCH=1.12

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl tar && \
    rm -rf /var/lib/apt/lists/*

# MetaMod:Source + SourceMod, baked into the image copy of the game tree.
# /tmp is used rather than the install dir so the archives cannot be mistaken
# for game content.
RUN set -eux; \
    cd /tmp; \
    mm="$(curl -sSL "https://mms.alliedmods.net/mmsdrop/${SOURCEMOD_BRANCH}/mmsource-latest-linux")"; \
    curl -sSL "https://mms.alliedmods.net/mmsdrop/${SOURCEMOD_BRANCH}/${mm}" -o mmsource.tar.gz; \
    sm="$(curl -sSL "https://sm.alliedmods.net/smdrop/${SOURCEMOD_BRANCH}/sourcemod-latest-linux")"; \
    curl -sSL "https://sm.alliedmods.net/smdrop/${SOURCEMOD_BRANCH}/${sm}" -o sourcemod.tar.gz; \
    tar -xzf mmsource.tar.gz -C /opt/l4d2/left4dead2; \
    tar -xzf sourcemod.tar.gz -C /opt/l4d2/left4dead2; \
    rm -f mmsource.tar.gz sourcemod.tar.gz; \
    # nextmap.smx vetoes the L4D2 nextmap cycle and breaks campaign rotation
    mkdir -p /opt/l4d2/left4dead2/addons/sourcemod/plugins/disabled; \
    mv -f /opt/l4d2/left4dead2/addons/sourcemod/plugins/nextmap.smx \
          /opt/l4d2/left4dead2/addons/sourcemod/plugins/disabled/; \
    # 64-bit metamod binaries only produce ELFCLASS64 dlopen warnings in 32-bit srcds
    rm -rf /opt/l4d2/left4dead2/addons/metamod/bin/linux64; \
    # Only what the archives touched needs an owner: base already handed the
    # install to steam, and re-stamping all 10 GB here would duplicate it into
    # a second layer. The tarballs carry a `cfg/` entry of their own, so
    # extracting as root hands that one directory back to root - fix it by
    # name rather than recursing.
    chown -R steam:steam /opt/l4d2/left4dead2/addons; \
    chown steam:steam /opt/l4d2/left4dead2/cfg

COPY --chown=steam:steam entrypoint.sh /entrypoint.sh
COPY --chown=steam:steam server.cfg.template /defaults/server.cfg.template
RUN chmod +x /entrypoint.sh

USER steam
WORKDIR /data

ENTRYPOINT ["/entrypoint.sh"]

# ===========================================================================
# coop8 - qol + l4dtoolz, so a co-op campaign can seat more than 4 survivors
# ===========================================================================
#
# `+maxplayers` is not what limits a co-op campaign: the engine's own client
# limit is 18 (and it overrides that cvar regardless of what is passed), while
# the *campaign* cap of 4 comes from the Steam lobby reservation the server
# registers. l4dtoolz exposes the cvars that lift the lobby cap and raise the
# player limit; the values live in the image-level overrides below.
FROM qol AS coop8

ARG L4DTOOLZ_VERSION=2.5.1
ARG L4DTOOLZ_BUILD=2155

LABEL description="Left 4 Dead 2 Dedicated Server with SourceMod/MetaMod and l4dtoolz, lifting the 4-player co-op campaign cap"
LABEL org.opencontainers.image.version="${SERVER_VERSION}"

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends unzip && \
    rm -rf /var/lib/apt/lists/*

# l4dtoolz.vdf points at "addons/l4dtoolz", so both files belong directly in
# addons/ - the vdf is what makes the engine load the extension.
RUN set -eux; \
    curl -sSL "https://github.com/lakwsh/l4dtoolz/releases/download/${L4DTOOLZ_VERSION}/l4dtoolz-${L4DTOOLZ_VERSION}-${L4DTOOLZ_BUILD}.zip" -o /tmp/l4dtoolz.zip; \
    unzip -q /tmp/l4dtoolz.zip -d /tmp/l4dtoolz; \
    install -o steam -g steam -m 0644 /tmp/l4dtoolz/l4dtoolz.so \
        /opt/l4d2/left4dead2/addons/l4dtoolz.so; \
    install -o steam -g steam -m 0644 /tmp/l4dtoolz/l4dtoolz.vdf \
        /opt/l4d2/left4dead2/addons/l4dtoolz.vdf; \
    rm -rf /tmp/l4dtoolz /tmp/l4dtoolz.zip

COPY --chown=steam:steam server_custom.cfg /defaults/server_custom.cfg

USER steam
WORKDIR /data
