# Maintenance

## Updating the game

The image carries no game files. The install is downloaded on the **first start
of a volume** from two pinned Steam depot manifests and reused on every start
after that, so updating the game is a one-line change rather than an image
rebuild.

```bash
GAME_MANIFEST=4827977561765481436 just up    # or set it in .env
```

There are two pins, because the install is two depots: `GAME_MANIFEST` for
depot `222861`, the game, and `LAUNCHER_MANIFEST` for depot `222863`, the
launcher that provides `srcds_run`. A manifest id, not a build number: two
volumes that resolve to the same value hold byte-identical files. The defaults
live in the Dockerfile as `ARG`s and are documented in
[architecture.md](architecture.md#build-arguments).

Two ways to move a deployment:

| | Needs an image | Needs a pull | Needs a re-download |
|---|---|---|---|
| Set `GAME_MANIFEST` in `.env` | no | no | yes, once |
| Bump the Dockerfile `ARG` and release | yes | yes | yes, once |

The first is enough for a game update. The second is how the default catches up.

Once the download has happened, restart is instant — nothing is re-fetched.
Changing the manifest is what triggers the next download.

> Steam can withdraw an old manifest id. A long-lived pin is therefore a
> *requested* version, not a permanent guarantee; if Valve stops serving it, the
> entrypoint says so and refuses to start rather than silently serving
> something else.

## Automated update checks

`.github/workflows/updates.yaml` runs once a day and compares four pins
against upstream with `scripts/resolve-upstream.py`:

| Pin | Upstream signal |
|---|---|
| `GAME_MANIFEST` | public manifest id of app 222860 depot 222861, the game |
| `LAUNCHER_MANIFEST` | public manifest id of depot 222863, which carries `srcds_run` |
| `L4DTOOLZ_VERSION` / `L4DTOOLZ_BUILD` | newest stable [lakwsh/l4dtoolz](https://github.com/lakwsh/l4dtoolz) release shipping a `l4dtoolz-<version>-<build>.zip` |
| `L4D_PLUGINS_REF` | head commit of [fbef0102/L4D1_2-Plugins](https://github.com/fbef0102/L4D1_2-Plugins) |

If any of them is stale, the workflow opens **one** pull request that rewrites
the `ARG` defaults and the matching rows in
[architecture.md](architecture.md#build-arguments) with
`scripts/apply-bump.py`, then enables auto-merge on it. The pull request lands
when `Check (just verify)` goes green, and that check is not a lint — it
downloads both pinned manifests, boots the server, checks the A2S self-check
and the plugin stack, and fails on any `Unknown command` the game build
introduced. So a merged bump is a booted one.

Every run, stale or not, updates a single `Upstream pin state` issue with where
the pins actually are. It is edited in place rather than re-posted, so it reads
as a status board.

Run it by hand from **Actions → Upstream updates → Run workflow**.

Merging a bump does **not** publish. `publish.yaml` still needs a release, and
the tag policy below still applies.

### Enabling auto-merge

`gh pr merge --auto` does nothing unless the repository allows it. Two one-time
commands, both need admin:

```bash
gh repo edit Delnegend/l4d2-linux-server \
  --enable-auto-merge --enable-rebase-merge --delete-branch-on-merge

gh api -X PUT repos/Delnegend/l4d2-linux-server/branches/main/protection \
  -H "Accept: application/vnd.github+json" --input - <<'EOF'
{
  "required_status_checks": { "strict": true, "contexts": ["Check (just verify)"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "allow_auto_merge": true
}
EOF
```

Under **Settings → Actions → General → Workflow permissions**, confirm **Allow
GitHub Actions to create and approve pull requests** is checked.

## Updating MetaMod and SourceMod

Both are resolved to the **newest build on the branch** at build time
(`SOURCEMOD_BRANCH`, default `1.12`). There is nothing to bump: the next build
picks up whatever AlliedModders published, and the daily check reports the
current drops in the status issue so you can see a move without hunting for it.

```bash
SOURCEMOD_BRANCH=1.13 just build    # 1.13 is the dev channel
```

1.12 is sourcemod.net's **stable** channel, 1.13 its dev channel, and 1.11 is a
legacy branch kept for people who need it. The 5+/8-player plugins are compiled
against 1.12, so a 1.11 build is the one combination that is both unsupported and
less functional ([eight-players.md](eight-players.md)).

## Updating the 5+ plugins

Three of the four come from [fbef0102/L4D1_2-Plugins](https://github.com/fbef0102/L4D1_2-Plugins)
and are pinned to a commit, `L4D_PLUGINS_REF`. The daily check opens a pull
request when the head moves. To do it by hand:

```bash
podman build --build-arg L4D_PLUGINS_REF=<sha> -t localhost/l4d2:dev .
```

Edit the `ARG L4D_PLUGINS_REF` line **and** its row in
[architecture.md](architecture.md#build-arguments) — `just check` fails if they
disagree.

`left4dhooks` is different: it is a forum attachment, not a package, so it is
vendored at `assets/left4dhooks.zip` and verified against
`LEFT4DHOOKS_SHA256`. No upstream feed exists, so no workflow can watch it.
Replacing it stays a manual two-step — drop the new archive in, update the
checksum — which the build enforces rather than trusting.

## Updating l4dtoolz

Pinned by two arguments, because the release asset name carries both:

```bash
podman build \
  --build-arg L4DTOOLZ_VERSION=<version> --build-arg L4DTOOLZ_BUILD=<build> \
  -t localhost/l4d2:dev .
```

Both arguments must match a real release asset; the filename the build expects
is `l4dtoolz-<version>-<build>.zip`. A release that ships only the rolling
`l4dtoolz-<version>-main.zip` cannot be pinned and is skipped by the update
workflow — the current pin is in the Dockerfile as `ARG L4DTOOLZ_VERSION`.

## Releases and tags

Publishing is driven by `.github/workflows/publish.yaml`: a GitHub release (or a
manual `workflow_dispatch` with a version) builds and pushes.

| Tag | Points at |
|---|---|
| `<version>` | the `server` image, e.g. `:1.0.3` |
| `latest` | the newest release |

One published image, exactly two tags: the exact version and `latest`. No
rolling `1.0` or `1` tags, and no per-target tags — so there is nothing
ambiguous for a deployment to latch onto by accident.

The **game build is not part of the tag**, and deliberately so. It is a
per-deployment property, set with `GAME_MANIFEST` in `.env`, and putting it in
the tag would mean one tag per Valve build for a value the image does not even
contain. The consequence is the one worth stating plainly: `:latest` and
`:1.0.3` may install different game builds on different days, and two
deployments on the same tag are only on the same game build if they agree on
`GAME_MANIFEST`. Set it explicitly if that matters to you.

A publish is now under a minute from a cold cache, because there is no 10 GB in
the build.

To push a locally built image with the same compression:

```bash
L4D2_VERSION=1.0.3 just push
```

## Cache behaviour

The image has nothing to invalidate. `podman build` caches on the mod overlay and
the entrypoint, so a rebuild after a change to `entrypoint.sh` or
`server.cfg.template` costs seconds. Changing `APP_ID`, `GAME_DEPOT`,
`GAME_MANIFEST`, `DEPOT_DOWNLOADER_VERSION`, `MAX_DOWNLOADS` or `SOURCEMOD_BRANCH`
invalidates only the stage that uses it.

The volume is the other cache, and the more important one: it holds the install,
so restarts are instant and only the first start pays. `just smoke` has no such
cache — it runs on a scratch volume — so it downloads ~10 GB every time.

## Post-update checks

After moving to a new game build, before pointing players at it:

1. `just smoke` boots the image on a scratch volume — which means it downloads
   the pinned manifests first — waits for
   `Self-check OK: server answers A2S queries`, checks the 5+ plugin stack
   loaded, and fails on any new `Unknown command` line beyond the known
   engine-internal one (`mat_bloom_scalefactor_scalar`). About three minutes
   end to end here, most of it the 9.5 GB download.
2. Join with one client and confirm the map loads and the server answers A2S.
   The self-check only proves the query layer; it does not prove the campaign
   scripts still run.
3. Confirm the l4dtoolz cvars took effect: `sv_maxplayers` and
   `precache_all_survivors` must not appear as `Unknown command`. The engine is
   silent about unknown cvars in config files, so pass them as launch arguments
   once if you want a real check.

Step 1 is what the daily update workflow runs for you, in CI, before it merges.
Steps 2 and 3 are the ones that need a human.

## Why the download happens at run time

The alternative — baking the install into the image — was the previous design,
and it cost a 10.3 GB pull for every deployment and an 8-minute CI build for
every release. It made a routine Valve patch an infrastructure event, and it
needed a farm of symlinks to reconcile a read-only install with a writable
volume.

Downloading at run time puts the cost where it belongs: once per volume, on the
machine that is going to run the server, against a manifest that names exactly
one set of files. The image becomes 528 MB, the release takes under a minute,
and moving to a new Valve build is an `.env` edit.

What it costs, stated plainly: a fresh volume pays a multi-minute download
before the server answers anything, and the install is now volume state, so two
volumes can hold different game builds. Both are visible and both are intended —
`just logs` shows the download, and `.l4d2-manifest` in the volume names
exactly what is installed.
