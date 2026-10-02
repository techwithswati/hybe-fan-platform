# Platform Engineering — Day 1 Setup

## What We Built

A **service descriptor validator** that:
- ✅ Validates YAML schema (required fields, types)
- ✅ Enforces platform policies (replicas, resources, backups, observability)
- ✅ Provides clear feedback on failures

## How to Use

### Validate Your Service

```bash
# If you have a service/
platform validate my-service/

# If you have a platform.yaml file
platform validate services/my-service/platform.yaml
```

### Example Output (Success)
✅ All validations passed!
Schema: OK
Policies: OK

🚀 Ready to deploy

### Example Output (Failure)
❌ Validation failed:

  1. ❌ POLICY: Min replicas must be ≥2 (no SPOF)
  2. ❌ POLICY: CPU limits required (runaway protection)
  3. ❌ POLICY: Observability.logging must be enabled
  
## Platform Policies (Must Pass All)

| Policy | Requirement | Why |
|--------|-------------|-----|
| Min replicas | ≥ 2 | No single point of failure |
| CPU limits | Required | Prevent runaway processes |
| Memory limits | Required | Prevent memory exhaustion |
| Database backups | If stateful | Data protection |
| Observability | All enabled | Debugging, monitoring |
| Team ownership | Required | Incident response |

## Next Steps

Tomorrow: Build the controller that generates Kubernetes manifests from service descriptors.
