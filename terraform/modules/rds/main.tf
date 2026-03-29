resource "aws_db_subnet_group" "main" {
  name       = "healsync-db-subnet-${var.environment}${var.name_suffix}"
  subnet_ids = var.subnet_ids
  tags       = { Name = "healsync-db-subnet-group" }
}
resource "aws_security_group" "rds" {
  name   = "healsync-rds-sg-${var.environment}${var.name_suffix}"; vpc_id = var.vpc_id
  ingress { from_port = 3306; to_port = 3306; protocol = "tcp"; security_groups = [var.eks_sg_id];         description = "MySQL from EKS" }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags    = { Name = "healsync-rds-sg" }
}
resource "aws_kms_key" "rds" {
  description = "RDS encryption"; deletion_window_in_days = 14; enable_key_rotation = true
}
resource "aws_db_parameter_group" "mysql8" {
  name   = "healsync-mysql8-${var.environment}${var.name_suffix}"; family = "mysql8.0"
  parameter { name = "binlog_format";   value = "ROW";     apply_method = "immediate" }
  parameter { name = "binlog_row_image"; value = "FULL";   apply_method = "immediate" }
  parameter { name = "expire_logs_days"; value = "7";      apply_method = "immediate" }
  parameter { name = "max_connections";  value = "1000";   apply_method = "pending-reboot" }
}
resource "aws_db_instance" "primary" {
  identifier              = "healsync-mysql-primary-${var.environment}${var.name_suffix}"
  engine                  = "mysql"
  engine_version          = "8.0.35"
  instance_class          = var.instance_class
  allocated_storage       = 100
  max_allocated_storage   = 1000
  storage_type            = "gp3"
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.rds.arn
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  parameter_group_name    = aws_db_parameter_group.mysql8.name
  multi_az                = true
  publicly_accessible     = false
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"
  monitoring_interval     = 60
  monitoring_role_arn     = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  deletion_protection                   = true
  skip_final_snapshot                   = false
  final_snapshot_identifier             = "healsync-mysql-final-${var.environment}${var.name_suffix}"
  tags = { Name = "healsync-mysql-primary-${var.environment}${var.name_suffix}", Role = "primary" }
}
resource "aws_db_instance" "replica" {
  identifier          = "healsync-mysql-replica-${var.environment}${var.name_suffix}"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class      = var.instance_class
  storage_encrypted   = true
  publicly_accessible = false
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn
  skip_final_snapshot = true
  tags = { Name = "healsync-mysql-replica-${var.environment}${var.name_suffix}", Role = "replica" }
}
resource "aws_iam_role" "rds_monitoring" {
  name = "healsync-rds-monitoring-${var.environment}${var.name_suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow"; Action = "sts:AssumeRole"; Principal = { Service = "monitoring.rds.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
resource "aws_cloudwatch_metric_alarm" "rds_replica_lag" {
  alarm_name          = "healsync-rds-replica-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2; metric_name = "ReplicaLag"; namespace = "AWS/RDS"
  period              = 60; statistic = "Average"; threshold = 30
  dimensions          = { DBInstanceIdentifier = aws_db_instance.replica.identifier }
  alarm_description   = "RDS replica lag > 30s — RPO at risk"
}
