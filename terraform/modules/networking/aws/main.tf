resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "healsync-vpc-${var.environment}" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "healsync-igw-${var.environment}" }
}

locals {
  azs               = ["${var.region}a", "${var.region}b", "${var.region}c"]
  public_cidrs      = ["10.0.1.0/24",  "10.0.2.0/24",  "10.0.3.0/24"]
  private_app_cidrs = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
  private_db_cidrs  = ["10.0.20.0/24", "10.0.21.0/24", "10.0.22.0/24"]
}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                     = "healsync-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private_app" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_app_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags = {
    Name                              = "healsync-private-app-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "private_db" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_db_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "healsync-private-db-${local.azs[count.index]}" }
}

resource "aws_eip" "nat" {
  count  = 3
  domain = "vpc"
  tags   = { Name = "healsync-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "nat" {
  count         = 3
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.igw]
  tags          = { Name = "healsync-nat-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; gateway_id = aws_internet_gateway.igw.id }
  tags   = { Name = "healsync-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_app" {
  count  = 3
  vpc_id = aws_vpc.main.id
  route  { cidr_block = "0.0.0.0/0"; nat_gateway_id = aws_nat_gateway.nat[count.index].id }
  tags   = { Name = "healsync-rt-private-app-${count.index}" }
}

resource "aws_route_table_association" "private_app" {
  count          = 3
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[count.index].id
}

resource "aws_route_table" "private_db" {
  count  = 3
  vpc_id = aws_vpc.main.id
  route  { cidr_block = "0.0.0.0/0"; nat_gateway_id = aws_nat_gateway.nat[count.index].id }
  tags   = { Name = "healsync-rt-private-db-${count.index}" }
}

resource "aws_route_table_association" "private_db" {
  count          = 3
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db[count.index].id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], aws_route_table.private_app[*].id, aws_route_table.private_db[*].id)
  tags              = { Name = "healsync-vpce-s3" }
}
