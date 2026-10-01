#!/usr/bin/env bash
set -e

echo "=================================================="
echo " Left 4 Dead 2 Linux Dedicated Server            "
echo "=================================================="

DATA_DIR="/data"
# Captured before validation so a failed check can name what was actually set.
WANTED_MANIFEST="${GAME_MANIFEST:-}"
WANTED_LAUNCHER="${LAUNCHER_MANIFEST:-}"

# The player count is a property of this image, not a runtime knob.
MAX_PLAYERS=8

# Default environment values
PORT="${PORT:-27015}"
STEAM_PORT="${STEAM_PORT:-26901}"
DEFAULT_MAP="${DEFAULT_MAP:-c1m1_hotel}"
SERVER_NAME="${SERVER_NAME:-Left 4 Dead 2 Dedicated Server}"
RCON_PASSWORD="${RCON_PASSWORD:-ChangeMeRcon123}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
STEAM_GROUP_ID="${STEAM_GROUP_ID:-}"
STEAM_GROUP_EXCLUSIVE="${STEAM_GROUP_EXCLUSIVE:-0}"
SV_CONSISTENCY="${SV_CONSISTENCY:-0}"
SV_PURE="${SV_PURE:-0}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "[Bootstrap] $*"
}

# Print a configuration error and refuse to start. Each argument is printed on
# its own line so callers can pass pre-formatted explanations.
fail() {
    {
        echo ""
        echo "=================================================="
        echo " CONFIGURATION ERROR - refusing to start"
        echo "=================================================="
        printf '%s\n' "$@"
        echo "=================================================="
        echo ""
    } >&2
    exit 1
}

# Refuse a launch flag outright.
#
# The flags below do not crash the server - they make it *invisible* while the
# logs still look perfectly healthy and direct `connect <ip>` still works. That
# failure mode is effectively impossible to diagnose from the server side, so
# the only safe behaviour is to not start at all.
reject_flag() {
    local flag="$1"
    shift
    case " ${EXTRA_ARGS} " in
        *" ${flag} "*)
            fail \
                "EXTRA_ARGS contains '${flag}', which this image refuses to run with." \
                "" \
                "$@" \
                "" \
                "Current EXTRA_ARGS: ${EXTRA_ARGS}" \
                "Remove '${flag}' from EXTRA_ARGS and restart the container."
            ;;
    esac
}

