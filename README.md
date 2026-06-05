# Hybrid GPU Inference Cluster

Two-node Kubernetes cluster spanning AWS (t2.micro control plane) and Lambda Labs
(A10 GPU worker), connected via Tailscale VPN. Runs vLLM AI inference on GPU with
full observability, GitOps, and policy enforcement.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         TAILSCALE MESH (WireGuard)                   │
│                                                                      │
│   ┌─────────────────────────┐       ┌─────────────────────────────┐  │
│   │   AWS t2.micro          │       │   Lambda Labs A10 VM        │  │
│   │   (control-plane)       │◄─────►│   (gpu-worker)              │  │
│   │                         │       │                             │  │
│   │   • kube-apiserver      │       │   • kubelet                 │  │
│   │   • etcd                │       │   • containerd              │  │
│   │   • controller-manager  │       │   • NVIDIA A10 24 GB VRAM   │  │
│   │   • scheduler           │       │   • GPU Operator (no driver)│  │
│   │   • ArgoCD              │       │   • vLLM (Mistral-7B-AWQ)   │  │
│   │   • Calico CNI          │       │   • DCGM Exporter           │  │
│   │   • Kyverno             │       │   • Prometheus Node Export  │  │
│   │   • Prometheus          │       │                             │  │
│   │   • Grafana             │       │   Taints:                   │  │
│   │                         │       │     gpu=true:NoSchedule     │  │
│   │   Taints:               │       │   Labels:                   │  │
│   │     control-plane:      │       │     node-role=gpu-worker    │  │
│   │       NoSchedule        │       │     accelerator=nvidia-a10  │  │
│   └─────────────────────────┘       └─────────────────────────────┘  │
│          100.x.x.1 (TS IP)                 100.x.x.2 (TS IP)         │
└──────────────────────────────────────────────────────────────────────┘

Traffic flow:
  kubectl → kube-apiserver (Tailscale IP:6443)
  Pod-to-Pod → Calico VXLAN over Tailscale tunnel
  Inference → vllm-mistral ClusterIP:8000
  Metrics → DCGM → Prometheus → Grafana
  GitOps → GitHub repo → ArgoCD → cluster
```

## Prerequisites

- AWS account with t2.micro instance (Ubuntu 22.04)
- Lambda Labs account with A10 instance (Ubuntu 22.04, NVIDIA drivers pre-installed)
- Tailscale account + auth key with tag:k8s
- HuggingFace account + token (for model download)
- Git repo for GitOps (fork this repo)
- `kubectl`, `helm` installed on your local machine

## Step-by-Step Setup

### 1. Provision VMs

**AWS t2.micro** — control plane only. No GPU needed.
```
OS: Ubuntu 22.04 LTS
Instance: t2.micro (1 vCPU, 1 GB RAM) — free tier eligible
Security Group: allow TCP 6443 from worker Tailscale IP only
```

**Lambda Labs A10** — GPU worker.
```
OS: Ubuntu 22.04 LTS (Lambda pre-installs NVIDIA drivers + CUDA)
Instance: gpu_1x_a10 (30 vCPU, 200 GB RAM, 1x A10 24 GB)
Firewall: no public ports needed — all traffic via Tailscale
```

### 2. Install Tailscale on Both Nodes

```bash
# On BOTH nodes — set TAILSCALE_AUTH_KEY first
export TAILSCALE_AUTH_KEY="tskey-auth-..."

# Control plane
ssh ubuntu@<AWS_IP> "bash -s" < scripts/01-tailscale-setup.sh k8s-control

# GPU worker
ssh ubuntu@<LAMBDA_IP> "bash -s" < scripts/01-tailscale-setup.sh k8s-gpu-worker
```

Verify both appear in your Tailscale admin console. Note each node's Tailscale IP
(`tailscale ip -4` — typically `100.x.x.x`).

### 3. Install Kubernetes Prerequisites

```bash
# On BOTH nodes
ssh ubuntu@<AWS_IP> "sudo bash -s" < scripts/02-k8s-prereqs.sh
ssh ubuntu@<LAMBDA_IP> "sudo bash -s" < scripts/02-k8s-prereqs.sh
```

This installs containerd, kubeadm, kubelet, kubectl, and binds kubelet to the
Tailscale IP so all inter-node traffic flows through the VPN tunnel.

### 4. Initialize Control Plane

```bash
ssh ubuntu@<AWS_IP>
sudo bash scripts/03-init-control-plane.sh
```

This runs `kubeadm init` with `--apiserver-advertise-address` set to the Tailscale IP,
installs the Tigera Operator, and applies the Calico Installation CR.

**Save the join command printed at the end** — you'll need it for step 5.

Copy kubeconfig to your local machine:
```bash
scp ubuntu@<AWS_IP>:~/.kube/config ~/.kube/hybrid-config
export KUBECONFIG=~/.kube/hybrid-config
kubectl get nodes  # should show control-plane NotReady (Calico not yet fully up)
```

### 5. Join GPU Worker

```bash
# Set these from the join command output in step 4
export CONTROL_TS_IP="100.x.x.1"
export JOIN_TOKEN="abcdef.0123456789abcdef"
export JOIN_HASH="sha256:aabbcc..."

