// Sentinel Shield — React + TypeScript ESLint flat config (ESLint 9+).
//
// Adds React, hooks, accessibility, and XSS/DOM-safety rules on top of the Node
// security baseline.
//
// Install:
//   npm i -D eslint typescript typescript-eslint \
//     eslint-plugin-security eslint-plugin-no-unsanitized \
//     eslint-plugin-react eslint-plugin-react-hooks eslint-plugin-jsx-a11y globals
//
// Starter config — tune to your app. Do not casually disable the no-unsanitized or
// react/no-danger rules; they are your XSS guardrails.

import js from "@eslint/js";
import tseslint from "typescript-eslint";
import security from "eslint-plugin-security";
import noUnsanitized from "eslint-plugin-no-unsanitized";
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
import jsxA11y from "eslint-plugin-jsx-a11y";
import globals from "globals";

export default tseslint.config(
  {
    ignores: ["dist/**", "build/**", "coverage/**", "node_modules/**"],
  },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  security.configs.recommended,
  {
    files: ["**/*.{ts,tsx,js,jsx}"],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: "module",
      globals: { ...globals.browser },
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
        ecmaFeatures: { jsx: true },
      },
    },
    settings: { react: { version: "detect" } },
    plugins: {
      react,
      "react-hooks": reactHooks,
      "jsx-a11y": jsxA11y,
      "no-unsanitized": noUnsanitized,
    },
    rules: {
      ...react.configs.recommended.rules,
      ...reactHooks.configs.recommended.rules,
      ...jsxA11y.configs.recommended.rules,

      // --- XSS / unsafe DOM (guardrails — keep as errors) ---
      "react/no-danger": "error",
      "react/no-danger-with-children": "error",
      "no-unsanitized/method": "error",
      "no-unsanitized/property": "error",
      "no-script-url": "error",
      "no-eval": "error",
      "no-new-func": "error",

      // --- React correctness ---
      "react/jsx-no-target-blank": ["error", { enforceDynamicLinks: "always" }],
      "react/react-in-jsx-scope": "off", // modern JSX transform
      "react-hooks/rules-of-hooks": "error",
      "react-hooks/exhaustive-deps": "warn",

      // --- Type-safety ---
      "@typescript-eslint/no-floating-promises": "error",
      "@typescript-eslint/no-misused-promises": "error",
      "@typescript-eslint/no-explicit-any": "warn",

      eqeqeq: ["error", "always"],
    },
  },
);
