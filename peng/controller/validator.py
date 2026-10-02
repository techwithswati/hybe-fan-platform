"""Service descriptor validator — ensures all services meet platform standards."""

import json
import yaml
import sys
from pathlib import Path
from jsonschema import validate, ValidationError
from typing import Tuple, List

class ServiceValidator:
    def __init__(self, schema_path: str = "peng/schemas/service_schema.json"):
        with open(schema_path) as f:
            self.schema = json.load(f)
    
    def validate_schema(self, service: dict) -> Tuple[bool, List[str]]:
        """Validate against JSON schema."""
        errors = []
        try:
            validate(instance=service, schema=self.schema)
            return True, []
        except ValidationError as e:
            errors.append(f"Schema validation failed: {e.message}")
            return False, errors
    
    def validate_policies(self, service: dict) -> Tuple[bool, List[str]]:
        """Validate against platform policies."""
        errors = []
        spec = service.get("spec", {})
        metadata = service.get("metadata", {})
        
        # Policy 1: Min replicas ≥ 2 (no single points of failure)
        min_replicas = spec.get("replicas", {}).get("min")
        if min_replicas and min_replicas < 2:
            errors.append("❌ POLICY: Min replicas must be ≥2 (no SPOF)")
        
        # Policy 2: CPU limits required
        cpu_limit = spec.get("resources", {}).get("cpu", {}).get("limit")
        if not cpu_limit:
            errors.append("❌ POLICY: CPU limits required (runaway protection)")
        
        # Policy 3: Memory limits required
        mem_limit = spec.get("resources", {}).get("memory", {}).get("limit")
        if not mem_limit:
            errors.append("❌ POLICY: Memory limits required (runaway protection)")
        
        # Policy 4: Database backups for stateful services
        has_db = spec.get("persistence", {}).get("database", {}).get("type") != "none"
        if has_db:
            backups_enabled = spec.get("persistence", {}).get("database", {}).get("backups", {}).get("enabled")
            if not backups_enabled:
                errors.append("❌ POLICY: Database backups required (data protection)")
        
        # Policy 5: Observability enabled (FIX: handle dict properly)
        observability = spec.get("observability", {})
        if isinstance(observability, dict):
            for key in ["logging", "metrics", "tracing", "dashboard"]:
                if not observability.get(key):
                    errors.append(f"❌ POLICY: Observability.{key} must be enabled")
        else:
            errors.append("❌ POLICY: Observability must be an object with logging, metrics, tracing, dashboard")
        
        # Policy 6: Team assigned (ownership)
        if not metadata.get("team"):
            errors.append("❌ POLICY: Team must be assigned (for incidents)")
        
        return len(errors) == 0, errors
    
    def validate_file(self, file_path: str) -> Tuple[bool, List[str]]:
        """Validate a service descriptor file."""
        all_errors = []
        
        # Load file
        try:
            with open(file_path) as f:
                service = yaml.safe_load(f)
        except FileNotFoundError:
            return False, [f"❌ File not found: {file_path}"]
        except yaml.YAMLError as e:
            return False, [f"❌ YAML parse error: {e}"]
        
        # Validate schema
        schema_ok, schema_errors = self.validate_schema(service)
        all_errors.extend(schema_errors)
        
        # Validate policies
        policies_ok, policy_errors = self.validate_policies(service)
        all_errors.extend(policy_errors)
        
        return schema_ok and policies_ok, all_errors

def main():
    if len(sys.argv) < 2:
        print("Usage: python -m peng.controller.validator <service-file>")
        sys.exit(1)
    
    file_path = sys.argv[1]
    validator = ServiceValidator()
    
    print(f"\n🔍 Validating: {file_path}\n")
    
    is_valid, errors = validator.validate_file(file_path)
    
    if is_valid:
        print("✅ All validations passed!")
        print("   Schema: OK")
        print("   Policies: OK")
        print("\n🚀 Ready to deploy\n")
        sys.exit(0)
    else:
        print("❌ Validation failed:\n")
        for error in errors:
            print(f"   {error}")
        print()
        sys.exit(1)

if __name__ == "__main__":
    main()
