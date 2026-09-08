# Blog reviews: what Moritz changed before approving

Written automatically by `.github/workflows/blog-publish.yml` when a post is approved in Slack.
One folder per post:

```
blog-reviews/<slug>/
├── original.md     the draft as the writer committed it
├── final.md        the version Moritz approved (after his edits on GitHub, if any)
├── changes.diff    unified diff between the two
└── status.json     slug, draft commit, approval time, who edited, learned: true|false
```

## What the writer does with it

Before writing the next post, the writer reads every folder whose `status.json` says `"learned": false`,
compares `original.md` with `final.md`, and works out for each change:

- what kind of change it is: cut, rewrite, reorder, added fact, softer or harder claim, word choice, tone, length, FAQ, structure
- why Moritz probably made it (too salesy, wrong fact, too long, not how he says it, missing context)
- whether it is a one-off for that post or a pattern that should apply to every post

Patterns become rules in `website/blog/EDITOR-LEARNINGS.md`, each with the date, the slug it came from, a
one-line before/after example, and the rule. Existing rules that a new review confirms get the slug
appended; rules a new review contradicts get rewritten, not duplicated. Then `learned` is set to `true`.

An approval without edits is a signal too: it confirms the current rules and is noted as such.

Nothing in this folder is served by the website. Keep it in git so the history of taste is visible.
