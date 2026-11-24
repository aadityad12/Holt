import { describe, expect, it } from "vitest";
import { createApp, getVersion } from "../src/index.js";

describe("server placeholder", () => {
  it("reports a semver package version", () => {
    expect(getVersion()).toMatch(/^\d+\.\d+\.\d+/);
  });

  it("constructs a Fastify instance", async () => {
    const app = createApp();
    expect(app).toBeDefined();
    await app.close();
  });
});
