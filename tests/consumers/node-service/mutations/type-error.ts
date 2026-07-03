// MUTATION FIXTURE — TS compile fault. Overlaid into src/ by the validation
// driver to prove the typecheck gate fails with reason code TS_COMPILE_FAIL.
// A string is assigned to a number: TypeScript error TS2322. ESLint stays clean,
// so this isolates the typecheck gate.
export const brokenScore: number = "not-a-number";
