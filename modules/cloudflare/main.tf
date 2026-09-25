# --- Cloudflare origin certificate + DNS, OCI Load Balancer + NSG ---
#
# The caller configures the cloudflare provider:
#   provider "cloudflare" {
#     api_token = var.CLOUDFLARE_API_TOKEN
#   }

locals {
  lb_instances = { for k, v in var.instances : k => v if v.behind_lb }
}

# --- Origin certificate ---

resource "tls_private_key" "origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin" {
  private_key_pem = tls_private_key.origin.private_key_pem
  subject {
    common_name = var.domain_name
  }
}

resource "cloudflare_origin_ca_certificate" "cert" {
  csr                = tls_cert_request.origin.cert_request_pem
  hostnames          = [var.domain_name, "*.${var.domain_name}"]
  request_type       = "origin-rsa"
  requested_validity = 5475 # 15 years
}

# Cloudflare Origin CA RSA root certificate
locals {
  cloudflare_origin_ca_rsa_root = <<-EOT
-----BEGIN CERTIFICATE-----
MIIEADCCAuigAwIBAgIID+rOSdTGfGcwDQYJKoZIhvcNAQELBQAwgYsxCzAJBgNV
BAYTAlVTMRkwFwYDVQQKExBDbG91ZEZsYXJlLCBJbmMuMTQwMgYDVQQLEytDbG91
ZEZsYXJlIE9yaWdpbiBTU0wgQ2VydGlmaWNhdGUgQXV0aG9yaXR5MRYwFAYDVQQH
Ew1TYW4gRnJhbmNpc2NvMRMwEQYDVQQIEwpDYWxpZm9ybmlhMB4XDTE5MDgyMzIx
MDgwMFoXDTI5MDgxNTE3MDAwMFowgYsxCzAJBgNVBAYTAlVTMRkwFwYDVQQKExBD
bG91ZEZsYXJlLCBJbmMuMTQwMgYDVQQLEytDbG91ZEZsYXJlIE9yaWdpbiBTU0wg
Q2VydGlmaWNhdGUgQXV0aG9yaXR5MRYwFAYDVQQHEw1TYW4gRnJhbmNpc2NvMRMw
EQYDVQQIEwpDYWxpZm9ybmlhMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
AQEAwEiVZ/UoQpHmFsHvk5isBxRehukP8DG9JhFev3WZtG76WoTthvLJFRKFCHXm
V6Z5/66Z4S09mgsUuFwvJzMnE6Ej6yIsYNCb9r9QORa8BdhrkNn6kdTly3mdnykb
OomnwbUfLlExVgNdlP0XoRoeMwbQ4598foiHblO2B/LKuNfJzAMfS7oZe34b+vLB
yrP/1bgCSLdc1AxQc1AC0EsQQhgcyTJNgnG4va1c7ogPlwKyhbDyZ4e59N5lbYPJ
SmXI/cAe3jXj1FBLJZkwnoDKe0v13xeF+nF32smSH0qB7aJX2tBMW4TWtFPmzs5I
lwrFSySWAdwYdgxw180yKU0dvwIDAQABo2YwZDAOBgNVHQ8BAf8EBAMCAQYwEgYD
VR0TAQH/BAgwBgEB/wIBAjAdBgNVHQ4EFgQUJOhTV118NECHqeuU27rhFnj8KaQw
HwYDVR0jBBgwFoAUJOhTV118NECHqeuU27rhFnj8KaQwDQYJKoZIhvcNAQELBQAD
ggEBAHwOf9Ur1l0Ar5vFE6PNrZWrDfQIMyEfdgSKofCdTckbqXNTiXdgbHs+TWoQ
wAB0pfJDAHJDXOTCWRyTeXOseeOi5Btj5CnEuw3P0oXqdqevM1/+uWp0CM35zgZ8
VD4aITxity0djzE6Qnx3Syzz+ZkoBgTnNum7d9A66/V636x4vTeqbZFBr9erJzgz
hhurjcoacvRNhnjtDRM0dPeiCJ50CP3wEYuvUzDHUaowOsnLCjQIkWbR7Ni6KEIk
MOz2U0OBSif3FTkhCgZWQKOOLo1P42jHC3ssUZAtVNXrCk3fw9/E15k8NPkBazZ6
0iykLhH1trywrKRMVw67F44IE8Y=
-----END CERTIFICATE-----
EOT
}

# --- Network security group (Cloudflare IPs only on 443) ---

resource "oci_core_network_security_group" "lb_nsg" {
  compartment_id = var.tenancy_ocid
  vcn_id         = var.vcn_id
  display_name   = "LB Network Security Group"
}

resource "oci_core_network_security_group_security_rule" "cf_ipv4" {
  for_each                  = toset(var.cloudflare_ipv4)
  network_security_group_id = oci_core_network_security_group.lb_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cf_ipv6" {
  for_each                  = toset(var.cloudflare_ipv6)
  network_security_group_id = oci_core_network_security_group.lb_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# --- Load balancer ---

resource "oci_load_balancer_load_balancer" "lb" {
  compartment_id = var.tenancy_ocid
  display_name   = "${var.project_name} Load Balancer"
  subnet_ids     = [var.public_subnet_id]
  shape          = "flexible"
  shape_details {
    maximum_bandwidth_in_mbps = 10
    minimum_bandwidth_in_mbps = 10
  }
  network_security_group_ids = [oci_core_network_security_group.lb_nsg.id]
}

resource "oci_load_balancer_certificate" "origin" {
  certificate_name = "cloudflare-origin-cert"
  load_balancer_id = oci_load_balancer_load_balancer.lb.id

  public_certificate = cloudflare_origin_ca_certificate.cert.certificate
  private_key        = tls_private_key.origin.private_key_pem
  ca_certificate     = local.cloudflare_origin_ca_rsa_root

  lifecycle {
    create_before_destroy = true
  }
}

resource "oci_load_balancer_backend_set" "backend" {
  load_balancer_id = oci_load_balancer_load_balancer.lb.id
  name             = "backend-set"
  policy           = "ROUND_ROBIN"
  health_checker {
    protocol = "HTTP"
    port     = 0 # use backend port
    url_path = "/health"
  }
}

resource "oci_load_balancer_backend" "instance" {
  for_each         = local.lb_instances
  load_balancer_id = oci_load_balancer_load_balancer.lb.id
  backendset_name  = oci_load_balancer_backend_set.backend.name
  ip_address       = var.instance_private_ips[each.key]
  port             = each.value.app_port
}

resource "oci_load_balancer_listener" "https" {
  load_balancer_id         = oci_load_balancer_load_balancer.lb.id
  default_backend_set_name = oci_load_balancer_backend_set.backend.name
  name                     = "https-listener"
  protocol                 = "HTTP"
  port                     = 443

  ssl_configuration {
    certificate_name        = oci_load_balancer_certificate.origin.certificate_name
    verify_peer_certificate = false
  }
}

# --- DNS records ---

resource "cloudflare_dns_record" "dns" {
  for_each = toset(var.dns_records)
  zone_id  = var.cloudflare_zone_id
  name     = each.value
  content  = [for ip in oci_load_balancer_load_balancer.lb.ip_address_details : ip.ip_address if ip.is_public][0]
  type     = "A"
  proxied  = true
  ttl      = 1
}

resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "ssl"
  value      = "strict"
}
