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

The image keeps the 20 GB install at `/opt/l4d2` and links it into the volume
at `/data`, so the server can keep using `/data` as its working directory. Only
these are **real directories** on the volume; everything else is a symlink into
the image:

```text
data/left4dead2/cfg/            real, contents linked
data/left4dead2/cfg/sourcemod/  real, contents linked
data/left4dead2/addons/         real, contents linked
data/left4dead2/maps/           real, contents linked
data/left4dead2/scripts/        real, contents linked
```

So:

- **A new file in one of those directories sticks.** It lands as a real file
  and survives restarts. Verified.
- **Writing to a path that is already a symlink does not stick.** The write goes
  into the container's own filesystem, and is gone when the container is
  recreated. This is the single most common way to lose a mod.

Check before you write anything:

```bash
ls -l data/left4dead2/addons/sourcemod     # link or real directory?
```

---

## SourceMod plugins (`.smx`)

### On the volume

`data/left4dead2/addons/sourcemod` is a **symlink to the image**, so a plugin
dropped inside it disappears. Replace the link with a real copy once:

```bash
podman compose exec l4d2 sh -c \
  'rm -f /data/left4dead2/addons/sourcemod && cp -r /opt/l4d2/left4dead2/addons/sourcemod /data/left4dead2/addons/'

podman compose cp ./myplugin.smx l4d2:/data/left4dead2/addons/sourcemod/plugins/
podman compose restart l4d2
```

After that the directory is a real one and the farm leaves it alone: plugins
you add persist across restarts.

Two things to know about this copy:

- It is a **snapshot**. Plugins the image ships in a later release will not
  appear in your copy until you redo it. If you are chasing an update, bake the
  mod instead.
- `podman compose exec ... rm -f` on a *real* directory deletes it. The `rm -f`
  is deliberate: it removes a link and fails loudly rather than deleting a real
  tree if you run it twice.

### Baked into the image

The right answer for anything that should be on every server, and the only way
to get a plugin that needs a build step. In the `server` stage, after
SourceMod is installed:

```dockerfile
ARG MYPLUGIN_REF=<commit-sha>
RUN set -eux; \
    plugins=/opt/l4d2/left4dead2/addons/sourcemod/plugins; \
    curl -fsSL -o /tmp/p.smx \
        "https://raw.githubusercontent.com/owner/repo/${MYPLUGIN_REF}/build/myplugin.smx"; \
    install -o steam -g steam -m 0644 /tmp/p.smx "${plugins}/myplugin.smx"; \
    rm -f /tmp/p.smx; \
    chown -R steam:steam /opt/l4d2/left4dead2/addons
```

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

`data/left4dead2/addons/` is a real directory, so dropping both files straight
in works and they persist:

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

Both directories are real, so files land next to the linked stock content.

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

`just smoke-plugins` automates exactly that against a freshly built image, and
also reports how many of the expected plugins are present.

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
# 1. is the path a symlink? (it is, until you do this)
podman compose exec l4d2 ls -ld /data/left4dead2/addons/sourcemod

# 2. make it real, once
podman compose exec l4d2 sh -c \
  'rm -f /data/left4dead2/addons/sourcemod && cp -r /opt/l4d2/left4dead2/addons/sourcemod /data/left4dead2/addons/'

# 3. install the plugin and anything it needs
podman compose cp ./myplugin.smx          l4d2:/data/left4dead2/addons/sourcemod/plugins/
podman compose cp ./myplugin_gamedata.txt l4d2:/data/left4dead2/addons/sourcemod/gamedata/

# 4. restart and read the log
podman compose restart l4d2
podman compose logs l4d2 | grep -E '\[SM\]'      # empty = good
```

Decide afterwards whether it earned a place in the image: if every server should
have it, move it into the `server` stage in the `Dockerfile` and delete the
volume copy.
