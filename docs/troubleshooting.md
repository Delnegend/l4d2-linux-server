# Troubleshooting

## The server is not showing up

The server can be perfectly healthy — map loaded, no errors, direct
`connect <ip>:27015` works — and still never appear in the server browser or
the Steam group list. Discovery depends on the server answering A2S queries, and
several settings stop that *silently*.

**Check the log first.** Within a minute or two of start-up the entrypoint prints:

```text
[Bootstrap] Self-check OK: server answers A2S queries on UDP 27015 (discoverable).
```

If you see a `SELF-CHECK FAILED` block instead, the process is running but
answering nothing. That block already lists the usual causes; the table below
extends it.

**Verify from the host** that the server answers on the address clients use:

```bash
python3 - <<'EOF'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(b"\xff\xff\xff\xffTSource Engine Query\x00", ("<server-ip>", 27015))
try:
    print("reply:", s.recvfrom(4096)[0][:20])   # 9-byte S2C_CHALLENGE is a valid reply
except socket.timeout:
    print("NO REPLY - the server is not discoverable")
EOF
```

| Cause | Symptom | Fix |
|---|---|---|
| `-insecure` in `EXTRA_ARGS` | No A2S reply at all; direct connect still works | Remove it — it is refused at startup, see below. |
| `-nomaster` in `EXTRA_ARGS` | No A2S reply; never registers with the master server | Remove it. |
| `sv_lan 1` | No master server heartbeat, no Steam auth | Leave `sv_lan` at `0` (the template default). |
| No inbound UDP `27015` (firewall, missing port forward) | A2S works locally but not from the internet | Forward UDP `27015` and `STEAM_PORT` to the host. |
| Wrong `STEAM_GROUP_ID` | A2S fine, but the group server list stays empty | Use the numeric group ID, not the group URL. |
| `STEAM_GROUP_EXCLUSIVE=1` | Server hidden until one player joins it from a lobby | Set it to `0` for immediate visibility. |
| `SERVER_PASSWORD` set | Players are prompted, and L4D2 can hang on that prompt | Leave `SERVER_PASSWORD` empty. |
| Host networking in use but the port is already bound | The server starts, nothing is reachable | `ss -lunp \| grep 27015` — the game port must be free. |

> **Why `-insecure` is fatal:** it is a *server* launch option that disables the
> Steam/VAC layer. The engine then stops answering A2S queries entirely, so no
> browser or matchmaking service can discover the server — while the game port
> keeps accepting connections, which is what makes the server look healthy. It
> has no legitimate use on a public dedicated server; it only exists to load
> unsigned modules into a *listen* server.

## Rejected flags

Rather than start a server that is invisible, the entrypoint refuses to launch
(exit code `1`) when `EXTRA_ARGS` contains any of these:

| Flag | Why it is refused |
|---|---|
| `-insecure` | Disables the Steam/VAC layer, after which the server answers no A2S queries at all (`INFO`, `PLAYER` and `RULES` are silently dropped). |
| `-nomaster` | Stops the server registering with the Steam master server, so it can never be discovered. |
| `-lan` | LAN mode disables the master server heartbeat and Steam authentication. |
| `sv_lan 1` / `+sv_lan 1` | Same as above — local network only. |

## Reading the boot log

Lines that look alarming and are not:

| Line | Meaning |
|---|---|
| `maxplayers set to 18` | The engine's hard-coded client limit. It overwrote whatever was requested — see [eight-players.md](eight-players.md). |
| `Unable to load plugin "addons/metamod/bin/linux64/server"` | Expected. The image removes the 64-bit MetaMod module because the engine is a 32-bit build. |
| `Unknown command "mat_bloom_scalefactor_scalar"` | The engine asking for a console variable from its own config. |
| `S_API FAIL SteamAPI_Init() failed; create pipe failed` | The first Steam init attempt, before the real one. Followed by `VAC secure mode is activated` and `Connection to Steam servers successful`. |
| `Couldn't find any entities named fire13_timer…` | Map script bookkeeping during load. Normal. |
| `Parent cvar in server.dll not allowed` | Engine chattiness. |
| `Server is hibernating` | L4D2 hibernates when empty. It still answers A2S, so it stays listed. |

Lines that matter:

| Line | Meaning |
|---|---|
| `Self-check OK: server answers A2S queries` | The server is discoverable. |
| `SELF-CHECK FAILED` | Running but answering nothing. |
| `[Bootstrap] WARNING: …/server.cfg differs from the rendered template` | Your hand-edits to `server.cfg` are about to be discarded. Move them to `server_custom.cfg`. |
| `exec: couldn't exec …` | An `exec` line in a config file. The engine resolves those against the install root on the volume — see [architecture.md](architecture.md#one-engine-quirk-worth-knowing). |
| `[SM] Unable to load plugin "X": Could not find required plugin "left4dhooks"` | Expected until DHooks is added. See [eight-players.md](eight-players.md). |
| `[SM] Unable to load plugin "X": unsupported feature set; code is too new` | The plugin is compiled against a newer SourceMod than this image ships. Check `SOURCEMOD_BRANCH`. |

## The volume is not what you expect

`data/` is about 50 MB, and that is correct: the ~10 GB game install is baked
into the image at `/opt/l4d2`. On startup, `mirror_tree` creates shallow symlinks
from `/opt/l4d2` into `data/`, so the host volume only holds real directories for
your persistent configs (`cfg/`), custom maps (`maps/`), custom scripts
(`scripts/`), and logs.

```bash
du -sh data/
ls -l data/srcds_run   # symlink pointing to /opt/l4d2/srcds_run
```

If `data/` is missing files or `srcds_run` fails to launch, check that `data/`
is a writable directory owned or writable by UID 1000 (`steam`).
## Players cannot see more than four slots

That is a client-side limit, not a server one. See
[eight-players.md](eight-players.md#getting-players-in-is-a-client-problem).
