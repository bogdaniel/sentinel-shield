// Clean, strict-typed baseline. Passes tsc --noEmit, eslint ., and vitest run.
export interface RiskInput {
  readonly critical: number;
  readonly high: number;
}

/**
 * Compute a simple weighted risk score. Pure, deterministic, fully typed.
 */
export function riskScore(input: RiskInput): number {
  return input.critical * 10 + input.high * 3;
}

export function isBlocking(input: RiskInput): boolean {
  return riskScore(input) >= 10;
}
