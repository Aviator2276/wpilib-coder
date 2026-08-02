terraform {
  required_version = ">= 1.4"
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

locals {
  username       = data.coder_workspace_owner.me.name
  claude_workdir = "/home/coder/project"
}

variable "docker_socket" {
  default = "" # LOCAL TEST ONLY — prod: tcp://dockersocket:2375
  type    = string
}

variable "authentik_key" {
  default   = ""
  type      = string
  sensitive = true
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# LOCAL TEST ONLY — restore before prod
# locals {
#   api_key = data.coder_parameter.api_key.value
# }

locals {
  # During `coder templates push` the template is imported via a dry-run plan
  # with no workspace-owner context, so the coder provider falls back to its
  # placeholder owner identity ("default@example.com"). A real workspace build
  # always carries the owner's real email. We must skip API-key validation
  # during import (there is no real key yet, only the placeholder default) but
  # enforce it on every real build. Note: start_count is 1 during import too
  # (transition defaults to "start"), and gating on the key value let the
  # placeholder default bypass validation entirely -- neither is a safe gate.
  is_template_import = data.coder_workspace_owner.me.email == "default@example.com"
  has_real_build     = !local.is_template_import
}

# LOCAL TEST ONLY — restore before prod
# data "coder_parameter" "api_key" {
#   name        = "Workspace API Key"
#   description = "To create a workspace, you must provide an API Key. Generate a key here: https://auth.chargingcourses.com/if/user/#/settings"
#   type        = "string"
#   form_type   = "input"
#   default     = "********-****-****-****-************"
#   mutable     = true
#   styling     = jsonencode({
#     mask_input = true
#   })
#   validation {
#     regex = "^[0-9A-F*]{8}-[0-9A-F*]{4}-[0-9A-F*]{4}-[0-9A-F*]{4}-[0-9A-F*]{12}$"
#     error = "Unfortunately, this isn't a valid API Key. Please contact the Administator for additional help."
#   }
# }

# LOCAL TEST ONLY — restore before prod
# data "http" "api_key_validation" {
#   count  = local.has_real_build ? 1 : 0
#   url    = "https://auth.chargingcourses.com/api/v3/flows/executor/coder-api-verify/"
#   method = "POST"
#   request_headers = {
#     "Authorization" = "Bearer ${var.authentik_key}"
#     "content-type"  = "application/json"
#   }
#   request_body = jsonencode({
#     component                    = "ak-stage-prompt"
#     "coder_api-verify-api"        = local.api_key
#     "coder_api-verify-workspace"  = "${lower(data.coder_workspace.me.template_name)}/coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
#   })
#
#   lifecycle {
#     postcondition {
#       condition = jsondecode(self.response_body).component == "xak-flow-redirect"
#       error_message = try(
#         jsondecode(self.response_body).response_errors.non_field_errors[0].string,
#         jsondecode(self.response_body).messages[0].message,
#         "API key validation failed. Please contact the administrator."
#       )
#     }
#   }
# }

# LOCAL TEST ONLY — restore before prod
# resource "terraform_data" "validate_api_key" {
#   count            = local.has_real_build ? 1 : 0
#   triggers_replace = [data.coder_workspace.me.id]
#
#   provisioner "local-exec" {
#     when = create
#     environment = {
#       VALID = try(
#         jsondecode(data.http.api_key_validation[0].response_body).component == "xak-flow-redirect",
#         false
#       )
#       ERROR = try(
#         jsondecode(data.http.api_key_validation[0].response_body).response_errors.non_field_errors[0].string,
#         jsondecode(data.http.api_key_validation[0].response_body).messages[0].message,
#         "Unknown error."
#       )
#     }
#     command    = "[[ \"$VALID\" == \"true\" ]] && echo \"API Key is valid.\" && exit 0 || echo \"$ERROR\" && exit 1"
#     on_failure = fail
#   }
# }

provider "docker" {
  # Defaulting to null if the variable is an empty string lets us have an optional variable without having to set our own default
  host = var.docker_socket != "" ? var.docker_socket : null
}

resource "random_integer" "port" {
  min = 11000
  max = 65535
}

resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = <<-EOT
    set -e

    # Prepare user home with default files on first start.
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi

    # JDK 17 (WPILib 2026 requirement) is baked into the image; the old
    # openjdk-25 install here broke GradleRIO builds and cost minutes per start.
  EOT

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  # You can remove this block if you'd prefer to configure Git manually or using
  # dotfiles. (see docs/dotfiles.md)
  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
  }

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
}

# See https://registry.coder.com/modules/coder/code-server
module "code-server" {
  count        = data.coder_workspace.me.start_count
  source       = "registry.coder.com/coder/code-server/coder"
  version      = "~> 1.0"
  agent_id     = coder_agent.main.id
  order        = 1
  display_name = "VS Code Web"
  folder       = "/home/coder/projects"
  port         = random_integer.port.result

  extensions = [
    "vscode-icons-team.vscode-icons",
    "esbenp.prettier-vscode",
    "ms-toolsai.jupyter",
    "wpilibsuite.vscode-wpilib",
    "moocfi.test-my-code",
    "ms-python.python",
    "vscjava.vscode-java-pack",
  ]
}

resource "coder_app" "github" {
  agent_id     = coder_agent.main.id
  slug         = "chargers-4189-github"
  display_name = "4189 GitHub"
  icon         = "/icon/github.svg"
  url          = "https://github.com/Chargers-4189"
  external     = true
  order        = 2
}

module "git-clone" {
  count       = data.coder_workspace.me.start_count
  source      = "registry.coder.com/coder/git-clone/coder"
  version     = "1.1.1"
  agent_id    = coder_agent.main.id
  url         = "https://github.com/Chargers-4189/frc-java-course"
  folder_name = "frc-java-course"
  base_dir    = "/home/coder/projects"
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  # Protect the volume from being deleted due to changes in attributes.
  lifecycle {
    ignore_changes = all
  }
  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  # This field becomes outdated if the workspace is renamed but can
  # be useful for debugging or cleaning out dangling volumes.
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = "wpilib-workspace:2026" # was codercom/enterprise-base:ubuntu — JDK17/KasmVNC/Mesa/gradle-cache baked in

  # Limit resources
  cpus        = 3
  memory      = 3072
  memory_swap = 3072

  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  #hostname = data.coder_workspace.me.name
  # network_mode = "container:OpenVPN-Client" # LOCAL TEST ONLY — restore before prod
  # Use the docker gateway if the access URL is 127.0.0.1
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env        = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]
  # LOCAL TEST ONLY — restore before prod
  # depends_on = [
  #   terraform_data.validate_api_key,
  #   data.http.api_key_validation,
  # ]

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }

  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}
# ------------------------------------------------------------------------------
# WPILib Simulator (wpilib-sim module)
# Prod: change source to the registry ref once published, e.g.
#   source  = "registry.coder.com/aviator2277/wpilib-sim/coder"
#   version = "1.0.0"
# ------------------------------------------------------------------------------
resource "random_integer" "sim_port" {
  min = 11000
  max = 65535
}

module "wpilib_sim" {
  count    = data.coder_workspace.me.start_count
  source   = "./modules/wpilib-sim" # vendored copy of ../../registry/...; prod: registry/git source
  agent_id = coder_agent.main.id
  port     = random_integer.sim_port.result
  order    = 3
}
