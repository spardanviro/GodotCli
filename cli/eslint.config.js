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
  {
    // Tests assert on values they have just set up.
    files: ["test/**"],
    rules: { "@typescript-eslint/no-non-null-assertion": "off" },
  },
);
