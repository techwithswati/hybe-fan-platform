# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║   HYBE Fan Platform — EKS Cluster                                            ║
# ║   Managed node groups with Cluster Autoscaler                                ║
# ║   Add-ons: ALB Controller, Metrics Server, ArgoCD, External Secrets          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.20"

  cluster_name    = local.cluster_name
  cluster_version = var.eks_cluster_version

  # VPC and Subnets
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Public endpoint for kubectl (secured by OIDC + IAM)
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access_cidrs = [
    "0.0.0.0/0"    # Restict to your office IP in real production
  ]

  # OIDC provider: enables IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # Cluster Access - EKS API mode (no aws-auth ConfigMap needed)
  authentication_mode = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # ── EKS Add-ons ─────────────────────────────────────────────────────────────
  cluster_addons = {
    # CoreDNS - service discovery
    coredns = {
        most_recent = true
        configuration_values = jsonencode({
          replicaCount = 2    # HA: 2 CoreDNS replicas
          resources = {
            limits   = { cpu = "200m", memory = "256Mi" }
            requests = { cpu = "100m", memory = "128Mi" }
          }
        })
    }

    # kube-proxy
    kube-proxy = { most_recent = true }

    # VPC CNI - pod networking
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          # Enable prefix delegation for 110 pods/node on t3.xlarge
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }

    # EBS CSI Driver - required for Redis persistent volumes
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.irsa_ebs_csi.iam_role_arn
    }
  }

  # ── Managed Node Groups ──────────────────────────────────────────────────────
  eks_managed_node_groups = {
    # Primary node group: general workloads (ticket-svc, merch-svc, api-gateway)
    general = {
      name            = "${local.cluster_name}-general"
      instance_types  = var.node_instance_types    # t3.xlarge default
      capacity_type   = "ON_DEMAND"

      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      # AMI: Bottlerocket - minimal, security-hardened OS (faster boot = faster pod start)
      ami_type = "BOTTLEROCKET_x86_64"

      # Disk: 100GB per node for container image caching
      disk_size = 100

      # Launch template customization
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # Labels and taints for pod scheduling
      labels = {
        role        = "general"
        environment = var.environment
      }

      # Cluster Autoscaler tags (required for auto-discovery)
      tags = {
        "k8s.io/cluster-autoscaler/enabled"                          = "true"
        "k8s.io/cluster-autoscaler/${local.cluster_name}"            = "owned" 
        "k8s.io/cluster-autoscaler/node-template/label/role"         = "general"
      }

      update_config = {
        max_unavailable_percentage = 33     # Rolling node updates: 1/3 at a time
      }
    }

    # Spot node group: burst capacity for peak fan events (cheaper)
    spot_burst = {
      name = "${local.cluster_name}-spot"
      instance_types = [
        "t3.xlarge", "t3a.xlarge",
        "m5.xlarge", "m5a.xlarge",
      ]
      capacity_type = "SPOT"

      min_size     = 0
      max_size     = 15
      desired_size = 0

      ami_type  = "AL2_x86_64"
      disk_size = 50

      labels = {
        role            = "spot-burst"
        "spot-instance" = "true"
      }

      taints = [{
        key    = "spot-instance"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]
      
      tags = {
        "k8s.io/cluster-autoscaler/enabled"                   = "true"
        "k8s.io/cluster-autoscaler/${local.cluster_name}"     = "owned"
        "k8s.io/cluster-autoscaler/node-template/taint/spot-instance" = "true:NoSchedule"
      }
    }
  }

  tags = local.common_tags
}

# ── IRSA for EBS CSI Driver ────────────────────────────────────────────────────
module "irsa_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name             = "${local.cluster_name}-ebs-csi-driver"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# ── IRSA for AWS Load Balancer Controller ─────────────────────────────────────
module "irsa_alb_controller" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                               = "${local.cluster_name}-alb-controller"
  attach_load_balancer_controller_policy  = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# ── IRSA for HYBE Platform Services ──────────────────────────────────────────
module "irsa_hybe_platform" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name = "${local.cluster_name}-platform-irsa"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["hybe-prod:hybe-platform-sa"]
    }
  }

  role_policy_arns = {
    secretsmanager = aws_iam_policy.secrets_manager_read.arn
    cloudwatch     = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  }
}

resource "aws_iam_policy" "secrets_manager_read" {
  name        = "${local.cluster_name}-secrets-read"
  description = "Allow pods to read HYBE secrets from AWS Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:hybe/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"}
        }
      }
    ]
  })
}

# ── Helm: AWS Load Balancer Controller (required for ALB Ingress) ─────────────
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_alb_controller.iam_role_arn
  }
  set { 
    name  = "replicaCount"
    value = "2" 
    }

  depends_on = [module.eks]
}

# ── Helm: Metrics Server (REQUIRED for HPA to function) ───────────────────────
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = var.metrics_server_version

  set { 
    name  = "replicas"
    value = "2"
    }
  set { 
    name  = "args[0]"
    value = "--kubelet-preferred-address-types=InternalIP" 
    }

  depends_on = [module.eks]
}

# ── Helm: Cluster Autoscaler (scales EC2 nodes when pods can't be scheduled) ──
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.37.0"

  set { 
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name 
    }
  set { 
    name  = "awsRegion"
    value = var.aws_region
    }
  set { 
    name  = "replicaCount"
    value = "2" 
    }
  set { 
    name  = "extraArgs.scale-down-delay-after-add"
    value = "5m" 
    }
  set { 
    name  = "extraArgs.scale-down-unneeded-time"
    value = "5m" 
    }
  set { 
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false" 
    }
  set { 
    name  = "extraArgs.balance-similar-node-groups"
    value = "true" 
    }

  depends_on = [module.eks]
}

# ── Helm: ArgoCD ──────────────────────────────────────────────────────────────
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = var.argocd_chart_version

  values = [yamlencode({
    server = {
      replicas = 2
      service  = { type = "ClusterIP" }
      # Expose ArgoCD UI via ALB Ingress
      ingress = {
        enabled          = true
        ingressClassName = "alb"
        annotations = {
          "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
          "alb.ingress.kubernetes.io/target-type"      = "ip"
        }
        hosts = ["argocd.hybe-devops.internal"]
      }
    }
    controller   = { replicas = 1 }
    repoServer   = { replicas = 2 }
    redis        = { enabled = true }
    configs = {
      params = {
        "server.insecure" = true    # TLS terminated at ALB
      }
    }
  })]

  depends_on = [
    module.eks,
    helm_release.aws_load_balancer_controller
  ]
}

# ── Helm: External Secrets Operator (syncs AWS Secrets Manager → K8s Secrets) -
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "0.9.20"

  depends_on = [module.eks]
}
