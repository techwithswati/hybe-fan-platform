"""Generate Helm values.yaml from service descriptor."""

import yaml
from typing import Dict, Any

class HelmValuesGenerator:
    """Transforms platform.yaml into Helm values."""
    
    def generate(self, service: Dict[str, Any]) -> Dict[str, Any]:
        """Generate Helm values from service descriptor."""
        
        spec = service.get("spec", {})
        metadata = service.get("metadata", {})
        
        values = {
            "service": {
                "name": metadata.get("name"),
                "team": metadata.get("team"),
                "description": metadata.get("description"),
                "slackChannel": metadata.get("slackChannel"),
            },
            
            "deployment": {
                "replicaCount": spec.get("replicas", {}).get("min", 3),
                "image": {
                    "repository": f"ecr.hybe.dev/{metadata.get('name')}",
                    "tag": "latest",  # Will be overridden by CI/CD
                },
                "containerPort": spec.get("port", 8080),
            },
            
            "resources": {
                "limits": {
                    "cpu": spec.get("resources", {}).get("cpu", {}).get("limit", "500m"),
                    "memory": spec.get("resources", {}).get("memory", {}).get("limit", "1Gi"),
                },
                "requests": {
                    "cpu": spec.get("resources", {}).get("cpu", {}).get("request", "250m"),
                    "memory": spec.get("resources", {}).get("memory", {}).get("request", "512Mi"),
                },
            },
            
            "autoscaling": {
                "enabled": True,
                "minReplicas": spec.get("replicas", {}).get("min", 3),
                "maxReplicas": spec.get("replicas", {}).get("max", 50),
                "targetCPUUtilizationPercentage": spec.get("replicas", {}).get("targetCPU", 60),
            },
            
            "persistence": self._generate_persistence(spec),
            
            "observability": self._generate_observability(spec, metadata),
            
            "alerts": self._generate_alerts(spec, metadata),
        }
        
        return values
    
    def _generate_persistence(self, spec: Dict) -> Dict:
        """Generate persistence config."""
        db_config = spec.get("persistence", {}).get("database", {})
        cache_config = spec.get("persistence", {}).get("cache", {})
        
        return {
            "database": {
                "enabled": db_config.get("type") != "none",
                "type": db_config.get("type", "mysql"),
                "backups": {
                    "enabled": db_config.get("backups", {}).get("enabled", False),
                    "retention": db_config.get("backups", {}).get("retention", "30days"),
                },
            },
            "cache": {
                "enabled": cache_config.get("type") != "none",
                "type": cache_config.get("type", "redis"),
            },
        }
    
    def _generate_observability(self, spec: Dict, metadata: Dict) -> Dict:
        """Generate observability config."""
        obs = spec.get("observability", {})
        
        return {
            "logging": {
                "enabled": obs.get("logging", True),
                "format": "json",
                "level": "info",
            },
            "metrics": {
                "enabled": obs.get("metrics", True),
                "scrapeInterval": "30s",
            },
            "tracing": {
                "enabled": obs.get("tracing", True),
                "sampleRate": 0.1,
            },
            "dashboard": {
                "enabled": obs.get("dashboard", True),
                "title": f"{metadata.get('name')} - Service Metrics",
            },
        }
    
    def _generate_alerts(self, spec: Dict, metadata: Dict) -> Dict:
        """Generate alerting rules."""
        alerts = spec.get("alerts", [])
        
        return {
            "enabled": len(alerts) > 0,
            "rules": [
                {
                    "name": alert.get("name"),
                    "expr": alert.get("condition"),
                    "severity": alert.get("severity", "warning"),
                    "annotations": {
                        "summary": f"{metadata.get('name')}: {alert.get('name')}",
                        "runbook": f"https://runbooks.hybe.dev/{metadata.get('name')}",
                    },
                }
                for alert in alerts
            ],
        }
    
    def to_yaml(self, service: Dict[str, Any]) -> str:
        """Generate and return as YAML string."""
        values = self.generate(service)
        return yaml.dump(values, default_flow_style=False, sort_keys=False)
    