# Post-boot visibility self-check.
#
# An L4D2 server that answers no A2S queries is absent from the server browser
# and from the Steam group server list, yet everything else looks normal. Probe
# the running server locally and shout if it is not answering.
a2s_self_check() {
    local port="$1"
    local attempts=12
    local i

    for i in $(seq 1 "${attempts}"); do
        sleep 10
        if perl - "${port}" <<'PERL'
use strict;
use warnings;
use Socket;

my $port = shift // die "no port\n";
my %cand;

# The engine ignores queries arriving on loopback, so the probe must use an
# address the server is actually reachable on.
#
# 1. The address this container would use to reach the outside world.
if (socket(my $tmp, PF_INET, SOCK_DGRAM, 17)) {
    if (connect($tmp, pack_sockaddr_in(53, inet_aton("1.1.1.1")))) {
        my (undef, $ip) = unpack_sockaddr_in(getsockname($tmp));
        $cand{inet_ntoa($ip)} = 1;
    }
    close($tmp);
}

# 2. Addresses /etc/hosts maps to our own hostname (Docker and Kubernetes both
#    write the container address there).
my $me = "";
if (open(my $hostfh, "<", "/proc/sys/kernel/hostname")) {
    local $/;
    $me = <$hostfh> // "";
    close($hostfh);
}
$me =~ s/\s+//g;
if ($me ne "" && open(my $hosts, "<", "/etc/hosts")) {
    while (my $line = <$hosts>) {
        $line =~ s/#.*//;
        my @tok = split ' ', $line;
        next unless @tok;
        my $ip = shift @tok;
        next unless $ip =~ /^\d+\.\d+\.\d+\.\d+$/ && $ip !~ /^127\./;
        $cand{$ip} = 1 if grep { $_ eq $me } @tok;
    }
    close($hosts);
}

# 3. Any specific address the server has bound UDP <port> to.
if (open(my $fh, "<", "/proc/net/udp")) {
    while (my $line = <$fh>) {
        my @f = split ' ', $line;
        next unless @f >= 2;
        my ($hexip, $hexport) = split /:/, $f[1];
        next unless defined $hexport && hex($hexport) == $port;
        next if $hexip eq "00000000";
        $cand{join ".", map { hex } ($hexip =~ /(..)(..)(..)(..)/)} = 1;
    }
    close($fh);
}

exit 2 unless keys %cand;

# A single A2S_INFO is enough: the server answers with at least an
# S2C_CHALLENGE. Anything \xff\xff\xff\xff-prefixed means it is answering.
for my $ip (sort keys %cand) {
    # 17 = IPPROTO_UDP. Slim images ship no /etc/protocols, so
    # getprotobyname("udp") returns undef and socket() would fail.
    socket(my $sock, PF_INET, SOCK_DGRAM, 17) or next;
    my $peer = pack_sockaddr_in($port, inet_aton($ip));
    send($sock, "\xff\xff\xff\xffTSource Engine Query\x00", 0, $peer) or next;
    my $rin = "";
    vec($rin, fileno($sock), 1) = 1;
    next unless select(my $rout = $rin, undef, undef, 3);
    recv($sock, my $buf, 4096, 0);
    exit 0 if substr($buf, 0, 4) eq "\xff\xff\xff\xff";
}

exit 1;
PERL
        then
            log "Self-check OK: server answers A2S queries on UDP ${port} (discoverable)."
            return 0
        fi
    done

    {
        echo ""
        echo "=================================================="
        echo " SELF-CHECK FAILED - server is NOT discoverable"
        echo "=================================================="
        echo "The server process is running, but it answered no A2S query on"
        echo "UDP ${port} after $((attempts * 10))s of retrying."
        echo ""
        echo "It will NOT appear in the server browser, and it will NOT appear in"
        echo "the Steam group server list. Direct 'connect <ip>:${port}' still"
        echo "works, so this failure is otherwise silent."
        echo ""
        echo "Common causes:"
        echo "  - '-insecure' or '-nomaster' in EXTRA_ARGS"
        echo "  - sv_lan set to 1"
        echo "  - inbound UDP ${port} blocked by a firewall or missing port forward"
        echo "=================================================="
        echo ""
    } >&2
    return 1
}

# ---------------------------------------------------------------------------
# Launch-argument validation
# ---------------------------------------------------------------------------

reject_flag "-insecure" \
    "It disables the Steam/VAC layer, after which the server answers no A2S" \
    "queries at all (INFO, PLAYER and RULES are silently dropped). The server" \
    "then never appears in the server browser or in the Steam group server" \
    "list, while direct 'connect <ip>' keeps working."

reject_flag "-nomaster" \
    "It stops the server registering with the Steam master server, so it can" \
    "never be discovered through the server browser or the Steam group list."

reject_flag "-lan" \
    "LAN mode disables the master server heartbeat and Steam authentication," \
    "so the server is only reachable from the local network."

case " ${EXTRA_ARGS} " in
    *" +sv_lan 1 "* | *" sv_lan 1 "*)
        fail \
            "EXTRA_ARGS sets sv_lan to 1." \
            "" \
            "LAN mode disables the master server heartbeat and Steam" \
            "authentication, so the server will never be listed publicly." \
            "" \
            "Current EXTRA_ARGS: ${EXTRA_ARGS}" \
            "Remove it from EXTRA_ARGS and restart the container."
        ;;
esac

# ---------------------------------------------------------------------------
# Game install
# ---------------------------------------------------------------------------
#
# The install lives on the volume, not in the image. The ~10 GB of Valve content
# is downloaded on the first start and reused on every start after that - a stamp
# file inside left4dead2/ records which manifests produced the tree.
#
# DATA_DIR is both the volume and the server's working directory, which is the
# layout the engine, the config paths and every admin tool already expect:
# srcds_run at its root, left4dead2/ beside it. There is nothing to join, so
# there are no symlinks and nothing is ever copied out of the image except the
# mod overlay.
#
# A volume whose stamp matches is left completely alone. A volume carrying any
# other stamp is replaced wholesale rather than merged: a manifest describes a
# whole depot, and a half-old, half-new install is not a state this can reach.
# left4dead2/cfg is the single exception, because it is the operator's.

