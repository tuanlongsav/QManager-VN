import type { Components } from "react-markdown";

const SAFE_LINK_PROTOCOLS = new Set(["http:", "https:", "mailto:"]);

function isSafeHref(href: string | undefined): boolean {
  if (!href) return false;
  try {
    const url = new URL(href, "https://example.invalid");
    return SAFE_LINK_PROTOCOLS.has(url.protocol);
  } catch {
    return false;
  }
}

/** Markdown renderer that blocks javascript:/data: links in release notes. */
export const safeMarkdownComponents: Components = {
  a: ({ href, children, ...props }) => {
    if (!isSafeHref(href)) {
      return <span>{children}</span>;
    }
    return (
      <a href={href} rel="noopener noreferrer" target="_blank" {...props}>
        {children}
      </a>
    );
  },
};
