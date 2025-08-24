variable "project"       { type = string, default = "fintech-zero-trust" }
variable "environment"   { type = string, default = "dryrun" }
variable "aws_region"    { type = string, default = "us-east-1" }
variable "name_prefix"   { type = string, default = "zt" }
variable "org_target_id" { type = string, default = "r-exampleroot" } # placeholder for SCP attachments (not used in this minimal set)
