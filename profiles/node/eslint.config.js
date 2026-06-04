// Sentinel Shield — Node.js ESLint flat config (ESLint 9+).
//
// Targets Node 22+, TypeScript, ES modules. Security-focused: pairs
// @typescript-eslint with eslint-plugin-security and eslint-plugin-no-unsanitized.
//
// Install:
//   npm i -D eslint typescript typescript-eslint \
//     eslint-plugin-security eslint-plugin-no-unsanitized globals
//
// This is a starter. Tune rules to your codebase; prefer turning rules to "error"
// over disabling them. Disabling a security rule should be justified in code review.

import js from "@eslint/js";
import tseslint from "typescript-eslint";
import security from "eslint-plugin-security";
import noUnsanitized from "eslint-plugin-no-unsanitized";
import globals from "globals";

export default tseslint.config(
  {
    ignores: ["dist/**", "build/**", "coverage/**", "node_modules/**"],
  },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  security.configs.recommended,
  {
    files: ["**/*.{ts,mts,cts,js,mjs,cjs}"],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: "module",
      globals: { ...globals.node },
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    plugins: {
      "no-unsanitized": noUnsanitized,
    },
    rules: {
      // --- Security-relevant (keep as errors) ---
      "no-eval": "error",
      "no-implied-eval": "error",
      "no-new-func": "error",
      "no-script-url": "error",
      "no-unsanitized/method": "error",
      "no-unsanitized/property": "error",
      "security/detect-child-process": "error",
      "security/detect-non-literal-fs-filename": "warn",
      "security/detect-eval-with-expression": "error",
      "security/detect-unsafe-regex": "warn",
      "security/detect-buffer-noassert": "error",
      "security/detect-pseudoRandomBytes": "error",

      // --- Type-safety (catch silent type holes) ---
      "@typescript-eslint/no-explicit-any": "warn",
      "@typescript-eslint/no-floating-promises": "error",
      "@typescript-eslint/no-misused-promises": "error",
      "@typescript-eslint/await-thenable": "error",
      "@typescript-eslint/no-unsafe-assignment": "warn",

      // --- Hygiene ---
      "no-console": ["warn", { allow: ["warn", "error"] }],
      eqeqeq: ["error", "always"],
    },
  },
);
