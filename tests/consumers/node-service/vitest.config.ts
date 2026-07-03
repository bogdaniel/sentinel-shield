import { defineConfig } from "vitest/config";

// Baseline test run covers src/ only. mutations/ holds intentional-defect
// fixtures the validation driver overlays into a throwaway copy of src/, so they
// are excluded here to keep the committed baseline green.
export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    exclude: ["node_modules/**", "dist/**", "mutations/**"],
  },
});
