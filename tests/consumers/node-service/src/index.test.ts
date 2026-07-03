import { describe, it, expect } from "vitest";
import { riskScore, isBlocking } from "./index.js";

describe("riskScore", () => {
  it("weights critical and high findings", () => {
    expect(riskScore({ critical: 2, high: 1 })).toBe(23);
  });

  it("is zero for a clean input", () => {
    expect(riskScore({ critical: 0, high: 0 })).toBe(0);
  });
});

describe("isBlocking", () => {
  it("blocks when the score reaches the threshold", () => {
    expect(isBlocking({ critical: 1, high: 0 })).toBe(true);
  });

  it("does not block a low score", () => {
    expect(isBlocking({ critical: 0, high: 1 })).toBe(false);
  });
});
