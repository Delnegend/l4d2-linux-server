#!/usr/bin/env bash
set -e

echo "=================================================="
echo " Left 4 Dead 2 Linux Dedicated Server (Bootstrap) "
echo "=================================================="

DATA_DIR="/data"
APP_ID=222860
DEPOT_DOWNLOADER="/opt/depotdownloader/DepotDownloader"

# Default environment values
PORT="${PORT:-27015}"
STEAM_PORT="${STEAM_PORT:-26901}"
DEFAULT_MAP="${DEFAULT_MAP:-c1m1_hotel}"
MAX_PLAYERS="${MAX_PLAYERS:-8}"
SERVER_NAME="${SERVER_NAME:-Left 4 Dead 2 Dedicated Server}"
RCON_PASSWORD="${RCON_PASSWORD:-ChangeMeRcon123}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
STEAM_GROUP_ID="${STEAM_GROUP_ID:-}"
STEAM_GROUP_EXCLUSIVE="${STEAM_GROUP_EXCLUSIVE:-0}"
SV_CONSISTENCY="${SV_CONSISTENCY:-0}"
SV_PURE="${SV_PURE:-0}"
AUTO_UPDATE="${AUTO_UPDATE:-false}"
VALIDATE_ON_BOOT="${VALIDATE_ON_BOOT:-false}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

# Check if server installation exists
NEEDS_DOWNLOAD=false
if [ ! -f "${DATA_DIR}/srcds_run" ] || [ ! -f "${DATA_DIR}/srcds_linux" ]; then
    echo "[Bootstrap] No existing server installation found in ${DATA_DIR}."
    NEEDS_DOWNLOAD=true
elif [ "${AUTO_UPDATE}" = "true" ]; then
    echo "[Bootstrap] AUTO_UPDATE is set to true. Checking for updates..."
    NEEDS_DOWNLOAD=true
fi

if [ "${NEEDS_DOWNLOAD}" = "true" ]; then
    echo "[Bootstrap] Running DepotDownloader (anonymous download for App ID ${APP_ID})..."
    DD_ARGS=(-app "${APP_ID}" -os linux -dir "${DATA_DIR}")

    if [ "${VALIDATE_ON_BOOT}" = "true" ]; then
        DD_ARGS+=(-validate)
    fi

    "${DEPOT_DOWNLOADER}" "${DD_ARGS[@]}"
    echo "[Bootstrap] DepotDownloader finished successfully."
fi

# Ensure executable permissions on binaries
chmod +x "${DATA_DIR}/srcds_run" "${DATA_DIR}/srcds_linux" 2>/dev/null || true

# Ensure steamclient.so is linked to ~/.steam/sdk32 for Valve Steam API
mkdir -p "${HOME}/.steam/sdk32"
ln -sf "${DATA_DIR}/bin/steamclient.so" "${HOME}/.steam/sdk32/steamclient.so"

# Template server.cfg on every startup to ensure environment variables are the source of truth
CFG_DIR="${DATA_DIR}/left4dead2/cfg"
mkdir -p "${CFG_DIR}"

echo "[Bootstrap] Templating server.cfg from /defaults/server.cfg.template..."
export SERVER_NAME RCON_PASSWORD SERVER_PASSWORD STEAM_GROUP_ID STEAM_GROUP_EXCLUSIVE SV_CONSISTENCY SV_PURE
# Substitute environment variables into template
perl -pe 's/\$\{(\w+)\}/defined($ENV{$1}) ? $ENV{$1} : $&/ge' /defaults/server.cfg.template > "${CFG_DIR}/server.cfg"

# Optional SourceMod / MetaMod installation
if [ "${INSTALL_SOURCEMOD:-false}" = "true" ] && [ ! -d "${DATA_DIR}/left4dead2/addons/sourcemod" ]; then
    echo "[Bootstrap] INSTALL_SOURCEMOD requested. Installing MetaMod:Source and SourceMod..."
    mkdir -p /tmp/sm
    cd /tmp/sm
    
    # Download latest MetaMod:Source 1.11
    MM_URL=$(curl -sSL "https://mms.alliedmods.net/mmsdrop/1.11/mmsource-latest-linux")
    curl -sSL "https://mms.alliedmods.net/mmsdrop/1.11/${MM_URL}" -o mmsource.tar.gz
    tar -xzf mmsource.tar.gz -C "${DATA_DIR}/left4dead2"
    
    # Download latest SourceMod 1.11
    SM_URL=$(curl -sSL "https://sm.alliedmods.net/smdrop/1.11/sourcemod-latest-linux")
    curl -sSL "https://sm.alliedmods.net/smdrop/1.11/${SM_URL}" -o sourcemod.tar.gz
    tar -xzf sourcemod.tar.gz -C "${DATA_DIR}/left4dead2"
    
    rm -rf /tmp/sm
    echo "[Bootstrap] MetaMod:Source and SourceMod installed."
fi

# SourceMod / MetaMod optimizations for L4D2:
# 1. Disable nextmap.smx (incompatible with L4D2 campaigns)
if [ -f "${DATA_DIR}/left4dead2/addons/sourcemod/plugins/nextmap.smx" ]; then
    echo "[Bootstrap] Disabling nextmap.smx (incompatible with L4D2)..."
    mkdir -p "${DATA_DIR}/left4dead2/addons/sourcemod/plugins/disabled"
    mv -f "${DATA_DIR}/left4dead2/addons/sourcemod/plugins/nextmap.smx" \
          "${DATA_DIR}/left4dead2/addons/sourcemod/plugins/disabled/" 2>/dev/null || true
fi

# 2. Remove 64-bit metamod binaries to silence ELFCLASS64 dlopen warnings in 32-bit srcds
if [ -d "${DATA_DIR}/left4dead2/addons/metamod/bin/linux64" ]; then
    rm -rf "${DATA_DIR}/left4dead2/addons/metamod/bin/linux64"
fi

echo "=================================================="
echo " Starting SRCDS on Port ${PORT}, Map ${DEFAULT_MAP} "
echo "=================================================="

cd "${DATA_DIR}"

# Start Left 4 Dead 2 Dedicated Server
exec ./srcds_run \
    -game left4dead2 \
    -console \
    -port "${PORT}" \
    -sport "${STEAM_PORT}" \
    +map "${DEFAULT_MAP}" \
    +maxplayers "${MAX_PLAYERS}" \
    ${EXTRA_ARGS}
