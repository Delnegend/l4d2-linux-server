# Configuration

Two layers: environment variables, and config files on the volume. The
environment is the source of truth for the *rendered* `server.cfg`; the volume's
`server_custom.cfg` is the source of truth for everything the environment does
not cover.

## Environment variables

Copy `.env.example` to `.env` and edit it. Compose passes each of these through.

| Variable | Default | Renders / does |
|---|---|---|
| `GAME_MANIFEST` | the image's `ARG` | Steam depot manifest id to install. Empty takes the one baked into the image. Setting it makes the next start of the volume download that build instead — see [maintenance.md](maintenance.md#updating-the-game). |
| `VANILLA` | `false` | Run as a vanilla 4-player server without SourceMod/l4dtoolz (`true` or `false`). |
| `PORT` | `27015` | `-port` |
| `STEAM_PORT` | `26901` | `-sport` |
| `SERVER_NAME` | `Left 4 Dead 2 Dedicated Server` | `hostname` |
| `RCON_PASSWORD` | `ChangeThisRcon123` | `rcon_password`. Change it. |
| `SERVER_PASSWORD` | `""` | `sv_password`. Leave empty — see below. |
| `DEFAULT_MAP` | `c1m1_hotel` | `+map` |
| `STEAM_GROUP_ID` | `""` | `sv_steamgroup`. Numeric ID, **not** the group URL. Empty disables group advertising. |
| `STEAM_GROUP_EXCLUSIVE` | `0` | `sv_steamgroup_exclusive`. `1` hides the server until a player joins it from a lobby. |
| `SV_CONSISTENCY` | `0` | `sv_consistency`. Must stay `0` for more than four survivors. |
| `SV_PURE` | `0` | `sv_pure` |
| `EXTRA_ARGS` | `""` | Appended to the `srcds_run` command line. Certain flags are rejected at startup — see [troubleshooting.md](troubleshooting.md#rejected-flags). |

**Player count is governed by the mode.** The image launches with `+maxplayers 8` by default, or `+maxplayers 4` when `VANILLA=true`; see [eight-players.md](eight-players.md).

> **`SERVER_PASSWORD` is best left empty.** L4D2 has a long-standing bug where
> the password prompt hangs when `sv_allow_lobby_connect_only` is `0`, which is
> what the template sets. The entrypoint logs a note when it is non-empty.

`GAME_MANIFEST` is the one knob that changes what is on disk rather than how
the server behaves. It deliberately has no default of its own: an empty `.env`
leaves the image's value in force, so a compose file that never mentions it
still gets a working server.

## Config file precedence

`server.cfg` is regenerated on **every** start. Three inputs are combined, in
this order, and the last one wins:

```text
server.cfg.template          baked into the image
        +
/defaults/server_custom.cfg  image-level cvars (l4dtoolz's, see
                            eight-players.md)
        +
/data/left4dead2/cfg/server_custom.cfg   yours, on the volume
        =
/data/left4dead2/cfg/server.cfg          the file the engine actually reads
```

So:

- **Do not edit `server.cfg`.** It is overwritten every start; the entrypoint
  logs a warning when it notices your edits are about to be discarded.
- **Do edit `server_custom.cfg`.** It is created on first start, never
  overwritten, and appended verbatim — later values override earlier ones, so
  you can shadow anything the image sets:

  ```bash
  echo 'sv_maxplayers 12' >> data/left4dead2/cfg/server_custom.cfg
  ```

- **No `exec` lines in `server_custom.cfg`.** The engine resolves `exec`
  against the install root, which lives in the image rather than the volume, so
  it silently finds nothing. The entrypoint appends the file instead; see
  [architecture.md](architecture.md#one-engine-quirk-worth-knowing).

## Cvars the engine does not have

Do not add these — the engine logs `Unknown command` for each and does nothing:

| Cvar | Note |
|---|---|
| `sv_minupdaterate`, `sv_maxupdaterate` | Do not exist in L4D2. They appear in l4dtoolz's tickrate list, but only for servers that register them; the shipped builds do not. |
| `sv_client_min_interp_ratio`, `sv_client_max_interp_ratio` | Also absent. Same list, same story. |
| `sv_hibernate_when_empty` | Absent; L4D2 hibernates automatically and still answers A2S, so nothing is needed to keep an empty server listed. |

A harmless one you will see in every log is
`Unknown command "mat_bloom_scalefactor_scalar"` — the engine asking for a
console variable from its own config. Nothing to do about it.

If you are unsure whether a cvar exists, pass it as a launch argument
(`EXTRA_ARGS="+some_cvar 1"`): the engine reports unknown cvars on the
command line, unlike in a config file, where it stays quiet.

## Custom maps and campaigns

| Content | Path | Kind |
|---|---|---|
| Custom map (`.vpk`) | `data/left4dead2/maps/` | real directory on the volume |
| Custom campaign | `data/left4dead2/scripts/` for the `.txt`, `maps/` for the VPKs | real directory |
| Campaign rotation | `data/left4dead2/mapcycle.txt` | real file |

All of it is real files on the volume, dropped-in content sitting beside the
stock content rather than replacing it.

## SourceMod and MetaMod

`data/left4dead2/addons/sourcemod` and `.../metamod` are refreshed from the
overlay the image carries on every start, so an image update does reach a volume
that already has the right game build. Files you add under those names survive
in the meantime — the copy overwrites same-named files and deletes nothing — but
they are **not** durable: an install swap removes the whole of `addons/`,
`left4dead2/cfg` being the only exception. Installing a plugin needs one
deliberate step first.

How to add a plugin, a MetaMod extension, or a custom map — and when a mod
belongs in the image rather than on the volume — is in
[mods.md](mods.md).

## What is not configurable, and why

| Thing | Why |
|---|---|
| Player count | The engine hard-codes MaxClients at 18 and overwrites `maxplayers` on startup. See [eight-players.md](eight-players.md). |
| Game files | Downloaded on the first start of a volume from `GAME_MANIFEST`, then left alone. See [maintenance.md](maintenance.md). |
| Mod versions | Baked per image tag, applied on every start. |
