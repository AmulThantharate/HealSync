variable "environment"       { type = string }
variable "grafana_password"  { type = string; sensitive = true }
variable "eks_cluster_name"  { type = string }
variable "aws_region"        { type = string }
variable "rds_identifier"    { type = string }
variable "s3_bucket_id"      { type = string }
