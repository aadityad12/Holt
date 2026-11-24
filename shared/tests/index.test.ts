import { describe, expect, it } from "vitest";
import { z } from "zod";
import * as shared from "../src/index.js";

describe("shared workspace", () => {
  it("exports an empty barrel module for now", () => {
    expect(Object.keys(shared)).toEqual([]);
  });

  it("validates schemas with zod", () => {
    const schema = z.object({ ok: z.boolean() });
    expect(schema.parse({ ok: true })).toEqual({ ok: true });
  });
});
