"""Command-line interface for HYBE Platform."""

import sys
import os
import yaml
from pathlib import Path
from peng.controller.validator import ServiceValidator
from peng.generator.helm_values_generator import HelmValuesGenerator

class PlatformCLI:
    def __init__(self):
        self.validator = ServiceValidator()
        self.generator = HelmValuesGenerator()
    
    def validate(self, service_path: str):
        """Validate a service descriptor."""
        if os.path.isdir(service_path):
            service_file = os.path.join(service_path, "platform.yaml")
        else:
            service_file = service_path
        
        print(f"\n{'='*60}")
        print(f"🔍 Platform Validation")
        print(f"{'='*60}\n")
        print(f"Service: {service_file}\n")
        
        is_valid, errors = self.validator.validate_file(service_file)
        
        if is_valid:
            print("┌─────────────────────────────────┐")
            print("│ ✅ VALIDATION PASSED            │")
            print("├─────────────────────────────────┤")
            print("│ Schema:   ✅ OK                  │")
            print("│ Policies: ✅ OK (all 6 passed)  │")
            print("└─────────────────────────────────┘\n")
            print("Ready to deploy to Kubernetes\n")
            return 0
        else:
            print("┌─────────────────────────────────┐")
            print("│ ❌ VALIDATION FAILED            │")
            print("└─────────────────────────────────┘\n")
            print("Errors:\n")
            for i, error in enumerate(errors, 1):
                print(f"  {i}. {error}")
            print()
            return 1
    
    def generate(self, service_path: str, output_path: str = None):
        """Generate Helm values from service descriptor."""
        if os.path.isdir(service_path):
            service_file = os.path.join(service_path, "platform.yaml")
        else:
            service_file = service_path
        
        print(f"\n{'='*60}")
        print(f"🛠️  Platform Generator")
        print(f"{'='*60}\n")
        print(f"Input:  {service_file}\n")
        
        # Load and validate
        try:
            with open(service_file) as f:
                service = yaml.safe_load(f)
        except Exception as e:
            print(f"❌ Error loading file: {e}\n")
            return 1
        
        # Validate before generating
        is_valid, errors = self.validator.validate_file(service_file)
        if not is_valid:
            print("❌ Validation failed — cannot generate.\n")
            for error in errors:
                print(f"   {error}")
            print()
            return 1
        
        # Generate values
        try:
            values_yaml = self.generator.to_yaml(service)
            
            # Determine output path
            if output_path is None:
                service_dir = os.path.dirname(service_file) or "."
                output_path = os.path.join(service_dir, "generated-values.yaml")
            
            # Write output
            os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
            with open(output_path, "w") as f:
                f.write(values_yaml)
            
            print(f"Output: {output_path}\n")
            print("✅ Generated successfully!\n")
            print("Preview (first 30 lines):\n")
            print("---")
            for i, line in enumerate(values_yaml.split("\n")[:30]):
                print(line)
            if len(values_yaml.split("\n")) > 30:
                print("...")
                print(f"\n(Full file has {len(values_yaml.split(chr(10)))} lines)")
            print("---\n")
            return 0
            
        except Exception as e:
            print(f"❌ Error generating: {e}\n")
            return 1

def main():
    if len(sys.argv) < 2:
        print("Usage: platform <command> [args]")
        print("\nCommands:")
        print("  validate <service>              Validate a service descriptor")
        print("  generate <service> [output]     Generate Helm values from descriptor")
        sys.exit(1)
    
    command = sys.argv[1]
    cli = PlatformCLI()
    
    if command == "validate":
        if len(sys.argv) < 3:
            print("Usage: platform validate <service-path>")
            sys.exit(1)
        service_path = sys.argv[2]
        sys.exit(cli.validate(service_path))
    
    elif command == "generate":
        if len(sys.argv) < 3:
            print("Usage: platform generate <service-path> [output-path]")
            sys.exit(1)
        service_path = sys.argv[2]
        output_path = sys.argv[3] if len(sys.argv) > 3 else None
        sys.exit(cli.generate(service_path, output_path))
    
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)

if __name__ == "__main__":
    main()
