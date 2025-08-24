resource "aws_vpc" "zt_vpc" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc-${var.environment}" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.zt_vpc.id
  cidr_block        = "10.42.1.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "${var.name_prefix}-priv-a-${var.environment}" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.zt_vpc.id
  cidr_block        = "10.42.2.0/24"
  availability_zone = "${var.aws_region}b"
  tags              = { Name = "${var.name_prefix}-priv-b-${var.environment}" }
}

# Security Groups
resource "aws_security_group" "workload_sg" {
  name        = "${var.name_prefix}-workload-sg-${var.environment}"
  description = "Workload SG"
  vpc_id      = aws_vpc.zt_vpc.id
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.42.0.0/16"]
  }
  tags = { Name = "${var.name_prefix}-workload-sg-${var.environment}" }
}

# PrivateLink VPC Endpoints
locals {
  services = [
    "com.amazonaws.${var.aws_region}.s3",
    "com.amazonaws.${var.aws_region}.kms",
    "com.amazonaws.${var.aws_region}.secretsmanager"
  ]
}

resource "aws_vpc_endpoint" "vpce" {
  for_each            = toset(local.services)
  vpc_id              = aws_vpc.zt_vpc.id
  service_name        = each.key
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids  = [aws_security_group.workload_sg.id]
  tags                = { Name = "${var.name_prefix}-vpce-${replace(each.key, ".", "-")}" }
}

locals {
  s3_vpce_id = aws_vpc_endpoint.vpce["com.amazonaws.${var.aws_region}.s3"].id
}

# S3 Bucket locked to VPCe
resource "aws_s3_bucket" "secure_data" {
  bucket = "${var.name_prefix}-secure-data-${var.environment}"
  tags   = { Name = "${var.name_prefix}-secure-data-${var.environment}" }
}

resource "aws_s3_bucket_policy" "secure_policy" {
  bucket = aws_s3_bucket.secure_data.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonVPCEAccess"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        "arn:aws:s3:::${aws_s3_bucket.secure_data.bucket}",
        "arn:aws:s3:::${aws_s3_bucket.secure_data.bucket}/*"
      ]
      Condition = {
        StringNotEquals = {
          "aws:sourceVpce" = local.s3_vpce_id
        }
      }
    }]
  })
}

# KMS Key + IAM Role
resource "aws_kms_key" "app" {
  description         = "KMS CMK"
  enable_key_rotation = true
}

resource "aws_iam_role" "app_role" {
  name = "${var.name_prefix}-app-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "app_policy" {
  name = "${var.name_prefix}-app-policy-${var.environment}"
  role = aws_iam_role.app_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:GetObject", "s3:ListBucket"],
        Resource = [
          "arn:aws:s3:::${aws_s3_bucket.secure_data.bucket}",
          "arn:aws:s3:::${aws_s3_bucket.secure_data.bucket}/*"
        ]
      },
      {
        Effect   = "Allow",
        Action   = ["kms:Decrypt", "kms:DescribeKey"],
        Resource = aws_kms_key.app.arn
      }
    ]
  })
}

output "zero_trust_summary" {
  value = {
    vpc_id   = aws_vpc.zt_vpc.id
    vpce_ids = [for k, v in aws_vpc_endpoint.vpce : v.id]
    bucket   = aws_s3_bucket.secure_data.bucket
    kms_arn  = aws_kms_key.app.arn
  }
}
