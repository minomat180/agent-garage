# Cloudflare side of agent-garage (docs/design.md sections 2, 5, 6): one locally
# managed tunnel, and per public bay an Access application with exactly one
# Allow policy and a proxied CNAME to the tunnel.
#
# Not managed here (dashboard, on purpose): the GitLab identity provider (its
# client secret would land in the state) and the organisation settings
# (team domain, allowed MFA methods).

provider "cloudflare" {
  # Token from the environment (CLOUDFLARE_API_TOKEN), set by ./garage-cf.
}

locals {
  account_id = var.garage.account_id
}

data "cloudflare_zone" "garage" {
  filter = {
    name = var.garage.zone
  }
}

# Referenced, not managed. Fails the plan if the id is not a generic OIDC IdP.
data "cloudflare_zero_trust_access_identity_provider" "gitlab" {
  account_id           = local.account_id
  identity_provider_id = var.garage.identity_provider_id

  lifecycle {
    postcondition {
      condition     = self.type == "oidc"
      error_message = "The garage identity provider must be the generic OIDC (GitLab) provider."
    }
  }
}

# ------------------------------------------------------------------ tunnel

# 32 random bytes; cloudflared proves the tunnel identity with it. Lives only
# in the (local, mode 600) state and the root-only credentials file.
resource "random_bytes" "tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "garage" {
  account_id    = local.account_id
  name          = "agent-garage"
  config_src    = "local"
  tunnel_secret = random_bytes.tunnel_secret.base64
}

# ------------------------------------------------------------------ access

resource "cloudflare_zero_trust_access_policy" "bay" {
  for_each = var.garage.bays

  account_id = local.account_id
  name       = "garage ${each.key}: allowed GitLab users"
  decision   = "allow"

  # OR over the bay's users: OIDC claim "sub" (numeric GitLab user id, never
  # reused or renamed) from the GitLab provider. Nothing else.
  include = [
    for sub in each.value.gitlab_subs : {
      oidc = {
        claim_name           = "sub"
        claim_value          = sub
        identity_provider_id = data.cloudflare_zero_trust_access_identity_provider.gitlab.id
      }
    }
  ]
}

resource "cloudflare_zero_trust_access_application" "bay" {
  for_each = var.garage.bays

  account_id = local.account_id
  name       = "garage ${each.key}"
  type       = "self_hosted"
  destinations = [
    {
      type = "public"
      uri  = each.value.hostname
    }
  ]

  allowed_idps              = [data.cloudflare_zero_trust_access_identity_provider.gitlab.id]
  auto_redirect_to_identity = true
  session_duration          = var.garage.session_duration
  app_launcher_visible      = false

  # Independent MFA, phishing resistant only (passkey / security key).
  mfa_config = {
    mfa_disabled           = false
    allowed_authenticators = ["biometrics", "security_key"]
    session_duration       = var.garage.session_duration
  }

  http_only_cookie_attribute = true
  # Strict would drop the cookie on the redirect back from the login page.
  same_site_cookie_attribute  = "lax"
  allow_authenticate_via_warp = false
  options_preflight_bypass    = false
  service_auth_401_redirect   = false

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.bay[each.key].id
      precedence = 1
    }
  ]
}

# --------------------------------------------------------------------- dns

# If the zone has a wildcard record, this explicit record takes precedence.
resource "cloudflare_dns_record" "bay" {
  for_each = var.garage.bays

  zone_id = data.cloudflare_zone.garage.zone_id
  name    = each.value.hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.garage.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "agent-garage bay ${each.key} (managed by OpenTofu)"
}

# ------------------------------------------------------------ app launcher

# Users enroll their passkey at <team>.cloudflareaccess.com/AddMfaDevice, which
# is part of the App Launcher; without a launcher application that page only
# says "contact your administrator". Same users as the bays (union of the bay
# policies), GitLab only, no MFA here (Cloudflare requires the launcher to be
# reachable without MFA for the first enrollment; adding further devices needs
# an existing one). The bays themselves stay hidden from the launcher.
resource "cloudflare_zero_trust_access_application" "launcher" {
  account_id = local.account_id
  name       = "App Launcher" # Cloudflare fixes this name for the launcher
  type       = "app_launcher"

  allowed_idps              = [data.cloudflare_zero_trust_access_identity_provider.gitlab.id]
  auto_redirect_to_identity = true
  session_duration          = var.garage.session_duration

  policies = [
    for i, name in sort(keys(var.garage.bays)) : {
      id         = cloudflare_zero_trust_access_policy.bay[name].id
      precedence = i + 1
    }
  ]
}

# -------------------------------------------------------------------- hsts

# HSTS on the bay hostnames only (docs/design.md section 6, A04): once a browser has
# seen it, it refuses to click through a certificate error on these hosts
# (e.g. a TLS-intercepting proxy). No includeSubDomains and no preload: other
# hosts in the zone are not affected. This resource owns the zone's whole
# http_response_headers_transform entrypoint; add other response header rules
# here, not in the dashboard (an apply would remove them).
resource "cloudflare_ruleset" "hsts" {
  count = length(var.garage.bays) > 0 ? 1 : 0

  zone_id     = data.cloudflare_zone.garage.zone_id
  name        = "agent-garage response headers"
  description = "HSTS on the agent-garage bay hostnames (managed by OpenTofu)"
  kind        = "zone"
  phase       = "http_response_headers_transform"

  rules = [
    {
      ref         = "garage_hsts"
      description = "agent-garage: HSTS on the bay hostnames"
      enabled     = true
      expression = format("http.host in {%s}", join(" ", [
        for h in sort([for b in values(var.garage.bays) : b.hostname]) : jsonencode(h)
      ]))
      action = "rewrite"
      action_parameters = {
        headers = {
          "Strict-Transport-Security" = {
            operation = "set"
            value     = "max-age=31536000"
          }
        }
      }
    }
  ]
}
