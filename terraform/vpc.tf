# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║   HYBE Fan Platform — VPC                                                    ║
# ║   3-AZ setup in ap-northeast-2 (Seoul): a, b, c                              ║
# ║   Public subnets: ALB, NAT GW                                                ║
# ║   Private subnets: EKS nodes, RDS                                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "~> 5.9"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  # 3 AZs for high availability (Seoul: ap-northeast-2a, 2b,2c)
  azs = local.azs

  # Public subnets: ALB lives here
  public_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 0),     # 10.0.0.0/24  - 2a
    cidrsubnet(var.vpc_cidr, 8, 1),     # 10.0.1.0/24  - 2b
    cidrsubnet(var.vpc_cidr, 8, 2),     # 10.0.2.0/24  - 2c
  ]

  # Private subnets: EKS nodes + RDS (no direct internet access)
  private_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 10),     # 10.0.10.0/24  - 2a
    cidrsubnet(var.vpc_cidr, 8, 11),     # 10.0.11.0/24  - 2b
    cidrsubnet(var.vpc_cidr, 8, 12),     # 10.0.12.0/24  - 2c
  ]

  # Database subnets: RDS (isolated - no route to internet)
  database_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 20),     # 10.0.20.0/24  - 2a
    cidrsubnet(var.vpc_cidr, 8, 21),     # 10.0.21.0/24  - 2b
    cidrsubnet(var.vpc_cidr, 8, 22),     # 10.0.22.0/24  - 2c
  ]

  # NAT Gateway: 1 per AZ for HA (EKS nodes → internet for ECR pulls, etc.)
  enable_nat_gateway     = true
  single_nat_gateway     = false        # One per AZ (production HA requirement)
  one_nat_gateway_per_az = true

  # DNS required for EKS
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Create a dedicated DB subnet group
  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  # Tags required by AWS ALB Ingress Controller and EKS Cluster Autoscaler
  public_subnet_tags = {
    "kubernetes.io/role/elb"                              = "1"
    "kubernetes.io/cluster/${local.cluster_name}"         = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                     = "1"
    "kubernetes.io/cluster/${local.cluster_name}"         = "shared"
    "karpenter.sh/discovery"                              = local.cluster_name
  }

  tags = local.common_tags
}

# ── VPC Flow Logs (security + debugging) ──────────────────────────────────────
resource "aws_flow_log" "vpc" {
  vpc_id          = module.vpc.vpc_id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.vpc_flow_log.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_log.arn 
}

resource "aws_cloudwatch_log_group" "vpc_flow_log" {
  name              = "/aws/vpc/hybe-fan-platform-flow-logs"
  retention_in_days = 30
  tags              = local.common_tags
}

resource "aws_iam_role" "vpc_flow_log" {
  name = "${var.project_name}-vpc-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com"}
    }]
  })
}

resource "aws_iam_role_policy" "vpc_flow_log" {
  name = "${var.project_name}-vpc-flow-log-policy"
  role = aws_iam_role.vpc_flow_log.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:CreateLogStreams",
      ]
      Resource = "*"
    }]
  })
}