ssh ubuntu@<LAMBDA_IP> "sudo CONTROL_TS_IP=${CONTROL_TS_IP} \
  JOIN_TOKEN=${JOIN_TOKEN} JOIN_HASH=${JOIN_HASH} bash -s" \
  < scripts/04-join-worker.sh
```

Verify both nodes Ready:
```bash
kubectl get nodes -o wide
# NAME             STATUS   ROLES           VERSION
# control-plane    Ready    control-plane   v1.29.x
# gpu-worker       Ready    <none>          v1.29.x
```

### 6. Post-Setup: Labels, GPU Operator, Workloads

```bash
# From control plane or local machine with KUBECONFIG set
# Create HF token secret first!
kubectl create secret generic hf-token -n gpu-workloads \
  --from-literal=token=<YOUR_HF_TOKEN>

# Run full post-setup (labels, GPU Operator, vLLM, observability, ArgoCD, Kyverno)
sudo bash scripts/05-post-setup.sh
```

### 7. Configure ArgoCD GitOps

**Update the repo URL** in `manifests/argocd/application.yaml`:
```yaml
repoURL: https://github.com/YOUR_ORG/hybrid-gpu-infra.git
```

If repo is private, add credentials:
```bash
kubectl create secret generic argocd-repo-creds \
  -n argocd \
  --from-literal=url=https://github.com/YOUR_ORG/hybrid-gpu-infra.git \
  --from-literal=username=git \
  --from-literal=password=<GITHUB_PAT>
kubectl label secret argocd-repo-creds -n argocd \
  argocd.argoproj.io/secret-type=repository
```

Access ArgoCD UI:
```bash
kubectl port-forward svc/argocd-server 8080:80 -n argocd
# URL: http://localhost:8080
# User: admin
# Password: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
```

### 8. Verify Inference

```bash
# Port-forward vLLM service
kubectl port-forward svc/vllm-mistral 8000:8000 -n gpu-workloads &

# Test inference
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-7b",
    "messages": [{"role": "user", "content": "What is a GPU?"}],
    "max_tokens": 100
  }'
```

### 9. Access Grafana Dashboard

```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n observability &
# URL: http://localhost:3000
# User: admin / Password: changeme (change in helm/prometheus-values.yaml)
# Dashboard: "GPU Inference — Hybrid Cluster"
```

---

## Running the Benchmark

```bash
# Port-forward vLLM (if not already)
kubectl port-forward svc/vllm-mistral 8000:8000 -n gpu-workloads &
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n observability &

pip install aiohttp
python benchmark/bench.py \
  --url http://localhost:8000 \
  --concurrency 8 \
  --requests 100 \
  --prometheus http://localhost:9090 \
  --output benchmark/my-results.md
```

See `benchmark/sample-results.md` for expected output on A10.

---

## GitOps: Auto-Sync & Rollback

ArgoCD watches the `manifests/` directory in the Git repo. Any commit to `main`
triggers automatic sync within ~3 minutes (default polling interval).

Auto-rollback behavior: ArgoCD tracks deployment health. If a new vLLM deployment
fails its readiness probe within the configured timeout, ArgoCD marks the app
`Degraded` and (with `selfHeal: true`) reverts to the last healthy revision.

To trigger a rollback manually:
```bash
argocd app rollback hybrid-gpu-infra <REVISION>
# or via UI: App → History → Roll back
```

---

## Stretch Goals

### Multi-Model Serving (/mistral and /llama)

Deploy the second model (requires A10 has enough VRAM for both):
```bash
kubectl apply -f manifests/vllm-llama/
kubectl apply -f manifests/ingress/model-routing.yaml
```

> **Note:** Running two quantized 7-8B models simultaneously on one A10 (24 GB) is
> tight. Mistral-7B-AWQ ≈ 4.5 GB + LLaMA-3-8B-GGUF ≈ 5.5 GB = ~10 GB weights.
> With KV caches at `--gpu-memory-utilization 0.80/0.85`, total usage ≈ 19–22 GB.
> Monitor with DCGM and reduce `--gpu-memory-utilization` if OOM.

### Kyverno GPU Policy

Already deployed by `scripts/05-post-setup.sh`. Test it:
```bash
# This should FAIL (GPU request, no nodeSelector)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: bad-gpu-pod
  namespace: gpu-workloads
