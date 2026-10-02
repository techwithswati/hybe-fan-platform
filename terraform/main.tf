# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║   HYBE Fan Platform — Terraform Root                                         ║
# ║   Backend: S3 + DynamoDB state locking (production-grade IaC)                ║
# ║   Region: ap-northeast-2 (Seoul) — where HYBE HQ is                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source = "hashicorp/helm"
      version = "~> 2.14"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # ── Remote State: S3 + DynamoDB Locking ─────────────────────────────────────
  # CRITICAL: Create this bucket BEFORE running terraform init
  #   aws s3 mb s3://hybe-terraform-state-ap-northeast-2 --region ap-northeast-2
  #   aws dynamodb create-table \
  #     --table-name hybe-terraform-locks \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST \
  #     --region ap-northeast-2
  # backend "s3" {
  #  bucket          = "hybe-terraform-state-ap-northeast-2"
  #  key             = "hybe-fan-platform/production/terraform.tfstate"
  #  region          = "ap-northeast-2"
  #  encrypt         = true
  #  dynamodb_table  = "hybe-terraform-locks"
  #  # KMS encryption for state file at rest
  #  kms_key_id      = "alias/hybe-terraform-state-key"
  # }
}

# ── AWS Provider ───────────────────────────────────────────────────────────────
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "hybe-fan-platform"
      Environment = var.environment
      ManagedBy   = "terraform"
      Team        = "devops"
      CostCentre  = "platform-engineering"
    }
  }
}

# Secondary provider for us-east-1 (ACM certificates must be in us-east-1 for CloudFront)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# ── Kubernetes Provider (uses EKS cluster from eks.tf) ────────────────────────
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region,
    ]
  }
}

# ── Helm Provider ──────────────────────────────────────────────────────────────
provider "helm" {
    kubernetes {
      host                   = module.eks.cluster_endpoint
      cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
      exec {
        api_version = "client.authentication.k8s.io/v1beta1"
        command     = "aws"
        args = [
            "eks", "get-token",
            "--cluster-name", module.eks.cluster_name,
            "--region", var.aws_region,
        ]
      }
    }
}

# ── Data Sources ───────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
    state = "available"
}

# ── Locals ─────────────────────────────────────────────────────────────────────
locals {
  account_id   = data.aws_caller_identity.current.account_id
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)
  cluster_name = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── ECR Repositories ───────────────────────────────────────────────────────────
resource "aws_ecr_repository" "services" {
    for_each = toset(["ticket-service", "merch-service", "api-gateway"])

    name                  = "hybe/${each.key}"
    image_tag_mutability  = "MUTABLE"

    image_scanning_configuration {
      scan_on_push = true   # Auto-scan for CVEs on every push
    }

    encryption_configuration {
      encryption_type = "KMS"
    }
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 20 production images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "prod-"]
          countType     = "imageCountMoreThan"
          countNumber    = 20
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description = "Delete untagged images after 1 day"
        selection = {
          tagStatus    = "untagged"
          countType    = "sinceImagePushed"
          countUnit    = "days"
          countNumber  = 1
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── Outputs ────────────────────────────────────────────────────────────────────
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "rds_endpoint" {
  description = "RDS cluster endpoint (writer)"
  value       = module.rds.cluster_endpoint
  sensitive   = true
}

output "ecr_urls" {
  description = "ECR repository URLs for CI/CD"
  value       = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}

output "kubeconfig_command" {
  description = "Command to update local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${local.cluster_name}"
}
