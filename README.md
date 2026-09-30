# Left 4 Dead 2 Linux Dedicated Server (Docker / Podman)

A Left 4 Dead 2 dedicated server container that downloads the game **at build
time** with [DepotDownloader](https://github.com/SteamRE/DepotDownloader) and
bakes it into the image. A cold start is instant: there is no first-boot
download, and the container never needs a Steam login.

---

## The problem this solves

Valve migrated the L4D2 dedicated server (App ID `222860`) to the newer
`freetodownload` package structure, and an unpatched platform bug in SteamCMD on
Linux makes an anonymous install fail outright:

```text
ERROR! Failed to install app '222860' (Invalid platform)
```

Server managers built on SteamCMD — LinuxGSM, most stock images — therefore
either fail or demand personal Steam credentials with the game owned.
DepotDownloader handles that API flow anonymously, which is why this image uses
it.

---

## Quick start

```bash
cp .env.example .env      # set at least RCON_PASSWORD
podman compose up -d --build
podman compose logs -f
```

That builds and runs the `qol` target. Expect `Self-check OK: server answers
A2S queries` in the log within a minute — that line is the server telling you it
is discoverable.

Pulling a prebuilt image instead? Use the `qol` tag, e.g.
`ghcr.io/delnegend/l4d2-linux-server:1.0.3-qol`. There is no unsuffixed
`<version>` tag; the target is always explicit.

## Image targets

| Target | Tags | Contents |
|---|---|---|
| `base` | *build stage only* | The 9.8 GB install exactly as DepotDownloader pulled it, plus the 32-bit runtime libraries. No entrypoint, no configuration, no mods, no customisation. |
| `qol` | `<version>-qol`, `qol`, `latest` | `FROM base`, plus MetaMod:Source + SourceMod (1.12), the entrypoint and the `server.cfg` template. **This is the one to run.** |
| `coop8` | `<version>-coop8`, `coop8` | `FROM qol`, plus l4dtoolz and the cvars that lift the 4-survivor cap on co-op campaigns. |

```bash
podman build --target qol   -t l4d2:1.0.3-qol   .
podman build --target coop8 -t l4d2:1.0.3-coop8 .
```

## What you get

- **Build-time install** — the full server including the DLC campaigns, fetched
  in parallel at `podman build` and baked in.
- **A ~1 MB volume** — the read-only game content stays in the image and is
  linked into `/data` at start-up. Nothing is ever copied.
- **No host dependencies** — the 32-bit runtime libraries are included; it runs
  on Fedora CoreOS, Ubuntu, Debian, Arch and friends without multilib.
- **Template-driven config** — `server.cfg` is regenerated from a template on
  every start, so environment variables are the single source of truth, and
  `server_custom.cfg` holds everything they don't cover.
- **Misconfiguration guards** — the entrypoint refuses to start rather than run
  a server that is invisible in the browser, and warns before discarding
  hand-edits to `server.cfg`.
- **Visibility self-check** — after boot it probes the running server over A2S
  and says so loudly, because an undiscoverable server otherwise looks perfectly
  healthy in the logs.
- **SourceMod and MetaMod baked in** — nothing is installed at boot.
- **Non-root** — runs as an unprivileged `steam` user, UID 1000.

## Configuration

Copy `.env.example` and change what you care about. The variables you are most
likely to touch:

| Variable | Default | Does |
|---|---|---|
| `SERVER_NAME` | `Left 4 Dead 2 Dedicated Server` | `hostname` |
| `RCON_PASSWORD` | `ChangeThisRcon123` | `rcon_password` — change it |
| `DEFAULT_MAP` | `c1m1_hotel` | `+map` |
| `STEAM_GROUP_ID` | `""` | Lists the server in that Steam group's server list |
| `SERVER_PASSWORD` | `""` | `sv_password` — leave empty, it can hang the client prompt |

**The full variable reference, config file precedence, custom map and campaign
paths, and the cvars L4D2 does *not* have** are in
[docs/configuration.md](docs/configuration.md).

The player count is not an environment variable: the image always launches with
`+maxplayers 8`, and the engine overwrites that itself. What actually limits a
co-op campaign to four survivors is something else entirely — see
[docs/eight-players.md](docs/eight-players.md).

## Documentation

| Document | Read it when |
|---|---|
| [docs/architecture.md](docs/architecture.md) | You want to know how the image is layered, how `/data` is joined to it, or what a build argument does. |
| [docs/configuration.md](docs/configuration.md) | You are setting variables, editing configs, or adding maps and campaigns. |
| [docs/eight-players.md](docs/eight-players.md) | You want more than four survivors in a co-op campaign. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | The server is not appearing in the browser, or you are reading a confusing boot log. |
| [docs/maintenance.md](docs/maintenance.md) | You are updating the game, the mods, or publishing a release. |

## License

MIT License. Left 4 Dead 2 and Source Engine are trademarks and/or registered
trademarks of Valve Corporation.
