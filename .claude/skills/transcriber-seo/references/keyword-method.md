# Keyword method

## Where the data comes from
A GitHub Actions job (`.github/workflows/seo-data.yml`) runs every night at 00:30 UTC with the secrets and writes fresh files to `keywords/data/`:
`overview.json` (volume, difficulty, intent for backlog, seed, suggestion and competitor keywords, each with a `source` and a `relevant` flag; ignore entries with `relevant: false`, they are competitor brand terms or off-topic), `suggestions.json` (ideas per seed), `competitors.json` (keywords competitor domains rank for), `serp.json` (live top 10 for the 12 strongest unshipped candidates), `quickwins.json` and `gsc-pages.json` (Search Console). **Read these files first.** Check `fetchedAt`; if a file is older than 48 hours or missing and the matching env var exists, call the script directly; if neither is available, use `website/blog/BACKLOG.md` as the fallback. Never call DataForSEO for keywords already present in `overview.json`.

## Sources, in this order
1. **Quick wins** from Search Console: `keywords/data/quickwins.json` (or `node scripts/gsc.mjs quickwins`) gives queries at position 5 to 20 with impressions, grouped by page. An existing page that almost ranks beats a new page. (Only meaningful once the property has a few weeks of data; empty output is normal at the start.)
2. **Backlog**: `keywords/backlog.json`, candidates that already passed the gates in an earlier run.
3. **Suggestions and competitors**: `keywords/data/suggestions.json` and `keywords/data/competitors.json` (or the scripts `dataforseo.mjs suggest` / `ranked` when env is available) (rotate: otter.ai, fireflies.ai, tldv.io, fathom.video, goodsnooze.gumroad.com for MacWhisper, granola.ai).

## The five gates, every candidate
1. **Relevance**: would someone searching this plausibly install a Mac app that records and transcribes calls locally? Only lanes from `site-config.md`. Forbidden lanes are out, no matter the volume.
2. **Verified volume**: `keywords/data/overview.json` (or `node scripts/dataforseo.mjs overview "<kw>"`) shows a real `volume` > 0 for the target market (EN: US `--loc 2840`, later DE: `--lang de`). Null or 0 is a reject.
3. **Intent**: informational → article; commercial or transactional ("alternative", "vs", "best", "app") → comparison page. Confirm against the live SERP: `keywords/data/serp.json` for the precomputed candidates, otherwise `node scripts/dataforseo.mjs serp "<kw>"` if env exists; if neither, WebSearch the keyword and read the top results. A page of guides means informational, a page of product pages means commercial.
4. **Winnability**: new site, so difficulty ≤ 30 unless the SERP is visibly weak. A difficulty-9 term at 300 searches beats a difficulty-60 term at 5,000. If the top 10 is wall-to-wall big brands (Microsoft, Zoom, Apple, Otter, Notion), reject and log it to `keywords/rejected.json` with reason `brands`.
5. **Anti-cannibalization**: check the keyword and close variants against `keywords/shipped.json`, `website/blog/sitemap.xml`, `website/blog/posts/` (drafts included) and `website/blog/BACKLOG.md`. If an existing post targets it, either skip or, if it is a quick win, improve that post instead (job optimize).

Log every rejected candidate to `keywords/rejected.json` as `{keyword, volume, difficulty, reason, date}`. Log passed-but-unused candidates to `keywords/backlog.json`.

## Competitor pass (mandatory before writing)
Read the top 3 results of the live SERP with WebFetch. Write, in the status file and in your head:
- coverage map: what all three explain
- gap list: what none of them cover, or cover badly (for our niche usually: no bot, both sides captured, local processing, echo, crash safety, honest limits)
- one sentence: why would someone read ours instead of the current top 3? If you cannot write that sentence, drop the keyword and take the next one.
The post must cover everything the top 3 cover, shorter, and add the gap list. Never ship thinner than what already ranks.

## Brief format (write it into the status file before writing)
```
keyword | volume | difficulty | intent | format (article|comparison|guide) | slug | differentiation sentence
```
After the post is committed, add the keyword to `keywords/shipped.json` as `{ "<keyword>": { "slug": "<slug>", "date": "<YYYY-MM-DD>", "volume": n, "difficulty": n } }`.
