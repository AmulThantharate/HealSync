# ── Cloud ─────────────────────────────────────────────────────────────────────
variable "aws_region"            { default = "us-east-1" }
variable "aws_secondary_region"  { default = "ap-south-1" }
variable "environment"           { default = "prod" }

# ── Network ───────────────────────────────────────────────────────────────────
variable "aws_vpc_cidr"    { default = "10.0.0.0/16" }
variable "aws_secondary_vpc_cidr" { default = "10.2.0.0/16" }
variable "aws_bgp_asn"     { default = 65000 }

# ── EKS ───────────────────────────────────────────────────────────────────────
variable "eks_cluster_name" { default = "healsync-eks-primary" }
variable "eks_secondary_cluster_name" { default = "healsync-eks-secondary" }
variable "eks_k8s_version"  { default = "1.29" }
variable "eks_node_type"    { default = "m5.xlarge" }
variable "eks_node_min"     { default = 2 }
variable "eks_node_max"     { default = 10 }
variable "eks_node_desired" { default = 3 }
variable "eks_secondary_node_type"    { default = "m5.xlarge" }
variable "eks_secondary_node_min"     { default = 2 }
variable "eks_secondary_node_max"     { default = 10 }
variable "eks_secondary_node_desired" { default = 3 }

# ── Database ──────────────────────────────────────────────────────────────────
variable "db_name"            { default = "healsync" }
variable "db_username"        { default = "dbadmin" }
variable "db_password"        { type = string; sensitive = true }
variable "rds_instance_class" { default = "db.r6g.xlarge" }
variable "rds_secondary_instance_class" { default = "db.r6g.large" }

# ── Storage ───────────────────────────────────────────────────────────────────
variable "s3_bucket_name"     { default = "healsync-primary-data" }

# ── DNS ───────────────────────────────────────────────────────────────────────
variable "route53_zone_id"       { type = string }
variable "app_domain"            { default = "app.example.com" }
variable "failover_cname_target" { default = "healsync-failover.example.com" }

# ── App ───────────────────────────────────────────────────────────────────────
variable "app_image"        { default = "your-registry/healsync-flask-app:latest" }
variable "grafana_password" { type = string; sensitive = true; default = "ChangeMe123!" }
