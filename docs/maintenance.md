# Maintenance

## Updating the game

The image is the only source of game updates. There is no runtime downloader,
no `AUTO_UPDATE`, and no `VALIDATE_ON_BOOT`: the install is fetched while
the image is built, and the running container never talks to Valve.

```bash
podman build --target qol   -t l4d2:1.0.4-qol   .
podman build --target coop8 -t l4d2:1.0.4-coop8 .
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
podman build --target qol --build-arg SOURCEMOD_BRANCH=1.11 -t l4d2:1.0.4-qol .
```

Use `1.11` only if a specific 1.12 build misbehaves — it is the last stable
branch, but the 5+/8-player plugins need 1.12
([eight-players.md](eight-players.md)).

## Updating l4dtoolz

```bash
podman build --target coop8 \
  --build-arg L4DTOOLZ_VERSION=2.5.1 --build-arg L4DTOOLZ_BUILD=2155 \
  -t l4d2:1.0.4-coop8 .
```

Both arguments must match a real release asset; the filename the build expects
is `l4dtoolz-<version>-<build>.zip`.

## Releases and tags

Publishing is driven by `.github/workflows/publish.yaml`: a GitHub release (or a
manual `workflow_dispatch` with a version) builds and pushes.

| Target | Tags |
|---|---|
| `qol` | `<version>-qol`, `qol`, `latest` |
| `coop8` | `<version>-coop8`, `coop8` |

`base` is a build stage and is not published — see
[architecture.md](architecture.md#the-build-graph).

> **Consumer note:** there is no unsuffixed `<version>` tag. A deployment that
> referenced `:1.0.1` must move to `:1.0.x-qol`, or it will fail to pull.
> `latest` currently points at `qol`; `coop8` is deliberately not aliased until
> it has been verified with real clients.

A publish needs about 10 GB of registry blobs per release, almost all of it the shared
install layer, and roughly 5–8 minutes of build time from cold.

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

1. `podman run` the new image with a scratch volume and check the log for
   `Self-check OK: server answers A2S queries`.
2. Confirm the boot log has no new `Unknown command` lines beyond the known
   engine-internal one (`mat_bloom_scalefactor_scalar`) — see the table in
   [troubleshooting.md](troubleshooting.md#reading-the-boot-log).
3. Join with one client and confirm the map loads and the server answers A2S.
   The self-check only proves the query layer; it does not prove the campaign
   scripts still run.
4. For `coop8`, confirm the l4dtoolz cvars took effect: `sv_maxplayers` and
   `precache_all_survivors` should not appear as `Unknown command`. Neither
   should they — the engine stays silent about unknown cvars in config files, so
   pass them as launch arguments once if you want a real check.

## Why the download happens at build time

The previous design downloaded the game on first boot into the volume. That
made every cold start of a fresh volume pay a multi-minute, multi-gigabyte
download, left the whole install on the persistent volume, and made the
container's contents depend on when it was first started. Baking the install in
moves all of that to build time, where it is cached, layered and versioned.
