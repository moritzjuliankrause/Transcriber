---
name: transcriber-seo
description: Keyword-driven SEO writing for gettranscriber.com. Picks one keyword from real search data (DataForSEO, Search Console), passes five gates, reads the live top results, writes one draft post through the blog pipeline. Used by the article, page, index, report and optimize routines.
---

# Transcriber SEO engine

Read in this order, every run: `references/run-protocol.md`, `references/keyword-method.md`,
`references/site-config.md`, then `website/blog/README.md` (post contract), `website/blog/WRITING.md`
(voice), `website/blog/EDITOR-LEARNINGS.md` (rules from Moritz's edits, they win), and the repo root
`README.md` (the only source of facts about Transcriber).

## Hard rules
- Everything is a draft. `draft: true` always. Moritz publishes in Slack. Never set `draft: false`.
- Keywords come from `scripts/dataforseo.mjs` and `scripts/gsc.mjs` only. No verified volume, no post.
- Every number, price, date or competitor claim is verified live in the run (WebFetch on the source) or cut.
- Facts about Transcriber: repo README only.
- Secrets are environment variables. Never print, log, commit or paste them.
- One run, one piece, one status line in `status/<YYYY-MM-DD>.txt`: `<job> | <keyword or slug> | <result>`.
- If a data source is unreachable or a gate fails for every candidate: write `SKIPPED (<reason>)` to the status file, send `node scripts/notify.mjs "<job>" "<reason>" warn`, stop. Never guess.
- Commit only sources (post, images, keywords/, status/), never generated HTML. Push to `main`; on rejection `git pull --rebase origin main` and retry.
