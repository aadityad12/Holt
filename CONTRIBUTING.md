# Contributing

Thank you for contributing. Before opening a pull request, please follow these
rules.

## Rules

1. **No AI attribution anywhere in the repo.**
   Do not include AI co-author trailers, `"Generated with"` lines, robot emoji,
   or tool or model names as authors in commits, code comments, pull request
   titles or descriptions, or docs. Human co-authors are welcome
   (`Co-Authored-By: Jane Doe <jane@example.com>` is fine). Documentation may
   describe that the product runs Claude Code and Codex sessions, because that
   is what it does.

2. **Tests come with the change.**
   Every code change should include tests. Security-sensitive folders
   (`server/src/auth`, `server/src/dispatch`, `server/src/sessions`,
   `server/src/credentials`) need a test for every new branch.

3. **Never put a token, cookie, or credential in the repo.**
   Do not commit secrets anywhere in the repository, in test fixtures, or in
   log lines.

## Local checks

Run the full check suite before opening a pull request:

```bash
pnpm install
pnpm -r typecheck
pnpm lint
pnpm -r test
pnpm -r build
```
