# Left 4 Dead 2 Linux Dedicated Server (Docker / Podman)

A Left 4 Dead 2 dedicated server container that downloads the game **at build
time** with [DepotDownloader](https://github.com/SteamRE/DepotDownloader) and
bakes it into the image. A cold start is instant: there is no first-boot
download, and the container never needs a Steam login.

Prebuilt images are published to `ghcr.io/delnegend/l4d2-linux-server`.

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
git clone https://github.com/Delnegend/l4d2-linux-server.git
cd l4d2-linux-server

cp .env.example .env      # set at least RCON_PASSWORD

podman compose pull
podman compose up -d
podman compose logs -f
```

That is the whole install: `compose.yaml` references the published image, so
nothing is built on your machine. Expect `Self-check OK: server answers A2S
queries` in the log within a minute — that line is the server telling you it is
discoverable.

### Image tags

| Tag | Meaning |
|---|---|
| `1.0.3` | An exact release. **Pin this for a real deployment.** |
| `latest` | The newest release. Convenient, and only as fresh as your last pull. |

Those are the only two tags. `:1.0.3` is the same image for everyone, there is
no per-target tag, and a deployment should always name an exact version.

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

## What you get

- **Build-time install** — the full server including the DLC campaigns, fetched
  in parallel at build time and baked in.
- **A ~1 MB volume** — the read-only game content stays in the image and is
  linked into `/data` at start-up. Nothing is ever copied.
- **No host dependencies** — the 32-bit runtime libraries are included; it runs
  on Fedora CoreOS, Ubuntu, Debian, Arch and friends without multilib.
- **SourceMod, MetaMod and l4dtoolz baked in** — nothing is installed at boot.
- **Template-driven config** — `server.cfg` is regenerated from a template on
  every start, so environment variables are the single source of truth, and
  `server_custom.cfg` holds everything they don't cover.
- **Misconfiguration guards** — the entrypoint refuses to start rather than run
  a server that is invisible in the browser, and warns before discarding
  hand-edits to `server.cfg`.
- **Visibility self-check** — after boot it probes the running server over A2S
  and says so loudly, because an undiscoverable server otherwise looks perfectly
  healthy in the logs.
- **Non-root** — runs as an unprivileged `steam` user, UID 1000.

## Documentation

| Document | Read it when |
|---|---|
| [docs/architecture.md](docs/architecture.md) | You want to know how the image is layered, how `/data` is joined to it, or what a build argument does. |
| [docs/configuration.md](docs/configuration.md) | You are setting variables, editing configs, or adding maps and campaigns. |
| [docs/eight-players.md](docs/eight-players.md) | You want more than four survivors in a co-op campaign, or you are wondering what `maxplayers` does. |
| [docs/mods.md](docs/mods.md) | You are adding a plugin, a MetaMod extension, or a custom map — and want to know whether it belongs on the volume or in the image. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | The server is not appearing in the browser, or you are reading a confusing boot log. |
| [docs/maintenance.md](docs/maintenance.md) | You are updating the game, the mods, or publishing a release. |

---

## Building from source (advanced)

You only need this if you are changing the image itself. A normal install is
the prebuilt image above.

```bash
just            # list the available recipes
just build      # build the image locally as localhost/l4d2:dev
just up         # build, then run it with compose
just smoke      # boot it on a scratch volume and wait for the A2S self-check
just check      # validate the docs against the code
```

The build is a plain `podman build` with no `--target` needed, because
`server` is the last stage:

```bash
podman build -t localhost/l4d2:dev .
```

`compose.yaml` points at the published image, so `just up` sets `L4D2_IMAGE` to
the local tag. To build the `base` stage alone — the vanilla install with no
mods and no entrypoint — use `just build-base`; it is for measuring the install,
not for deploying.

Requires [just](https://github.com/casey/just) and podman. See
[docs/architecture.md](docs/architecture.md) for the build arguments and
[docs/maintenance.md](docs/maintenance.md) for releasing.

## License

MIT License. Left 4 Dead 2 and Source Engine are trademarks and/or registered
trademarks of Valve Corporation.
