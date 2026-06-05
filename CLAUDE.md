# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Infrastructure-as-code for a two-node hybrid Kubernetes cluster: AWS t2.micro (control plane) + Lambda Labs A10 GPU (worker), bridged by Tailscale VPN. Runs vLLM serving Mistral-7B-AWQ with GitOps via ArgoCD, GPU observability via DCGM + Prometheus + Grafana, and policy enforcement via Kyverno.

**No application code.** Everything is shell scripts, Kubernetes manifests, Helm values, and a benchmark script.

## Key Operational Commands

```bash
# Check cluster state
kubectl get nodes -o wide
kubectl get pods -A

# Port-forward services (run in background)
kubectl port-forward svc/vllm-mistral 8000:8000 -n gpu-workloads &
kubectl port-forward svc/prometheus-grafana 3000:80 -n observability &
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n observability &
kubectl port-forward svc/argocd-server 8080:80 -n argocd &

# Test inference
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-7b","messages":[{"role":"user","content":"test"}],"max_tokens":50}'

# Run benchmark (requires aiohttp: pip install aiohttp)
python benchmark/bench.py --url http://localhost:8000 --concurrency 8 --requests 100 \
  --prometheus http://localhost:9090 --output benchmark/my-results.md

# Apply manifest changes (GitOps will auto-sync, but for immediate apply)
kubectl apply -f manifests/<dir>/

# Get ArgoCD admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# Watch GPU metrics
kubectl logs -n observability -l app=dcgm-exporter -f
```

## Architecture & Data Flow

```
kubectl → Tailscale IP:6443 → kube-apiserver (AWS t2.micro)
Pod-to-Pod → Calico VXLAN tunneled over tailscale0 interface
Inference → vllm-mistral ClusterIP:8000 (gpu-workloads namespace)
Metrics → DCGM Exporter → Prometheus → Grafana dashboard
GitOps → GitHub main branch → ArgoCD polls every ~3min → applies manifests/
```

**Node constraints that matter:**
- All GPU workloads need `nodeSelector: node-role: gpu-worker` + toleration `gpu=true:NoSchedule` — without this, pods schedule on t2.micro and crash/OOM immediately.
- Kyverno enforces this: any pod in `gpu-workloads` requesting `nvidia.com/gpu` without the nodeSelector is rejected.

## Critical Design Decisions

| Decision | Why it matters |
|----------|----------------|
| `driver.enabled=false` in `helm/gpu-operator-values.yaml` | Lambda Labs pre-installs NVIDIA drivers; Operator must NOT reinstall or conflicts arise |
| `--apiserver-advertise-address` = Tailscale IP | AWS private IP unreachable from Lambda; must use `100.x.x.x` TS address |
| Calico configured with `interface: tailscale0` | Forces pod-to-pod traffic through VPN — see `manifests/calico/installation.yaml` |
| `--skip-phases=addon/kube-proxy` in kubeadm init | Calico handles pod routing; kube-proxy is redundant |
| DCGM Exporter deployed standalone (not via GPU Operator) | GPU Operator's bundled DCGM crashes when `driver.enabled=false` |
| AWQ quantization for Mistral-7B | ~4.5 GB VRAM vs ~14 GB fp16; leaves headroom for KV cache on 24 GB A10 |

## Namespaces

| Namespace | Contents |
|-----------|----------|
| `gpu-workloads` | vLLM deployments, HF token secret |
| `gpu-operator` | NVIDIA GPU Operator |
| `observability` | Prometheus, Grafana, DCGM Exporter |
| `argocd` | ArgoCD server + app controller |
| `kyverno` | Kyverno admission controller |
| `calico-system` | Calico CNI |

## GitOps Workflow

ArgoCD Application (`manifests/argocd/application.yaml`) watches the `manifests/` directory on `main`. `selfHeal: true` + `prune: true` means:
- Commit to main → auto-applied within ~3 min
- Drift from desired state → auto-reverted
- Manual rollback: `argocd app rollback hybrid-gpu-infra <REVISION>`

**Before changing `manifests/argocd/application.yaml`:** update `repoURL` from `YOUR_ORG` placeholder to actual repo.

## Multi-Model Stretch (vllm-llama)

`manifests/vllm-llama/` deploys LLaMA-3-8B on port 8001. `manifests/ingress/model-routing.yaml` routes `/mistral` and `/llama` paths. Running both simultaneously uses ~10 GB weights + KV caches ≈ 19–22 GB of 24 GB A10 VRAM — monitor DCGM, reduce `--gpu-memory-utilization` if OOM.

## Troubleshooting Cheatsheet

```bash
# Nodes NotReady → check Calico + Tailscale
kubectl get pods -n calico-system
ip addr show tailscale0  # (on nodes)

# vLLM pending/init → check GPU allocatable + HF secret
kubectl describe pod -n gpu-workloads -l app=vllm-mistral
kubectl describe node gpu-worker | grep -A5 Allocatable

# GPU not allocatable → GPU Operator must be fully Running first
kubectl get pods -n gpu-operator
kubectl describe node gpu-worker | grep nvidia

# DCGM crashloop → needs SYS_ADMIN + /dev access
kubectl logs -n observability -l app=dcgm-exporter
```
