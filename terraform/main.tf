# -------------------------------
# VPC + Private Subnets (no IGW shown) — isolation
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

# -------------------------------
# Security Groups
# -------------------------------
# Workload SG: no ingress; egress ONLY to the endpoint SG on 443
resource "aws_security_group" "workload_sg" {
  name        = "${var.name_prefix}-workload-sg-${var.environment}"
  description = "Workload SG"
  vpc_id      = aws_vpc.zt_vpc.id

  # No ingress rules -> traffic must come through controlled fronts (LB/proxy/etc.)

  # Egress only to VPC endpoint SG on 443
  egress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.endpoint_sg.id]
    description     = "Workload egress -> Interface VPCE only"
  }

  tags = { Name = "${var.name_prefix}-workload-sg-${var.environment}" }
}

# Endpoint SG: allow inbound 443 only from the workload SG
resource "aws_security_group" "endpoint_sg" {
  name        = "${var.name_prefix}-vpce-sg-${var.environment}"
  description = "Interface VPCE SG"
  vpc_id      = aws_vpc.zt_vpc.id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.workload_sg.id]
    description     = "Allow 443 from workload SG"
  }

  # (Optional) Restrictive egress back into VPC (not required for VPCE, but kept tight)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.42.0.0/16"]
    description = "Restrict egress within VPC"
  }

  tags = { Name = "${var.name_prefix}-vpce-sg-${var.environment}" }
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
  security_group_ids  = [aws_security_group.endpoint_sg.id] # <-- attach endpoint SG
  tags                = { Name = "${var.name_prefix}-vpce-${replace(each.key, ".", "-")}" }
}

locals {
  s3_vpce_id = aws_vpc_endpoint.vpce["com.amazonaws.${var.aws_region}.s3"].id
}

# -------------------------------
# S3 bucket locked to PrivateLink via aws:sourceVpce
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
          "aws:sourceVpce" = local.s3_vpce_id
        }
      }
    }]
  })
}

# -------------------------------
# KMS Key + Least-Privilege IAM Role
# -------------------------------
resource "aws_kms_key" "app" {
  description             = "KMS CMK"
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
    vpc_id   = aws_vpc.zt_vpc.id
    vpce_ids = [for k, v in aws_vpc_endpoint.vpce : v.id]
    bucket   = aws_s3_bucket.secure_data.bucket
    kms_arn  = aws_kms_key.app.arn
  }
}
