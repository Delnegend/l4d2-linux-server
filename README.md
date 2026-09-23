# Left 4 Dead 2 Linux Dedicated Server (Docker / Podman)

A lightweight, automated Left 4 Dead 2 Dedicated Server container that uses **DepotDownloader** to download and update game files anonymously.

---

### The Problem This Solves

Valve migrated Left 4 Dead 2 Dedicated Server (App ID `222860`) to the newer `freetodownload` package structure. Due to an unpatched platform bug in SteamCMD on Linux, attempting to install or update the server anonymously fails with:
```text
ERROR! Failed to install app '222860' (Invalid platform)
```
As a result, managers relying on official SteamCMD (such as LinuxGSM and standard Docker images) fail to download anonymously and demand personal Steam credentials with game ownership.

**This image solves this problem** by utilizing [DepotDownloader](https://github.com/SteamRE/DepotDownloader), which properly handles the `freetodownload` API flow anonymously without requiring a Steam login.

---

### Features

- **Anonymous First-Boot Bootstrap**: If `./data` is empty, it automatically downloads the complete L4D2 dedicated server files on first run.
- **Auto-Update Support**: Toggle `AUTO_UPDATE=true` to automatically check for game updates on container startup.
- **Zero Host Dependencies**: Fully containerized with 32-bit runtime libraries included. Runs smoothly on modern 64-bit distributions without multilib (e.g. Fedora CoreOS, Ubuntu, Debian, Arch).
- **Template-Driven Config**: `server.cfg` is regenerated from `server.cfg.template` on every start, so the environment variables are the single source of truth. Persistent cvars belong in `server_custom.cfg`, which is never overwritten.
- **Misconfiguration Guards**: The entrypoint refuses to start with launch flags that silently make the server undiscoverable (`-insecure`, `-nomaster`, `-lan`, `sv_lan 1`), and warns before discarding hand-edits to `server.cfg`.
- **Visibility Self-Check**: After boot it probes the running server over A2S and reports loudly if the server is not answering — an undiscoverable server otherwise looks perfectly healthy in the logs.
- **Optional SourceMod & MetaMod Support**: Toggle `INSTALL_SOURCEMOD=true` to automatically install the latest MetaMod:Source and SourceMod releases on initial setup.
- **Non-Root Execution**: Runs under an unprivileged `steam` user (UID 1000) for security and file permission parity.

---

### Quick Start

1. **Clone the repository**:
   ```bash
   git clone https://github.com/<your-user>/l4d2-linux-server.git
   cd l4d2-linux-server
   ```

2. **Configure environment**:
   ```bash
   cp .env.example .env
   # Edit .env with your preferred server name, rcon password, etc.
   ```

3. **Start the server**:
   ```bash
   docker compose up -d
   # or with podman:
   podman compose up -d
   ```

4. **Monitor logs**:
   ```bash
   docker compose logs -f
   ```

---

### Configuration (`.env`)

| Variable | Default | Description |
|---|---|---|
| `PORT` | `27015` | Server UDP/TCP game port |
| `STEAM_PORT` | `26901` | Steam master server communication port |
| `SERVER_NAME` | `Left 4 Dead 2 Dedicated Server` | Server name displayed in the server browser |
| `RCON_PASSWORD` | `ChangeThisRconPassword123` | Remote console administration password |
| `SERVER_PASSWORD` | `""` | Optional password required to connect. **L4D2 has a long-standing bug where the password prompt hangs** when `sv_allow_lobby_connect_only` is `0` (the template default), so leaving this empty is strongly recommended. |
| `DEFAULT_MAP` | `c1m1_hotel` | Initial map loaded on startup |
| `MAX_PLAYERS` | `8` | Maximum client player slots |
| `STEAM_GROUP_ID` | `""` | Numeric Steam group ID (not the group URL). Renders `sv_steamgroup`. Empty disables group advertising. |
| `STEAM_GROUP_EXCLUSIVE` | `0` | Renders `sv_steamgroup_exclusive`. `0` lists the server publicly; `1` hides it until one player joins it from a lobby. |
| `SV_CONSISTENCY` | `0` | Renders `sv_consistency` |
| `SV_PURE` | `0` | Renders `sv_pure` |
| `AUTO_UPDATE` | `false` | If `true`, checks and updates game files via DepotDownloader on boot |
| `VALIDATE_ON_BOOT` | `false` | If `true`, validates existing game depot checksums on update |
| `INSTALL_SOURCEMOD`| `false` | If `true`, auto-installs MetaMod and SourceMod on first boot |
| `EXTRA_ARGS` | `""` | Additional command-line flags passed directly to `srcds_run`. Flags that break server discovery are **rejected at startup** — see [Misconfiguration guards](#misconfiguration-guards). |

---

### Directory Structure

```text
.
├── .env.example            # Environment configuration template
├── .gitignore              # Ignores ./data and local config
├── Dockerfile              # Container definition (Debian slim + 32-bit libs + DepotDownloader)
├── compose.yaml            # Docker / Podman compose file
├── entrypoint.sh           # Bootstrap script (updates, config generation, launches SRCDS)
├── server.cfg.template     # Template for auto-generating server.cfg
└── data/                   # [Mounted volume] Game files, configs, addons, logs
    └── left4dead2/cfg/
        ├── server.cfg          # Regenerated from server.cfg.template every start
        └── server_custom.cfg   # Persistent overrides (exec'd, never overwritten)
```

---

### Customization & Addons

* Custom maps (`.vpk`) can be placed directly in:
  `./data/left4dead2/addons/`
* **Persistent cvars go in `./data/left4dead2/cfg/server_custom.cfg`.** It is
  `exec`'d at the end of `server.cfg` and is never overwritten; the entrypoint
  creates it on first start.
* **Do not edit `./data/left4dead2/cfg/server.cfg`.** It is regenerated from
  `server.cfg.template` on every container start, so hand-edits are discarded
  (the entrypoint logs a warning when this happens). To change one of its values
  permanently, change the matching environment variable instead.
* Any other changes made to `./data` persist across container restarts.

---

### Misconfiguration guards

An L4D2 server can be running perfectly and still be **completely invisible**:
discovery depends on the server answering A2S queries, and several settings
disable that silently while the logs continue to look healthy and direct
`connect <ip>:27015` keeps working. The entrypoint therefore refuses to start
(exit code `1`) when `EXTRA_ARGS` contains any of these:

| Flag | Why it is refused |
|---|---|
| `-insecure` | Disables the Steam/VAC layer. The server then answers **no** A2S queries at all (`INFO`, `PLAYER` and `RULES` are silently dropped), so nothing can discover it. |
| `-nomaster` | Stops the server registering with the Steam master server, so it can never be discovered through the server browser or the Steam group list. |
| `-lan` | LAN mode disables the master server heartbeat and Steam authentication. |
| `sv_lan 1` / `+sv_lan 1` | Same as above — the server is only reachable from the local network. |

It also:

- creates `server_custom.cfg` on first start, so overrides have a permanent home;
- logs a **warning** when the existing `server.cfg` differs from the freshly
  rendered template, i.e. when hand-edits are about to be discarded;
- logs a **note** when `SERVER_PASSWORD` is set, because of the prompt bug above;
- runs a **visibility self-check** after boot (`Self-check OK: server answers A2S
  queries on UDP <port>`), and prints a `SELF-CHECK FAILED` block if the running
  server is not answering.

---

### Troubleshooting: the server is not showing up

The server can be healthy — map loaded, no errors, direct `connect <ip>:27015`
works — and still never appear in the server browser or in the Steam group
server list.

**Check first:** look for the `Self-check OK: server answers A2S queries` line in
the container log shortly after boot. If you instead see `SELF-CHECK FAILED`, the
server is running but not discoverable.

Verify from the host that the server answers on the address clients will use:

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

Common causes, in rough order of likelihood:

| Cause | Symptom | Fix |
|---|---|---|
| `-insecure` in `EXTRA_ARGS` | No A2S reply at all; direct connect still works | Remove it — see [Misconfiguration guards](#misconfiguration-guards). |
| `-nomaster` in `EXTRA_ARGS` | No A2S reply; never registers with the master server | Remove it. |
| `sv_lan 1` | No master server heartbeat, no Steam auth | Leave `sv_lan` at `0` (the template default). |
| No inbound UDP `27015` (firewall / missing port forward) | A2S works locally but not from the internet | Forward UDP `27015` and `STEAM_PORT` to the host. |
| Wrong `STEAM_GROUP_ID` | A2S fine, but the group server list stays empty | Use the numeric group ID, not the group URL. |
| `STEAM_GROUP_EXCLUSIVE=1` | Server hidden until one player joins it from a lobby | Set it to `0` for immediate visibility. |
| `SERVER_PASSWORD` set | Players are prompted, and L4D2 can hang on that prompt | Leave `SERVER_PASSWORD` empty. |

> **Why `-insecure` is fatal:** it is a *server* launch option that disables the
> Steam/VAC layer. The engine then stops answering A2S queries entirely, so no
> browser or matchmaking service can discover the server — while the game port
> keeps accepting connections, which makes the server look perfectly healthy.
> There is no legitimate reason to run a public dedicated server with it; it is
> only needed to load unsigned modules into a *listen* server.

> **Note:** L4D2 has no `sv_hibernate_when_empty` cvar (the engine reports
> `Unknown command`). L4D2 hibernates automatically when empty and still answers
> A2S queries, so nothing is needed to keep an empty server listed.

---

### License

MIT License. Left 4 Dead 2 and Source Engine are trademarks and/or registered trademarks of Valve Corporation.
