# =============================================================================
# CCS — Compañía Colombiana de Seguimiento de Vehículos
# Infraestructura AWS · Terraform · región us-east-1
# -----------------------------------------------------------------------------
# Backend: LOCAL (decisión del reto). El estado queda en ./terraform.tfstate.
# No se declara bloque `backend` → Terraform usa el backend local por defecto.
# En un entorno productivo se migraría a S3 + lock en DynamoDB.
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
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
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
