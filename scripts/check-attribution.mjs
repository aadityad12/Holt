import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_MARKERS_PATH = resolve(SCRIPT_DIR, "ai-markers.txt");

const EXACT_EXEMPT_PATHS = new Set(["scripts/check-attribution.mjs", "scripts/ai-markers.txt"]);
const EXEMPT_PATH_PATTERNS = [/(^|\/)test[^/]*\//i, /(^|\/)fixtures\//i];
const CO_AUTHOR_PATTERN = /co-authored-by\s*:(.*)$/i;

/**
 * Parse markers from scripts/ai-markers.txt into plain and co-author lists.
 * @param {string} raw
 * @returns {{ plain: string[]; coAuthor: string[] }}
 */
export function parseMarkers(raw) {
  /** @type {string[]} */
  const plain = [];
  /** @type {string[]} */
  const coAuthor = [];
  /** @type {"plain" | "co-author" | null} */
  let section = null;

  for (const rawLine of raw.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) {
      continue;
    }
    if (line === "[plain]") {
      section = "plain";
      continue;
    }
    if (line === "[co-author]") {
      section = "co-author";
      continue;
    }
    if (section === "plain") {
      plain.push(line.toLowerCase());
    } else if (section === "co-author") {
      coAuthor.push(line.toLowerCase());
    } else {
      throw new Error(`Marker outside of [plain] or [co-author] section: ${line}`);
    }
  }

  return { plain, coAuthor };
}

/**
 * Return true if a repo-relative path is exempt from tracked-file scanning.
 * @param {string} relPath
 * @returns {boolean}
 */
export function isExemptPath(relPath) {
  const normalized = relPath.replaceAll("\\", "/").replace(/^\.\//, "");
  if (EXACT_EXEMPT_PATHS.has(normalized)) {
    return true;
  }
  return EXEMPT_PATH_PATTERNS.some((pattern) => pattern.test(normalized));
}

/**
 * Scan text for AI attribution markers.
 * @param {string} text
 * @param {{ plain: string[]; coAuthor: string[] }} markers
 * @param {{ source: string; allowQuotedGeneratedWith?: boolean }} options
 * @returns {string[]}
 */
export function findViolations(text, markers, options) {
  /** @type {string[]} */
  const violations = [];
  const lines = text.split(/\r?\n/);

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    const lower = line.toLowerCase();
    const lineNumber = i + 1;

    for (const marker of markers.plain) {
      if (lower.includes(marker)) {
        if (
          options.allowQuotedGeneratedWith &&
          marker === "generated with" &&
          lower.includes('"generated with"') &&
          !lower.replaceAll('"generated with"', "").includes("generated with")
        ) {
          continue;
        }
        violations.push(`${options.source}:${lineNumber} contains banned marker "${marker}"`);
      }
    }

    const coAuthorMatch = CO_AUTHOR_PATTERN.exec(line);
    if (coAuthorMatch) {
      const value = (coAuthorMatch[1] ?? "").toLowerCase();
      for (const marker of markers.coAuthor) {
        if (value.includes(marker)) {
          violations.push(
            `${options.source}:${lineNumber} has AI Co-Authored-By matching "${marker}"`,
          );
          break;
        }
      }
    }
  }

  return violations;
}

/**
 * Load commits in the requested revision range.
 * @param {string | undefined} baseSha
 * @param {string | undefined} headSha
 * @returns {Array<{ sha: string; message: string }>}
 */
function readCommits(baseSha, headSha) {
  const args = ["log", "--format=%H%x1f%B%x1e"];
  if (headSha) {
    if (baseSha && !/^0+$/.test(baseSha)) {
      args.push(`${baseSha}..${headSha}`);
    } else {
      args.push("-n", "1", headSha);
    }
  } else {
    args.push("-n", "1", "HEAD");
  }

  const output = execFileSync("git", args, { encoding: "utf8" });
  /** @type {Array<{ sha: string; message: string }>} */
  const commits = [];
  for (const record of output.split("\x1e")) {
    const trimmed = record.trim();
    if (!trimmed) {
      continue;
    }
    const sep = trimmed.indexOf("\x1f");
    if (sep === -1) {
      continue;
    }
    commits.push({
      sha: trimmed.slice(0, sep),
      message: trimmed.slice(sep + 1),
    });
  }
  return commits;
}

/**
 * Scan PR metadata, commits, and tracked files.
 * @param {string} [markersPath]
 * @returns {string[]}
 */
export function runCheck(markersPath = DEFAULT_MARKERS_PATH) {
  const markers = parseMarkers(readFileSync(markersPath, "utf8"));
  /** @type {string[]} */
  const violations = [];

  if (process.env.PR_TITLE) {
    violations.push(...findViolations(process.env.PR_TITLE, markers, { source: "PR title" }));
  }
  if (process.env.PR_BODY) {
    violations.push(...findViolations(process.env.PR_BODY, markers, { source: "PR body" }));
  }

  for (const commit of readCommits(process.env.BASE_SHA, process.env.HEAD_SHA)) {
    violations.push(
      ...findViolations(commit.message, markers, {
        source: `commit ${commit.sha.slice(0, 12)}`,
      }),
    );
  }

  const trackedRaw = execFileSync("git", ["ls-files", "-z"]);
  const trackedPaths = trackedRaw
    .toString("utf8")
    .split("\0")
    .filter((entry) => entry.length > 0);

  for (const relPath of trackedPaths) {
    if (isExemptPath(relPath) || !existsSync(relPath)) {
      continue;
    }
    const buf = readFileSync(relPath);
    if (buf.includes(0)) {
      continue;
    }
    violations.push(
      ...findViolations(buf.toString("utf8"), markers, {
        source: relPath,
        allowQuotedGeneratedWith: relPath === "CONTRIBUTING.md",
      }),
    );
  }

  return violations;
}

const isEntrypoint =
  process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isEntrypoint) {
  const violations = runCheck();
  if (violations.length > 0) {
    console.error("AI attribution check failed:");
    for (const violation of violations) {
      console.error(`  - ${violation}`);
    }
    process.exit(1);
  }
  console.log("AI attribution check passed.");
}
