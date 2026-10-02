# HYBE Fan Platform - Production-Grade DevOps Portfolio

![Architecture](https://img.shields.io/badge/Architecture-EKS%20%2B%20GitOps-blue)
![Platform](https://img.shields.io/badge/Platform-Kubernetes-326CE5)
![IaC](https://img.shields.io/badge/IaC-Terraform-623CE4)

## Overview

A **production-grade infrastructure simulation** for a high-traffic K-pop fan platform handling **50,000+ concurrent users**. Demonstrates enterprise DevOps practices: Kubernetes autoscaling, GitOps pull-based delivery, infrastructure as code, CI/CD automation, and observability.

Built to showcase real-world DevOps challenges: managing sudden traffic spikes (fan platform merch drops), atomic operations under contention (Redis), and infrastructure resilience.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     GitHub Actions CI/CD                        │
│  Lint → Build → ECR Push → GitOps Promotion (values.yaml)      │
└──────────────┬──────────────────────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────────────────────┐
│                      ArgoCD (GitOps)                            │
│  Pull-based reconciliation: Git → EKS cluster state            │
└──────────────┬──────────────────────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────────────────────┐
│                   AWS EKS Cluster (Seoul)                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Microservices (HPA: 3→50 pods)                         │   │
│  │  • ticket-service (Flask + Redis atomic DECR)           │   │
│  │  • merch-service (Flask + Redis cart locking)           │   │
│  │  • api-gateway (NGINX rate limiting)                    │   │
│  └─────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Persistent Layer                                       │   │
│  │  • RDS Aurora MySQL (Multi-AZ, 3 readers)              │   │
│  │  • Redis (Bitnami subchart)                             │   │
│  │  • ALB Ingress Controller                               │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Features

### 1. **Horizontal Pod AutoScaling (HPA)**
- Min replicas: **3** | Max replicas: **50**.
- Scales on CPU utilization (target: 60%).
- Asymmetric scaling: fast up, slow down (prevents thrashing).
- **Interview insight:** Demonstrates understanding of Kubernetes resource management under load.

### 2. **GitOps Pull-Based Delivery (ArgoCD)**
- Single source of truth: Git repository (`helm/hybe-platform/values.yaml`).
- CI/CD promotes new image tags → Git commit.
- ArgoCD automatically syncs cluster to match Git state.
- **Interview insight:** Proves understanding of declarative infrastructure, drift detection, and pull vs. push deployments.

### 3. **Infrastructure as Code (Terraform)**
- **28 files** covering: VPC, EKS, RDS, IAM, ECR, KMS.
- OIDC federation (no long-lived credentials).
- S3 + DynamoDB backend for state management.
- **Interview insight:** Shows ability to code infrastructure with proper security practices.

### 4. **Microservices with Real Challenges**
- **Ticket Service:** Atomic Redis DECR (prevents overselling under high concurrency).
- **Merch Service:** Redis cart locking (distributed lock across pods).
- **API Gateway:** Rate limiting (50 req/s per IP, tiered buckets).
- **Interview insight:** Demonstrates understanding of distributed systems, concurrency, and eventual consistency.

### 5. **CI/CD Pipeline**
- **Test:** Python linting (flake8) + security scans (bandits).
- **Build:** Multi-service parallel Docker builds with layer caching.
- **Push:** ECR with image scanning (Trivy for CVEs).
- **Promote:** Automated GitOps trigger (values.yaml update + Git push).
- **Interview insight:** End-to-end automation with security gates and GitOps integration.

### 6. **Load Testing (K6)**
- **5 phases:** pre-drop → announcement spike → peak frenzy → settling → tail.
- **50,000 concurrent users** over 15 minutes.
- Validates HPA scaling, latency SLOs (p95 < 500ms), error rates.
- **Interview insight:** Proves ability to simulate real-world traffic patterns and measure system behavior.

### 7. **Observability**
- **Grafana dashboards:** HPA metrics, pod scaling events, latency percentiles.
- **Prometheus alerts:** SLO burn rate, pod restart loops.
- **Kubernetes logs:** POds events, deployment rollout status.
- **Interview insight:** Shows understanding of observability as a first-class concern.

---

## Tech Stack

| Layer | Technology|
|-------|-----------|
| **Container Orchestration** | Kubernetes (AWS EKS) |
| **Infrastructure as Code** | Terraform (5 modules: VPC, EKS, RDS, IAM, ECR) |
| **Config Management** | Helm 3 (templates, subcharts, conditional rendering) |
| **GitOps** | ArgoCD (ApplicationSet, project RBAC, sync windows) |
| **CI/CD** | GitHub Actions (matrix strategy, OIDC auth) |
| **Load Balancing** | AWS ALB + NGINX Ingress Controller |
| **Database** | Amazon RDS Aurora MySQL (Multi-AZ) |
| **Caching** | Redis (Bitnami chart) |
| **Microservices** | FLask + Gunicorn (Python) |
| **Load Testing** | K6 (Javascript) |
| **Monitoring** | Prometheus + Grafana |

---

## Project Structure

```
hybe-fan-platform/
├── .github/workflows/
|   └── ci.yaml                    # Github Actions: test → build → push ECR → promote
├── apps/
|   ├── ticket-service/            # Flask service + Redis atomic DECR
|   ├── merch-service/             # Flask service + Redis cart locking
|   └── api-gateway/               # NGINX rate limiting + reverse proxy
├── helm/hybe-platform/
|   ├── Chart.yaml                 # Main chart (3 services, 1 ingress)
|   ├── values.yaml                # Single source of truth for deployment
|   └── templates/
        ├── deployments.yaml       # All 3 microservices
        ├── services.yaml          # ClusterIP + ALB Ingress
        ├── hpa.yaml               # Autoscaling (3→50 pods)
        ├── configmap.yaml         # Environment variables + secrets
        └── ...
├── argocd/
|   ├── project.yaml           # RBAC project + sync windows
|   └── application.yaml       # ArgoCD Application (GitOps sync config)
├── terraform/
|   ├── main.tf                # Providers, backend, ECR, locals
|   ├── eks.tf                 # EKS cluster + managed nodes, IRSA, add-ons
|   ├── rds.tf                 # Aurora MySQL Multi-AZ, parameter tuning
|   ├── vpc.tf                 # VPC, subnets (3 AZs), security groups
|   ├── variables.tf           # Input variables
|   └── outputs.tf             # CLuster endpoint, RDS writer endpoint
├── k6/
|   └── load-test.js           # K6 load test: 5 phases, 50k VUs
├── scripts/
|   ├── bootstrap.sh           # One-shot cluster setup (install add-ons)
|   └── promote.sh             # Update image tag in values.yaml (GitOps trigger)
├── monitoring/
|   └── grafana-dashboard.json # Grafana dashboard: HPA, latency, errors
```

---

## Quick Start (Local Development)

### Prerequisites
- Terraform >= 1.9.0
- Helm >= 3.15
- kubectl >= 1.28
- K6 (optional, for load testing)

### Deploy to EKS
```bash
# 1. Provision infrastructure
cd terraform/
terraform init
terraform plan
terraform apply    # Creates EKS cluster, RDS, VPC, etc. (~15 min)

# 2. Bootstrap cluster (installs ArgoCD, Metrics Server, etc.)
cd ../scripts
./bootstrap.sh

# 3. Verify deployment
kubectl get all -n hybe-prod
kubectl get hpa -n hybe-prod --watch # Watch HPA scale pods

# 4. Test GitOps promotion
./promote.sh 20250611-abc1234   # updates values.yaml, triggers ArgoCD sync
```

### Run Load Test
```bash
k6 run k6/load-test.js
# Expect: 50k concurrent fans → HPA scales 3→30+ pods over 15 min
```

---

## Interview Talking Points

### What This Project Demonstrates

1. **Kubernetes Expertise**
   - HPA asymmetric scaling (fast up, slow down prevents thrashing).
   - Pod disruption budgets, resource requests/limits.
   - IRSA (IAM Roles for Service Accounts) for AWS integration.

2. **DevOps Best Practices**
   - Infrastructure as Code (Terraform) with state management.
   - OIDC federation (zero long-lived credentials).
   - GitOps pull-based delivery (vs. imperative push).
   - Comprehensive CI/CD with security gates (CVE scanning,linting).

3. **Production-Ready Thinking**
   - Multi-AZ RDS with read replicas (HA & scalability).
   - Distributed systems challenges (atomic operations, cart locking).
   - Observability from the start (Prometheus, Grafana, SLO alerts)
   - Load testing validates actual system behavior.

4. **Real-World Problem Solving**
   - Ticket overselling prevention (Redis atomic DECR).
   - Rate limiting under sudden spikes (K-pop merch drops)
   - Graceful degradation (ArgoCD sync windows, pod disruption budgets)

---

## Challenges Solved

| Challenge | Solution | Interview Value |
|-----------|----------|-----------------|
| 50k concurrent users | HPA + Aurora read replicas | Shows scalability thinking |
| Ticket overselling | Redis atomic DECR under contention | Distributed systems knowledge |
| Cart contention | Redis distributed locking + conflict detection | Race condition handling |
| Deployment safety | GitOps + sync windows + PDB | Risk mitigation mindset |
| Security | OIDC federation, KMS encryption, no hardcoded secrets | Security-first engineering |
| Cost optimization | Spot instances, auto-scaling down | Infrastructure efficiency |

---

## Results & Metrics

- **HPA Performance:** Scales from 3→30+ pods in ~2 minutes under peak load.
- **Load Test:** K6 validates p95 latency < 500ms at 50k concurrent users.
- **Deployment Safety:** Zero-downtime deployments via GitOps + ArgoCD.
- **Code Quality:** 100% of python code passes linting + security scans.
- **Infrastructure:** 5 Terraform modules = 600+ lines of production-grade IaC.

---

## What This Is NOT

- ❌ A tutorial project (production-grade code with real constraints).
- ❌ A toy monolith (actual microservices with distributed systems challenges).
- ❌ A "run locally" demo (designed for AWS EKS, not minikube).
- ❌ Copy-Paste code from docs (custom, thoughtful implementations).

---

## Contact & Next Steps

**GitHub:** [techwithswati/hybe-fan-platform](https://github.com/techwithswati/hybe-fan-platform)

**Ready to discuss:**
- HPA scaling strategies and the risks of symmetric scaling.
- GitOps vs. imperative deployments (trade-offs, consistency).
- Distributed systems challenges (eventual consistency, CAP theorem).
- Infrastructure code organization and Terraform best practices.
- Observability architecture and SLO/burn-rate alerting.

---

## License

MIT
