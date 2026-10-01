# Development commands for the L4D2 dedicated server image.
#
# Run `just` with no arguments for the list. `just check` is the gate to run
# before pushing anything.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Where the published image lives, and the local tag development builds use.
image := env_var_or_default("L4D2_IMAGE", "ghcr.io/delnegend/l4d2-linux-server")
version := env_var_or_default("L4D2_VERSION", "dev")
local_tag := "localhost/l4d2:" + version
registry := env_var_or_default("L4D2_REGISTRY", "ghcr.io/delnegend/l4d2-linux-server")

# Registry blobs are zstd level 4. Consumers need a runtime that understands
# zstd layers (containerd 1.7+, Docker 20.10+, podman 3+); set
# L4D2_COMPRESSION=gzip if that ever stops being true. This affects the push
# only - podman keeps its own format for layers in the local store.
compression_format := env_var_or_default("L4D2_COMPRESSION", "zstd")
compression_level := env_var_or_default("L4D2_COMPRESSION_LEVEL", "4")

# Build arguments. Anything here can be overridden from the environment, e.g.
#   MAX_DOWNLOADS=32 just build
build_args := "--build-arg SERVER_VERSION=" + version + " --build-arg MAX_DOWNLOADS=" + env_var_or_default("MAX_DOWNLOADS", "16") + " --build-arg SOURCEMOD_BRANCH=" + env_var_or_default("SOURCEMOD_BRANCH", "1.12")

# List the available recipes.
default:
    @just --list --unsorted

# Print the resolved image, version, registry and compression settings.
config:
    @echo "published image   {{image}}"
    @echo "version           {{version}}  ->  tag {{local_tag}}"
    @echo "registry          {{registry}}"
    @echo "compression       {{compression_format}} level {{compression_level}}"
    @echo "build args        {{build_args}}"

# Build the published image. This is the `server` target, which is also the
# last stage, so no --target is needed.
build:
    podman build {{build_args}} -t {{local_tag}} .

# Build only the `base` stage: the vanilla install with no mods, no
# entrypoint. Useful for measuring the install itself; not deployable.
build-base:
    podman build --target base {{build_args}} -t localhost/l4d2:base .

# Run the locally built image with compose, recreating the container.
up: build
    L4D2_IMAGE={{local_tag}} podman compose up -d --force-recreate

# Run the published image with compose, pulling it first.
up-remote:
    podman compose pull
    podman compose up -d

down:
    podman compose down

# Follow the server log.
logs:
    podman compose logs -f

# Open a shell in the running server. The game dir is /data, the image's
# install is /opt/l4d2.
shell:
    podman compose exec l4d2 /bin/bash

# Run a one-shot command in the running server, e.g. `just run-in rcon-help`.
run-in command:
    podman compose exec l4d2 /bin/bash -c "{{command}}"

# Boot the freshly built image on a scratch volume and wait for the server to
# report itself discoverable. Fails if SELF-CHECK FAILED shows up.
smoke: build
    #!/usr/bin/env bash
    set -euo pipefail
    scratch="$(mktemp -d)"
    name="l4d2-smoke-$$"
    trap 'podman rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT
    podman run -d --name "$name" \
        --userns=keep-id --user 1000:1000 \
        -e PORT=27099 -e STEAM_GROUP_ID=46303910 \
        -p 27099:27099/udp -p 27099:27099/tcp \
        -v "$scratch:/data:Z" \
        {{local_tag}} >/dev/null
    echo "waiting for the A2S self-check (up to 120s)..."
    for _ in $(seq 1 60); do
        sleep 2
        if podman logs "$name" 2>&1 | grep -q "Self-check OK"; then
            podman logs "$name" 2>&1 | grep -E "Self-check OK|Players:|Appending" || true
            echo "--- volume used: $(du -sh "$scratch" | cut -f1) ---"
            echo "smoke test passed"
            exit 0
        fi
        if podman logs "$name" 2>&1 | grep -q "SELF-CHECK FAILED"; then
            podman logs "$name" 2>&1 | tail -40
            echo "smoke test FAILED: the server is not discoverable" >&2
            exit 1
        fi
    done
    podman logs "$name" 2>&1 | tail -40
    echo "smoke test FAILED: no self-check line within 120s" >&2
    exit 1

# Layer sizes per image, which is how the 10 GB duplicate-layer regression in
# docs/architecture.md was caught.
sizes:
    podman images --filter reference='localhost/l4d2*'
    @echo "--- layers of {{local_tag}}, largest first ---"
    podman history {{local_tag}} --format json | python3 -c 'import json,sys; [print("%10.1f MB  %s" % (l["size"]/1e6, l["CreatedBy"][:66])) for l in sorted(json.load(sys.stdin), key=lambda l: -l["size"])[:8]]'

# Push the locally built image, compressed as zstd level 4.
push: build
    podman tag {{local_tag}} {{registry}}:{{version}}
    podman push --compression-format {{compression_format}} \
               --compression-level {{compression_level}} \
               {{registry}}:{{version}}
    @echo "pushed {{registry}}:{{version}} ({{compression_format}} level {{compression_level}})"
    @echo "tags the release workflow also moves: {{registry}}:{{version}} and {{registry}}:latest"

# Remove local images and containers. Does not touch the ./data volume.
clean:
    podman rm -f l4d2-smoke-* 2>/dev/null || true
    -podman rmi -f $(podman images -q --filter reference='localhost/l4d2*') 2>/dev/null
    @echo "removed local build images; ./data was left alone"

# Full clean, including the downloaded game in the local build cache. Slow and
# irreversible: the next build re-downloads ~10 GB.
clean-all:
    podman rmi -f $(podman images -q --filter reference='localhost/l4d2*') 2>/dev/null || true
    podman builder prune -f
    @echo "pruned the build cache; the next build re-downloads the game"

# Validate the docs against the code: every relative link and anchor resolves,
# the variable table matches .env.example and entrypoint.sh, documented build
# arguments and --target values exist, and the workflow's tags are the ones the
# docs advertise.
check:
    python3 scripts/docs-check.py

# Confirm the 5+ plugin stack actually loaded. A clean boot prints no [SM]
# lines at all; any of them means a dependency is missing.
smoke-plugins: build
    #!/usr/bin/env bash
    set -euo pipefail
    scratch="$(mktemp -d)"; name="l4d2-plugins-$$"
    trap 'podman rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT
    podman run -d --name "$name" --userns=keep-id --user 1000:1000 \
        -e PORT=27097 -p 27097:27097/udp -p 27097:27097/tcp \
        -v "$scratch:/data:Z" {{local_tag}} >/dev/null
    sleep 50
    if podman logs "$name" 2>&1 | grep -qE "\[SM\].*(Unable|Error|Exception)"; then
        podman logs "$name" 2>&1 | grep -E "\[SM\]" | head -10
        echo "plugin stack FAILED to load" >&2; exit 1
    fi
    echo "plugins on the image: $(podman exec "$name" ls /data/left4dead2/addons/sourcemod/plugins/ | grep -cE 'left4dhooks|multislots|unreservelobby|CreateSurvivorBot') of 4"
    echo "l4dmultislots.cfg:  $(podman exec "$name" grep -c '^l4d_' /data/left4dead2/cfg/sourcemod/l4dmultislots.cfg) cvars"
    echo "plugin stack OK"

# Everything CI does, before pushing.
verify: check smoke smoke-plugins
    @echo "check + smoke + plugin stack all passed"
