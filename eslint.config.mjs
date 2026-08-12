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
    // files the tooling writes show up as lint findings against the project:
    // .remember/tmp/*.ts, and above all .claude/worktrees/, which holds full
    // repo checkouts (node_modules included) and alone contributed ~15.7k
    // findings. Git already ignores these via the /.claude rule.
    ".claude/**",
    ".remember/**",
    ".codegraph/**",
    "qmanager-build/**",
    // iCloud/Finder conflict copies — "use-i18n 2.ts" beside "use-i18n.ts".
    // They are stale snapshots, so linting them re-reports every issue that was
    // already fixed in the real file: a sync event once resurrected all 16
    // react-hooks/set-state-in-effect errors this way, pointing at files whose
    // committed versions were clean. Ignoring them here keeps lint honest;
    // they are deliberately NOT git-ignored, so `git status` still shows them
    // and scripts/test/run-all.sh still warns, or they would pile up unseen.
    "**/* [0-9].*",
    "**/* [0-9] copy.*",
  ]),
]);

export default eslintConfig;
