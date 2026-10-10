# Development commands for the L4D2 dedicated server image.
#
# Run `just` with no arguments for the list. `just check` is the gate to run
# before pushing anything; `just verify` is everything CI does.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Where the published image lives, and the local tag development builds use.
image := env_var_or_default("L4D2_IMAGE", "ghcr.io/delnegend/l4d2-server-container")
version := env_var_or_default("L4D2_VERSION", "dev")
local_tag := "localhost/l4d2:" + version
registry := env_var_or_default("L4D2_REGISTRY", "ghcr.io/delnegend/l4d2-server-container")

# Registry blobs are zstd level 4. Consumers need a runtime that understands
# zstd layers (containerd 1.7+, Docker 20.10+, podman 3+); set
# L4D2_COMPRESSION=gzip if that ever stops being true. This affects the push
# only - podman keeps its own format for layers in the local store.
compression_format := env_var_or_default("L4D2_COMPRESSION", "zstd")
compression_level := env_var_or_default("L4D2_COMPRESSION_LEVEL", "4")

# Container engine. Local runs use podman; CI sets CONTAINER_ENGINE=docker,
# which is the engine a GitHub runner comes with. `push` is the exception and
# stays podman-only: --compression-format is a podman flag, not a docker one.
engine := env_var_or_default("CONTAINER_ENGINE", "podman")

# Rootless podman maps the container's uid 1000 onto the host user with
# keep-id. Rootful docker cannot remap uids at all, so on CI the volume is
# chowned to 1000 instead. Everything below takes the same commands on both.
userns := if engine == "docker" { "" } else { "--userns=keep-id" }
own_volume := if engine == "docker" { "sudo chown -R 1000:1000 \"$scratch\"" } else { "true" }

# The volume belongs to uid 1000 after that chown, so on docker the invoking
# user cannot delete it either - and nothing may read it from the host for the
# same reason. Everything below therefore asks the *container* about the volume
# rather than looking at it, which is also engine-agnostic.
drop_volume := if engine == "docker" { "sudo rm -rf \"$scratch\" >/dev/null 2>&1 || true" } else { "rm -rf \"$scratch\" >/dev/null 2>&1 || true" }

smoke_dir := env_var_or_default("L4D2_SMOKE_DIR", ".smoke")

# Build arguments. Anything here can be overridden from the environment, e.g.
#   SOURCEMOD_BRANCH=1.13 just build
build_args := "--build-arg SERVER_VERSION=" + version + " --build-arg MAX_DOWNLOADS=" + env_var_or_default("MAX_DOWNLOADS", "16") + " --build-arg SOURCEMOD_BRANCH=" + env_var_or_default("SOURCEMOD_BRANCH", "1.12")
extra_build_args := env_var_or_default("EXTRA_BUILD_ARGS", "")
# List the available recipes.
default:
    @just --list --unsorted

# Print the resolved image, version, registry and compression settings.
config:
    @echo "published image   {{image}}"
    @echo "version           {{version}}  ->  tag {{local_tag}}"
    @echo "registry          {{registry}}"
    @echo "engine            {{engine}}"
    @echo "compression       {{compression_format}} level {{compression_level}}"
    @echo "build args        {{build_args}}"

# Build the image: one target, and it is the last stage.
build:
    {{engine}} build {{build_args}} {{extra_build_args}} -t {{local_tag}} .

# Build the vanilla 4-player server without mods.
build-vanilla:
    {{engine}} build --target vanilla {{build_args}} {{extra_build_args}} -t localhost/l4d2:vanilla .

# Run the locally built image with compose, recreating the container.
up: build
    #!/usr/bin/env bash
    set -euo pipefail
    L4D2_IMAGE={{local_tag}} {{engine}} compose up -d --force-recreate

# Run the published image with compose, pulling it first.
up-remote:
    {{engine}} compose pull
    {{engine}} compose up -d

down:
    {{engine}} compose down

# Follow the server log.
logs:
    {{engine}} compose logs -f

# Open a shell in the running server.
shell:
    {{engine}} compose exec l4d2 /bin/bash

# Run a one-shot command in the running server, e.g. `just run-in rcon-help`.
run-in command:
    {{engine}} compose exec l4d2 /bin/bash -c "{{command}}"