INSTALL_DIR="${DATA_DIR}/left4dead2"
MANIFEST_STAMP="${INSTALL_DIR}/.l4d2-manifest"

if [ ! -x "${DEPOT_DOWNLOADER}" ]; then
    fail \
        "${DEPOT_DOWNLOADER} is missing or not executable." \
        "" \
        "This image downloads the game at start-up rather than carrying it, so" \
        "the downloader has to be there. If you are running an image you built" \
        "yourself, check that the entrypoint is the published one."
fi

# Two manifests, because the install is two depots: the game, and the launcher
# depot that provides srcds_run. Steam versions them independently - the game
# depot has not moved since 2024, the launcher depot moves far more often - so
# one pin cannot describe an install and one would leave the server binary
# unpinned.
check_manifest() {
    local name="$1" value="$2"
    case "${value}" in
        ''|*[!0-9]*)
            fail \
                "${name} is '${value}', which is not a Steam depot manifest id." \
                "" \
                "It is a decimal number - the gid of the depot's public manifest." \
                "The image's own defaults are the ARG lines of those names in the" \
                "Dockerfile; override them in .env to move this deployment to a" \
                "different Valve build."
            ;;
    esac
}
check_manifest GAME_MANIFEST "${WANTED_MANIFEST}"
check_manifest LAUNCHER_MANIFEST "${WANTED_LAUNCHER}"

GAME_MANIFEST="${WANTED_MANIFEST}"
LAUNCHER_MANIFEST="${WANTED_LAUNCHER}"
APP_ID="${APP_ID:-222860}"
GAME_DEPOT="${GAME_DEPOT:-222861}"
LAUNCHER_DEPOT="${LAUNCHER_DEPOT:-222863}"
MAX_DOWNLOADS="${MAX_DOWNLOADS:-16}"
OVERLAY_DIR="${OVERLAY_DIR:-/opt/l4d2-overlay}"

# The identity of an install. Both depot/manifest pairs, because one alone does
# not name a tree the server can actually start from.
WANTED_INSTALL="${GAME_DEPOT}=${GAME_MANIFEST} ${LAUNCHER_DEPOT}=${LAUNCHER_MANIFEST}"

installed="none"
if [ -f "${MANIFEST_STAMP}" ]; then
    installed="$(cat "${MANIFEST_STAMP}")"
fi

if [ "${installed}" = "${WANTED_INSTALL}" ] && [ -x "${DATA_DIR}/srcds_run" ]; then
    log "Install present on the volume: ${WANTED_INSTALL}."
