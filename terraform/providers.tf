terraform {
  required_version = ">= 1.7"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.40" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.27" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
    archive    = { source = "hashicorp/archive", version = "~> 2.4" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "healsync"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.aws_secondary_region
  default_tags {
    tags = {
      Project     = "healsync"
      Environment = "${var.environment}-secondary"
      ManagedBy   = "terraform"
    }
  }
}

provider "kubernetes" {
  alias                  = "eks"
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}
