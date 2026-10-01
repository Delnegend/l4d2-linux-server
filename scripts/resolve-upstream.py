#!/usr/bin/env python3
"""Compare the upstream sources against the pins in this repository.

Emits KEY=VALUE lines on stdout, which the update workflow appends to
$GITHUB_OUTPUT. Runnable by hand for the same answer:

    GITHUB_TOKEN=$(gh auth token) scripts/resolve-upstream.py

Four things are pinned by an ARG in the Dockerfile, and this is what says
whether each one is stale:

  game_manifest        the public manifest id of depot 222861 of app 222860 -
                       the game itself, ~9.5 GB, 116 977 files.
  launcher_manifest    the public manifest id of depot 222863 of the same app -
                       674 files, and the only one of the two that carries
                       srcds_run. Steam versions the depots independently, so
                       this is a separate pin rather than a second half of the
                       first.
  l4dtoolz_version,
  l4dtoolz_build       the newest stable lakwsh/l4dtoolz release that ships the
                       l4dtoolz-<version>-<build>.zip the Dockerfile downloads. A
                       release that only ships the rolling -main.zip cannot be
                       pinned, so it is skipped.
  plugins_ref          head commit of fbef0102/L4D1_2-Plugins.

MetaMod and SourceMod are reported and never bumped: the Dockerfile resolves
both to the newest build on SOURCEMOD_BRANCH at build time, so a new drop needs
no pin changed - only a rebuild.

GITHUB_TOKEN is optional. Without it the GitHub calls are unauthenticated and
rate limited per source address, which is enough for one run a day.
"""

import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCKERFILE = ROOT / "Dockerfile"

APP_ID = 222860
# The install is two depots: the game, and the launcher that carries srcds_run.
GAME_DEPOT = 222861
LAUNCHER_DEPOT = 222863
PLUGINS_REPO = "fbef0102/L4D1_2-Plugins"
L4DTOOLZ_REPO = "lakwsh/l4dtoolz"

# The build downloads
# .../releases/download/${L4DTOOLZ_VERSION}/l4dtoolz-${L4DTOOLZ_VERSION}-${L4DTOOLZ_BUILD}.zip,
# so the asset name and the release tag have to be the same version.
L4DTOOLZ_ASSET = re.compile(r"^l4dtoolz-(?P<version>.+?)-(?P<build>\d+)\.zip$")

TIMEOUT = 30


def fetch(url: str) -> str:
    request = urllib.request.Request(
        url, headers={"User-Agent": "l4d2-linux-server-upstream-check"}
    )
    token = os.environ.get("GITHUB_TOKEN")
    if token and "api.github.com" in url:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return response.read().decode("utf-8", "replace").strip()


def arg(name: str) -> str:
    """The default of `ARG <name>=` in the Dockerfile, which is the pin."""
    match = re.search(rf"^ARG {name}=(.*)$", DOCKERFILE.read_text(), re.M)
    if not match:
        raise SystemExit(f"resolve-upstream: Dockerfile has no ARG {name}")
    return match.group(1).strip()


def latest_l4dtoolz() -> tuple[str, str]:
    """Newest stable release carrying a pinnable asset, as (version, build).

    Releases are walked newest first and the first pinnable one wins, so a
    release that ships only the rolling -main.zip does not hide an older
    pinnable release.
    """
    releases = json.loads(
        fetch(f"https://api.github.com/repos/{L4DTOOLZ_REPO}/releases?per_page=20")
    )
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        version = release["tag_name"]
        for asset in release.get("assets", []):
            match = L4DTOOLZ_ASSET.match(asset["name"])
            if match and match.group("version") == version:
                return version, match.group("build")
    raise SystemExit(
        "resolve-upstream: no stable l4dtoolz release ships a l4dtoolz-<version>-<build>.zip"
    )


def plugins_head() -> str:
    commits = json.loads(fetch(f"https://api.github.com/repos/{PLUGINS_REPO}/commits?per_page=1"))
    return commits[0]["sha"]


def depot_manifest(depot: int) -> str:
    """Public manifest id of one depot of the dedicated server app.

    There is no build number to read without a Steam Web API key; the manifest
    gid is the same signal, and it is exactly what the entrypoint pins. This is
    an unauthenticated proxy for Steam's own IStoreService/GetAppInfo.
    """
    info = json.loads(fetch(f"https://api.steamcmd.net/v1/info/{APP_ID}"))["data"][str(APP_ID)]
    return str(info["depots"][str(depot)]["manifests"]["public"]["gid"])


def alliedmods_drop(host: str, drop: str, name: str, branch: str) -> str:
    """The filename AlliedModders' `<name>-latest-linux` redirect points at."""
    return fetch(f"https://{host}/{drop}/{branch}/{name}-latest-linux")


def main() -> None:
    branch = arg("SOURCEMOD_BRANCH")

    version, build = latest_l4dtoolz()
    ref = plugins_head()
    game = depot_manifest(GAME_DEPOT)
    launcher = depot_manifest(LAUNCHER_DEPOT)

    pinned = {
        "L4DTOOLZ_VERSION": arg("L4DTOOLZ_VERSION"),
        "L4DTOOLZ_BUILD": arg("L4DTOOLZ_BUILD"),
        "L4D_PLUGINS_REF": arg("L4D_PLUGINS_REF"),
        "GAME_MANIFEST": arg("GAME_MANIFEST"),
        "LAUNCHER_MANIFEST": arg("LAUNCHER_MANIFEST"),
    }
    latest = {
        "L4DTOOLZ_VERSION": version,
        "L4DTOOLZ_BUILD": build,
        "L4D_PLUGINS_REF": ref,
        "GAME_MANIFEST": game,
        "LAUNCHER_MANIFEST": launcher,
    }

    stale = [
        f"{name} {pinned[name]}{'…' if len(pinned[name]) > 16 else ''} -> {latest[name]}"
        for name in latest
        if pinned[name] != latest[name]
    ]

    out = {
        "game_manifest": game,
        "launcher_manifest": launcher,
        "l4dtoolz_version": version,
        "l4dtoolz_build": build,
        "plugins_ref": ref,
        "sourcemod_branch": branch,
        "mmsource_drop": alliedmods_drop("mms.alliedmods.net", "mmsdrop", "mmsource", branch),
        "sourcemod_drop": alliedmods_drop("sm.alliedmods.net", "smdrop", "sourcemod", branch),
        "pins_stale": str(bool(stale)).lower(),
        "pins_summary": "; ".join(stale) or "every pin matches upstream",
    }
    for key, value in out.items():
        if "\n" in value:
            raise SystemExit(f"resolve-upstream: {key} is multi-line, which GITHUB_OUTPUT cannot carry")
        print(f"{key}={value}")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.URLError as error:
        raise SystemExit(f"resolve-upstream: could not reach an upstream: {error.reason}") from error
