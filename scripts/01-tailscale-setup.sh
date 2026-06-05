#!/usr/bin/env bash
# Run on BOTH nodes — installs Tailscale and connects to tailnet
set -euo pipefail

TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:?Set TAILSCALE_AUTH_KEY env var}"
HOSTNAME="${1:?Usage: $0 <hostname>}"  # e.g. k8s-control or k8s-gpu-worker

curl -fsSL https://tailscale.com/install.sh | sh

systemctl enable --now tailscaled

tailscale up \
  --authkey="${TAILSCALE_AUTH_KEY}" \
  --hostname="${HOSTNAME}" \
  --accept-routes \
  --reset

echo "Tailscale IP: $(tailscale ip -4)"
