#!/usr/bin/env bash
# Registers the runner once (RUNNER_TOKEN) and keeps the registration in the state volume.
set -euo pipefail
cd /home/runner
STATE=/home/runner/state
FILES=(.runner .credentials .credentials_rsaparams)

if [ -f "$STATE/.runner" ]; then
    for f in "${FILES[@]}"; do cp "$STATE/$f" .; done
else
    : "${RUNNER_TOKEN:?RUNNER_TOKEN is not set – see runner/README.md}"
    ./config.sh --unattended --replace \
        --url "${REPO_URL:?REPO_URL is not set}" --token "$RUNNER_TOKEN" \
        --name "${RUNNER_NAME:-opennit-build}" --labels "${RUNNER_LABELS:-opennit-build}" \
        --work /home/runner/_work
    for f in "${FILES[@]}"; do cp "$f" "$STATE/"; done
    echo "[runner] Registered – RUNNER_TOKEN is no longer needed and can be removed from .env."
fi

# Wait for the Docker daemon (dind)
for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null 2>&1 || { echo "[runner] Docker daemon at $DOCKER_HOST not reachable." >&2; exit 1; }

exec ./run.sh
