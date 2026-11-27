# All inputs come from the Nix side (lib.tofuVars in flake.nix applied to the
# site, see examples/site/site.nix), passed by ./garage-cf as TF_VAR_garage.
# Adding a public bay is a site entry, never an edit here.
variable "garage" {
  description = "Cloudflare constants and the public bays (lib.tofuVars of the site)."
  type = object({
    account_id           = string
    zone                 = string
    team_name            = string
    identity_provider_id = string
    session_duration     = string
    bays = map(object({
      hostname    = string
      gitlab_subs = list(string)
    }))
  })

  validation {
    condition = alltrue([
      for name, b in var.garage.bays :
      can(regex("^[a-z][a-z0-9-]{1,30}$", name))
      && endswith(b.hostname, ".${var.garage.zone}")
      && length(b.gitlab_subs) > 0
      && alltrue([for s in b.gitlab_subs : can(regex("^[0-9]{1,12}$", s))])
    ])
    error_message = "Each bay needs a valid name, a hostname in the zone and at least one numeric GitLab user id."
  }
}
