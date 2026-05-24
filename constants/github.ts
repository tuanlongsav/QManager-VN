/**
 * GitHub repo metadata for QManager-VN fork.
 *
 * Single source of truth for repo owner/name used by the frontend.
 * Backend (bash scripts) duplicates this in:
 *   - qmanager-installer.sh         (GITHUB_REPO)
 *   - scripts/www/cgi-bin/quecmanager/system/update.sh  (GITHUB_REPO)
 *   - scripts/usr/bin/qmanager_update                   (URL whitelist)
 *   - scripts/usr/bin/qmanager_auto_update              (REPO)
 *
 * If renaming/moving the repo, update all four bash files AND this file.
 */
export const GITHUB_OWNER = "tuanlongsav";
export const GITHUB_REPO = "QManager-VN";
export const GITHUB_REPO_FULL = `${GITHUB_OWNER}/${GITHUB_REPO}`;
export const GITHUB_REPO_URL = `https://github.com/${GITHUB_REPO_FULL}`;
export const GITHUB_API_URL = `https://api.github.com/repos/${GITHUB_REPO_FULL}`;
export const GITHUB_RELEASES_URL = `${GITHUB_REPO_URL}/releases`;
export const GITHUB_ISSUES_URL = `${GITHUB_REPO_URL}/issues`;

/**
 * Upstream repo (for credit/attribution in UI).
 */
export const UPSTREAM_OWNER = "dr-dolomite";
export const UPSTREAM_REPO = "QManager-RM520N";
export const UPSTREAM_URL = `https://github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}`;
