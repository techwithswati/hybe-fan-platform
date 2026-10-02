variable "aws_region" {
    description = "AWS region - Seoul for HYBE"
    type        = string
    default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Project identifier used for resource naming"
  type        = string
  default     = "hybe-fan-platform"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
  validation {
    condition      = contains(["prod", "staging", "dev"], var.environment)
    error_message = "Environment must be prod, staging, or dev."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "eks_cluster_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "EC2 instance types for EKS managed node group"
  type        = list(string)
  default     = [ "t3.xlarge" ]    # 4 vCPU, 16GB - enough headroom for 50 pods/node
}

variable "node_group_min_size" {
  description = "Minimum EKS nodes (always-on baseline)"
  type        = number
  default     = 2
}

variable "node_group_max_size" {
  description = "Maximum EKS nodes (Cluster Autoscaler ceiling)"
  type        = number
  default     = 20
}

variable "node_group_desired_size" {
  description = "Desired EKS node count at rest"
  type        = number
  default     = 3
}

variable "rds_instance_class" {
  description = "RDS Aurora instance class"
  type        = string
  default     = "db.r6g.large"   # ARM Graviton2 - cost efficient for MySQL
}

variable "rds_min_capacity" {
  description = "Aurora Serverless min ACUs (fallback)"
  type        = number
  default     = 2
}

variable "rds_max_capacity" {
  description = "Aurora Serverless max ACUs"
  type        = number
  default     = 64
}

variable "db_password" {
  description = "RDS master password - passed via CI secret, never hardcoded"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 16
    error_message = "DB password must be at least 16 characters."
  }
}

variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "hybeadmin"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "7.3.11"
}

variable "metrics_server_version" {
  description = "Metrics Server chart version (required for HPA)"
  type        = string
  default     = "3.12.1"
}
