# Maintenance

## Updating the game

The image is the only source of game updates. There is no runtime downloader,
no `AUTO_UPDATE`, and no `VALIDATE_ON_BOOT`: the install is fetched while
the image is built, and the running container never talks to Valve.

```bash
just build
```

The build cache keeps the download layer, so a rebuild only fetches what Valve
actually changed. If Valve pushed a new game build, the download layer's cache
entry is invalidated and DepotDownloader re-syncs — that is the moment to
publish a release.

## Updating MetaMod and SourceMod

Both are resolved to the **newest build on the branch** at build time
(`SOURCEMOD_BRANCH`, default `1.12`). There is nothing to bump: the next time
that stage re-runs, it picks up whatever AlliedModders published. The cost is
that images are only reproducible against a warm cache.

```bash
SOURCEMOD_BRANCH=1.13 just build    # 1.13 is the dev channel
```

1.12 is sourcemod.net's **stable** channel, 1.13 its dev channel, and 1.11 is a
legacy branch kept for people who need it. The 5+/8-player plugins are compiled
against 1.12, so a 1.11 build is the one combination that is both unsupported and
less functional ([eight-players.md](eight-players.md)).

## Updating l4dtoolz

```bash
podman build \
  --build-arg L4DTOOLZ_VERSION=2.5.1 --build-arg L4DTOOLZ_BUILD=2155 \
  -t localhost/l4d2:dev .
```

Both arguments must match a real release asset; the filename the build expects
is `l4dtoolz-<version>-<build>.zip`.

## Releases and tags

Publishing is driven by `.github/workflows/publish.yaml`: a GitHub release (or a
manual `workflow_dispatch` with a version) builds and pushes.

| Tag | Points at |
|---|---|
| `<version>` | the `server` image, e.g. `:1.0.3` |
| `<major>.<minor>`, `<major>` | the newest release in that range |
| `latest` | the newest release |

One published image, no per-target tags. `base` is a build stage and is never
pushed — see [architecture.md](architecture.md#why-base-is-a-stage-and-not-an-image).

> **Consumer note:** pin an exact version. A deployment on `:latest` changes
> underneath you on the next pull, and `:1.0` moves when a patch is released.

A publish needs roughly 10 GB of registry blobs, almost all of it the install
layer, compressed with zstd level 4 (see
[architecture.md](architecture.md#compression)), and takes about 5–8 minutes
from a cold cache.

To push a locally built image with the same compression:

```bash
L4D2_VERSION=1.0.3 just push
```

## Cache behaviour

`podman build` caches on the download layer first, then on the runtime libraries
and the mod stage. A rebuild after a source change to the entrypoint or template
reuses everything up to the last copy step, so iterating on the entrypoint costs
seconds, not a multi-gigabyte download.

If a build starts re-downloading everything unexpectedly, something invalidated
the fetch stage — most often a changed `APP_ID`, `DEPOT_DOWNLOADER_VERSION` or
`MAX_DOWNLOADS` build argument.

## Post-update checks

After pulling a new game build, before pointing players at it:

1. `just smoke` boots the new image on a scratch volume and waits for
   `Self-check OK: server answers A2S queries`.
2. Confirm the boot log has no new `Unknown command` lines beyond the known
   engine-internal one (`mat_bloom_scalefactor_scalar`) — see the table in
   [troubleshooting.md](troubleshooting.md#reading-the-boot-log).
3. Join with one client and confirm the map loads and the server answers A2S.
   The self-check only proves the query layer; it does not prove the campaign
   scripts still run.
4. Confirm the l4dtoolz cvars took effect: `sv_maxplayers` and
   `precache_all_survivors` must not appear as `Unknown command`. The engine is
   silent about unknown cvars in config files, so pass them as launch arguments
   once if you want a real check.

## Why the download happens at build time

The previous design downloaded the game on first boot into the volume. That
made every cold start of a fresh volume pay a multi-minute, multi-gigabyte
download, left the whole install on the persistent volume, and made the
container's contents depend on when it was first started. Baking the install in
moves all of that to build time, where it is cached, layered and versioned.
