terraform {
  required_version = ">= 1.0"

  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}

variable "agent_id" {
  type        = string
  description = "The ID of a Coder agent."
}

variable "wpilib_year" {
  type        = string
  description = "WPILib season. Selects the software-rendering environment for the sim GUI: 2026 uses GLFW/OpenGL3 (Mesa llvmpipe), 2027+ additionally forces the SDL 2D renderer."
  default     = "2026"

  validation {
    condition     = can(regex("^20[0-9]{2}$", var.wpilib_year))
    error_message = "wpilib_year must be a four-digit year, e.g. \"2026\"."
  }
}

variable "port" {
  type        = number
  description = "Port for the KasmVNC websocket. In a shared network namespace this must be unique per workspace — pass a per-workspace random port (e.g. random_integer between 11000 and 65535). The X display number is derived from it (port - 10000)."
  default     = 16800

  validation {
    condition     = var.port > 10000 && var.port < 65536
    error_message = "port must be between 10001 and 65535 (the X display number is port - 10000)."
  }
}

variable "resolution" {
  type        = string
  description = "VNC screen resolution, WIDTHxHEIGHT. 1280x720 matches the sim GUI's native default size — larger costs CPU."
  default     = "1280x720"

  validation {
    condition     = can(regex("^[0-9]{3,4}x[0-9]{3,4}$", var.resolution))
    error_message = "resolution must look like 1280x720."
  }
}

variable "sim_fps" {
  type        = number
  description = "Frame rate preseeded into each robot project's simgui-window.json. The WPILib default of 120 pegs a software-rendered CPU; 30 measured at ~82% of one core."
  default     = 30
}

variable "max_frame_rate" {
  type        = number
  description = "KasmVNC encoder max frame rate."
  default     = 24
}

variable "jpeg_quality_min" {
  type        = number
  description = "KasmVNC minimum JPEG quality (0-9). Low values save CPU on frequently-changing regions."
  default     = 3
}

variable "jpeg_quality_max" {
  type        = number
  description = "KasmVNC maximum JPEG quality (0-9)."
  default     = 6
}

variable "enable_clipboard" {
  type        = bool
  description = "Allow clipboard transfer between the VNC session and the browser. Off by default: the session runs a single GUI with no text surfaces worth pasting into."
  default     = false
}

variable "kasm_version" {
  type        = string
  description = "KasmVNC version to install when not already present in the image."
  default     = "1.5.0"
}

variable "projects_dir" {
  type        = string
  description = "Directory scanned for robot projects (containing .wpilib/wpilib_preferences.json) to preseed sim frame-rate settings into."
  default     = "$HOME/projects"
}

variable "order" {
  type        = number
  description = "The order determines the position of the app in the UI presentation. The lowest order is shown first and apps with equal order are sorted by name (ascending order)."
  default     = null
}

variable "group" {
  type        = string
  description = "The name of a group that this app belongs to."
  default     = null
}

variable "share" {
  type    = string
  default = "owner"

  validation {
    condition     = var.share == "owner" || var.share == "authenticated" || var.share == "public"
    error_message = "Incorrect value. Please set either 'owner', 'authenticated', or 'public'."
  }
}

variable "subdomain" {
  type        = bool
  description = "Is subdomain sharing enabled in your cluster?"
  default     = true
}

locals {
  # One X display per workspace: display numbers become abstract unix sockets
  # (@/tmp/.X11-unix/XN) which live in the *network* namespace. Workspaces that
  # share a netns (network_mode = "container:...") would collide on a fixed
  # number, so derive it from the (per-workspace) port.
  display_number = var.port - 10000
  vnc_user       = "coder"
}

# Basic-auth credential for the VNC endpoint. In a shared network namespace,
# 127.0.0.1 is reachable from every sibling workspace — a random port alone is
# obscurity, not authentication.
resource "random_password" "vnc" {
  length  = 24
  special = false
}

resource "coder_env" "display" {
  agent_id = var.agent_id
  name     = "DISPLAY"
  value    = ":${local.display_number}"
}

resource "coder_env" "libgl_software" {
  agent_id = var.agent_id
  name     = "LIBGL_ALWAYS_SOFTWARE"
  value    = "1"
}

resource "coder_env" "gallium_driver" {
  agent_id = var.agent_id
  name     = "GALLIUM_DRIVER"
  value    = "llvmpipe"
}

# 2027+ wpigui prefers SDL_GPU (Vulkan); force the SDL 2D renderer instead —
# software Vulkan is not viable on a 2-vCPU box. Harmless if set alongside 2026.
resource "coder_env" "wpigui_force_renderer" {
  count    = tonumber(var.wpilib_year) >= 2027 ? 1 : 0
  agent_id = var.agent_id
  name     = "WPIGUI_FORCE_RENDERER"
  value    = "2d"
}

resource "coder_env" "vnc_password" {
  agent_id = var.agent_id
  name     = "CODER_WPILIB_SIM_PASSWORD"
  value    = random_password.vnc.result
}

resource "coder_script" "wpilib_sim" {
  agent_id     = var.agent_id
  display_name = "WPILib Simulator"
  icon         = "https://raw.githubusercontent.com/wpilibsuite/allwpilib/main/wpiutil/src/main/native/resources/wpilib-128.png"
  run_on_start = true
  script = templatefile("${path.module}/run.sh", {
    PORT             = var.port
    DISPLAY_NUMBER   = local.display_number
    RESOLUTION       = var.resolution
    SIM_FPS          = var.sim_fps
    MAX_FRAME_RATE   = var.max_frame_rate
    JPEG_MIN         = var.jpeg_quality_min
    JPEG_MAX         = var.jpeg_quality_max
    ENABLE_CLIPBOARD = var.enable_clipboard ? "true" : "false"
    KASM_VERSION     = var.kasm_version
    VNC_USER         = local.vnc_user
    PROJECTS_DIR     = var.projects_dir
    SUBDOMAIN        = tostring(var.subdomain)
    PATH_VNC_HTML    = var.subdomain ? "" : file("${path.module}/path_vnc.html")
  })
}

resource "coder_app" "wpilib_sim" {
  agent_id     = var.agent_id
  slug         = "wpilib-sim"
  display_name = "WPILib Simulator"
  url          = "http://localhost:${var.port}"
  icon         = "https://raw.githubusercontent.com/wpilibsuite/allwpilib/main/wpiutil/src/main/native/resources/wpilib-128.png"
  subdomain    = var.subdomain
  share        = var.share
  order        = var.order
  group        = var.group

  healthcheck {
    # Every kasm endpoint requires basic auth; embed the credential so the
    # agent's probe passes. It is already in state via random_password.
    url       = "http://${local.vnc_user}:${random_password.vnc.result}@localhost:${var.port}/app"
    interval  = 5
    threshold = 5
  }
}

output "vnc_port" {
  value       = var.port
  description = "KasmVNC websocket port."
}

output "display" {
  value       = ":${local.display_number}"
  description = "X display the sim renders to."
}
