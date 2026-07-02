// MUTATION FIXTURE — ESLint fault. Overlaid into src/ by the validation driver to
// prove the lint gate fails with reason code ESLINT_ERROR. Declares an unused
// binding that trips @typescript-eslint/no-unused-vars (error). tsconfig does NOT
// set noUnusedLocals, so tsc stays clean and this isolates the lint gate.
export function lintOffender(): number {
  const unusedFinding = 42;
  return 7;
}
