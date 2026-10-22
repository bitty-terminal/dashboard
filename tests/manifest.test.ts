/**
 * Manifest and README contract checks for bitty-terminal.dashboard.
 *
 * The authoritative manifest validator and README checker come from the
 * pinned bitty-plugin-sdk commit. This test asserts the plugin-specific
 * invariants the dashboard promises: exactly two least-privilege grants, one
 * lazy command, three observation events, and a README that matches the SDK
 * user-documentation contract.
 */

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  checkPluginReadme,
  lintManifestSource,
  loadManifestModel,
} from "bitty-plugin-sdk";

const manifestSource = readFileSync("bitty-plugin.toml", "utf8");
const readmeSource = readFileSync("README.md", "utf8");

describe("bitty-plugin.toml", () => {
  test("passes the accepted manifest validator", () => {
    const result = lintManifestSource(manifestSource);
    const errors = result.diagnostics.filter(
      (entry) => entry.severity === "error",
    );
    expect(errors).toEqual([]);
  });

  test("declares the dashboard identity and 0.0.26 compatibility floor", () => {
    const model = loadManifestModel(manifestSource);
    expect(model.pluginId).toBe("bitty-terminal.dashboard");
    expect(model.name).toBe("Dashboard");
    expect(model.version).toBe("0.0.1");
    expect(model.pluginApiRange).toBe("^1.0");
    expect(manifestSource).toContain('bitty = ">=0.0.26"');
    // Minimum-only: a declared ceiling would reject newer compatible hosts.
    expect(manifestSource).not.toMatch(/bitty = ">=0\.0\.26,/);
  });

  test("requests exactly the two least-privilege grants", () => {
    const model = loadManifestModel(manifestSource);
    expect([...model.capabilities].sort()).toEqual([
      "runtime.inspect",
      "ui.overlay.focus",
    ]);
  });

  test("never requests write, focus-capture, process, or filesystem authority", () => {
    const model = loadManifestModel(manifestSource);
    for (const forbidden of [
      "config.manage",
      "runtime.configure",
      "runtime.plugin-manage",
      "terminal.input.all",
      "terminal.raw-read",
      "clipboard.write",
      "process.spawn",
      "network.connect",
    ]) {
      expect(model.capabilities).not.toContain(forbidden);
    }
    expect(manifestSource).not.toContain("[[capabilities.filesystem]]");
  });

  test("reserves one lazy command and the three observation events", () => {
    const model = loadManifestModel(manifestSource);
    expect([...model.commands]).toEqual([
      "bitty-terminal.dashboard:toggle_dashboard",
    ]);
    expect([...model.events].sort()).toEqual([
      "focus.changed",
      "overlay.input.available",
      "overlay.released",
    ]);
  });

  test("declares no settings and no provided services", () => {
    const model = loadManifestModel(manifestSource);
    expect(model.hasSettingsTable).toBe(false);
    expect(model.settings.size).toBe(0);
    expect(model.providedServices.size).toBe(0);
    expect(model.requiredServices.size).toBe(0);
  });
});

describe("README", () => {
  test("matches the SDK user-documentation contract", () => {
    const result = checkPluginReadme({
      manifestSource,
      readmeSource,
    });
    expect([...result.diagnostics]).toEqual([]);
    expect(result.valid).toBe(true);
  });

  test("states that settings editing is deferred", () => {
    expect(readmeSource).toContain("config.manage");
    expect(readmeSource).toContain("#2393");
  });
});
