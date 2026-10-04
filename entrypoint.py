#!/usr/bin/env python3
"""Left 4 Dead 2 Dedicated Server Entrypoint.

Handles directory setup, mod stack overlays, configuration templating,
and launches the server with visibility self-checks.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import time

DATA_DIR = Path("/data")
GAME_DIR = Path(os.environ.get("GAME_DIR", "/opt/l4d2"))
OVERLAY_DIR = Path(os.environ.get("OVERLAY_DIR", "/opt/l4d2-overlay"))

WRITABLE_DIRS = ["cfg", "addons", "maps", "scripts"]
WRITABLE_GAME_FILES = ["motd.txt", "mapcycle.txt", "missioncycle.txt", "maplist.txt"]
WRITABLE_DATA_FILES = ["console.log"]

EIGHT_PLAYER_FILES = {
    "l4dtoolz.so",
    "l4dtoolz.vdf",
    "l4dmultislots.smx",
    "l4d_CreateSurvivorBot.smx",
    "l4d_unreservelobby.smx",
    "l4d_CreateSurvivorBot.txt",
    "l4dmultislots.phrases.txt",
}

DEFAULT_CONFIG_VALUES = {
    "SERVER_NAME": "Left 4 Dead 2 Dedicated Server",
    "RCON_PASSWORD": "ChangeMeRcon123",
    "SERVER_PASSWORD": "",
    "STEAM_GROUP_ID": "",
    "STEAM_GROUP_EXCLUSIVE": "0",
    "SV_CONSISTENCY": "0",
    "SV_PURE": "0",
}


def log(msg: str) -> None:
    print(f"[Bootstrap] {msg}", flush=True)


def fail(*lines: str) -> None:
    banner = [
        "",
        "==================================================",
        " CONFIGURATION ERROR - refusing to start",
        "==================================================",
        *lines,
        "==================================================",
        "",
    ]
    print("\n".join(banner), file=sys.stderr, flush=True)
    sys.exit(1)


def reject_flag(extra_args: str, flag: str, *reasons: str) -> None:
    if f" {flag} " in f" {extra_args} ":
        fail(
            f"EXTRA_ARGS contains '{flag}', which this image refuses to run with.",
            "",
            *reasons,
            "",
            f"Current EXTRA_ARGS: {extra_args}",
            f"Remove '{flag}' from EXTRA_ARGS and restart the container.",
        )


def mirror_tree(src: Path, dst: Path) -> None:
    """Mirror one directory level using symlinks.

    Existing real files/directories in dst are never overwritten.
    Dangling symlinks from removed source files are cleaned up.
    """
    dst.mkdir(parents=True, exist_ok=True)
    if not src.is_dir():
        return
    for entry in src.iterdir():
        target = dst / entry.name
        if target.is_symlink() and not target.exists():
            target.unlink()
        if target.exists() or target.is_symlink():
            continue
        target.symlink_to(entry)


def find_candidate_ips(port: int) -> set[str]:
    cands: set[str] = set()

    # 1. Address used to reach the outside world
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("1.1.1.1", 53))
            ip = s.getsockname()[0]
            if ip and not ip.startswith("127."):
                cands.add(ip)
    except Exception:
        pass

    # 2. Hostname addresses in /etc/hosts
    try:
        hostname_path = Path("/proc/sys/kernel/hostname")
        hostname = (
            hostname_path.read_text(encoding="utf-8").strip()
            if hostname_path.exists()
            else ""
        )
        hosts_path = Path("/etc/hosts")
        if hostname and hosts_path.exists():
            for line in hosts_path.read_text(encoding="utf-8").splitlines():
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                tokens = line.split()
                if len(tokens) >= 2:
                    ip = tokens[0]
                    if not ip.startswith("127.") and re.match(
                        r"^\d+\.\d+\.\d+\.\d+$", ip
                    ):
                        if hostname in tokens[1:]:
                            cands.add(ip)
    except Exception:
        pass

    # 3. Addresses bound to UDP port in /proc/net/udp
    try:
        proc_udp = Path("/proc/net/udp")
        if proc_udp.exists():
            for line in proc_udp.read_text(encoding="utf-8").splitlines():
                parts = line.strip().split()
                if len(parts) >= 2 and ":" in parts[1]:
                    hex_ip, hex_port = parts[1].split(":", 1)
                    if int(hex_port, 16) == port and hex_ip != "00000000":
                        ip = socket.inet_ntoa(struct.pack("<I", int(hex_ip, 16)))
                        if not ip.startswith("127."):
                            cands.add(ip)
    except Exception:
        pass

    return cands


def probe_a2s(ip: str, port: int, timeout: float = 3.0) -> bool:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(timeout)
            query = b"\xff\xff\xff\xffTSource Engine Query\x00"
            s.sendto(query, (ip, port))
            data, _ = s.recvfrom(4096)
            return data.startswith(b"\xff\xff\xff\xff")
    except Exception:
        return False


def run_a2s_self_check(port: int, attempts: int = 12, delay: float = 10.0) -> bool:
    for _ in range(attempts):
        time.sleep(delay)
        cands = find_candidate_ips(port)
        for ip in sorted(cands):
            if probe_a2s(ip, port):
                log(
                    f"Self-check OK: server answers A2S queries on UDP {port} (discoverable)."
                )
                return True

    print("\n==================================================", file=sys.stderr)
    print(" SELF-CHECK FAILED - server is NOT discoverable", file=sys.stderr)
    print("==================================================", file=sys.stderr)
    print(
        "The server process is running, but it answered no A2S query on",
        file=sys.stderr,
    )
    print(
        f"UDP {port} after {int(attempts * delay)}s of retrying.\n",
        file=sys.stderr,
    )
    print(
        "It will NOT appear in the server browser, and it will NOT appear in",
        file=sys.stderr,
    )
    print(
        f"the Steam group server list. Direct 'connect <ip>:{port}' still",
        file=sys.stderr,
    )
    print("works, so this failure is otherwise silent.\n", file=sys.stderr)
    print("Common causes:", file=sys.stderr)
    print("  - '-insecure' or '-nomaster' in EXTRA_ARGS", file=sys.stderr)
    print("  - sv_lan set to 1", file=sys.stderr)
    print(
        f"  - inbound UDP {port} blocked by a firewall or missing port forward",
        file=sys.stderr,
    )
    print(
        "==================================================\n",
        file=sys.stderr,
        flush=True,
    )
    return False


def setup_game_files(game_dir: Path, data_dir: Path) -> Path:
    game_data_dir = data_dir / "left4dead2"
    log(f"Linking the image install ({game_dir}) into {data_dir}...")
    mirror_tree(game_dir, data_dir)

    if game_data_dir.is_symlink():
        game_data_dir.unlink()
    game_data_dir.mkdir(parents=True, exist_ok=True)
    mirror_tree(game_dir / "left4dead2", game_data_dir)

    for name in WRITABLE_DIRS:
        src_dir = game_dir / "left4dead2" / name
        src_dir.mkdir(parents=True, exist_ok=True)
        dst_dir = game_data_dir / name
        if dst_dir.is_symlink():
            dst_dir.unlink()
        dst_dir.mkdir(parents=True, exist_ok=True)
        mirror_tree(src_dir, dst_dir)

    for name in WRITABLE_GAME_FILES:
        target = game_data_dir / name
        if target.is_symlink():
            target.unlink()
            src = game_dir / "left4dead2" / name
            if src.is_file():
                shutil.copy2(src, target)

    for name in WRITABLE_DATA_FILES:
        target = data_dir / name
        if target.is_symlink():
            target.unlink()
        if not target.exists():
            target.touch()
    # Link steamclient.so to ~/.steam/sdk32 for Valve Steam API
    home = Path(os.environ.get("HOME", "/home/steam"))
    sdk32 = home / ".steam" / "sdk32"
    sdk32.mkdir(parents=True, exist_ok=True)
    steamclient_link = sdk32 / "steamclient.so"
    if steamclient_link.is_symlink() or steamclient_link.exists():
        steamclient_link.unlink()
    steamclient_link.symlink_to(data_dir / "bin" / "steamclient.so")

    return game_data_dir


def link_overlay_tree(
    src: Path, dst: Path, exclude_names: set[str] | None = None
) -> None:
    """Recursively link overlay files from src to dst.

    Creates subdirectories in dst and symlinks individual files.
    Skips any entry whose filename is in exclude_names.
    """
    if exclude_names is None:
        exclude_names = set()
    dst.mkdir(parents=True, exist_ok=True)
    for entry in src.iterdir():
        if entry.name in exclude_names:
            continue
        target = dst / entry.name
        if entry.is_dir() and not entry.is_symlink():
            link_overlay_tree(entry, target, exclude_names)
        else:
            if target.is_symlink() or target.exists():
                target.unlink()
            target.symlink_to(entry)


def setup_mods(
    server_mode: str,
    overlay_dir: Path,
    game_data_dir: Path,
    admin_users: str,
) -> None:
    addons_dir = game_data_dir / "addons"
    overlay_addons = overlay_dir / "left4dead2" / "addons"
    overlay_prefix = str(overlay_dir)

    if server_mode == "vanilla":
        log("SERVER_MODE is 'vanilla': running pure 4-player server without mods.")
        if addons_dir.is_dir():
            for item in list(addons_dir.rglob("*")):
                if item.is_symlink():
                    target = os.path.realpath(item)
                    if target.startswith(overlay_prefix):
                        item.unlink()
        return

    if server_mode == "sourcemod":
        log(
            "SERVER_MODE is 'sourcemod': running 4-player server with SourceMod and admin tools."
        )
        # Clean up any 8-player symlinks from a previous run
        if addons_dir.is_dir():
            for item in list(addons_dir.rglob("*")):
                if item.is_symlink() and item.name in EIGHT_PLAYER_FILES:
                    target = os.path.realpath(item)
                    if target.startswith(overlay_prefix):
                        item.unlink()
        if overlay_addons.is_dir():
            link_overlay_tree(
                overlay_addons, addons_dir, exclude_names=EIGHT_PLAYER_FILES
            )
    elif server_mode == "8players":
        log("SERVER_MODE is '8players': running 8-player server with full mod stack.")
        if overlay_addons.is_dir():
            link_overlay_tree(overlay_addons, addons_dir)
        overlay_cfg = overlay_dir / "left4dead2" / "cfg"
        if overlay_cfg.is_dir():
            sm_cfg = game_data_dir / "cfg" / "sourcemod"
            sm_cfg.mkdir(parents=True, exist_ok=True)
            src_multislots = overlay_cfg / "sourcemod" / "l4dmultislots.cfg"
            dst_multislots = sm_cfg / "l4dmultislots.cfg"
            if src_multislots.is_file() and not dst_multislots.exists():
                shutil.copy2(src_multislots, dst_multislots)

    if admin_users:
        configure_admins(
            admin_users,
            game_data_dir / "addons" / "sourcemod" / "configs" / "admins_simple.ini",
        )

def configure_admins(admin_users: str, config_path: Path) -> None:
    log("Configuring SourceMod admins from ADMIN_USERS...")
    config_path.parent.mkdir(parents=True, exist_ok=True)
    if config_path.is_symlink() or config_path.exists():
        config_path.unlink()

    lines = [
        "// Generated by container bootstrap from ADMIN_USERS.\n",
        "// To customize permissions per admin, use steamid@flags or edit admins.cfg.\n",
    ]
    for raw in admin_users.split(","):
        entry = raw.strip().strip("'\"")
        if not entry:
            continue
        if "@" in entry:
            admin_id, flags = entry.split("@", 1)
        elif "=" in entry:
            admin_id, flags = entry.split("=", 1)
        else:
            admin_id, flags = entry, "99:z"
        admin_id = admin_id.strip().strip("'\"")
        flags = flags.strip()
        lines.append(f'"{admin_id}" "{flags}"\n')
        log(f"  Added admin: {admin_id} ({flags})")

    config_path.write_text("".join(lines), encoding="utf-8")


def setup_config(
    game_data_dir: Path,
    server_mode: str,
    server_password: str,
) -> None:
    cfg_dir = game_data_dir / "cfg"
    cfg_dir.mkdir(parents=True, exist_ok=True)

    custom_cfg = cfg_dir / "server_custom.cfg"
    if not custom_cfg.is_file():
        log(f"Creating {custom_cfg} for persistent cvar overrides.")
        custom_cfg.write_text(
            "// Persistent cvar overrides, appended to the end of server.cfg.\n"
            "//\n"
            "// server.cfg is regenerated from /defaults/server.cfg.template on EVERY\n"
            "// container start, so anything edited there is lost on the next restart.\n"
            "// Whatever is in THIS file is appended to the rendered server.cfg verbatim on\n"
            "// every start, so it must not contain `exec`.\n"
            "// Put cvars that must survive a restart in THIS file instead - it is never\n"
            "// overwritten.\n"
            "//\n"
            "// Note: L4D2 has no `sv_hibernate_when_empty` cvar (the engine reports\n"
            '// "Unknown command"). L4D2 hibernates automatically when empty and still\n'
            "// answers A2S queries, so nothing is needed to stay listed.\n",
            encoding="utf-8",
        )

    log("Templating server.cfg from /defaults/server.cfg.template...")
    template_path = Path("/defaults/server.cfg.template")
    if not template_path.is_file():
        fail(f"Config template not found at {template_path}")

    template_content = template_path.read_text(encoding="utf-8")
    rendered = re.sub(
        r"\$\{(\w+)\}",
        lambda m: os.environ.get(m.group(1), m.group(0)),
        template_content,
    )

    override_sources: list[Path] = []
    default_custom = Path("/defaults/server_custom.cfg")
    if (
        server_mode == "8players"
        and default_custom.is_file()
        and default_custom.stat().st_size > 0
    ):
        override_sources.append(default_custom)
    if custom_cfg.is_file() and custom_cfg.stat().st_size > 0:
        override_sources.append(custom_cfg)
    for overrides in override_sources:
        log(f"Appending persistent overrides from {overrides}...")
        content = overrides.read_text(encoding="utf-8")
        rendered += (
            f"\n\n// ---------------------------------------------------------------------\n"
            f"// {overrides}, verbatim\n"
            f"// ---------------------------------------------------------------------\n"
            f"{content}"
        )

    rendered_bytes = rendered.encode("utf-8")
    rendered_hash = hashlib.md5(rendered_bytes).hexdigest()

    server_cfg = cfg_dir / "server.cfg"
    if server_cfg.is_file():
        existing_hash = hashlib.md5(server_cfg.read_bytes()).hexdigest()
        if rendered_hash != existing_hash:
            log(f"WARNING: {server_cfg} differs from the rendered template.")
            log(
                "         It is being regenerated now, so those differences are discarded."
            )
            log(
                f"         Move persistent cvars to {custom_cfg}, which is never overwritten."
            )

    server_cfg.write_bytes(rendered_bytes)

    if server_password:
        log(
            "NOTE: SERVER_PASSWORD is set - clients will be prompted for a password."
        )
        log(
            "      L4D2 has a long-standing bug where that prompt hangs when"
        )
        log(
            "      sv_allow_lobby_connect_only is 0 (the value used by the template)."
        )


def main() -> None:
    if len(sys.argv) >= 3 and sys.argv[1] == "--self-check":
        port = int(sys.argv[2])
        success = run_a2s_self_check(port)
        sys.exit(0 if success else 1)

    print("==================================================")
    print(" Left 4 Dead 2 Linux Dedicated Server            ")
    print("==================================================")

    # Initialize environment defaults
    for key, val in DEFAULT_CONFIG_VALUES.items():
        if key not in os.environ:
            os.environ[key] = val

    game_manifest = os.environ.get("GAME_MANIFEST", "")
    # Mode: 8players (default), sourcemod (4-player with admin tools), vanilla (pure 4-player)
    server_mode = os.environ.get("SERVER_MODE", "8players").strip().lower()

    if server_mode not in ("8players", "sourcemod", "vanilla"):
        fail(
            f"Invalid SERVER_MODE: '{server_mode}'.",
            "",
            "Valid options:",
            "  - '8players'  : 8-player co-op with full mod stack (default)",
            "  - 'sourcemod' : 4-player server with SourceMod and admin tools",
            "  - 'vanilla'   : pure 4-player vanilla server without mods",
        )

    os.environ["SERVER_MODE"] = server_mode
    default_players = "8" if server_mode == "8players" else "4"
    max_players = os.environ.get("MAX_PLAYERS", default_players)
    port = os.environ.get("PORT", "27015")
    steam_port = os.environ.get("STEAM_PORT", "26901")
    default_map = os.environ.get("DEFAULT_MAP", "c1m1_hotel")
    server_name = os.environ.get("SERVER_NAME", DEFAULT_CONFIG_VALUES["SERVER_NAME"])
    rcon_password = os.environ.get("RCON_PASSWORD", DEFAULT_CONFIG_VALUES["RCON_PASSWORD"])
    server_password = os.environ.get("SERVER_PASSWORD", "")
    steam_group_id = os.environ.get("STEAM_GROUP_ID", "")
    steam_group_exclusive = os.environ.get("STEAM_GROUP_EXCLUSIVE", "0")
    sv_consistency = os.environ.get("SV_CONSISTENCY", "0")
    sv_pure = os.environ.get("SV_PURE", "0")
    admin_users = os.environ.get("ADMIN_USERS", "")
    extra_args = os.environ.get("EXTRA_ARGS", "")

    # Validation
    reject_flag(
        extra_args,
        "-insecure",
        "It disables the Steam/VAC layer, after which the server answers no A2S",
        "queries at all (INFO, PLAYER and RULES are silently dropped). The server",
        "then never appears in the server browser or in the Steam group server",
        "list, while direct 'connect <ip>' keeps working.",
    )
    reject_flag(
        extra_args,
        "-nomaster",
        "It stops the server registering with the Steam master server, so it can",
        "never be discovered through the server browser or the Steam group list.",
    )
    reject_flag(
        extra_args,
        "-lan",
        "LAN mode disables the master server heartbeat and Steam authentication,",
        "so the server is only reachable from the local network.",
    )

    if " +sv_lan 1 " in f" {extra_args} " or " sv_lan 1 " in f" {extra_args} ":
        fail(
            "EXTRA_ARGS sets sv_lan to 1.",
            "",
            "LAN mode disables the master server heartbeat and Steam",
            "authentication, so the server will never be listed publicly.",
            "",
            f"Current EXTRA_ARGS: {extra_args}",
            "Remove it from EXTRA_ARGS and restart the container.",
        )

    if not (GAME_DIR / "left4dead2").is_dir():
        fail(
            f"No server install at {GAME_DIR}.",
            "",
            "This image bakes the game files in, so the install is missing from the",
            "image itself. Check that the image was built properly.",
        )

    if game_manifest:
        log(f"Game manifest: {game_manifest} (baked in image).")

    # Game files & directory structure
    game_data_dir = setup_game_files(GAME_DIR, DATA_DIR)

    # Mod stack
    setup_mods(server_mode, OVERLAY_DIR, game_data_dir, admin_users)

    # Check executable
    srcds_run = DATA_DIR / "srcds_run"
    if not srcds_run.is_file() or not os.access(srcds_run, os.X_OK):
        fail(
            f"{srcds_run} is missing or not executable.",
            "",
            f"Check that {DATA_DIR} is a writable volume and that nothing in it",
            "shadows the image install.",
        )
    # Configuration files
    setup_config(game_data_dir, server_mode, server_password)

    # Launch
    print("==================================================")
    print(f" Starting SRCDS on Port {port}, Map {default_map} ")
    print("==================================================")
    log(f"Mode: {server_mode}")
    log(f"Players: {max_players} (SERVER_MODE={server_mode})")
    log(
        f"Steam group: {steam_group_id if steam_group_id else '<none>'} (exclusive: {steam_group_exclusive})"
    )
    log(f"Password protected: {'yes' if server_password else 'no'}")
    log(f"Extra arguments: {extra_args if extra_args else '<none>'}")

    try:
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--self-check", port]
        )
    except Exception as e:
        log(f"Warning: could not start visibility self-check: {e}")

    os.chdir(DATA_DIR)
    cmd = [
        "./srcds_run",
        "-game",
        "left4dead2",
        "-console",
        "-port",
        port,
        "-sport",
        steam_port,
        "+map",
        default_map,
        "+maxplayers",
        max_players,
    ]
    if extra_args:
        cmd.extend(shlex.split(extra_args))

    os.execv(cmd[0], cmd)


if __name__ == "__main__":
    main()
