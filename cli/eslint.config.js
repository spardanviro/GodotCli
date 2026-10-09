import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["dist/**", "coverage/**"] },
  ...tseslint.configs.strict,
  {
    rules: {
      "no-console": "error",
      eqeqeq: "error",
    },
  },
);
