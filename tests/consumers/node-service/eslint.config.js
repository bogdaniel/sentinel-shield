// Flat ESLint config (ESLint 9). Baseline lints src/ and MUST pass clean.
// mutations/ holds intentional-defect fixtures the validation driver overlays
// into a throwaway copy of src/; they are ignored here so the committed baseline
// stays green and only the driver's injected fault trips the lint gate.
import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["node_modules/**", "dist/**", "mutations/**", "coverage/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    rules: {
      "no-unused-vars": "off",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
    },
  },
);
