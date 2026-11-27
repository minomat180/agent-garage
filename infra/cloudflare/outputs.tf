# Non-secret values the host module needs (written to outputs.json next to
# the site by `./garage-cf export`).
output "public" {
  description = "Tunnel id and the Access AUD tag of each bay (not secret)."
  value = {
    tunnel_id = cloudflare_zero_trust_tunnel_cloudflared.garage.id
    bays = {
      for name, app in cloudflare_zero_trust_access_application.bay :
      name => { aud = app.aud }
    }
  }
}

# cloudflared credentials file. Only ever piped by `./garage-cf install-credentials`
# into a root-only file; never print it.
output "tunnel_credentials" {
  description = "cloudflared tunnel credentials JSON (secret)."
  sensitive   = true
  value = jsonencode({
    AccountTag   = var.garage.account_id
    TunnelID     = cloudflare_zero_trust_tunnel_cloudflared.garage.id
    TunnelSecret = random_bytes.tunnel_secret.base64
  })
}
