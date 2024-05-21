locals {
  elasticache_subnet_group_name    = var.elasticache_subnet_group_name != "" ? var.elasticache_subnet_group_name : join("", aws_elasticache_subnet_group.default.*.name)
  elasticache_parameter_group_name = var.use_existing_parameter_group ? var.elasticache_parameter_group_name : join("", aws_elasticache_parameter_group.default.*.name)
  nodes_list = var.cluster_mode_enabled ? flatten([
    for i in range(var.cluster_mode_num_node_groups) : [
      for j in range(var.cluster_mode_replicas_per_node_group + 1) :
      "${module.label.id}-000${i + 1}-00${j + 1}"
    ]
  ]) : [module.label.id]
}

module "label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.22.1"
  enabled    = var.enabled
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = var.attributes
  tags       = var.tags
}

#
# Security Group Resources
#
resource "aws_security_group" "default" {
  count  = var.enabled && var.use_existing_security_groups == false ? 1 : 0
  vpc_id = var.vpc_id
  name   = module.label.id
  tags   = module.label.tags
}

resource "aws_security_group_rule" "egress" {
  count             = var.enabled && var.use_existing_security_groups == false ? 1 : 0
  description       = "Allow all egress traffic"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = join("", aws_security_group.default.*.id)
  type              = "egress"
}

resource "aws_security_group_rule" "ingress_security_groups" {
  count                    = var.enabled && var.use_existing_security_groups == false ? length(var.allowed_security_groups) : 0
  description              = "Allow inbound traffic from existing Security Groups"
  from_port                = var.port
  to_port                  = var.port
  protocol                 = "tcp"
  source_security_group_id = var.allowed_security_groups[count.index]
  security_group_id        = join("", aws_security_group.default.*.id)
  type                     = "ingress"
}

resource "aws_security_group_rule" "ingress_cidr_blocks" {
  count             = var.enabled && var.use_existing_security_groups == false && length(var.allowed_cidr_blocks) > 0 ? 1 : 0
  description       = "Allow inbound traffic from CIDR blocks"
  from_port         = var.port
  to_port           = var.port
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr_blocks
  security_group_id = join("", aws_security_group.default.*.id)
  type              = "ingress"
}

resource "aws_elasticache_subnet_group" "default" {
  count      = var.enabled && var.elasticache_subnet_group_name == "" && length(var.subnets) > 0 ? 1 : 0
  name       = module.label.id
  subnet_ids = var.subnets
}

resource "aws_elasticache_parameter_group" "default" {
  count  = var.enabled && !var.use_existing_parameter_group ? 1 : 0
  name   = module.label.id
  family = var.family



  dynamic "parameter" {
    for_each = var.cluster_mode_enabled ? concat([{ "name" = "cluster-enabled", "value" = "yes" }], var.parameter) : var.parameter
    content {
      name  = parameter.value.name
      value = parameter.value.value
    }
  }
}

resource "aws_elasticache_replication_group" "default" {
  count = var.enabled ? 1 : 0

  auth_token                    = var.transit_encryption_enabled ? var.auth_token : null
  replication_group_id          = var.replication_group_id == "" ? module.label.id : var.replication_group_id
  description                   = var.replication_group_description == "" ? module.label.id : var.replication_group_description
  node_type                     = var.instance_type
  num_cache_clusters            = var.cluster_mode_enabled ? null : var.cluster_size
  port                          = var.port
  parameter_group_name          = local.elasticache_parameter_group_name
  preferred_cache_cluster_azs   = var.cluster_mode_enabled ? null : [for n in range(0, var.cluster_size) : element(var.availability_zones, n)]
  automatic_failover_enabled    = var.automatic_failover_enabled
  subnet_group_name             = local.elasticache_subnet_group_name
  security_group_ids            = var.use_existing_security_groups ? var.existing_security_groups : [join("", aws_security_group.default.*.id)]
  maintenance_window            = var.maintenance_window
  notification_topic_arn        = var.notification_topic_arn
  engine_version                = var.engine_version
  at_rest_encryption_enabled    = var.at_rest_encryption_enabled
  transit_encryption_enabled    = var.transit_encryption_enabled
  snapshot_window               = var.snapshot_window
  snapshot_retention_limit      = var.snapshot_retention_limit
  apply_immediately             = var.apply_immediately
  multi_az_enabled              = var.multi_az_enabled

  tags = module.label.tags

  replicas_per_node_group = var.cluster_mode_replicas_per_node_group
  num_node_groups         = var.cluster_mode_num_node_groups
}

#
# CloudWatch Resources
#
resource "aws_cloudwatch_metric_alarm" "cache_cpu" {
  for_each = var.enabled ? toset(local.nodes_list) : []

  alarm_name          = "${each.value}-cpu-utilization"
  alarm_description   = "Redis cluster CPU utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = "300"
  statistic           = "Average"
  tags                = module.label.tags

  threshold = var.alarm_cpu_threshold_percent

  dimensions = {
    CacheClusterId = each.value
  }

  alarm_actions             = var.alarm_actions
  ok_actions                = var.ok_actions
  insufficient_data_actions = var.insufficient_data_actions
  depends_on                = [aws_elasticache_replication_group.default]
}

resource "aws_cloudwatch_metric_alarm" "cache_memory" {
  for_each = var.enabled ? toset(local.nodes_list) : []

  alarm_name          = "${each.value}-freeable-memory"
  alarm_description   = "Redis cluster freeable memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "FreeableMemory"
  namespace           = "AWS/ElastiCache"
  period              = "60"
  statistic           = "Average"
  tags                = module.label.tags

  threshold = var.alarm_memory_threshold_bytes

  dimensions = {
    CacheClusterId = each.value
  }

  alarm_actions             = var.alarm_actions
  ok_actions                = var.ok_actions
  insufficient_data_actions = var.insufficient_data_actions
  depends_on                = [aws_elasticache_replication_group.default]
}

module "dns" {
  source  = "cloudposse/route53-cluster-hostname/aws"
  version = "0.12.0"

  enabled = var.enabled && var.zone_id != "" ? true : false
  name    = var.dns_subdomain != "" ? var.dns_subdomain : var.name
  ttl     = 60
  zone_id = var.zone_id
  records = var.cluster_mode_enabled ? [join("", aws_elasticache_replication_group.default.*.configuration_endpoint_address)] : [join("", aws_elasticache_replication_group.default.*.primary_endpoint_address)]
}
