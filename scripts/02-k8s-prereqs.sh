#!/usr/bin/env bash
# Run on BOTH nodes — installs containerd + kubeadm/kubelet/kubectl
set -euo pipefail

K8S_VERSION="1.32"
TAILSCALE_IP=$(tailscale ip -4)

# Disable swap
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

# Ubuntu 26.04 defaults to nftables; Kubernetes requires iptables-legacy
if update-alternatives --query iptables 2>/dev/null | grep -q iptables-legacy; then
  update-alternatives --set iptables /usr/sbin/iptables-legacy
  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
fi

# Kernel modules
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# sysctl networking
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# containerd
apt-get update -q
apt-get install -yq ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Fall back to noble if Docker repo doesn't yet support this Ubuntu release
DOCKER_CODENAME=$(lsb_release -cs)
curl -fsSL "https://download.docker.com/linux/ubuntu/dists/${DOCKER_CODENAME}/Release" \
  &>/dev/null || DOCKER_CODENAME="noble"

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -q
apt-get install -yq containerd.io

# containerd config — enable systemd cgroup driver
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# kubeadm / kubelet / kubectl
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -q
apt-get install -yq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Pin kubelet to Tailscale IP so inter-node comms go over tunnel
echo "KUBELET_EXTRA_ARGS=--node-ip=${TAILSCALE_IP}" > /etc/default/kubelet
systemctl daemon-reload
systemctl enable kubelet

echo "Prereqs done. Tailscale IP bound: ${TAILSCALE_IP}"
