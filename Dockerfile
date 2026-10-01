# syntax=docker/dockerfile:1.7
#
# One published image, one stage, and none of Valve's 10 GB inside it.
#
# The game install is downloaded on the first start of a volume from a pinned
# Steam depot manifest, and reused on every start after that. What this image
# carries is what is ours: the 32-bit runtime libraries, DepotDownloader (which
# has to ship now that it runs at start-up), the mod stack, the entrypoint and
# the config template.
#
# The mod stack is staged as a tree at /opt/l4d2-overlay that mirrors the
# install layout, and the entrypoint copies it over the downloaded install on
# every start. Staging it rather than writing straight into an install is what
# lets the install be replaced wholesale when Valve ships a new build without
# losing the mod stack - and it means addons/ and cfg/ are merged with
# different rules, because one of them belongs to us and the other to you.
#
#   just build          # or: podman build -t l4d2:dev .
#
# Docs: docs/architecture.md, docs/configuration.md, docs/eight-players.md,
#       docs/troubleshooting.md, docs/maintenance.md

ARG DEBIAN_IMAGE=debian:trixie-slim
ARG SERVER_VERSION=dev

FROM ${DEBIAN_IMAGE} AS server

ARG SERVER_VERSION

LABEL maintainer="Homelab Admin"
LABEL description="Left 4 Dead 2 Dedicated Server with SourceMod/MetaMod, l4dtoolz and templated configuration, 8 player slots"
LABEL org.opencontainers.image.version="${SERVER_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# The pin: where the game comes from
# ---------------------------------------------------------------------------
#
# The install spans two Steam depots of app 222860, and each carries its own
# manifest id: the game itself (222861) and the launcher depot that provides
# srcds_run and srcds_linux (222863). DepotDownloader takes one -depot per run
# and the two are versioned independently - the game depot has not moved since
# 2024, the launcher depot moves far more often - so pinning only the game
# would leave the server binary itself unpinned.
#
# A manifest id, not a build number: two runs that resolve to the same value
# fetch byte-identical files, and a different value is the only thing that makes
# the entrypoint download again. These are ARGs rather than constants so an
# operator can move a deployment to a new Valve build from .env, without
# waiting for - or even pulling - a new image.
ARG APP_ID=222860
# 222861 is the linux dedicated server: 116 977 files, ~9.5 GB. 222863 is 674
# files, the launcher. The SDK depot is not selected: -os linux never picks it.
ARG GAME_DEPOT=222861
ARG GAME_MANIFEST=4827977561765481436
ARG LAUNCHER_DEPOT=222863
ARG LAUNCHER_MANIFEST=868244163643826330

# DepotDownloader ships in the published image now - the download it performs
# is the entrypoint's first job, not the build's. That is the price of not
# baking the install in, and it is why the old one-shot `fetch` stage is gone.
ARG DEPOT_DOWNLOADER_VERSION=3.4.0
# DepotDownloader splits each depot manifest into chunks and downloads
# `-max-downloads` of them concurrently. 8 is the tool's own default and
# saturates a normal uplink; raise it for a fat pipe.
ARG MAX_DOWNLOADS=16

# AlliedModders release branch for BOTH MetaMod:Source and SourceMod. 1.12 is
# sourcemod.net's *stable* channel (its dev channel is 1.13, and the 1.11 line
# is kept as a legacy branch), and it is what the 5+/8-player plugin ecosystem
# is compiled against: on 1.11, l4dmultislots fails to load with
# "unsupported feature set; code is too new".
ARG SOURCEMOD_BRANCH=1.12

# Everything the entrypoint needs at run time, as environment variables: the
# pins and the downloader's limits are build arguments for readability, but
# they have to reach the start-up code that uses them.
ENV APP_ID=${APP_ID} \
    GAME_DEPOT=${GAME_DEPOT} \
    GAME_MANIFEST=${GAME_MANIFEST} \
    LAUNCHER_DEPOT=${LAUNCHER_DEPOT} \
    LAUNCHER_MANIFEST=${LAUNCHER_MANIFEST} \
    MAX_DOWNLOADS=${MAX_DOWNLOADS} \
    DEPOT_DOWNLOADER=/opt/depotdownloader/DepotDownloader

# The staged mod stack. Mirrors left4dead2/ so the entrypoint can copy
# `addons/` and `cfg/` with separate rules.
ENV OVERLAY_DIR=/opt/l4d2-overlay

# ---------------------------------------------------------------------------
# Runtime libraries and tools
# ---------------------------------------------------------------------------
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        lib32gcc-s1 \
        lib32stdc++6 \
        libc6:i386 \
        libcurl4-gnutls-dev:i386 \
        locales \
        tar \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# The steam user exists so the downloaded install has an owner that is not root.
# The volume is bind-mounted and keeps whatever ids the host has; the entrypoint
# runs as this user either way.
RUN useradd -m -u 1000 -s /bin/bash steam

