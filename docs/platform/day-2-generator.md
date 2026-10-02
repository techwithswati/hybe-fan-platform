# Platform Engineering — Day 2: Helm Values Generator

## What We Built

A **Helm values generator** that transforms service descriptors into Kubernetes-ready Helm values.

### The Flow
platform.yaml (service descriptor)
↓
Validator (validates against policies)
↓
Generator (creates Helm values)
↓
generated-values.yaml (K8s-ready config)
↓
Helm deploy

## Quick Start

### Generate Helm values

```bash
platform generate apps/ticket-service/
```

This creates `apps/ticket-service/generated-values.yaml` with:
- Deployment config (replicas, resources, image)
- HPA (autoscaling) config
- Observability (Prometheus, Jaeger, ELK)
- Alerts and SLOs
- Persistence (database, cache)

### What Gets Generated

The generator automatically creates:

**Deployment**: Min/max replicas, resource requests/limits, health checks, security context

**Autoscaling**: HPA with CPU targets, scale-up/scale-down behavior

**Observability**: 
- Prometheus metrics scraping
- Jaeger distributed tracing
- Structured logging to ELK
- Grafana dashboard config
- Alert rules with SLO burn rate

**Persistence**:
- Database connection pooling
- Backup retention policies
- Redis cache config
- Secret management

## How It Works

### Descriptor → Helm Values

Input:
```yaml
apiVersion: platform.hybe.dev/v1
kind: Service
metadata:
  name: ticket-service
  team: platform-eng
spec:
  language: python
  port: 8080
  replicas:
    min: 3
    max: 50
    targetCPU: 60%
  resources:
    cpu:
      request: 250m
      limit: 500m
    memory:
      request: 512Mi
      limit: 1Gi
```

Output:
```yaml
service:
  name: ticket-service
  team: platform-eng

deployment:
  replicaCount: 3
  image:
    repository: ecr.hybe.dev/ticket-service
  containerPort: 8080

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 50
  targetCPUUtilizationPercentage: 60

resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 500m
    memory: 1Gi
```

## Next Steps

Tomorrow: Integrate with Helm deployment.
