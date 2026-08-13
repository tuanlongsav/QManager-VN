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
    // Where scripts/dev/icloud-exclude.sh parks the regenerable artefacts so
    // iCloud stops syncing them. The entries above are matched by path, not by
    // basename, so once .next/ and out/ physically live one level down they
    // stop being ignored — the real build output then lints as project source
    // and buries the ~9 genuine findings under ~15.9k of noise.
    ".artifacts.nosync/**",
    // iCloud conflict copies — "use-i18n 2.ts" beside "use-i18n.ts". They are
    // stale snapshots, so linting them re-reports every issue that was already
    // fixed in the real file: a sync event once resurrected all 16
    // react-hooks/set-state-in-effect errors this way, pointing at files whose
    // committed versions were clean.
    //
    // These three globs mirror the regex in scripts/dev/conflict-copies.sh as
    // closely as minimatch allows: one space, one to three digits, then an
    // extension whose first segment starts with a letter. Mirroring is the
    // requirement, not a nicety, and it is wrong in BOTH directions. Ignore
    // more than the detector matches and the surplus shapes are seen by no
    // guard at all — which is what the previous spelling did, "**/* [0-9]*.*"
    // swallowing "use-i18n 10.ts" and "use-i18n 2 copy.ts" while a second
    // "**/* copy.*" swallowed Finder's "use-i18n copy.ts", none of the three
    // ever reported by the detector. Ignore less and a genuine stale copy lints
    // as though it were source, which is the noise this entry exists to stop.
    //
    // The odd-looking bounds are the detector's and are load-bearing there:
    // capping at three digits keeps prose like "rfc 2024.md" out, and demanding
    // a letter after the dot stops "version 1.2.3" parsing as a copy of
    // "version". Finder's worded duplicates ("use-i18n copy.ts") match neither
    // side on purpose — they lint. Extension-less copies (".git/refs/heads/
    // main 2" was one) match the detector only, which is enough: `eslint .`
    // opens only files whose extension it lints, so a glob for them here would
    // be decoration.
    "**/* [0-9].[A-Za-z]*",
    "**/* [0-9][0-9].[A-Za-z]*",
    "**/* [0-9][0-9][0-9].[A-Za-z]*",
  ]),
]);

export default eslintConfig;
