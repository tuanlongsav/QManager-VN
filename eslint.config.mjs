import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    // Tooling scratch dirs — not project source. Without these, throwaway
    // files the tooling writes (e.g. .remember/tmp/*.ts) show up as lint
    // findings against the project.
    ".remember/**",
    ".codegraph/**",
    "qmanager-build/**",
  ]),
]);

export default eslintConfig;