# Boot the freshly built image on a scratch volume: linking, A2S, plugin stack.
smoke: build
    #!/usr/bin/env bash
    set -euo pipefail

    log_has() {
        [ "$({{engine}} logs --tail 400 "$1" 2>&1 | grep -c -F -- "$2" || true)" -gt 0 ]
    }

    mkdir -p "{{smoke_dir}}"
    scratch="$(mktemp -d "{{smoke_dir}}/vol-XXXXXX")"
    name="l4d2-smoke-$$"
    trap '{{engine}} rm -f "$name" >/dev/null 2>&1 || true; {{drop_volume}}' EXIT

    {{own_volume}}
    {{engine}} run -d --name "$name" \
        {{userns}} --user 1000:1000 \
        -e PORT=27099 -e STEAM_GROUP_ID=46303910 \
        -p 27099:27099/udp -p 27099:27099/tcp \
        -v "$scratch:/data:Z" \
        {{local_tag}} >/dev/null

    echo "waiting for the server to initialize (up to 60s)..."
    deadline=$((SECONDS + 60))
    ready=0
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if {{engine}} exec "$name" test -x /data/srcds_run; then
            ready=1
            break
        fi
        if [ "$({{engine}} inspect -f '{{"{{.State.Running}}"}}' "$name" 2>/dev/null)" != "true" ]; then
            {{engine}} logs --tail 40 "$name" 2>&1 || true
            echo "smoke test FAILED: the container exited before initializing" >&2
            exit 1
        fi
        sleep 2
    done
    if [ "${ready}" -ne 1 ]; then
        {{engine}} logs --tail 40 "$name" 2>&1 || true
        echo "smoke test FAILED: server did not initialize within 60s" >&2
        exit 1
    fi

    # Give the server time to load the plugin stack before judging it.
    sleep 35

    if [ "$({{engine}} logs "$name" 2>&1 | grep -cE '\[SM\].*(Unable|Error|Exception)' || true)" -gt 0 ]; then
        {{engine}} logs "$name" 2>&1 | grep -E '\[SM\]' | sed -n '1,10p' || true
        echo "smoke test FAILED: the plugin stack did not load" >&2
        exit 1
    fi
    echo "plugins installed: $({{engine}} exec "$name" ls /data/left4dead2/addons/sourcemod/plugins/ | grep -cE 'left4dhooks|multislots|unreservelobby|CreateSurvivorBot') of 4"
    echo "l4dmultislots.cfg:  $({{engine}} exec "$name" grep -c '^l4d_' /data/left4dead2/cfg/sourcemod/l4dmultislots.cfg) cvars"

    echo "waiting for the A2S self-check (up to 120s)..."
    for _ in $(seq 1 60); do
        if log_has "$name" "Self-check OK"; then
            {{engine}} logs "$name" 2>&1 | grep -E "Self-check OK|Players:|Appending" || true

            unknown="$({{engine}} logs "$name" 2>&1 \
                | grep -o 'Unknown command "[^"]*"' | sort -u || true)"
            unexpected="$(printf '%s\n' "${unknown}" \
                | grep -v 'mat_bloom_scalefactor_scalar' | grep -v '^$' || true)"
            if [ -n "${unexpected}" ]; then
                echo "unknown console commands in the boot log:" >&2
                printf '%s\n' "${unexpected}" >&2
                echo "smoke test FAILED: the engine rejected a command the config uses" >&2
                exit 1
            fi
            echo "unknown commands: none beyond the known engine-internal one"

            echo "--- volume used: $({{engine}} exec "$name" du -sh /data | cut -f1) ---"
            echo "smoke test passed"
            exit 0
        fi
        if log_has "$name" "SELF-CHECK FAILED"; then
            {{engine}} logs --tail 40 "$name" 2>&1 || true
            echo "smoke test FAILED: the server is not discoverable" >&2
            exit 1
        fi
        sleep 2
    done
    {{engine}} logs --tail 40 "$name" 2>&1 || true
    echo "smoke test FAILED: no self-check line within 120s" >&2
    exit 1

# Layer sizes per image.
sizes:
    podman images --filter reference='localhost/l4d2*'
    @echo "--- layers of {{local_tag}}, largest first ---"
    podman history {{local_tag}} --format json | python3 -c 'import json,sys; [print("%10.1f MB  %s" % (l["size"]/1e6, l["CreatedBy"][:66])) for l in sorted(json.load(sys.stdin), key=lambda l: -l["size"])[:8]]'

# Push the locally built image, compressed as zstd level 4. Podman only, since
# --compression-format is not a docker flag.
push: build
    podman tag {{local_tag}} {{registry}}:{{version}}
    podman push --compression-format {{compression_format}} \
               --compression-level {{compression_level}} \
               {{registry}}:{{version}}
    @echo "pushed {{registry}}:{{version}} ({{compression_format}} level {{compression_level}})"
    @echo "tags the release workflow also moves: {{registry}}:{{version}} and {{registry}}:latest"

# Remove local images and containers. Does not touch the ./data volume.
clean:
    {{engine}} rm -f l4d2-smoke-* 2>/dev/null || true
    -{{engine}} rmi -f $({{engine}} images -q --filter reference='localhost/l4d2*') 2>/dev/null
    -rm -rf "{{smoke_dir}}"
    @echo "removed local build images and the smoke volumes; ./data was left alone"

# Full clean, including the downloaded game in the local build cache. Slow and
# irreversible: the next build re-downloads ~10 GB.
clean-all:
    {{engine}} rmi -f $({{engine}} images -q --filter reference='localhost/l4d2*') 2>/dev/null || true
    {{engine}} builder prune -f
    -rm -rf "{{smoke_dir}}"
    @echo "pruned the build cache; the next build re-downloads the game"

# Validate the docs against the code it describes. See scripts/docs-check.py.
check:
    python3 scripts/docs-check.py

# Everything CI does, before pushing.
verify: check smoke
    @echo "check + smoke (linking, A2S self-check, plugin stack) all passed"

# No manifest: versions live in git tags, so this is a documented no-op.
bump version:
    @echo "versions are tracked by git tags; nothing to bump"
