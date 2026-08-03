run "defaults" {
  command = plan

  variables {
    agent_id = "test-agent-id"
  }

  assert {
    condition     = resource.coder_app.wpilib_sim.url == "http://localhost:16800"
    error_message = "App URL should use the default port"
  }

  assert {
    condition     = resource.coder_app.wpilib_sim.slug == "wpilib-sim"
    error_message = "App slug should be wpilib-sim"
  }

  assert {
    condition     = resource.coder_env.display.value == ":6800"
    error_message = "DISPLAY should be derived as port - 10000"
  }

  assert {
    condition     = length(resource.coder_env.wpigui_force_renderer) == 0
    error_message = "2026 must not force the SDL 2D renderer"
  }
}

run "custom_port_drives_display" {
  command = plan

  variables {
    agent_id = "test-agent-id"
    port     = 23456
  }

  assert {
    condition     = resource.coder_app.wpilib_sim.url == "http://localhost:23456"
    error_message = "App URL should use the configured port"
  }

  assert {
    condition     = resource.coder_env.display.value == ":13456"
    error_message = "DISPLAY must follow the configured port"
  }
}

run "year_2027_forces_2d_renderer" {
  command = plan

  variables {
    agent_id    = "test-agent-id"
    wpilib_year = "2027"
  }

  assert {
    condition     = length(resource.coder_env.wpigui_force_renderer) == 1
    error_message = "2027 must force the SDL 2D renderer"
  }
}

run "rejects_low_port" {
  command = plan

  variables {
    agent_id = "test-agent-id"
    port     = 6800
  }

  expect_failures = [
    var.port,
  ]
}

run "rejects_bad_resolution" {
  command = plan

  variables {
    agent_id   = "test-agent-id"
    resolution = "big"
  }

  expect_failures = [
    var.resolution,
  ]
}

run "rejects_bad_year" {
  command = plan

  variables {
    agent_id    = "test-agent-id"
    wpilib_year = "26"
  }

  expect_failures = [
    var.wpilib_year,
  ]
}

run "custom_credentials" {
  command = plan

  variables {
    agent_id     = "test-agent-id"
    vnc_username = "student1"
    vnc_password = "hunter42"
  }

  assert {
    condition     = anytrue([for h in resource.coder_app.wpilib_sim.healthcheck : strcontains(h.url, "student1:hunter42@")])
    error_message = "Healthcheck must use the supplied credentials"
  }
}

run "rejects_short_password" {
  command = plan

  variables {
    agent_id     = "test-agent-id"
    vnc_password = "abc"
  }

  expect_failures = [
    var.vnc_password,
  ]
}

# Auth off must reach the script (so -DisableBasicAuth is applied) and must strip
# the credentials from the healthcheck URL, or the probe would send basic-auth
# headers to an endpoint that no longer expects them.
run "auth_can_be_disabled" {
  variables {
    agent_id = "test"
    port     = 12345
    vnc_auth = false
  }

  assert {
    condition     = strcontains(coder_script.wpilib_sim.script, "VNC_AUTH=\"false\"")
    error_message = "VNC_AUTH=false must be templated into run.sh"
  }

  assert {
    condition     = one([for h in coder_app.wpilib_sim.healthcheck : h.url]) == "http://localhost:12345/app"
    error_message = "healthcheck must drop embedded credentials when auth is disabled"
  }
}

run "auth_on_by_default" {
  variables {
    agent_id = "test"
    port     = 12345
  }

  assert {
    condition     = strcontains(coder_script.wpilib_sim.script, "VNC_AUTH=\"true\"")
    error_message = "auth must default to on"
  }
}
