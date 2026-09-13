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
- **Auto Config Generation**: Generates a tuned `server.cfg` if one is not present.
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
| `SERVER_PASSWORD` | `""` | Optional password required to connect |
| `DEFAULT_MAP` | `c1m1_hotel` | Initial map loaded on startup |
| `MAX_PLAYERS` | `8` | Maximum client player slots |
| `AUTO_UPDATE` | `false` | If `true`, checks and updates game files via DepotDownloader on boot |
| `VALIDATE_ON_BOOT` | `false` | If `true`, validates existing game depot checksums on update |
| `INSTALL_SOURCEMOD`| `false` | If `true`, auto-installs MetaMod and SourceMod on first boot |
| `EXTRA_ARGS` | `""` | Additional command-line flags passed directly to `srcds_run` |

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
```

---

### Customization & Addons

* Custom maps (`.vpk`) can be placed directly in:
  `./data/left4dead2/addons/`
* Custom configurations and server cvars can be edited in:
  `./data/left4dead2/cfg/server.cfg`
* Any changes made to `./data` persist across container restarts.

---

### License

MIT License. Left 4 Dead 2 and Source Engine are trademarks and/or registered trademarks of Valve Corporation.
