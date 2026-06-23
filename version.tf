terraform {
  required_version = "1.15.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
provider "aws" {
  default_tags {
    tags = {
      Project     = "URLShortener"
      Environment = "dev"
      ManagedBy   = "Terraform"
    }
  }
}