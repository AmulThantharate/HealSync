resource "aws_s3_bucket" "primary" {
  bucket        = var.s3_bucket_name
  force_destroy = false
  tags          = { Name = var.s3_bucket_name, Role = "primary" }
}
resource "aws_s3_bucket_versioning" "primary" {
  bucket = aws_s3_bucket.primary.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "primary" {
  bucket = aws_s3_bucket.primary.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
    bucket_key_enabled = true
  }
}
resource "aws_s3_bucket_public_access_block" "primary" {
  bucket                  = aws_s3_bucket.primary.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_lifecycle_configuration" "primary" {
  bucket     = aws_s3_bucket.primary.id
  depends_on = [aws_s3_bucket_versioning.primary]
  rule {
    id     = "transition-old-versions"
    status = "Enabled"
    noncurrent_version_transition { noncurrent_days = 30; storage_class = "STANDARD_IA" }
    noncurrent_version_expiration { noncurrent_days = 90 }
  }
}

resource "aws_s3_bucket" "replica" {
  bucket        = "${var.s3_bucket_name}-replica"
  force_destroy = false
  tags          = { Role = "replica" }
}
resource "aws_s3_bucket_versioning" "replica" {
  bucket = aws_s3_bucket.replica.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "replica" {
  bucket = aws_s3_bucket.replica.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
    bucket_key_enabled = true
  }
}
resource "aws_s3_bucket_public_access_block" "replica" {
  bucket                  = aws_s3_bucket.replica.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "replication" {
  name = "healsync-s3-replication-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow"; Action = "sts:AssumeRole"; Principal = { Service = "s3.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy" "replication" {
  name = "healsync-s3-replication-policy"; role = aws_iam_role.replication.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow"; Action = ["s3:GetReplicationConfiguration","s3:ListBucket"];                         Resource = [aws_s3_bucket.primary.arn] },
      { Effect = "Allow"; Action = ["s3:GetObjectVersionForReplication","s3:GetObjectVersionAcl","s3:GetObjectVersionTagging"]; Resource = ["${aws_s3_bucket.primary.arn}/*"] },
      { Effect = "Allow"; Action = ["s3:ReplicateObject","s3:ReplicateDelete","s3:ReplicateTags"];             Resource = ["${aws_s3_bucket.replica.arn}/*"] }
    ]
  })
}
resource "aws_s3_bucket_replication_configuration" "primary_to_replica" {
  depends_on = [aws_s3_bucket_versioning.primary]
  bucket     = aws_s3_bucket.primary.id
  role       = aws_iam_role.replication.arn
  rule {
    id     = "replicate-all"
    status = "Enabled"
    destination { bucket = aws_s3_bucket.replica.arn; storage_class = "STANDARD_IA" }
  }
}
