# Transcriber blog

Static blog next to the landing page. Posts are Markdown files with frontmatter, a script renders
them to HTML, and nothing is published until Moritz approves it in Slack.

```
website/
├── index.html                  landing page (hand-written, not generated)
├── blog/
│   ├── posts/<slug>.md         SOURCE. One file per post. This is the only thing a writer touches.
│   ├── img/<slug>/*.webp       images for that post (hero + inline), referenced as img/<slug>/name.webp
│   ├── config.json             site URL, blog title, author, download link, default closing paragraph
│   ├── blog.css                the blog's stylesheet, inlined into every page
│   ├── index.html              GENERATED  list of published posts
│   ├── <slug>/index.html       GENERATED  published post
│   ├── preview/<slug>/         GENERATED  draft preview, noindex, linked from the Slack message
│   ├── feed.xml, sitemap.xml   GENERATED
│   └── README.md               this file
└── scripts/
    ├── build-blog.mjs          renders everything above. Node 22, no dependencies.
    ├── notify-slack.mjs        posts a draft to Slack with Approve / Request changes / Edit / Reject buttons
    └── slack-approve-worker.js Cloudflare Worker that turns a button click into a GitHub dispatch
```

## Writing a post

Create `website/blog/posts/<slug>.md`. The slug is the URL (`/blog/<slug>/`): lowercase, hyphens,
keyword first, no dates. Frontmatter:

```yaml
---
title: How to record a Zoom call on a Mac and get a transcript     # under 60 chars, keyword first, no brand
description: One or two sentences, under 155 chars, keyword in the first 20 words.
date: 2026-09-08            # optional for drafts, the publish step stamps today if missing
updated: 2026-09-20         # optional
author: Moritz Krause       # optional, defaults to config.json
keyword: record zoom call mac
keywords: [record zoom call mac, zoom call transcript, transcribe zoom call]
hero: img/<slug>/record-zoom-call-mac.webp        # optional, 16:9, path relative to website/blog/
heroAlt: record zoom call mac                     # optional, defaults to keyword
cta: Custom closing paragraph.                    # optional, defaults to config.json ctaText
draft: true                 # REQUIRED for anything not yet approved. Missing = draft.
faq:                        # optional, 4 to 8 entries, rendered as an accordion + FAQPage schema
  - q: Does any audio leave my Mac?
    a: No. Transcription runs on your machine with a downloaded model.
---
```

Then the body. The first paragraph answers the title directly, H2s are phrased as questions where
that sounds natural, prose before lists, FAQ goes in the frontmatter (not in the body), and the
closing paragraph is rendered from `cta` / `ctaText`, so don't write a sales ending in the body.
No H1 in the body: the title is the H1. Voice and banned words: `website/blog/WRITING.md`, then
`website/blog/EDITOR-LEARNINGS.md`, which holds the rules learned from Moritz's edits and wins where
they conflict. The build refuses en/em dashes.

Supported Markdown: `##`/`###` headings, paragraphs, `**bold**`, `*italic*`, `` `code` ``, links,
`![alt](img/<slug>/name.webp "optional caption")`, `-` and `1.` lists, `>` quotes, fenced code,
tables (`| a | b |`, they stack into cards on phones), `---`.

Facts about Transcriber come from the app's README only. If it's not in there, it doesn't go in a post.

Hero images are rendered from the app's real UI code (`--render-hero`, `Sources/Transcriber/App/HeroRender.swift`).
A writer does not need a Mac for that: drop `website/blog/img/<slug>/hero.json` next to the post,

```json
{ "lines": ["Anna: Can we move the launch?", "Me: If design signs off by Friday, yes.", "Anna: Then the 21st it is"],
  "caption": "Recorded on your Mac. Nobody joins the call.", "sub": "Zoom · Teams · Meet · FaceTime", "timer": "23:41" }
```

and the GitHub workflow `hero-render.yml` (macOS runner) renders `hero.webp`, adds `hero:` and `heroAlt:` to the
post's frontmatter and commits. Three lines of realistic call dialogue, one of them from "Me"; the caption is
the post's promise in five to eight words; the sub line is optional. Locally: `swift build -c release` and
`.build/release/Transcriber --render-hero out.png --timer 12:34 --caption "…" --sub "…" "Anna: …" "Me: …" "Anna: …"`.

Every post automatically gets the AI disclaimer from `aiNote` in `config.json` under the closing
paragraph. Do not write your own disclaimer into the body.

## Building

```sh
node website/scripts/build-blog.mjs           # renders posts, index, feed, sitemap, draft previews
node website/scripts/build-blog.mjs --check   # lint only: frontmatter, lengths, dashes, missing images
open website/blog/index.html
```

Generated files are committed, so the site is plain static files wherever it is hosted. Set
`siteUrl` in `config.json` to the real address before the first publish; canonical URLs, Open Graph,
the feed and the sitemap are built from it.

## Approval flow

1. The writing routine commits `posts/<slug>.md` with `draft: true` and pushes to `main`.
2. The GitHub workflow `.github/workflows/blog-publish.yml` rebuilds. The draft appears at
   `/blog/preview/<slug>/` (noindex) once the site deploys, and `notify-slack.mjs` posts it to
   Slack with the preview link and two buttons.
3. For bigger changes click **Request changes**, write what should change and why, submit. The notes
   are saved to `blog-reviews/<slug>/requests/`, the rewrite routine rewrites the draft, pushes with
   `[rewrite]` in the commit message, and the workflow posts the new preview to Slack (same buttons).
   For small fixes click **Edit on GitHub**, edit the Markdown in the browser and commit
   to `main`. The push rebuilds the preview (no new Slack message, the file is not new). Then approve.
4. Clicking **Approve and publish** calls the Cloudflare Worker, which verifies Slack's signature
   and sends `repository_dispatch: approve-post {slug}` to GitHub. The workflow sets
   `draft: false`, stamps the date if missing, rebuilds, and commits. The post is now at
   `/blog/<slug>/`, in the index, the feed and the sitemap. The Slack message updates itself with
   who approved it. The same run saves the original draft, the approved version and their diff to
   `blog-reviews/<slug>/`, and the writer turns those edits into rules in `EDITOR-LEARNINGS.md`
   before the next post (see `blog-reviews/README.md`).
5. **Reject** renames the file to `<slug>.md.rejected` so it drops out of the build but stays in git.

Both actions also exist under Actions › Blog › Run workflow, for approving without Slack.

### One-time setup

Slack app (api.slack.com/apps, "from scratch"):
- OAuth scopes: `chat:write`. Install to the workspace, invite the bot to the channel.
- Save the **Bot User OAuth Token** as GitHub secret `SLACK_BOT_TOKEN`, the channel id as `SLACK_CHANNEL`.
- Interactivity & Shortcuts: on, Request URL = the worker URL below.
- Basic Information › **Signing Secret** goes to the worker.

Worker:
```sh
npx wrangler deploy website/scripts/slack-approve-worker.js --name transcriber-blog-approval
npx wrangler secret put SLACK_SIGNING_SECRET
npx wrangler secret put GITHUB_TOKEN        # fine-grained PAT, this repo only, Contents: read and write
npx wrangler deploy … --var GITHUB_REPO:moritzjuliankrause/Transcriber --var ALLOWED_USERS:U0123ABC   # your Slack user id
```

Hosting: the workflow only commits. Whatever serves `website/` (GitHub Pages, Cloudflare Pages, an
rsync to moritz-krause.com) picks up the new files on the next deploy; if that deploy is not
automatic, add it as a last step in the workflow.
