#!/usr/bin/env bash
# Run on GPU WORKER (A10 Lambda Labs) only
# Usage: CONTROL_TS_IP=100.x.x.x JOIN_TOKEN=xxx JOIN_HASH=sha256:xxx ./04-join-worker.sh
set -euo pipefail

CONTROL_TS_IP="${CONTROL_TS_IP:?Set CONTROL_TS_IP}"
JOIN_TOKEN="${JOIN_TOKEN:?Set JOIN_TOKEN}"
JOIN_HASH="${JOIN_HASH:?Set JOIN_HASH (sha256:...)}"
WORKER_TS_IP=$(tailscale ip -4)

kubeadm join "${CONTROL_TS_IP}:6443" \
  --token "${JOIN_TOKEN}" \
  --discovery-token-ca-cert-hash "${JOIN_HASH}" \
  --node-name=gpu-worker

echo "Worker joined. Tailscale IP: ${WORKER_TS_IP}"
