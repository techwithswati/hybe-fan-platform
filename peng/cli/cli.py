"""Command-line interface for HYBE Platform"""

import sys
import os
from pathlib import Path
from peng.controller.validator import ServiceValidator


class PlatformCLI:
    def __init__(self):
        self.validator = ServiceValidator()
        
    def validate(self, service_path: str):
        """Validate a service descriptor."""
        # Find platform.yaml if given directory
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
        
def main():
    cli = PlatformCLI()
    
    if len(sys.argv) < 2:
        print("Usage: platform <command> [args]")
        print("\nCommands:")
        print("  validate <service>   Validate a service descriptor")
        sys.exit(1)
        
    command = sys.argv[1]    
        
    if command == "validate":
        if len(sys.argv) < 3:
            print("Usage: platform validate <service-path>")
            sys.exit(1)
        service_path = sys.argv[2]
        sys.exit(cli.validate(service_path))
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)
        
if __name__ == "__main__":
    main()
