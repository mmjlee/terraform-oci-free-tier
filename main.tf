terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 9.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.9.0"
    }
  }
}

# --- Data Sources ---

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_services" "all" {}

data "oci_core_images" "arm_linux" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.arm_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.tenancy_ocid
}

locals {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name

  filtered_services = [
    for s in data.oci_core_services.all.services : s
    if strcontains(lower(s.name), "all")
  ]
  all_services = local.filtered_services[0]

  arm_image_id = data.oci_core_images.arm_linux.images[0].id
}
