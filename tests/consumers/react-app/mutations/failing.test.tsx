// MUTATION FIXTURE — test fault (reason code TEST_FAIL). Overlaid into src/ by the
// validation driver. A deliberately wrong assertion makes `vitest run` exit
// non-zero.
import { severityWeight } from "./Badge.js";

describe("injected failing test", () => {
  it("asserts a weight that is intentionally wrong", () => {
    expect(severityWeight("low")).toBe(999);
  });
});
