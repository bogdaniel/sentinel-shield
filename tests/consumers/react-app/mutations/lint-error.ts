// MUTATION FIXTURE — ESLint fault (reason code ESLINT_ERROR). Overlaid into src/
// by the validation driver. Declares an unused binding that trips
// @typescript-eslint/no-unused-vars (error). tsconfig has no noUnusedLocals, so
// tsc stays clean and this isolates the lint gate.
export function lintOffender(): number {
  const unusedFinding = 42;
  return 7;
}
