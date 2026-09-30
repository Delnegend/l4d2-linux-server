#!/usr/bin/env bash
set -e

echo "=================================================="
echo " Left 4 Dead 2 Linux Dedicated Server            "
echo "=================================================="

DATA_DIR="/data"
# The install is baked into the image; DATA_DIR is the volume. See "Game files"
# below for how the two are joined.
GAME_DIR="${GAME_DIR:-/opt/l4d2}"

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

# Mirror one directory level.
#
# Every entry of the image directory appears in the data directory, as a
# symlink - unless the data directory already holds a real entry of that name,
# which always wins. That rule is what makes this non-destructive: an old
# volume carrying a full install keeps every one of its files, and only gains
# links for whatever the image adds.
mirror_tree() {
    local src="$1" dst="$2" entry name

    mkdir -p "${dst}"
    shopt -s nullglob dotglob
    for entry in "${src}"/*; do
        name="$(basename "${entry}")"
        if [ -L "${dst}/${name}" ] && [ ! -e "${dst}/${name}" ]; then
            # The image dropped this file; keeping the link would leave a
            # dangling symlink behind.
            rm -f "${dst}/${name}"
        fi
        if [ -e "${dst}/${name}" ] || [ -L "${dst}/${name}" ]; then
            continue
        fi
        ln -s "${entry}" "${dst}/${name}"
    done
    shopt -u nullglob dotglob
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
# Game files
# ---------------------------------------------------------------------------
#
# The ~20 GB install is baked into the image at GAME_DIR. DATA_DIR is the
# volume, and it stays the server's working directory - the layout the engine,
# the config paths and every admin tool already expect. The join is a farm of
# symlinks: read-only game content is linked in from the image, while the
# directories and files the server or an admin writes to are real.
#
# Directories under left4dead2/ the server and the admin write to. Each becomes
# a real directory whose own entries are links, so a workshop map or a custom
# campaign dropped in shows up alongside the shipped ones.
WRITABLE_DIRS="cfg addons maps scripts"

# Plain files the server rewrites or an admin edits by hand. Never links: a
# write through a link would land in the container filesystem and vanish on
# the next restart.
WRITABLE_GAME_FILES="motd.txt mapcycle.txt missioncycle.txt maplist.txt"
WRITABLE_DATA_FILES="console.log"

if [ ! -d "${GAME_DIR}/left4dead2" ]; then
    fail \
        "No server install at ${GAME_DIR}." \
        "" \
        "This image bakes the game files in, so the install is missing from the" \
        "image itself. If you are running the 'qol' image, check that the image" \
        "was not rebuilt with --no-cache after the install layer was pruned."
fi

log "Linking the image install (${GAME_DIR}) into ${DATA_DIR}..."
mirror_tree "${GAME_DIR}" "${DATA_DIR}"

GAME_DATA_DIR="${DATA_DIR}/left4dead2"

# left4dead2/ is linked by the mirroring above, and it has to be a real
# directory before its contents can be linked into it - otherwise the links
# would be written into the image instead of the volume. An old volume that
# already holds a real install is left alone.
if [ -L "${GAME_DATA_DIR}" ]; then
    rm -f "${GAME_DATA_DIR}"
fi
mkdir -p "${GAME_DATA_DIR}"
mirror_tree "${GAME_DIR}/left4dead2" "${GAME_DATA_DIR}"

for name in ${WRITABLE_DIRS}; do
    [ -d "${GAME_DIR}/left4dead2/${name}" ] || continue

    # The mirroring above linked this directory; replace that link with a real
    # directory, which is what lets files be added to it.
    if [ -L "${GAME_DATA_DIR}/${name}" ]; then
        rm -f "${GAME_DATA_DIR}/${name}"
    fi
    mkdir -p "${GAME_DATA_DIR}/${name}"
    mirror_tree "${GAME_DIR}/left4dead2/${name}" "${GAME_DATA_DIR}/${name}"
done

for name in ${WRITABLE_GAME_FILES}; do
    if [ -L "${GAME_DATA_DIR}/${name}" ]; then
        rm -f "${GAME_DATA_DIR}/${name}"
        cp "${GAME_DIR}/left4dead2/${name}" "${GAME_DATA_DIR}/${name}"
    fi
done

for name in ${WRITABLE_DATA_FILES}; do
    if [ -L "${DATA_DIR}/${name}" ]; then
        rm -f "${DATA_DIR}/${name}"
    fi
    if [ ! -e "${DATA_DIR}/${name}" ]; then
        : > "${DATA_DIR}/${name}"
    fi
done

if [ ! -x "${DATA_DIR}/srcds_run" ]; then
    fail \
        "${DATA_DIR}/srcds_run is missing or not executable after linking." \
        "" \
        "Check that ${DATA_DIR} is a writable volume and that nothing in it" \
        "shadows the image install."
fi

# Ensure steamclient.so is linked to ~/.steam/sdk32 for Valve Steam API
mkdir -p "${HOME}/.steam/sdk32"
ln -sf "${DATA_DIR}/bin/steamclient.so" "${HOME}/.steam/sdk32/steamclient.so"

# ---------------------------------------------------------------------------
# Configuration files
# ---------------------------------------------------------------------------
#
# server.cfg is regenerated from /defaults/server.cfg.template on every start so
# that the environment variables are the single source of truth. Hand-edits to
# server.cfg therefore do NOT survive a restart. Persistent cvars belong in
# server_custom.cfg, whose contents are appended to the rendered server.cfg
# and which is never overwritten.

CFG_DIR="${GAME_DATA_DIR}/cfg"
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