else
    if [ "${installed}" != "none" ]; then
        log "Volume carries ${installed}."
        log "This image pins ${WANTED_INSTALL}."
        log "Replacing the install. left4dead2/cfg is kept, everything else is rebuilt."
    fi

    log "Downloading the Left 4 Dead 2 dedicated server (~10 GB, once per volume)."
    log "  app ${APP_ID}"
    log "  depot ${GAME_DEPOT} manifest ${GAME_MANIFEST}   the game"
    log "  depot ${LAUNCHER_DEPOT} manifest ${LAUNCHER_MANIFEST}   srcds_run"

    # The staging tree lives inside the volume on purpose: swapping it into
    # place is then a rename per entry rather than a second 10 GB copy, and an
    # interrupted download can never be mistaken for a finished one.
    staging="${DATA_DIR}/.l4d2-install"
    saved_cfg=""
    rm -rf "${staging}" "${staging}-cfg"
    mkdir -p "${staging}"

    # One run per depot: DepotDownloader takes a single -depot, and the two
    # write disjoint paths into the same staging tree. The launcher goes first
    # because it is 674 files and finishes in seconds, which makes a broken pin
    # fail fast instead of after ten minutes.
    "${DEPOT_DOWNLOADER}" \
        -app "${APP_ID}" \
        -depot "${LAUNCHER_DEPOT}" \
        -manifest "${LAUNCHER_MANIFEST}" \
        -dir "${staging}" \
        -max-downloads "${MAX_DOWNLOADS}"

    "${DEPOT_DOWNLOADER}" \
        -app "${APP_ID}" \
        -depot "${GAME_DEPOT}" \
        -manifest "${GAME_MANIFEST}" \
        -dir "${staging}" \
        -max-downloads "${MAX_DOWNLOADS}"

    # The tool drops its own .DepotDownloader bookkeeping - manifest copies and
    # a staging area - into the install directory.
    rm -rf "${staging}/.DepotDownloader"

    if [ ! -x "${staging}/srcds_run" ] || [ ! -d "${staging}/left4dead2" ]; then
        rm -rf "${staging}"
        fail \
            "The download reported success but did not produce a server in ${DATA_DIR}." \
            "" \
            "Expected srcds_run from depot ${LAUNCHER_DEPOT} and left4dead2/ from" \
            "depot ${GAME_DEPOT}. Either a manifest id has stopped belonging to" \
            "its depot, or Steam is no longer serving it - old manifests can be" \
            "withdrawn, so a long-lived pin is not a permanent guarantee."
    fi

    # left4dead2/cfg is the operator's: the engine and SourceMod write into it
    # and server_custom.cfg lives there. Park it beside the staging tree and
    # put it back after the swap.
    if [ -d "${INSTALL_DIR}/cfg" ]; then
        saved_cfg="${staging}-cfg"
        mv "${INSTALL_DIR}/cfg" "${saved_cfg}"
    fi

    shopt -s dotglob nullglob
    for entry in "${staging}"/*; do
        name="$(basename "${entry}")"
        rm -rf "${DATA_DIR:?}/${name}"
        mv "${entry}" "${DATA_DIR}/"
    done
    shopt -u dotglob nullglob
    rmdir "${staging}"

    if [ -n "${saved_cfg}" ]; then
        rm -rf "${INSTALL_DIR}/cfg"
        mv "${saved_cfg}" "${INSTALL_DIR}/cfg"
    fi

    printf '%s\n' "${WANTED_INSTALL}" > "${MANIFEST_STAMP}"
    log "Install ready: ${WANTED_INSTALL}."
fi

# ---------------------------------------------------------------------------
# Mod stack
# ---------------------------------------------------------------------------
#
# The image stages our addons/ and cfg/ at OVERLAY_DIR, mirroring left4dead2/,
# and they are applied on every start - not only after a download - so an image
# update reaches a volume that already carries the right game build.
#
# addons/ is ours and is overwritten. cfg/ is the operator's and is copied
# without clobbering, so a tuned sourcemod.cfg or l4dmultislots.cfg survives.
# --no-preserve=ownership because the overlay is root-owned in the image and the
# install is written by an unprivileged user.
log "Applying the mod stack from ${OVERLAY_DIR}..."
if [ -d "${OVERLAY_DIR}/left4dead2/addons" ]; then
    mkdir -p "${INSTALL_DIR}/addons"
    cp -a --no-preserve=ownership "${OVERLAY_DIR}/left4dead2/addons/." "${INSTALL_DIR}/addons/"
fi
if [ -d "${OVERLAY_DIR}/left4dead2/cfg" ]; then
    mkdir -p "${INSTALL_DIR}/cfg"
    cp -an --no-preserve=ownership "${OVERLAY_DIR}/left4dead2/cfg/." "${INSTALL_DIR}/cfg/" || true
fi

if [ ! -x "${DATA_DIR}/srcds_run" ]; then
    fail \
        "${DATA_DIR}/srcds_run is missing or not executable." \
        "" \
        "The install was just written to the volume, so this means ${DATA_DIR}" \
        "is not the writable volume it was expected to be."
fi

# Ensure steamclient.so is linked to ~/.steam/sdk32 for Valve Steam API
mkdir -p "${HOME}/.steam/sdk32"
ln -sf "${DATA_DIR}/bin/steamclient.so" "${HOME}/.steam/sdk32/steamclient.so"

# srcds writes its console here as well as to stdout; make sure it can create
# the file before it decides to.
[ -e "${DATA_DIR}/console.log" ] || : > "${DATA_DIR}/console.log"

# ---------------------------------------------------------------------------
# Configuration files
# ---------------------------------------------------------------------------
#
# server.cfg is regenerated from /defaults/server.cfg.template on every start so
# that the environment variables are the single source of truth. Hand-edits to
# server.cfg therefore do NOT survive a restart. Persistent cvars belong in
# server_custom.cfg, whose contents are appended to the rendered server.cfg
# and which is never overwritten.

CFG_DIR="${INSTALL_DIR}/cfg"
mkdir -p "${CFG_DIR}"

CUSTOM_CFG="${CFG_DIR}/server_custom.cfg"
if [ ! -f "${CUSTOM_CFG}" ]; then
    log "Creating ${CUSTOM_CFG} for persistent cvar overrides."
    cat > "${CUSTOM_CFG}" <<'EOF'
// Persistent cvar overrides, appended to the end of server.cfg.
//
// server.cfg is regenerated from /defaults/server.cfg.template on EVERY
// container start, so anything edited there is lost on the next restart.
// Whatever is in THIS file is appended to the rendered server.cfg verbatim on
// every start, so it must not contain `exec`.
// Put cvars that must survive a restart in THIS file instead - it is never
// overwritten.
//
// Note: L4D2 has no `sv_hibernate_when_empty` cvar (the engine reports
// "Unknown command"). L4D2 hibernates automatically when empty and still
// answers A2S queries, so nothing is needed to stay listed.
EOF
fi

log "Templating server.cfg from /defaults/server.cfg.template..."
export SERVER_NAME RCON_PASSWORD SERVER_PASSWORD STEAM_GROUP_ID STEAM_GROUP_EXCLUSIVE SV_CONSISTENCY SV_PURE

RENDERED_CFG="$(mktemp)"
# Substitute environment variables into template
perl -pe 's/\$\{(\w+)\}/defined($ENV{$1}) ? $ENV{$1} : $&/ge' /defaults/server.cfg.template > "${RENDERED_CFG}"

# Append the overrides to the rendered file rather than leaving them to an
# `exec` in the template: the engine resolves `exec` against the install root,
# which is inside the image, so it can never reach this volume.
#
# Two sources, in order, so the volume always has the last word:
#   1. /defaults/server_custom.cfg - what the image itself needs (the coop8
#      target ships l4dtoolz's cvars this way)
#   2. ${CUSTOM_CFG}               - what the operator added
for overrides in /defaults/server_custom.cfg "${CUSTOM_CFG}"; do
    [ -s "${overrides}" ] || continue
    log "Appending persistent overrides from ${overrides}..."
    {
        echo ""
        echo "// ---------------------------------------------------------------------"
        echo "// ${overrides}, verbatim"
        echo "// ---------------------------------------------------------------------"
        cat "${overrides}"
    } >> "${RENDERED_CFG}"
done

# Warn before discarding hand-edits, so the loss is never silent.
file_hash() {
    md5sum "$1" | cut -d' ' -f1
}
if [ -f "${CFG_DIR}/server.cfg" ] && \
   [ "$(file_hash "${RENDERED_CFG}")" != "$(file_hash "${CFG_DIR}/server.cfg")" ]; then
    log "WARNING: ${CFG_DIR}/server.cfg differs from the rendered template."
    log "         It is being regenerated now, so those differences are discarded."
    log "         Move persistent cvars to ${CUSTOM_CFG}, which is never overwritten."
fi
mv "${RENDERED_CFG}" "${CFG_DIR}/server.cfg"

if [ -n "${SERVER_PASSWORD}" ]; then
    log "NOTE: SERVER_PASSWORD is set - clients will be prompted for a password."
    log "      L4D2 has a long-standing bug where that prompt hangs when"
    log "      sv_allow_lobby_connect_only is 0 (the value used by the template)."
fi

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

echo "=================================================="
echo " Starting SRCDS on Port ${PORT}, Map ${DEFAULT_MAP} "
echo "=================================================="
log "Players: ${MAX_PLAYERS} (fixed by this image)"
log "Steam group: ${STEAM_GROUP_ID:-<none>} (exclusive: ${STEAM_GROUP_EXCLUSIVE})"
log "Password protected: $([ -n "${SERVER_PASSWORD}" ] && echo yes || echo no)"
log "Extra arguments: ${EXTRA_ARGS:-<none>}"

# Verify the running server is actually queryable. Runs in the background so it
# survives the exec() below; it only ever logs.
a2s_self_check "${PORT}" &

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
