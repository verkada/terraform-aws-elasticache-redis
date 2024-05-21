terraform {
  required_version = ">= 0.13"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">=5, <6"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.1.0, < 4"
    }
  }
}
