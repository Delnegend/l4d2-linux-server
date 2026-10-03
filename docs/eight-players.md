# More than four survivors

L4D2 caps a co-op campaign at **four survivors**, and `+maxplayers` has nothing
to do with it. Two independent limits are involved and they are easy to
misattribute, so start here.

| Limit | Value | What actually controls it |
|---|---|---|
| Client slots (MaxClients) | **18, hard-coded** | The engine. It overwrites `maxplayers` during start-up, so both `+maxplayers 8` and a `maxplayers 4` cvar are discarded — the log prints `maxplayers set to 18` either way. |
| Co-op campaign survivors | **4** | The Steam **lobby reservation** the server registers. While a lobby cookie exists, the game caps campaigns at 4 and versus at 8. |

Measured on build 10097: `+maxplayers 8` → `maxplayers set to 18`;
`+maxplayers 4` → `maxplayers set to 18`; `maxplayers 4` as a cvar in
`server.cfg` → `maxplayers set to 18`. l4dtoolz's documentation states the same
thing from the other side: *"The engine's default value is 18."*

So the honest summary is that `+maxplayers 8` locks **8 slots**, and l4dtoolz is
what addresses the 4-survivor cap. Both ship in the published image.

## What the image does about it

[Source](https://github.com/lakwsh/l4dtoolz) is l4dtoolz 2.5.1, staged in the
image's mod overlay with three cvars in the image-level override layer
(`/defaults/server_custom.cfg`):

```cvar
sv_force_unreserved 1     // drop the lobby reservation -> the campaign cap of 4 lifts
sv_maxplayers 8           // the player cap itself (-1..31)
precache_all_survivors 1  // preload every survivor model, avoids crashes at 5+
```

All three are real engine cvars once l4dtoolz is loaded — verified by passing a
deliberately bogus cvar alongside them on the command line, which the engine
correctly rejected while accepting these.

Notes on the three:

- `sv_force_unreserved` is l4dtoolz's built-in alternative to the
  `l4d_unreservelobby` plugin: it forces `sv_allow_lobby_connect_only` to `0` and
  stops processing lobby matching, so no lobby cookies are issued.
- `sv_maxplayers` is the player cap, **not** MaxClients. That one is `sv_setmax`
  (18–32) and this image leaves it at the default; l4dtoolz warns against
  raising it above 31 after *The Last Stand*.
- `precache_all_survivors` exists because more than four different survivor
  models in play at once will otherwise crash the server.

The volume's `server_custom.cfg` is appended *after* the image's, so any of
them can be changed without a rebuild:

```bash
echo 'sv_maxplayers 12' >> data/left4dead2/cfg/server_custom.cfg
```

### Putting it back the way it was

To go back to a stock 4-survivor campaign — no lobby changes at all — override
the one cvar that does the work:

```bash
echo 'sv_force_unreserved 0' >> data/left4dead2/cfg/server_custom.cfg
```

The last value wins, so the appended line replaces the image's `1` with `0`.
Deleting `l4dtoolz.so` and `l4dtoolz.vdf` from `data/left4dead2/addons/` does
**not** work: the overlay is copied over `addons/` on every start and it carries
both files. Use the cvar above.

## Getting players in is a client problem

Lifting the cap on the server does not widen the L4D2 client lobby, which only
ever offers four co-op slots. Friends need one of:

- **Direct connect** — `mm_dedicated_force_servers <ip>:27015` in the client
  console. No mod, works immediately, the `:27015` is optional.
- **Steam group list** — set `STEAM_GROUP_ID` to the numeric group ID. The
  server then shows up in the group's server list for members, with no client
  mod at all. This is the least friction for a group that already exists.
- **A workshop "8 player lobby" mutation** — only the person *hosting* the lobby
  has to subscribe; everyone else connects as above.

## What is deliberately not in the image

The 5+ player fix pack (defib, survivor identity, AFK, upgrade pack, charger
collision, ladder crash, …) is **not** baked in. It is a long tail of plugins,
each patching one specific 5+ bug, and several commonly cited ones are marked
broken upstream. One thing is actually in the way, and it is a single artifact:

> **Left 4 DHooks.** `l4d_unreservelobby` (removes the lobby reservation) and
> `l4dmultislots` (gives the game spare survivor slots) both declare it a
> required plugin, and SourceMod reports exactly that in this image:
>
> ```text
> [SM] Unable to load plugin "l4dmultislots.smx": Could not find required plugin "left4dhooks"
> ```

Everything else about those two is already satisfied — they load far enough for
SourceMod to name the missing dependency, which only happens on the **1.12**
branch that the images build. On the legacy 1.11 branch `l4dmultislots` dies
earlier and less usefully, with `unsupported feature set; code is too new`.
1.12 is sourcemod.net's stable channel, so this costs nothing in stability.

### Why DHooks is not automated

The current build (1.168/1.169) is a **forum attachment** on AlliedModders.
That forum sits behind bot protection that returns HTTP 403 to both scripted
downloads and headless browsers, and no AlliedModders mirror serves it — every
`smdrop` path probed returns a soft 404. The last GitHub-hosted native is
`peace-maker/DHooks2` v2.2.0 from **2021**, which predates *The Last Stand* and
carries no matching `left4dhooks.smx`.

To go further, download `left4dhooks.zip` from the bottom of that thread in a
normal browser, drop it into the repository, and pin its checksum. It is a
`left4d2/addons/sourcemod/` tree, so it drops into the same place the image
already bakes SourceMod.

### Dead ends, for the next person

- **ABM** is what older write-ups pair with l4dtoolz. It is absent from the
  current (2026-07) community guide and should be treated as obsolete.
- **`sm_cvar <name> <value>`** in `server.cfg` is the guide's way of setting
  plugin cvars, and it needs DHooks. For l4dtoolz's own cvars it is unnecessary
  — plain names work, as verified above.
- The `8 Slots Lobby Mod` (workshop 2754956355) and `CRAZY 8 PACK`
  (3054034434) are client-side addons. They change what a lobby displays, not
  what the server allows.

## References

- [l4dtoolz README](https://github.com/lakwsh/l4dtoolz/blob/main/README_EN.md) —
  §1.1 the 18 default, §1.2 `sv_maxplayers`, §1.3 the lobby cap
- [8+ Survivors In Coop guide](https://github.com/fbef0102/Game-Private_Plugin/tree/main/Tutorial_%E6%95%99%E5%AD%B8%E5%8D%80/English/Game/L4D2/8%2B_Survivors_In_Coop)
  — the community-maintained plugin list, updated 2026-07-26
- [L4D2 with 5+ players](https://jackzie.dev/posts/sourcemod/l4d2-and-5players/)
  — independent walkthrough, the source of the 1.12 branch tip
- [Left 4 DHooks Direct](https://forums.alliedmods.net/showthread.php?t=321696) —
  the blocked thread