spec:
  containers:
  - name: test
    image: nginx
    resources:
      limits:
        nvidia.com/gpu: "1"
EOF
# Expected: Error from server: ... require-gpu-nodeselector
```

---

## File Structure

```
hybrid-gpu-infra/
├── README.md
├── scripts/
│   ├── 01-tailscale-setup.sh      # Install + join Tailscale (both nodes)
│   ├── 02-k8s-prereqs.sh          # containerd + kubeadm/kubelet/kubectl
│   ├── 03-init-control-plane.sh   # kubeadm init + Calico (control plane only)
│   ├── 04-join-worker.sh          # kubeadm join (worker only)
│   └── 05-post-setup.sh           # Labels, GPU Operator, all workloads
├── manifests/
│   ├── 00-namespaces.yaml
│   ├── calico/
│   │   └── installation.yaml      # Calico CRD — uses tailscale0 iface
│   ├── vllm/
│   │   ├── deployment.yaml        # Mistral-7B-AWQ, nodeSelector=gpu-worker
│   │   ├── service.yaml           # ClusterIP:8000
│   │   └── secret-template.yaml   # HF token (do not commit real value)
│   ├── vllm-llama/                # Stretch: LLaMA-3-8B on port 8001
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── observability/
│   │   ├── dcgm-exporter.yaml     # DaemonSet + Service + ServiceMonitor
│   │   ├── vllm-servicemonitor.yaml
│   │   └── grafana-dashboard-cm.yaml
│   ├── argocd/
│   │   └── application.yaml       # GitOps sync from this repo
│   ├── kyverno/
│   │   └── gpu-nodeselector-policy.yaml  # Enforce nodeSelector on GPU pods
│   ├── alerts/
│   │   └── gpu-utilization.yaml   # PrometheusRules for GPU/latency alerts
│   └── ingress/
│       └── model-routing.yaml     # Stretch: /mistral + /llama routing
├── helm/
│   ├── gpu-operator-values.yaml   # driver.enabled=false
│   ├── prometheus-values.yaml     # kube-prometheus-stack
│   └── argocd-values.yaml
└── benchmark/
    ├── bench.py                   # Async benchmark script
    └── sample-results.md          # Expected output on A10
```

---

## Key Design Decisions

| Decision | Reason |
|----------|--------|
| `driver.enabled=false` in GPU Operator | Lambda Labs pre-installs NVIDIA drivers; re-installing via Operator causes conflicts |
| Tailscale IP for `--apiserver-advertise-address` | AWS private IP not reachable from Lambda; Tailscale creates stable cross-cloud overlay |
| `nodeSelector: node-role: gpu-worker` on all GPU pods | t2.micro has no GPU; wrong node assignment = immediate OOM or crash |
| Calico with `interface: tailscale0` | Forces pod-to-pod traffic through VPN tunnel, not public internet |
| `--skip-phases=addon/kube-proxy` in kubeadm | Calico handles routing; kube-proxy adds overhead |
| AWQ quantization | Fits Mistral-7B in ~4.5 GB VRAM vs ~14 GB fp16; leaves headroom for KV cache |
| DCGM Exporter standalone | GPU Operator's bundled DCGM conflicts with `driver.enabled=false` on Lambda |

---

## Troubleshooting

**Nodes stay NotReady after join:**
```bash
kubectl describe node gpu-worker | grep -A5 Conditions
# Check Calico pods: kubectl get pods -n calico-system
# Ensure tailscale0 interface exists on both nodes: ip addr show tailscale0
```

**vLLM pod stuck in Init/Pending:**
```bash
kubectl describe pod -n gpu-workloads -l app=vllm-mistral
# Common: HF token secret missing, GPU resource not allocatable
# Check GPU allocatable: kubectl describe node gpu-worker | grep -A5 Allocatable
```

**GPU not showing as allocatable:**
```bash
kubectl get pods -n gpu-operator
# GPU Operator pods must all be Running before nvidia.com/gpu appears
# Check: kubectl describe node gpu-worker | grep nvidia
```

**DCGM Exporter crashloop:**
```bash
kubectl logs -n observability -l app=dcgm-exporter
# Needs SYS_ADMIN capability + /dev access — check securityContext in manifest
```
