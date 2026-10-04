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

> Auto-merge and branch protection are already enabled on the repository, so
> there is nothing to configure by hand. They live in the repository's
> settings rather than in this file; if they are ever reset, the `gh` commands
> that set them up are in this file's history.

Every run, stale or not, updates a single `Upstream pin state` issue with where
the pins actually are. It is edited in place rather than re-posted, so it reads
as a status board.

Run it by hand from **Actions → Upstream updates → Run workflow**.

Merging a bump does **not** publish. It lands on `main`, and releasing is a
separate button press — see [When it runs](#when-it-runs).

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

`.github/workflows/release.yaml` ships the image, and **nobody types a version
number**. The version is derived from the commit history by
[`ietf-tools/semver-action`](https://github.com/ietf-tools/semver-action), which
reads the Conventional Commits since the last tag:

| Commit prefix | Version moves |
|---|---|
| `feat:` | minor — `1.0.3` → `1.1.0` |
| `fix:`, `refactor:`, `perf:`, `test:`, `build:` | patch — `1.0.3` → `1.0.4` |
| anything breaking (`BREAKING CHANGE:`) | major — `1.0.3` → `2.0.0` |
| `docs:`, `ci:`, `chore:` | **nothing** |

`build:` counts as a patch rather than as nothing, because this repository uses
that prefix for changes that really do ship inside the image — the Dockerfile,
the mod stack, the overlay.

So the version is a fact about the commits rather than a claim someone made
about them.

### When it runs

**Actions → Release → Run workflow.** By hand, and only by hand. There is no
schedule: shipping a new image to everyone who pulls `:latest` is a deliberate
act, not something that should happen because it was Sunday.

The run takes no inputs. If it decides there is nothing worth releasing, the
build job is skipped and the run ends green having published nothing.

So the decision is two separate ones, and only one of them is automatic:

| | Decided by | You can override? |
|---|---|---|
| **What version** | the commit messages | no — nothing in the workflow accepts a number |
| **Whether to ship** | you, by pressing the button | that is the button |

If you dispatch it and it publishes nothing, the commits since the last tag did
not earn a bump. Fix that in the commit message — `git commit --amend` to
`fix:` rather than `chore:` — rather than looking for a number to type.

### The tags themselves

| Tag | Points at |
|---|---|
| `<version>` | the `server` image, e.g. `:1.0.3` |
| `latest` | the newest release |

One published image, exactly two tags: the exact version and `latest`. No
rolling `1.0` or `1` tags, and no per-target tags — so there is nothing
ambiguous for a deployment to latch onto by accident. `just check` fails the
build if that ever changes, so the policy cannot drift quietly.

The **game build is not part of the tag**, and deliberately so. It is a
per-deployment property, set with `GAME_MANIFEST` in `.env`, and putting it in
the tag would mean one tag per Valve build for a value the image does not even
contain. The consequence is the one worth stating plainly: `:latest` and
`:1.0.3` may install different game builds on different days, and two
deployments on the same tag are only on the same game build if they agree on
`GAME_MANIFEST`. Set it explicitly if that matters to you.

To push a locally built image with the same compression:

```bash
L4D2_VERSION=1.0.3 just push
```

## Cache behaviour

The multi-stage build is heavily optimized for Docker layer caching:
- The `fetch` stage downloads the pinned game depots using a BuildKit cache mount.
- The `base` stage copies `/opt/l4d2` and installs runtime libraries. Because it does not contain entrypoint scripts or configuration files, this ~10 GB layer remains permanently cached.
- The `mods` stage downloads and stages plugins independently into `/opt/l4d2-overlay`.
- Rebuilding after a change to `entrypoint.py` or `server.cfg.template` takes under a second because neither `base` nor `mods` needs to re-run.

## Post-update checks

After moving to a new game build, before pointing players at it:

1. `just smoke` boots the image on a scratch volume, waits for
   `Self-check OK: server answers A2S queries`, checks the 5+ plugin stack
   loaded, and fails on any new `Unknown command` line beyond the known
   engine-internal one (`mat_bloom_scalefactor_scalar`).
2. Join with one client and confirm the map loads and the server answers A2S.
   The self-check only proves the query layer; it does not prove the campaign
   scripts still run.
3. Confirm the l4dtoolz cvars took effect: `sv_maxplayers` and
   `precache_all_survivors` must not appear as `Unknown command`. The engine is
   silent about unknown cvars in config files, so pass them as launch arguments
   once if you want a real check.

Step 1 is what the daily update workflow runs for you, in CI, before it merges.
Steps 2 and 3 are the ones that need a human.

## Why the game is baked in

Baking the game install into the `base` image layer removes the 10-minute download
on first boot, ensures byte-identical reproducibility across all servers, and keeps
host volumes tiny (~50 MB for configs, maps, and logs) without risk of data
corruption or leftover mod files.
