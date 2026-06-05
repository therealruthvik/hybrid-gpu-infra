#!/usr/bin/env bash
# Run on CONTROL PLANE (t2.micro) only
set -euo pipefail

CONTROL_TS_IP=$(tailscale ip -4)
POD_CIDR="10.244.0.0/16"
SVC_CIDR="10.96.0.0/12"

echo "Initializing control plane at Tailscale IP: ${CONTROL_TS_IP}"

# Fix hostname resolution (required by kubeadm)
grep -q "control-plane" /etc/hosts || echo "127.0.0.1 control-plane" >> /etc/hosts

kubeadm init \
  --apiserver-advertise-address="${CONTROL_TS_IP}" \
  --apiserver-cert-extra-sans="${CONTROL_TS_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --service-cidr="${SVC_CIDR}" \
  --node-name=control-plane \
  --ignore-preflight-errors=Mem

# kubeconfig for root + current user
mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# Taint control plane — no workload pods ever land here
kubectl taint nodes control-plane node-role.kubernetes.io/control-plane:NoSchedule --overwrite

# Install Flannel CNI
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo ""
echo "=== SAVE THIS JOIN COMMAND FOR THE WORKER NODE ==="
kubeadm token create --print-join-command
echo "==================================================="
