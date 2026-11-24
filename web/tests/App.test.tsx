import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { App } from "../src/App.js";

describe("App placeholder", () => {
  it("renders the placeholder view", () => {
    const html = renderToStaticMarkup(<App />);
    expect(html).toContain("Agent Workstation");
    expect(html).toContain("not usable yet");
  });
});
