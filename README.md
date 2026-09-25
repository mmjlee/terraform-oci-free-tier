# terraform-oci-free-tier

Reusable Terraform module for OCI Always Free tier infrastructure. Core module deploys ARM compute instances, Oracle Autonomous Databases, and OCI Vault KMS. Optional addon modules — Cloudflare LB+SSL, Auth0 application stack, and GitHub Actions secret sync — are invoked separately by the consumer when needed.

> **Architecture: addons are standalone top-level modules.** The core module's `required_providers` is just `oci` and `random`. If you don't need Cloudflare, Auth0, or GitHub sync, you don't pay any provider tax for them — no stub provider blocks, no transitive auth0/cloudflare/github init at plan time. Each addon is invoked only when the consumer wants it.

## What it creates

### Core (always)
- **Networking** — VCN, public/private subnets, internet + service gateways, route tables
- **Compute** — 1+ ARM A1.Flex instances with per-instance cloud-init, optional block volumes
- **Database** — 0–2 ATP free-tier instances (23ai) with auto-generated passwords stored in Vault
- **Vault** — OCI Vault + AES-256 master key + dynamic group + IAM policies for instance principal auth
- **Object Storage** — Optional Object Storage bucket with `prevent_destroy` lifecycle
- **Security** — Public/private security lists, SSH access, per-instance app port ingress
- **Quota** — Free tier enforcement (4 ARM OCPUs, 2 AMD micros, 200GB storage)

### Addon modules (opt-in)
- [`modules/cloudflare`](modules/cloudflare) — Load balancer, origin CA certificate, DNS records, strict SSL, Cloudflare-IP NSG
- [`modules/auth0`](modules/auth0) — SPA + M2M clients, API resource server with admin scope, admin/user roles, post-login JWT action
- [`modules/github`](modules/github) — Auto-pushes OCI auth, SSH keys, Cloudflare/Auth0 creds, and infrastructure outputs (per-instance `<NAME>_IP`, per-database `<KEY>_DB_OCID`, vault, OS namespace) into a GitHub repo's Actions secrets

## Prerequisites

