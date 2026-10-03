# Installing mods

Every mod lands in one of two places, and the difference matters more than it
sounds: **on the volume** (this server only, survives restarts) or **baked into
the image** (versioned, reproducible, needs a rebuild).

| | On the volume | Baked into the image |
|---|---|---|
| Reaches | this server | every server built from the image |
| Changed by | dropping files in | a commit and a rebuild |
| Tracked in git | no | yes |
| Right for | plugins you are trialling, a map for one group | anything everyone should have |

Two things to decide first: *where* it lives, and *what kind* of mod it is —
a SourceMod plugin, a MetaMod extension, or map/campaign content.

---

## The rule that governs everything

On every start the entrypoint copies the overlay the image carries at
`/opt/l4d2-overlay` over the install, and it merges `addons/` and `cfg/`
differently on purpose:

```text
data/left4dead2/addons/         image overlay symlinked in; user files on volume stick
data/left4dead2/cfg/            no-clobber - seeded from the image only where missing
data/left4dead2/maps/           yours, real directory on volume
data/left4dead2/scripts/        yours, real directory on volume
```

So:

- **A file in `cfg/`, `maps/` or `scripts/` sticks.** Real files on the volume,
  surviving restarts.
- **A custom plugin or file in `addons/` sticks across restarts too.**
  The entrypoint symlinks the image's mod overlay without deleting existing
  volume files. If you run in `VANILLA=true` mode, image overlay symlinks are
  temporarily unlinked, leaving your custom volume files intact.

`cfg/` is seeded with no-clobber rather than overwritten, because
`server_custom.cfg`, `sourcemod.cfg` and `l4dmultislots.cfg` are yours to tune.

> **Keep content that costs you a download out of `addons/`.** A campaign VPK
> there survives restarts but not a game update, and the loss is silent — the
> server boots perfectly without it. `maps/` and `scripts/` are real directories
> the overlay never touches, and the engine loads from them, so a campaign that
> belongs to the server rather than the image belongs there. Anything you cannot
> re-download in a minute should be baked into the overlay instead.

---

## SourceMod plugins (`.smx`)

### Baked into the image

The right answer for anything that should be on every server, and the only way
to get a plugin that needs a build step. The overlay is staged at
`/opt/l4d2-overlay/left4dead2`, so a plugin lands there rather than in an
install:

```dockerfile
ARG MYPLUGIN_REF=<commit-sha>
RUN set -eux; \
    plugins=/opt/l4d2-overlay/left4dead2/addons/sourcemod/plugins; \
    curl -fsSL -o /tmp/p.smx \
        "https://raw.githubusercontent.com/owner/repo/${MYPLUGIN_REF}/build/myplugin.smx"; \
    install -m 0644 /tmp/p.smx "${plugins}/myplugin.smx"; \
    rm -f /tmp/p.smx
```

No `chown` is needed: the entrypoint copies the overlay as an unprivileged user
and `--no-preserve=ownership` makes that work.

Pin it to a commit, not a branch, so a rebuild gets the same bytes. A `.smx`
that is fetched from a forum attachment rather than a package feed has no such
option — that is why `assets/left4dhooks.zip` is vendored and checked against
`LEFT4DHOOKS_SHA256` instead.

### Dependencies

A SourceMod plugin rarely ships alone, and the failures are quiet unless you
read the log. These are the four seen in practice, verbatim:

| Log line | Missing |
|---|---|
| `Could not find required plugin "X"` | another `.smx` that must load first |
| `Error parsing gameconfig file "…/X.txt"` / `Stream failed to open` | the plugin's `gamedata/` file |
| `Fatal error encountered parsing translation file "X.phrases.txt"` | the plugin's `translations/` file |
| `unsupported feature set; code is too new` | the plugin is compiled against a newer SourceMod than the image ships |

Some plugins also need a **library** — a `.inc` in
`addons/sourcemod/scripting/include/`. SourceMod decides a library is present
by finding that file on disk at load time, so the include has to be installed
even though the plugin is already compiled. `l4dmultislots` needs Multi-Colors
this way.

If a plugin's archive contains `addons/sourcemod/...`, extract it with that
layout intact. If it contains a bare `sourcemod/...`, the tree belongs in
`addons/`.

---

## MetaMod extensions (`.so` + `.vdf`)

