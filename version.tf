terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "3.72.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "3.1.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.4.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.7.1"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.1.0"
    }
  }
}
