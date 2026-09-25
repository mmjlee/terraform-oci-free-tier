terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 9.3.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 5.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.4.0"
    }
  }
}
