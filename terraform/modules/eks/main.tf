data "aws_iam_policy_document" "eks_assume" {
  statement {
    effect  = "Allow"; actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["eks.amazonaws.com"] }
  }
}
resource "aws_iam_role" "eks_cluster" {
  name               = "healsync-eks-cluster-role-${var.environment}${var.name_suffix}"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.k8s_version
  role_arn = aws_iam_role.eks_cluster.arn
  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }
  enabled_cluster_log_types = ["api","audit","authenticator","controllerManager","scheduler"]
  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}
data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"; actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["ec2.amazonaws.com"] }
  }
}
resource "aws_iam_role" "eks_nodes" {
  name               = "healsync-eks-node-role-${var.environment}${var.name_suffix}"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}
resource "aws_iam_role_policy_attachment" "node_worker" {
  role = aws_iam_role.eks_nodes.name; policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}
resource "aws_iam_role_policy_attachment" "node_cni" {
  role = aws_iam_role.eks_nodes.name; policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role = aws_iam_role.eks_nodes.name; policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role = aws_iam_role.eks_nodes.name; policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_security_group" "nodes" {
  name   = "healsync-eks-nodes-sg-${var.environment}${var.name_suffix}"; vpc_id = var.vpc_id
  ingress { from_port = 0; to_port = 0; protocol = "-1"; self = true }
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["10.0.0.0/16"] }
  ingress { from_port = 1025; to_port = 65535; protocol = "tcp"; cidr_blocks = ["10.0.0.0/16"] }
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags    = { Name = "healsync-eks-nodes-sg" }
}
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "healsync-nodes-${var.environment}${var.name_suffix}"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2_x86_64"
  scaling_config  { min_size = var.node_min; max_size = var.node_max; desired_size = var.node_desired }
  update_config   { max_unavailable = 1 }
  depends_on = [aws_iam_role_policy_attachment.node_worker,aws_iam_role_policy_attachment.node_cni,aws_iam_role_policy_attachment.node_ecr]
  lifecycle { ignore_changes = [scaling_config[0].desired_size] }
}
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
resource "aws_eks_access_entry" "nodes" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.eks_nodes.arn
  type          = "EC2_LINUX"
}