RUN set -eux; \
    mkdir -p /opt/depotdownloader /opt/l4d2-overlay/left4dead2/addons /opt/l4d2-overlay/left4dead2/cfg; \
    curl -fsSL "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOT_DOWNLOADER_VERSION}/DepotDownloader-linux-x64.zip" -o /tmp/dd.zip; \
    unzip -q /tmp/dd.zip -d /opt/depotdownloader; \
    chmod +x /opt/depotdownloader/DepotDownloader; \
    rm -f /tmp/dd.zip

# ---------------------------------------------------------------------------
# MetaMod:Source + SourceMod
# ---------------------------------------------------------------------------
#
# Both are resolved to the newest build on SOURCEMOD_BRANCH, so a rebuild picks
# up whatever AlliedModders published - there is nothing to bump for them.
RUN set -eux; \
    ovl=/opt/l4d2-overlay/left4dead2; \
    cd /tmp; \
    mm="$(curl -fsSL "https://mms.alliedmods.net/mmsdrop/${SOURCEMOD_BRANCH}/mmsource-latest-linux")"; \
    curl -fsSL "https://mms.alliedmods.net/mmsdrop/${SOURCEMOD_BRANCH}/${mm}" -o mmsource.tar.gz; \
    sm="$(curl -fsSL "https://sm.alliedmods.net/smdrop/${SOURCEMOD_BRANCH}/sourcemod-latest-linux")"; \
    curl -fsSL "https://sm.alliedmods.net/smdrop/${SOURCEMOD_BRANCH}/${sm}" -o sourcemod.tar.gz; \
    # Both tarballs are rooted at addons/ - there is no component to strip.
    # Extract to the side and copy the contents in, so the merge into the
    # overlay cannot depend on which tarball was unpacked first.
    mkdir -p mm sm; \
    tar -xzf mmsource.tar.gz -C mm; \
    tar -xzf sourcemod.tar.gz -C sm; \
    cp -a mm/addons/. "${ovl}/addons/"; \
    cp -a sm/addons/. "${ovl}/addons/"; \
    rm -rf mm mmsource.tar.gz; \
    # SourceMod ships three cfg/sourcemod files. They are seeded, not forced:
    # the entrypoint copies cfg/ with no-clobber, so a server that has tuned
    # sourcemod.cfg keeps its own.
    cp -a sm/cfg/. "${ovl}/cfg/"; \
    rm -rf sm sourcemod.tar.gz; \
    # nextmap.smx vetoes the L4D2 nextmap cycle and breaks campaign rotation
    mkdir -p "${ovl}/addons/sourcemod/plugins/disabled"; \
    mv -f "${ovl}/addons/sourcemod/plugins/nextmap.smx" \
          "${ovl}/addons/sourcemod/plugins/disabled/"; \
    # 64-bit metamod binaries only produce ELFCLASS64 dlopen warnings in 32-bit srcds
    rm -rf "${ovl}/addons/metamod/bin/linux64"

# ---------------------------------------------------------------------------
# l4dtoolz
# ---------------------------------------------------------------------------
#
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
    ovl=/opt/l4d2-overlay/left4dead2; \
    curl -fsSL "https://github.com/lakwsh/l4dtoolz/releases/download/${L4DTOOLZ_VERSION}/l4dtoolz-${L4DTOOLZ_VERSION}-${L4DTOOLZ_BUILD}.zip" -o /tmp/l4dtoolz.zip; \
    unzip -q /tmp/l4dtoolz.zip -d /tmp/l4dtoolz; \
    install -m 0644 /tmp/l4dtoolz/l4dtoolz.so "${ovl}/addons/l4dtoolz.so"; \
    install -m 0644 /tmp/l4dtoolz/l4dtoolz.vdf "${ovl}/addons/l4dtoolz.vdf"; \
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
    ovl=/opt/l4d2-overlay/left4dead2; \
    sm="${ovl}/addons/sourcemod"; \
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
    sm=/opt/l4d2-overlay/left4dead2/addons/sourcemod; \
    curl -fsSL -o /tmp/mc.zip \
        "https://github.com/fbef0102/L4D1_2-Plugins/releases/download/Multi-Colors/multicolors.zip"; \
    unzip -q /tmp/mc.zip -d /tmp/mc; \
    cp -r /tmp/mc/scripting/include/. "${sm}/scripting/include/"; \
    rm -rf /tmp/mc /tmp/mc.zip

# Ship the cvar that turns the spare slots into survivors. It is copied with
# no-clobber like the rest of cfg/, so an operator who has tuned it keeps their
# value.
COPY l4dmultislots.cfg /opt/l4d2-overlay/left4dead2/cfg/sourcemod/l4dmultislots.cfg

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

COPY server_custom.cfg /defaults/server_custom.cfg

COPY entrypoint.sh /entrypoint.sh
COPY server.cfg.template /defaults/server.cfg.template
RUN chmod +x /entrypoint.sh

USER steam
WORKDIR /data

EXPOSE 27015/tcp 27015/udp 26901/udp

ENTRYPOINT ["/entrypoint.sh"]
