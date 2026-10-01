# syntax=docker/dockerfile:1.7
#
# Targets:
#
#   fetch   one-shot DepotDownloader stage, never published
#   base    vanilla dedicated server, downloaded at BUILD time and baked in, plus
#           the 32-bit runtime libraries. Never published: it exists so the
#           image below is provably layered on an unmodified install, and so
#           that rebuilding after a change to the entrypoint or the config
#           template hits the build cache instead of re-downloading 10 GB.
#   server  the published image: base + MetaMod:Source + SourceMod + l4dtoolz,
#           the entrypoint, the config template, and the image-level cvars.
#           This is the last stage, so a bare `podman build .` produces it.
#
#   just build          # or: podman build -t l4d2:dev .
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
# server - the published image
# ===========================================================================
FROM base AS server

ARG SERVER_VERSION

LABEL description="Left 4 Dead 2 Dedicated Server with SourceMod/MetaMod, l4dtoolz and templated configuration, 8 player slots"
LABEL org.opencontainers.image.version="${SERVER_VERSION}"

# AlliedModders release branch for BOTH MetaMod:Source and SourceMod. 1.12 is
# sourcemod.net's *stable* channel (its dev channel is 1.13, and the 1.11 line
# is kept as a legacy branch), and it is what the 5+/8-player plugin ecosystem
# is compiled against: on 1.11, l4dmultislots fails to load with
# "unsupported feature set; code is too new".
ARG SOURCEMOD_BRANCH=1.12

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl tar unzip && \
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

# l4dtoolz lifts L4D2's 4-survivor cap on co-op campaigns, which has nothing to
# do with `+maxplayers`: the engine hard-codes 18 client slots and overwrites
# that cvar regardless, while the campaign cap of 4 comes from the Steam lobby
# reservation. Its cvars live in the image-level override below.
#
# l4dtoolz.vdf points at "addons/l4dtoolz", so both files belong directly in
# addons/ - the vdf is what makes the engine load the extension.
ARG L4DTOOLZ_VERSION=2.5.1
ARG L4DTOOLZ_BUILD=2155

RUN set -eux; \
    curl -sSL "https://github.com/lakwsh/l4dtoolz/releases/download/${L4DTOOLZ_VERSION}/l4dtoolz-${L4DTOOLZ_VERSION}-${L4DTOOLZ_BUILD}.zip" -o /tmp/l4dtoolz.zip; \
    unzip -q /tmp/l4dtoolz.zip -d /tmp/l4dtoolz; \
    install -o steam -g steam -m 0644 /tmp/l4dtoolz/l4dtoolz.so \
        /opt/l4d2/left4dead2/addons/l4dtoolz.so; \
    install -o steam -g steam -m 0644 /tmp/l4dtoolz/l4dtoolz.vdf \
        /opt/l4d2/left4dead2/addons/l4dtoolz.vdf; \
    rm -rf /tmp/l4dtoolz /tmp/l4dtoolz.zip

# ---------------------------------------------------------------------------
# Left 4 DHooks and the 5+ survivor stack
# ---------------------------------------------------------------------------
#
# The native half of DHooks (extensions/dhooks.ext.so) already ships inside the
# SourceMod tarball, so the native is not the hard part. What is not on any
# package feed is left4dhooks.smx - the plugin front-end - so that one archive
# is vendored under assets/ and checked against a pinned sha256. The plugins
# that use it come from a public repo, pinned to a commit.
#
# What the stack is for: l4dtoolz drops the lobby reservation that caps a co-op
# campaign at 4 survivors, l4d_unreservelobby stops it coming back, and
# l4dmultislots turns the spare slots into actual survivors - a joining 5th
# player gets a survivor instead of ending up a spectator.
ARG LEFT4DHOOKS_SHA256=1536aac340787fe6d740a7ac2696c64a3b0fda160e57644a887f5b5481e12675
ARG L4D_PLUGINS_REF=3494e4786210f143d642e12b2ce6f6918bb7160b
ARG L4D_PLUGINS_REPO=https://raw.githubusercontent.com/fbef0102/L4D1_2-Plugins

COPY assets/left4dhooks.zip /tmp/left4dhooks.zip

RUN set -eux; \
    sm=/opt/l4d2/left4dead2/addons/sourcemod; \
    echo "${LEFT4DHOOKS_SHA256}  /tmp/left4dhooks.zip" | sha256sum -c -; \
    unzip -q /tmp/left4dhooks.zip -d /tmp; \
    # the archive holds a `sourcemod/` tree and addons/ is where it belongs
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

# l4dmultislots is compiled against the Multi-Colors include, and SourceMod
# decides a library is present by finding its .inc on disk at load time.
RUN set -eux; \
    curl -fsSL -o /tmp/mc.zip \
        "https://github.com/fbef0102/L4D1_2-Plugins/releases/download/Multi-Colors/multicolors.zip"; \
    unzip -q /tmp/mc.zip -d /tmp/mc; \
    cp -r /tmp/mc/scripting/include/. \
        /opt/l4d2/left4dead2/addons/sourcemod/scripting/include/; \
    rm -rf /tmp/mc /tmp/mc.zip; \
    chown -R steam:steam /opt/l4d2/left4dead2/addons; \
    chown steam:steam /opt/l4d2/left4dead2/cfg

# Ship the two cvars that make it a 5+ server out of the box. See
# docs/eight-players.md for how to change them on the volume.
COPY --chown=steam:steam l4dmultislots.cfg /opt/l4d2/left4dead2/cfg/sourcemod/l4dmultislots.cfg


COPY --chown=steam:steam server_custom.cfg /defaults/server_custom.cfg

COPY --chown=steam:steam entrypoint.sh /entrypoint.sh
COPY --chown=steam:steam server.cfg.template /defaults/server.cfg.template
RUN chmod +x /entrypoint.sh

USER steam
WORKDIR /data

ENTRYPOINT ["/entrypoint.sh"]
