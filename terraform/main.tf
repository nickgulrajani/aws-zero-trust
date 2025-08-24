# -------------------------------
# VPC + Private Subnets (no IGW) — isolation
# -------------------------------
resource "aws_vpc" "zt_vpc" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc-${var.environment}" }
}

resource "aws_subnet" "private_a" {
  vpc_id                  = aws_vpc.zt_vpc.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-priv-a-${var.environment}" }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.zt_vpc.id
  cidr_block              = "10.42.2.0/24"
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-priv-b-${var.environment}" }
}

# Optional private route table (no IGW/NAT in dry run)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.zt_vpc.id
  tags   = { Name = "${var.name_prefix}-rt-private-${var.environment}" }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# -------------------------------
# Security Groups (no inline rules; rules created below to avoid cycles)
# -------------------------------
resource "aws_security_group" "workload_sg" {
  name        = "${var.name_prefix}-workload-sg-${var.environment}"
  description = "Workload security group"
  vpc_id      = aws_vpc.zt_vpc.id
  tags        = { Name = "${var.name_prefix}-workload-sg-${var.environment}" }
}

resource "aws_security_group" "endpoint_sg" {
  name        = "${var.name_prefix}-vpce-sg-${var.environment}"
  description = "Interface VPC endpoint security group"
  vpc_id      = aws_vpc.zt_vpc.id
  tags        = { Name = "${var.name_prefix}-vpce-sg-${var.environment}" }
}

# ---- SG Rules (cycle-free) ----

# Workload egress to VPCE on 443
resource "aws_security_group_rule" "workload_to_vpce_egress" {
  type                     = "egress"
  security_group_id        = aws_security_group.workload_sg.id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.endpoint_sg.id
  description              = "Workload egress to interface VPC endpoint on 443"
}

# VPCE ingress from Workload on 443
resource "aws_security_group_rule" "vpce_from_workload_ingress" {
  type                     = "ingress"
  security_group_id        = aws_security_group.endpoint_sg.id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.workload_sg.id
  description              = "Allow 443 from workload security group"
}

# Optional: restrict VPCE egress within VPC only
resource "aws_security_group_rule" "vpce_egress_vpc_only" {
  type              = "egress"
  security_group_id = aws_security_group.endpoint_sg.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["10.42.0.0/16"]
  description       = "Restrict VPC endpoint egress within VPC CIDR"
}

# -------------------------------
# PrivateLink (Interface VPC Endpoints)
# -------------------------------
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
  security_group_ids  = [aws_security_group.endpoint_sg.id]
  tags                = { Name = "${var.name_prefix}-vpce-${replace(each.key, ".", "-")}" }
}

# ID for S3 endpoint to enforce in the bucket policy
locals {
  s3_vpce_id = aws_vpc_endpoint.vpce["com.amazonaws.${var.aws_region}.s3"].id
}

# -------------------------------
# S3 bucket locked to PrivateLink via aws:SourceVpce
# -------------------------------
resource "aws_s3_bucket" "secure_data" {
  bucket = "${var.name_prefix}-secure-data-${var.environment}"
  tags   = { Name = "${var.name_prefix}-secure-data-${var.environment}" }
}

resource "aws_s3_bucket_policy" "secure_policy" {
  bucket = aws_s3_bucket.secure_data.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonVPCEAccess"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [
        "arn:aws:s3:::${aws_s3_bucket.secure_data.bucket}",
        "arn:aws:s3:::${aws_s3_bucket.secure_data.bucket}/*"
      ]
      Condition = {
        StringNotEquals = {
          "aws:SourceVpce" = local.s3_vpce_id
        }
      }
    }]
  })
}

# -------------------------------
# KMS CMK + Least-Privilege IAM Role
# -------------------------------
resource "aws_kms_key" "app" {
  description             = "Application KMS CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = { Name = "${var.name_prefix}-kms-${var.environment}" }
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
  tags = { Name = "${var.name_prefix}-app-role-${var.environment}" }
}

resource "aws_iam_role_policy" "app_policy" {
  name = "${var.name_prefix}-app-policy-${var.environment}"
  role = aws_iam_role.app_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid: "BucketReadOnly",
        Effect = "Allow",
        Action = ["s3:GetObject", "s3:ListBucket"],
        Resource = [
          "arn:aws:s3:::${aws_s3_bucket.secure_data.bucket}",
          "arn:aws:s3:::${aws_s3_bucket.secure_data.bucket}/*"
        ]
      },
      {
        Sid: "KMSDecryptDescribeOnlyThisKey",
        Effect   = "Allow",
        Action   = ["kms:Decrypt", "kms:DescribeKey"],
        Resource = aws_kms_key.app.arn
      }
    ]
  })
}

# -------------------------------
# Outputs
# -------------------------------
output "zero_trust_summary" {
  value = {
    vpc_id          = aws_vpc.zt_vpc.id
    private_subnets = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    vpce_ids        = [for k, v in aws_vpc_endpoint.vpce : v.id]
    s3_bucket       = aws_s3_bucket.secure_data.bucket
    kms_key_arn     = aws_kms_key.app.arn
    iam_role        = aws_iam_role.app_role.name
  }
}
