import { defineConfig } from "vitest/config";

const MIN_COVERAGE = 80;

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      // main.ts is the process entry point; everything it does lives in cli.ts.
      exclude: ["src/main.ts"],
      thresholds: {
        lines: MIN_COVERAGE,
        functions: MIN_COVERAGE,
        branches: MIN_COVERAGE,
        statements: MIN_COVERAGE,
      },
    },
  },
});
