#!/usr/bin/env bash
# Run on CONTROL PLANE (t2.micro) only
set -euo pipefail

CONTROL_TS_IP=$(tailscale ip -4)
POD_CIDR="192.168.0.0/16"
SVC_CIDR="10.96.0.0/12"

echo "Initializing control plane at Tailscale IP: ${CONTROL_TS_IP}"

kubeadm init \
  --apiserver-advertise-address="${CONTROL_TS_IP}" \
  --apiserver-cert-extra-sans="${CONTROL_TS_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --service-cidr="${SVC_CIDR}" \
  --node-name=control-plane \
  --skip-phases=addon/kube-proxy

# kubeconfig for root + current user
mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# Taint control plane — no workload pods ever land here
kubectl taint nodes control-plane node-role.kubernetes.io/control-plane:NoSchedule --overwrite

# Install Tigera Operator for Calico
kubectl create -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/tigera-operator.yaml

# Apply Calico Installation (uses tailscale0 interface for node IP detection)
kubectl apply -f "$(dirname "$0")/../manifests/calico/installation.yaml"

echo ""
echo "=== SAVE THIS JOIN COMMAND FOR THE WORKER NODE ==="
kubeadm token create --print-join-command
echo "==================================================="
