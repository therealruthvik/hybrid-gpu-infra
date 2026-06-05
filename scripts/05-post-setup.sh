#!/usr/bin/env bash
# Run on CONTROL PLANE after worker joins
# Labels + taints worker, installs GPU Operator, deploys all workloads
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Waiting for gpu-worker to be Ready..."
kubectl wait node/gpu-worker --for=condition=Ready --timeout=300s

echo "==> Labeling and tainting gpu-worker..."
kubectl label node gpu-worker node-role=gpu-worker accelerator=nvidia-a10 --overwrite
kubectl taint node gpu-worker gpu=true:NoSchedule --overwrite

echo "==> Installing GPU Operator (driver.enabled=false)..."
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --values "${REPO_ROOT}/helm/gpu-operator-values.yaml" \
  --wait --timeout=600s

echo "==> Applying namespaces..."
kubectl apply -f "${REPO_ROOT}/manifests/00-namespaces.yaml"

echo "==> NOTE: Create HF token secret before deploying vLLM:"
echo "    kubectl create secret generic hf-token -n gpu-workloads \\"
echo "      --from-literal=token=<YOUR_HF_TOKEN>"
echo ""
echo "==> Deploying vLLM (Mistral-7B-AWQ)..."
kubectl apply -f "${REPO_ROOT}/manifests/vllm/"

echo "==> Deploying observability stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace observability \
  --values "${REPO_ROOT}/helm/prometheus-values.yaml" \
  --wait --timeout=300s

kubectl apply -f "${REPO_ROOT}/manifests/observability/"

echo "==> Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values "${REPO_ROOT}/helm/argocd-values.yaml" \
  --wait --timeout=300s

kubectl apply -f "${REPO_ROOT}/manifests/argocd/"

echo "==> Installing Kyverno + GPU policy..."
helm repo add kyverno https://kyverno.github.io/kyverno
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --wait --timeout=300s
kubectl apply -f "${REPO_ROOT}/manifests/kyverno/"

echo "==> Applying alert rules..."
kubectl apply -f "${REPO_ROOT}/manifests/alerts/"

echo ""
echo "=== CLUSTER READY ==="
kubectl get nodes -o wide
kubectl get pods -A
