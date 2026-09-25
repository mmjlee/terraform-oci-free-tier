# Example: full deployment with all optional addons (Cloudflare, Auth0, GitHub
# secret sync) wired in.
#
# In Path B, addons are separate top-level module calls. Pick the ones you
# want, configure their providers, and wire core outputs into addon inputs.
# Consumers using only `module "core"` don't pay any provider tax for addons
# they don't use.

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
    github = {
      source  = "integrations/github"
      version = ">= 6.13.0"
    }
    auth0 = {
      source  = "auth0/auth0"
      version = ">= 1.58.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.9.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.4.0"
    }
  }
}

provider "oci" {
  tenancy_ocid = var.TENANCY_OCID
  user_ocid    = var.USER_OCID
  fingerprint  = var.FINGERPRINT
  private_key  = local.oci_private_key
  region       = var.REGION
}

provider "cloudflare" {
  api_token = var.CLOUDFLARE_API_TOKEN
}

provider "github" {
  owner = var.GITHUB_OWNER
  token = var.GITHUB_TOKEN
}

provider "auth0" {
  domain        = var.AUTH0_DOMAIN
  client_id     = var.AUTH0_M2M_CLIENT_ID
  client_secret = var.AUTH0_M2M_CLIENT_SECRET
}

# --- Core infrastructure (required) ---

module "core" {
  source = "../.."

  tenancy_ocid   = var.TENANCY_OCID
  region         = var.REGION
  ssh_public_key = local.ssh_public_key
  project_name   = "example-app"

  instances = {
    app = {
      ocpus           = 4
      memory_gb       = 24
      block_volume_gb = 50
      behind_lb       = true
    }
  }

  databases = {
    main = { display_name = "MainDB", db_name = "MAINDB" }
  }

  bucket_name = "example-app-backups"
}

# --- Cloudflare addon (optional) ---

module "cloudflare" {
  source = "../../modules/cloudflare"

  tenancy_ocid     = var.TENANCY_OCID
  project_name     = "example-app"
  vcn_id           = module.core.vcn_id
  public_subnet_id = module.core.public_subnet_id

  instances = {
    for k, v in module.core.instances : k => {
      app_port  = 8080
      behind_lb = true
    }
  }
  instance_private_ips = { for k, v in module.core.instances : k => v.private_ip }

  domain_name        = var.DOMAIN_NAME
  cloudflare_zone_id = var.CLOUDFLARE_ZONE_ID
  dns_records        = [var.DOMAIN_NAME, "app"]
}

# --- Auth0 addon (optional) ---

module "auth0" {
  source = "../../modules/auth0"

  auth0_api_audience  = var.AUTH0_API_AUDIENCE
  auth0_jwt_namespace = var.AUTH0_JWT_NAMESPACE
  auth0_callback_urls = var.AUTH0_CALLBACK_URLS
  auth0_admin_user_id = var.AUTH0_ADMIN_USER_ID
}

# --- GitHub Actions secret sync addon (optional) ---
#
# Forwards OCI auth + module outputs (instance IPs, vault, DB OCIDs) and
# any other credential vars into the repo's Actions secrets.

module "github_secrets" {
  source = "../../modules/github"

  github_owner = var.GITHUB_OWNER
  github_repo  = var.GITHUB_REPO

  # OCI auth (synced as secrets)
  oci_user_ocid   = var.USER_OCID
  oci_fingerprint = var.FINGERPRINT
  oci_private_key = local.oci_private_key
  ssh_private_key = local.ssh_private_key
  ssh_public_key  = local.ssh_public_key
  ip_address      = var.IP_ADDRESS

  # Cloudflare creds (passed through as secrets)
  cloudflare_api_token = var.CLOUDFLARE_API_TOKEN
  cloudflare_zone_id   = var.CLOUDFLARE_ZONE_ID
  domain_name          = var.DOMAIN_NAME

  # Auth0 creds (passed through as secrets)
  auth0_domain            = var.AUTH0_DOMAIN
  auth0_client_id         = var.AUTH0_CLIENT_ID
  auth0_client_secret     = var.AUTH0_CLIENT_SECRET
  auth0_m2m_client_id     = var.AUTH0_M2M_CLIENT_ID
  auth0_m2m_client_secret = var.AUTH0_M2M_CLIENT_SECRET

  # Module-derived values (synced as secrets)
  tenancy_ocid          = var.TENANCY_OCID
  region                = var.REGION
  vault_ocid            = module.core.vault_id
  vault_key_id          = module.core.vault_key_id
  vault_crypto_endpoint = module.core.vault_crypto_endpoint
  os_namespace          = module.core.os_namespace
  instance_public_ips   = { for k, v in module.core.instances : k => v.public_ip }
  database_ids          = module.core.database_ids

  # Project-specific extras (merged on top of the auto-derived secrets)
  extra_secrets = {
    # GOOGLE_CLIENT_ID = var.GOOGLE_CLIENT_ID
  }
}
