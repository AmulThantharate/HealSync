# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — NETWORKING (AWS)
# ═════════════════════════════════════════════════════════════════════════════
module "aws_networking" {
  source      = "./modules/networking/aws"
  vpc_cidr    = var.aws_vpc_cidr
  region      = var.aws_region
  environment = var.environment
  bgp_asn     = var.aws_bgp_asn
}

module "aws_networking_secondary" {
  source      = "./modules/networking/aws"
  providers   = { aws = aws.secondary }
  vpc_cidr    = var.aws_secondary_vpc_cidr
  region      = var.aws_secondary_region
  environment = "${var.environment}-secondary"
  bgp_asn     = var.aws_bgp_asn
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — KUBERNETES CLUSTER (EKS)
# ═════════════════════════════════════════════════════════════════════════════
module "eks" {
  source             = "./modules/eks"
  cluster_name       = var.eks_cluster_name
  k8s_version        = var.eks_k8s_version
  region             = var.aws_region
  vpc_id             = module.aws_networking.vpc_id
  private_subnet_ids = module.aws_networking.private_app_subnet_ids
  node_instance_type = var.eks_node_type
  node_min           = var.eks_node_min
  node_max           = var.eks_node_max
  node_desired       = var.eks_node_desired
  environment        = var.environment
  name_suffix        = "-primary"
}

module "eks_secondary" {
  source             = "./modules/eks"
  providers          = { aws = aws.secondary }
  cluster_name       = var.eks_secondary_cluster_name
  k8s_version        = var.eks_k8s_version
  region             = var.aws_secondary_region
  vpc_id             = module.aws_networking_secondary.vpc_id
  private_subnet_ids = module.aws_networking_secondary.private_app_subnet_ids
  node_instance_type = var.eks_secondary_node_type
  node_min           = var.eks_secondary_node_min
  node_max           = var.eks_secondary_node_max
  node_desired       = var.eks_secondary_node_desired
  environment        = var.environment
  name_suffix        = "-secondary"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — DATABASES (RDS)
# ═════════════════════════════════════════════════════════════════════════════
module "rds" {
  source         = "./modules/rds"
  environment    = var.environment
  vpc_id         = module.aws_networking.vpc_id
  subnet_ids     = module.aws_networking.private_db_subnet_ids
  instance_class = var.rds_instance_class
  db_name        = var.db_name
  db_username    = var.db_username
  db_password    = var.db_password
  eks_sg_id      = module.eks.node_sg_id
  aws_region     = var.aws_region
  name_suffix    = "-primary"
}

module "rds_secondary" {
  source         = "./modules/rds"
  providers      = { aws = aws.secondary }
  environment    = var.environment
  vpc_id         = module.aws_networking_secondary.vpc_id
  subnet_ids     = module.aws_networking_secondary.private_db_subnet_ids
  instance_class = var.rds_secondary_instance_class
  db_name        = var.db_name
  db_username    = var.db_username
  db_password    = var.db_password
  eks_sg_id      = module.eks_secondary.node_sg_id
  aws_region     = var.aws_secondary_region
  name_suffix    = "-secondary"
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — STORAGE (S3 + S3 replica)
# ═════════════════════════════════════════════════════════════════════════════
module "s3_blob" {
  source               = "./modules/s3-blob"
  environment          = var.environment
  aws_region           = var.aws_region
  s3_bucket_name       = "${var.s3_bucket_name}-${var.environment}"
  replication_role_arn = module.eks.worker_role_arn
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5 — LAMBDA FAILOVER (AWS)
# ═════════════════════════════════════════════════════════════════════════════
module "lambda_failover" {
  source                = "./modules/lambda-failover"
  environment           = var.environment
  aws_region            = var.aws_region
  vpc_id                = module.aws_networking.vpc_id
  subnet_ids            = module.aws_networking.private_app_subnet_ids
  eks_cluster_name      = module.eks.cluster_name
  rds_identifier        = module.rds.identifier
  s3_bucket_name        = module.s3_blob.s3_bucket_id
  route53_zone_id       = var.route53_zone_id
  app_domain            = var.app_domain
  failover_cname_target = var.failover_cname_target
  eks_endpoint          = module.eks.cluster_endpoint
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6 — MONITORING
# ═════════════════════════════════════════════════════════════════════════════
module "monitoring" {
  source           = "./modules/monitoring"
  providers        = { kubernetes = kubernetes.eks }
  environment      = var.environment
  grafana_password = var.grafana_password
  eks_cluster_name = module.eks.cluster_name
  aws_region       = var.aws_region
  rds_identifier   = module.rds.identifier
  s3_bucket_id     = module.s3_blob.s3_bucket_id
}
