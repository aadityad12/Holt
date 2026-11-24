import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { findViolations, isExemptPath, parseMarkers } from "../check-attribution.mjs";

const markersPath = resolve(fileURLToPath(new URL("../ai-markers.txt", import.meta.url)));
const markers = parseMarkers(readFileSync(markersPath, "utf8"));

describe("check-attribution", () => {
  it("loads plain and co-author markers from scripts/ai-markers.txt", () => {
    assert.ok(markers.plain.includes("generated with"));
    assert.ok(markers.plain.includes("🤖"));
    for (const expected of [
      "claude",
      "anthropic",
      "openai",
      "codex",
      "copilot",
      "cursor",
      "gemini",
      "kiro",
      "grok",
      "noreply@anthropic.com",
    ]) {
      assert.ok(markers.coAuthor.includes(expected), `missing marker ${expected}`);
    }
  });

  it("rejects AI co-author trailers case-insensitively", () => {
    const violations = findViolations(
      "Add feature\n\nCo-Authored-By: Claude <noreply@anthropic.com>",
      markers,
      { source: "commit abc123" },
    );
    assert.equal(violations.length, 1);
  });

  it("allows human co-author trailers", () => {
    const violations = findViolations(
      "Add feature\n\nCo-Authored-By: Jane Doe <jane@example.com>",
      markers,
      { source: "commit abc123" },
    );
    assert.deepEqual(violations, []);
  });

  it("rejects Generated with lines and robot emoji", () => {
    const generated = findViolations("Generated with Example Tool", markers, {
      source: "PR body",
    });
    assert.equal(generated.length, 1);

    const robot = findViolations("Ship it 🤖", markers, { source: "PR title" });
    assert.equal(robot.length, 1);
  });

  it("allows documentation mentioning Claude Code and Codex without attribution", () => {
    const violations = findViolations(
      "The server manages long-lived Claude Code and Codex sessions.",
      markers,
      { source: "README.md" },
    );
    assert.deepEqual(violations, []);
  });

  it("exempts the checker, marker list, test directories, and fixtures", () => {
    assert.equal(isExemptPath("scripts/check-attribution.mjs"), true);
    assert.equal(isExemptPath("scripts/ai-markers.txt"), true);
    assert.equal(isExemptPath("server/tests/example.test.ts"), true);
    assert.equal(isExemptPath("web/src/test-utils/sample.ts"), true);
    assert.equal(isExemptPath("shared/fixtures/commit.txt"), true);

    assert.equal(isExemptPath("README.md"), false);
    assert.equal(isExemptPath("server/src/index.ts"), false);
    assert.equal(isExemptPath("web/src/App.tsx"), false);
  });
});
