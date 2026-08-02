import { describe, expect, it } from "bun:test";
import {
  findResourceInstance,
  runTerraformApply,
  runTerraformInit,
  testRequiredVariables,
} from "~test";

describe("wpilib-sim", () => {
  it("should init successfully", async () => {
    await runTerraformInit(import.meta.dir);
  });

  testRequiredVariables(import.meta.dir, {
    agent_id: "test-agent",
  });

  it("applies with defaults and wires the app to the port", async () => {
    const state = await runTerraformApply(import.meta.dir, {
      agent_id: "test-agent",
    });
    const app = findResourceInstance(state, "coder_app");
    expect(app.slug).toBe("wpilib-sim");
    expect(app.display_name).toBe("WPILib Simulator");
    expect(app.url).toBe("http://localhost:16800");
    expect(app.healthcheck[0].url).toContain("@localhost:16800/app");
  });

  it("derives DISPLAY from the port", async () => {
    const state = await runTerraformApply(import.meta.dir, {
      agent_id: "test-agent",
      port: "23456",
    });
    expect(state.outputs.display.value).toBe(":13456");
  });

  it("keeps the credential out of the script body", async () => {
    const state = await runTerraformApply(import.meta.dir, {
      agent_id: "test-agent",
    });
    const script = findResourceInstance(state, "coder_script");
    const password = state.resources
      .find((r) => r.type === "random_password")
      ?.instances[0]?.attributes.result as string;
    expect(password).toBeTruthy();
    expect(script.script).not.toContain(password);
  });

  it("sets the software-rendering environment", async () => {
    const state = await runTerraformApply(import.meta.dir, {
      agent_id: "test-agent",
    });
    const envs = state.resources.filter((r) => r.type === "coder_env");
    const names = envs.flatMap((r) =>
      r.instances.map((i) => i.attributes.name),
    );
    expect(names).toContain("DISPLAY");
    expect(names).toContain("LIBGL_ALWAYS_SOFTWARE");
    expect(names).toContain("CODER_WPILIB_SIM_PASSWORD");
    expect(names).not.toContain("WPIGUI_FORCE_RENDERER");
  });

  it("forces the 2d renderer for 2027", async () => {
    const state = await runTerraformApply(import.meta.dir, {
      agent_id: "test-agent",
      wpilib_year: "2027",
    });
    const names = state.resources
      .filter((r) => r.type === "coder_env")
      .flatMap((r) => r.instances.map((i) => i.attributes.name));
    expect(names).toContain("WPIGUI_FORCE_RENDERER");
  });
});
