// MUTATION FIXTURE — test fault. Overlaid into src/ by the validation driver to
// prove the test gate fails with reason code TEST_FAIL. A deliberately false
// assertion makes `vitest run` exit non-zero.
import { describe, it, expect } from "vitest";
import { riskScore } from "./index.js";

describe("injected failing test", () => {
  it("asserts a value that is intentionally wrong", () => {
    expect(riskScore({ critical: 0, high: 0 })).toBe(999);
  });
});
