FROM debian:bookworm-slim

LABEL maintainer="Homelab Admin"
LABEL description="Dedicated Left 4 Dead 2 Server using DepotDownloader to bypass SteamCMD anonymous login bugs"

ENV DEBIAN_FRONTEND=noninteractive

# Install 32-bit runtime dependencies for Source Engine & DepotDownloader
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        tar \
        perl \
        lib32gcc-s1 \
        lib32stdc++6 \
        libc6:i386 \
        libcurl4-gnutls-dev:i386 \
        locales \
    && rm -rf /var/lib/apt/lists/*

# Install DepotDownloader
ARG DEPOT_DOWNLOADER_VERSION=3.4.0
RUN mkdir -p /opt/depotdownloader && \
    curl -sSL "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOT_DOWNLOADER_VERSION}/DepotDownloader-linux-x64.zip" -o /tmp/dd.zip && \
    unzip -q /tmp/dd.zip -d /opt/depotdownloader && \
    chmod +x /opt/depotdownloader/DepotDownloader && \
    rm -f /tmp/dd.zip

# Create steam user (UID 1000)
RUN useradd -m -u 1000 -s /bin/bash steam && \
    mkdir -p /data /defaults && \
    chown -R steam:steam /data /defaults

COPY --chown=steam:steam entrypoint.sh /entrypoint.sh
COPY --chown=steam:steam server.cfg.template /defaults/server.cfg.template
RUN chmod +x /entrypoint.sh

USER steam
WORKDIR /data

EXPOSE 27015/tcp 27015/udp 26901/udp

ENTRYPOINT ["/entrypoint.sh"]