An extension is a library the engine loads itself, ahead of SourceMod — that is
what l4dtoolz is. It needs two files in `addons/`, and the **`.vdf` is what
makes the engine load it**:

```vdf
"Plugin"
{
	"file"	"addons/mytoolz"
}
```

Dropping both files straight into `data/left4dead2/addons/` persists across
restarts — but only until the next install is replaced, at which point they go
with everything else in `addons/`. Bake them into the overlay if the extension
is meant to be permanent:

```bash
podman compose cp ./mytoolz.so l4d2:/data/left4dead2/addons/
podman compose cp ./mytoolz.vdf l4d2:/data/left4dead2/addons/
podman compose restart l4d2
```

The path inside the `.vdf` is relative to the game directory and normally has no
extension: `addons/mytoolz` finds `mytoolz.so`.

**Ship the 32-bit build.** L4D2's engine is 32-bit here, and the image strips
MetaMod's `linux64/` module — that is the source of the harmless
`Unable to load plugin "addons/metamod/bin/linux64/server"` line in the log.

---

## Maps and campaigns

| Content | Goes in |
|---|---|
| Map (`.vpk`) | `data/left4dead2/maps/` |
| Campaign `.txt` definition | `data/left4dead2/scripts/` |
| Campaign VPKs | `data/left4dead2/maps/` |

Both directories are real and untouched by the overlay, so files land next to
the stock content and survive a game update.

Workshop VPKs are conventionally dropped straight into
`data/left4dead2/addons/`, because that is where the engine looks for mounted
content and it is what the workshop tooling does. It works, and it survives
restarts — but an install swap deletes it, silently, and the server boots
without the campaign. If a map is worth more than a re-download, move it to
`maps/` once you are happy with it.

Two cvars matter for custom content, and the image already sets both:

- **`sv_consistency 0`** must stay 0. The consistency check rejects custom
  model and VPK files outright, and the symptom is content silently not
  loading.
- **`precache_all_survivors 1`** preloads every survivor model, which is what
  stops the server crashing once more than four different characters are in
  play.

Workshop "addons" are mostly client-side and do nothing for the server. If a
workshop item is a map or campaign, the server needs the files in the paths
above; if it is a client mutator or HUD, it does not.

---

## Verifying a mod actually loaded

**The log is the reliable check, and silence is the pass condition.** A clean
plugin load prints nothing at all; any `[SM]` line means something did not
load.

```bash
podman compose logs l4d2 | grep -E '\[SM\]'      # empty = everything loaded
```

`just smoke` automates exactly that against a freshly built image, and also
reports how many of the expected plugins are present.

From a connected client, the in-game console is the other view — `sm plugins`
lists what SourceMod loaded, `meta list` what MetaMod has. Those are the
standard SourceMod and MetaMod commands; the log check above is the one verified
in this repository's own tests, because it needs no client.

Then, for a plugin that changes behaviour, actually use it. A plugin that loads
and does nothing is usually a cvar in its own config file that never got set.

---

## A worked example

Adding a plugin to one server only, and not to the image:

```bash
# 1. install the plugin and anything it needs
podman compose cp ./myplugin.smx          l4d2:/data/left4dead2/addons/sourcemod/plugins/
podman compose cp ./myplugin_gamedata.txt l4d2:/data/left4dead2/addons/sourcemod/gamedata/

# 2. restart and read the log
podman compose restart l4d2
podman compose logs l4d2 | grep -E '\[SM\]'      # empty = good
```

That works across restarts. It does **not** survive an install being replaced —
a manifest change or a new volume — because everything in `addons/` goes then.
To make it stick for good, either stage it in the overlay as above, or have the
server load it from a directory the overlay does not touch:

```bash
podman compose exec l4d2 mkdir -p /data/left4dead2/mods/mine
podman compose cp ./myplugin.smx l4d2:/data/left4dead2/mods/mine/
podman compose exec l4d2 sh -c \
  'echo "sm plugins load /data/left4dead2/mods/mine/myplugin.smx" >> /data/left4dead2/cfg/server_custom.cfg'
podman compose restart l4d2
```

Decide afterwards whether it earned a place in the image: if every server should
have it, move it into the `server` stage in the `Dockerfile` and delete the
volume copy.
