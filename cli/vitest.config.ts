import { defineConfig } from "vitest/config";

const MIN_COVERAGE = 80;

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      // main.ts wires real I/O into cli.ts, and process-runner.ts only starts
      // and stops child processes; both are exercised by scripts/cli-e2e.mjs.
      exclude: ["src/main.ts", "src/process-runner.ts"],
      thresholds: {
        lines: MIN_COVERAGE,
        functions: MIN_COVERAGE,
        branches: MIN_COVERAGE,
        statements: MIN_COVERAGE,
      },
    },
  },
});
