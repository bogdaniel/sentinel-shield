// Flat ESLint config (ESLint 9) for the React consumer. Baseline lints src/ and
// MUST pass clean. mutations/ (intentional-defect fixtures) is ignored so only the
// validation driver's injected fault trips the lint gate.
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
