# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║   HYBE Fan Platform — Amazon RDS Aurora MySQL (Multi-AZ)                     ║
# ║   Writer in 2a, Reader replicas in 2b + 2c                                   ║
# ║   Handles persistent booking/order records under massive concurrent load     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

module "rds" {
  source = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 9.5"

  name           = "${var.project_name}-db"
  engine         = "aurora-mysql"
  engine_version = "8.0.mysql_aurora.3.05.2"
  instance_class = var.rds_instance_class

  # 3-AZ setup: 1 writer + 2 readers
  instances = {
    writer = {
      instance_class      = var.rds_instance_class
      publicly_accessible = false
      promotion_tier      = 0    # Primary writer
    }
    reader-1 = {
      instance_class      = var.rds_instance_class
      publicly_accessible = false
      promotion_tier      = 1    # First failover candidate
    }
    reader-2 = {
      instance_class      = var.rds_instance_class
      publicly_accessible = false
      promotion_tier      = 2
    }
  }

  # VPC: database subnet group (isolated from internet)
  vpc_id               = module.vpc.vpc_id
  db_subnet_group_name = module.vpc.database_subnet_group_name
  security_group_rules = {
    eks_ingress = {
      type                     = "ingress"
      from_port                = 3306
      to_port                  = 3306
      protocol                 = "tcp"
      source_security_group_id = module.eks.node_security_group_id
      description              = "MySQL from EKS pods"
    }
  }
  
  # Credentials
  master_username = var.db_username
  master_password = var.db_password
  manage_master_user_password = false

  # Database config
  database_name               = "hybe"
  port                        = 3306

  # Aurora MySQL cluster parameters
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.hybe.name

  # Storage
  storage_encrypted = true     # KMS encryption at rest

  # Backup
  backup_retention_period = 7
  preferred_backup_window = "02:00-04:00"       # UTC = 11:00-13:00 KST (low traffic)
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.project_name}-final-snapshot"
  deletion_protection     = true                # Prevent accidental drops

  # Maintenance
  preferred_maintenance_window = "sun:04:00-sun:06:00"  # UTC Sunday early morning
  auto_minor_version_upgrade   = true

  # Enhanced monitoring (60-second granularity for production)
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  # Performance Insights (query-level monitoring)
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  # Logging
  enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]
  
  apply_immediately = false   # Schedule changes during maintenance window in prod

  tags = local.common_tags
}

# ── Aurora Parameter Group - tuned for high-concurrency fan platform ──────────
resource "aws_rds_cluster_parameter_group" "hybe" {
  family      = "aurora-mysql8.0"
  name        = "${var.project_name}-aurora-params"
  description = "HYBE Fan Platform Aurora MySQL 8.0 parameter group"

  # Max connections: tuned for many pods connecting simultaneously
  parameter {
    name = "max_connection"
    value = "1000"
  }

  # Larger buffer pool for read-heavy catalog queries
  parameter {
    name  = "innodb_buffer_pool_size"
    value = "{DBInstanceClassMemory*3/4}"  # 75% of RAM
  }

  # Reduce lock wait for concurrent ticket/merch writes
  parameter {
    name  = "innodb_lock_wait_timeout"
    value = "10"
  }

  # Enable slow query log (threshold: 1 second)
  parameter {
    name  = "slow_query_log"
    value = "1"
  }
  parameter {
    name  = "long_query_time"
    value = "1"
  }

  # Binary logging for replication
  parameter {
    name  = "binlog_format"
    value = "ROW"
    apply_method = "pending-reboot"
  }

  tags = local.common_tags
}

# ── RDS Enhanced Monitoring IAM Role ──────────────────────────────────────────
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project_name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazoneRDSEnhancedMonitoringRole"
}

# ── Store credentials in AWS Secrets Manager ──────────────────────────────────
# External Secrets Operator syncs this into K8s secret automatically
resource "aws_secretmanager_secret" "rds" {
  name                    = "hybe/prod/rds"
  description             = "HYBE Fan Platform RDS credentials"
  recovery_window_in_days = 7

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id

  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = module.rds.cluster_endpoint
    port     = 3306
    dbname   = "hybe"
  })
}

# ── CloudWatch Alarms for RDS ─────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project_name}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU > 80% - check for slow queries or missing indexes"
  alarm_actions       = []  # Add SNS ARN for PagerDuty/Slack alerts

  dimensions = {
    DBClusterIdentifier = module.rds.cluster_id
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.project_name}-rds-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 800    # Alert at 80% of max_connections=1000
  alarm_description   = "RDS connections approaching limit - consider connection pooling"
  alarm_actions       = []

  dimensions = {
    DBClusterIdentifier = module.rds.cluster_id
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────────
output "rds_writer_endpoint" {
  description = "RDS writer endpoint (use for INSERT/UPDATE)"
  value       = module.rds.cluster_endpoint
  sensitive   = true
}

output "rds_reader_endpoint" {
  description = "RDS reader endpoint (use for SELECT - load balanced)"
  value       = module.rds.cluster_reader_endpoint
  sensitive   = true
}

output "rds_secret_arn" {
  description = "AWS Secrets Manager ARN for RDS credentials"
  value       = aws_secretsmanager_secret.rds.arn
}