- [Terraform](https://terraform.io) >= 1.10
- OCI account (Pay As You Go — all resources stay within Always Free tier)
- `~/.oci/config` configured for local OCI auth ([setup guide](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm))
- Cloudflare account with a domain (only if using the cloudflare addon)

## Getting Started

```bash
# 1. In your project's terraform directory, create main.tf with the module call (see examples below)
# 2. Configure providers (OCI for core; cloudflare/auth0/github only if using those addons)
# 3. Create terraform.tfvars with your credentials
# 4. Run:
terraform init
terraform plan    # review what will be created
terraform apply   # deploy (confirm with 'yes')

# 5. After deploy:
terraform output                                   # see IPs, DB info, SSH commands
terraform output -json ssh_commands                # all SSH commands (map)
terraform output -json instances | jq -r '.app.public_ip'  # one instance's IP
```

## Usage

### Core only (simplest case)

```hcl
terraform {
  required_providers {
    oci    = { source = "oracle/oci",       version = ">= 9.3.0" }
    random = { source = "hashicorp/random", version = ">= 3.9.0" }
  }
}

provider "oci" {
  tenancy_ocid = var.TENANCY_OCID
  user_ocid    = var.USER_OCID
  fingerprint  = var.FINGERPRINT
  private_key  = file(var.OCI_PRIVATE_KEY_PATH)
  region       = var.REGION
}

module "core" {
  source = "github.com/MMJLee/terraform-oci-free-tier"

  tenancy_ocid   = var.TENANCY_OCID
  region         = var.REGION
  ssh_public_key = file("./id_rsa.pub")
  project_name   = "myapp"

  instances = {
    app = {
      ocpus            = 4
      memory_gb        = 24
      block_volume_gb  = 50
      extra_packages   = ["nodejs:20"]
      extra_cloud_init = "npm install -g some-cli || true"
      behind_lb        = false  # no LB without the cloudflare addon
    }
  }

  databases = {
    main = { display_name = "MainDB", db_name = "MAINDB" }
  }

  bucket_name = "myapp-backups"
}
```

### Multiple instances (split free tier)

```hcl
module "core" {
  source = "github.com/MMJLee/terraform-oci-free-tier"

  tenancy_ocid   = var.TENANCY_OCID
  region         = var.REGION
  ssh_public_key = file("./id_rsa.pub")
  project_name   = "platform"

  instances = {
    api = {
      ocpus            = 2
      memory_gb        = 12
      block_volume_gb  = 50
      app_port         = 8080
      extra_packages   = ["nodejs:20"]
      behind_lb        = true
    }
    worker = {
      ocpus            = 1
      memory_gb        = 6
      block_volume_gb  = 50
      app_port         = 9090
      extra_packages   = ["python3"]
      behind_lb        = false
    }
    agent = {
      ocpus            = 1
      memory_gb        = 6
      app_port         = 8081
      extra_cloud_init = "npm install -g @anthropic-ai/claude-code || true"
      behind_lb        = false
    }
  }

  databases = {
    main  = { display_name = "MainDB",  db_name = "MAINDB" }
    agent = { display_name = "AgentDB", db_name = "AGENTDB" }
  }

  bucket_name = "platform-backups"
}
```

### Adding the Cloudflare addon

```hcl
provider "cloudflare" {
  api_token = var.CLOUDFLARE_API_TOKEN
}

module "cloudflare" {
  source = "github.com/MMJLee/terraform-oci-free-tier//modules/cloudflare"

  tenancy_ocid     = var.TENANCY_OCID
  project_name     = "platform"
  vcn_id           = module.core.vcn_id
  public_subnet_id = module.core.public_subnet_id

  instances = {
    for k, v in module.core.instances : k => {
      app_port  = 8080  # match each instance's app_port
      behind_lb = true
    } if k == "api"     # only the api instance is behind the LB
  }
  instance_private_ips = { for k, v in module.core.instances : k => v.private_ip }

  domain_name        = "example.com"
  cloudflare_zone_id = var.CLOUDFLARE_ZONE_ID
  dns_records        = ["example.com", "api"]
}

output "load_balancer_ip" {
  value = module.cloudflare.load_balancer_ip
}
```

### Adding the Auth0 addon

```hcl
provider "auth0" {
  domain        = var.AUTH0_DOMAIN
  client_id     = var.AUTH0_M2M_CLIENT_ID
  client_secret = var.AUTH0_M2M_CLIENT_SECRET
}

module "auth0" {
  source = "github.com/MMJLee/terraform-oci-free-tier//modules/auth0"

  auth0_api_audience  = "https://api.example.com"
  auth0_jwt_namespace = "https://app.example.com" # must match what your backend reads
  auth0_callback_urls = ["https://app.example.com", "http://localhost:5173"]
  auth0_admin_user_id = "auth0|abc123" # optional; auto-assigns admin role
}
```

### Adding the GitHub Actions secret sync addon

```hcl
provider "github" {
  owner = var.GITHUB_OWNER
  token = var.GITHUB_TOKEN
}

module "github_secrets" {
  source = "github.com/MMJLee/terraform-oci-free-tier//modules/github"

  github_owner = var.GITHUB_OWNER
  github_repo  = var.GITHUB_REPO

  # OCI auth (synced as secrets)
  oci_user_ocid   = var.USER_OCID
  oci_fingerprint = var.FINGERPRINT
  oci_private_key = file(var.OCI_PRIVATE_KEY_PATH)
  ssh_private_key = file(var.SSH_PRIVATE_KEY_PATH)
  ip_address      = var.IP_ADDRESS

  # Module-derived values (always synced when this module is invoked)
  tenancy_ocid          = var.TENANCY_OCID
  region                = var.REGION
  vault_ocid            = module.core.vault_id
  vault_key_id          = module.core.vault_key_id
  vault_crypto_endpoint = module.core.vault_crypto_endpoint
  os_namespace          = module.core.os_namespace
  instance_public_ips   = { for k, v in module.core.instances : k => v.public_ip }
  database_ids          = module.core.database_ids

  # Project-specific extras (merged on top)
  extra_secrets = {
    GOOGLE_CLIENT_ID = var.GOOGLE_CLIENT_ID
  }
}
```

See [`examples/with-auth0-and-github/`](examples/with-auth0-and-github/) for the full working example with all four modules wired together.

## Migrating from `enable_*` flags

Earlier versions of this module exposed `enable_cloudflare`, `enable_auth0`, and `enable_github` toggles in the root. Those are gone — addons are now opt-in via separate `module` calls. To migrate:

| Before | After |
|--------|-------|
| `module "infra" { enable_cloudflare = true; cloudflare_api_token = ...; ... }` | `module "core" { ... }` + `module "cloudflare" { source = ".//modules/cloudflare"; vcn_id = module.core.vcn_id; ... }` |
| `module "infra" { enable_auth0 = true; auth0_api_audience = ...; ... }` | `module "core" { ... }` + `module "auth0" { source = ".//modules/auth0"; auth0_api_audience = ...; ... }` |
| `module "infra" { enable_github = true; github_owner = ...; oci_user_ocid = ...; ... }` | `module "core" { ... }` + `module "github_secrets" { source = ".//modules/github"; github_owner = ...; oci_user_ocid = ...; vault_ocid = module.core.vault_id; ... }` |

The provider configuration moves outside the `module "core"` call. You only configure providers for addons you actually invoke.

## Core Module

### Inputs

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `tenancy_ocid` | string | required | OCI tenancy OCID |
| `region` | string | required | OCI region (e.g. `us-ashburn-1`) |
| `ssh_public_key` | string | required | SSH public key content for instance access |
| `instances` | map(object) | one default instance | Map of ARM instances. See below. |
| `databases` | map(object) | `{}` | Map of ATP databases. Key drives resource naming. |
| `bucket_name` | string | `""` | Object Storage bucket name. Empty = skip. |
| `arm_shape` | string | `"VM.Standard.A1.Flex"` | ARM compute shape |
| `project_name` | string | `"app"` | Project name used in resource display names |

### Instance configuration

Each instance in the `instances` map accepts:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `ocpus` | number | required | ARM OCPUs for this instance |
| `memory_gb` | number | required | Memory in GB |
| `boot_volume_gb` | number | `50` | Boot volume size |
| `block_volume_gb` | number | `0` | Block volume size (0 = none) |
| `app_port` | number | `8080` | Application port |
| `app_user` | string | `"opc"` | OS user for the app |
| `workspace_path` | string | `"/var/workspace"` | Block volume mount path |
| `extra_packages` | list(string) | `[]` | Additional dnf packages |
| `extra_cloud_init` | string | `""` | Additional cloud-init commands |
| `behind_lb` | bool | `true` | Hint for the cloudflare addon — set `false` if you don't plan to add the LB or this instance shouldn't be backed |

**Free tier limits:** Total OCPUs across all instances must not exceed 4. Total memory must not exceed 24GB.

### Outputs

| Name | Description |
|------|-------------|
| `instances` | Map of instance IDs, public IPs, private IPs |
| `ssh_commands` | Map of SSH commands per instance |
| `vcn_id` / `public_subnet_id` / `private_subnet_id` | Wire these into the cloudflare addon |
| `database_ids` / `database_connection_urls` / `db_region_host` | Database references |
| `database_admin_passwords` / `database_wallet_passwords` | (sensitive) |
| `vault_id` / `vault_crypto_endpoint` / `vault_key_id` | Wire these into the github addon |
| `os_namespace` | Object Storage namespace (S3-compatible endpoint suffix) |
| `bucket_name` | Bucket name (null if `bucket_name = ""`) |

## Addon Modules

### Cloudflare (`modules/cloudflare`)

Provisions an OCI Load Balancer fronted by Cloudflare with origin CA certificate, NSG restricted to Cloudflare IPv4/IPv6 ranges, DNS records, and strict SSL.

**Provider:** consumer must configure `provider "cloudflare" { api_token = ... }`.

**Inputs:**

| Variable | Type | Notes |
|----------|------|-------|
| `tenancy_ocid` | string | from `var.tenancy_ocid` |
| `project_name` | string | from `var.project_name` |
| `vcn_id` | string | from `module.core.vcn_id` |
| `public_subnet_id` | string | from `module.core.public_subnet_id` |
| `instances` | map(object{app_port, behind_lb}) | filter / shape from `module.core.instances` |
| `instance_private_ips` | map(string) | from `{ for k, v in module.core.instances : k => v.private_ip }` |
| `domain_name` | string | apex domain on Cloudflare |
| `cloudflare_zone_id` | string | Cloudflare zone for DNS records |
| `dns_records` | list(string) | DNS records to create |
| `cloudflare_ipv4` / `cloudflare_ipv6` | list(string) | NSG ranges; sane defaults included |

**Outputs:** `load_balancer_ip`, `load_balancer_id`.

### Auth0 (`modules/auth0`)

Creates SPA + M2M clients, API resource server with admin scope, admin/user roles, post-login JWT action, and optional admin role auto-assignment.

**Provider:** consumer must configure `provider "auth0" { domain = ...; client_id = ...; client_secret = ... }`.

**Inputs:**

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `auth0_api_audience` | string | required | API identifier (audience claim) |
| `auth0_jwt_namespace` | string | required | Custom-claim namespace prefix injected into JWTs. Must match what your backend reads. |
| `auth0_callback_urls` | list(string) | `[]` | Allowed callback / logout / web-origin URLs |
| `auth0_admin_user_id` | string | `""` | Auth0 user_id auto-assigned the `admin` role. Empty = skip. |
| `auth0_spa_name` / `auth0_m2m_name` / `auth0_api_name` | string | sensible defaults | Display names |

**Outputs:** `spa_client_id` (sensitive), `m2m_client_id` (sensitive), `api_audience`.

The post-login action requires verified email and injects `<namespace>/email`, `<namespace>/name`, and `<namespace>/roles` into both access and ID tokens. Two roles are created: `admin` (with `admin:access` scope on the API) and `user`.

### GitHub Actions secret sync (`modules/github`)

Pushes module-derived values + caller-supplied credentials into a GitHub repo's Actions secrets so CI pipelines can authenticate to OCI and use deployed infrastructure.

**Provider:** consumer must configure `provider "github" { owner = ...; token = ... }`.

**Inputs:**

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `github_owner` / `github_repo` | string | required | Target repo |
| `extra_secrets` | map(string) (sensitive) | `{}` | Additional secrets, keyed by secret name |
| `oci_user_ocid` / `oci_fingerprint` / `oci_private_key` | string (sensitive) | `""` | OCI auth, synced as `OCI_*` |
| `ssh_private_key` / `ssh_public_key` | string (sensitive) | `""` | Synced as `SSH_*` |
| `ip_address` | string | `""` | CI runner / dev CIDR. Synced as `IP_ADDRESS`. |
| `cloudflare_api_token` / `cloudflare_zone_id` / `domain_name` | string | `""` | Synced as `CLOUDFLARE_*` / `DOMAIN_NAME` |
| `auth0_domain` / `auth0_client_id` / `auth0_client_secret` / `auth0_m2m_client_id` / `auth0_m2m_client_secret` / `auth0_admin_user_id` | string | `""` | Synced as the matching uppercase secret names |
| `tenancy_ocid` / `region` | string | required | Synced as `OCI_TENANCY_OCID` / `OCI_REGION` |
| `vault_ocid` / `vault_key_id` / `vault_crypto_endpoint` | string | required | From `module.core.*` |
| `os_namespace` | string | required | From `module.core.os_namespace` |
| `instance_public_ips` | map(string) | `{}` | From `module.core.instances` (key → public_ip). Synced as `<UPPERCASE_KEY>_IP`. |
| `database_ids` | map(string) | `{}` | From `module.core.database_ids`. Synced as `<UPPERCASE_KEY>_DB_OCID`. |

**Auto-derived secrets** (always set when this module is invoked):

| Secret | Source |
|--------|--------|
| `OCI_TENANCY_OCID` / `OCI_REGION` | passthrough from inputs |
| `<NAME>_IP` | one per instance, e.g. `APP_IP`, `WORKER_IP` |
| `<KEY>_DB_OCID` | one per database, e.g. `MAIN_DB_OCID`, `AGENT_DB_OCID` |
| `VAULT_OCID` / `VAULT_KEY_ID` / `VAULT_CRYPTO_ENDPOINT` | OCI Vault outputs |
| `OCI_OS_NAMESPACE` | Object Storage namespace |
| `GH_OWNER` / `GH_REPO` | from `github_owner` / `github_repo` (`GITHUB_*` is reserved by Actions) |

## Free Tier Limits

| Resource | Spec |
|----------|------|
| ARM Instances | 4 OCPU / 24GB total (split across instances) |
| Boot + Block Volume | 200GB total |
| Load Balancer | 1 flexible, 10 Mbps (only if you use the cloudflare addon) |
| Autonomous DB | 2 instances, 20GB each |
| OCI Vault | 20 key versions, 150 secrets |
| Object Storage | 10GB |
