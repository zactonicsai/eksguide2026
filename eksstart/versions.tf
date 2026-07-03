# versions.tf
# Pin Terraform and the AWS provider so applies are reproducible.
# AWS provider 6.x is the current major line (6.52.0 latest as of June 2026).
# Pinning protects you from surprise breaking changes in a future major (7.x).

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # allows 6.x, blocks 7.0 breaking changes
    }
  }

  # Recommended for teams: store state remotely with locking instead of locally.
  # Uncomment and fill in once you have an S3 bucket + DynamoDB lock table.
  # backend "s3" {
  #   bucket         = "my-tfstate-bucket"
  #   key            = "network/vpc/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "tf-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  # Tags applied to every taggable resource automatically.
  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project_name
      ManagedBy   = "Terraform"
    }
  }
}
