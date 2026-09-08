# Run protocol

Jobs: `article` (Tue, Thu), `page` (Sat, a comparison or per-app guide), `index` (daily), `report` (daily), `optimize` (Sun, only once Search Console has 8 weeks of data). All run as Claude Code cloud routines with the repo checked out on `main`.

## Pre-flight (every job)
1. `git pull --rebase origin main`.
2. Data comes from `keywords/data/*.json` (written nightly by GitHub Actions). Env vars are optional; never echo them. If `keywords/data/overview.json` is missing or older than 48 h AND no env var exists, fall back to `website/blog/BACKLOG.md`.
3. Read `keywords/shipped.json`, `keywords/backlog.json`, `website/blog/BACKLOG.md`, and list `website/blog/posts/` (drafts included). More than 4 open drafts (`draft: true`) → `SKIPPED (review queue full)`, notify warn, stop. Moritz's review time is the bottleneck, not writing.

## Job article / page
1. Build the brief per `keyword-method.md`: quick wins → backlog → suggestions. Apply the five gates and the competitor pass. `page` prefers commercial intent (comparison, alternative, per-app guide); `article` prefers informational.
2. If no candidate survives: take the first `status: todo` entry from `website/blog/BACKLOG.md` instead, write it, and note `fallback: backlog` in the status line. If that is empty too: SKIPPED.
3. Write the post per `website/blog/README.md`, `WRITING.md`, `EDITOR-LEARNINGS.md`, facts from the README only. Frontmatter `draft: true`, FAQ 4 to 8, no hero field (Moritz renders images), link landing page once plus one sibling post from `website/blog/sitemap.xml`.
4. `node website/scripts/build-blog.mjs --check` and `node scripts/check-draft.mjs website/blog/posts/<slug>.md`. Fix once, rerun. Hard fails after the second run → do not commit, SKIPPED (lint).
5. Update `keywords/shipped.json` (and `rejected.json` / `backlog.json` with what the run learned). If the topic came from BACKLOG.md, set its status to `drafted <date>`.
6. Commit post + keywords + status with message `Blog draft: <slug>` and a body with three distribution texts (LinkedIn post, Reddit-style answer with link, newsletter paragraph). Push. The workflow builds the preview and posts the Slack card.
7. Status line: `article | <keyword> | drafted <slug> (vol n, kd n)`.

## Job index
Indexing runs inside the nightly GitHub Actions job (`seo-data.yml`, which has the secrets). The routine only verifies: read `status/indexed.json`, compare with the live sitemap, and if URLs published more than 2 days ago are missing, write a status line `index | <n> urls not submitted` (the report picks it up). No commit needed.

## Job report
Read `status/` for the last 24 hours, count open drafts, list change requests with `status: open`, note routine errors. Write the summary to `status/report-latest.md` (overwrite) and commit; a GitHub workflow posts it to Slack. If `SLACK_BOT_TOKEN` happens to be set, `node scripts/notify.mjs` may be used instead.

## Job optimize (Phase 4)
`node scripts/gsc.mjs quickwins`. Take at most 3 published posts with queries at position 5 to 20. For each: sharpen title and description toward the query, add or extend an FAQ entry that answers it, add an internal link from a sibling post, keep facts README-only. Edit the published post file in place (it stays published), commit `Blog optimize: <slug> (<query>)`, status line per post. Never touch drafts.

## Guardrails
- One piece per run. No second post "while we're at it".
- Never modify `EDITOR-LEARNINGS.md` in these jobs (only the rewrite-and-learn routine does).
- Never delete or rename posts.
- Hard time budget: if a run passes 25 minutes, commit what is lint-clean or stop with SKIPPED.
