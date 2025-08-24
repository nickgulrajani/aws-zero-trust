variable "project" {
  type        = string
  default     = "fintech-zero-trust"
  description = "Project tag used for default_tags"
}

variable "environment" {
  type        = string
  default     = "dryrun"
  description = "Environment name (dry-run only)"
}

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region (no API calls in dry run)"
}

variable "name_prefix" {
  type        = string
  default     = "zt"
  description = "Resource name prefix"
}

variable "org_target_id" {
  type        = string
  default     = "r-exampleroot"
  description = "Organizations root/OU ID for SCP attachment (placeholder)"
}
