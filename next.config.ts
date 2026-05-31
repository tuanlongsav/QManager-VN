import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  /* config options here */
  output: "export",
  trailingSlash: true,

  // Tree-shake large libraries down to the symbols actually used so the ARMv7
  // modem parses/executes less JS. Next applies a per-package modularize-imports
  // transform for everything listed here.
  experimental: {
    optimizePackageImports: ["lucide-react", "recharts", "motion"],
  },

  // Uncomment for local dev. Comment out before `bun run build` (static export).
  // async rewrites() {
  //   return [
  //     {
  //       source: "/cgi-bin/:path*",
  //       // Disable lighttpd's HTTP→HTTPS redirect on the modem for local dev.
  //       // Bun doesn't support NODE_TLS_REJECT_UNAUTHORIZED for self-signed certs.
  //       destination: "http://192.168.225.1/cgi-bin/:path*",
  //       // Tailscale alternative:
  //       // destination: "http://toothless.tail23767.ts.net/cgi-bin/:path*",
  //       basePath: false,
  //     },
  //   ];
  // },
};

export default nextConfig;
