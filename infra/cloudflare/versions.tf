terraform {
  required_version = ">= 1.10"

  # Local state outside the repo; ./garage-cf init sets the path
  # (~/.local/state/agent-garage/tofu/terraform.tfstate).
  backend "local" {}

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.29.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
  }
}
