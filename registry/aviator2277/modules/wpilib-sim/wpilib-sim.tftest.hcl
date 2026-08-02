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
