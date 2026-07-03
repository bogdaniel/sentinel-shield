import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

// jsdom + Testing Library. Baseline covers src/ only; mutations/ (intentional
// defect fixtures) are excluded so the committed baseline stays green.
export default defineConfig({
  plugins: [react()],
  test: {
    globals: true,
    environment: "jsdom",
    setupFiles: ["./vitest.setup.ts"],
    include: ["src/**/*.test.tsx", "src/**/*.test.ts"],
    exclude: ["node_modules/**", "dist/**", "mutations/**"],
  },
});
