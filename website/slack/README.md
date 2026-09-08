# Slack app for blog approval

Slack apps can't be created from the command line without an owner login, so this takes about
ten minutes in the browser, once. Everything else is code in this repo.

## 1. Create the app from the manifest
1. https://api.slack.com/apps → **Create New App** → **From a manifest** → pick the workspace.
2. Paste `manifest.json`. Leave the interactivity URL as it is for now, you'll fix it in step 3.
3. **Install to Workspace**. Copy the **Bot User OAuth Token** (`xoxb-…`).
4. **Basic Information** → copy the **Signing Secret**.
5. Create a channel (e.g. `#blog`), invite the bot (`/invite @Transcriber Blog`), copy the channel id
   (channel details → bottom of the About tab, starts with `C`).
6. Your own Slack user id: profile → ⋯ → Copy member ID (starts with `U`).

## 2. GitHub secrets (repo → Settings → Secrets and variables → Actions)
- `SLACK_BOT_TOKEN` = the `xoxb-…` token
- `SLACK_CHANNEL` = the channel id

## 3. Deploy the worker (Cloudflare, free)
```sh
npx wrangler login
npx wrangler deploy website/scripts/slack-approve-worker.js --name transcriber-blog-approval \
  --var GITHUB_REPO:moritzjkr/Transcriber --var ALLOWED_USERS:U0123ABC
npx wrangler secret put SLACK_SIGNING_SECRET      # from step 1.4
npx wrangler secret put SLACK_BOT_TOKEN           # from step 1.3, the worker needs it to open the change-request dialog
npx wrangler secret put GITHUB_TOKEN              # fine-grained PAT, this repo only, Contents: read and write
```
The deploy prints the worker URL. Put it into the Slack app under **Interactivity & Shortcuts →
Request URL** and save.

## 4. Test with the existing draft
Actions → Blog → Run workflow → action `notify`, slug `record-meeting-without-bot-mac`. A message with
four buttons appears in the channel. Click **Request changes**, type a note, submit: the note lands in
`blog-reviews/<slug>/requests/` and the rewrite routine picks it up. Click **Approve**: the post is
published and `blog-reviews/<slug>/` gets the original, the final and the diff.

## What each button does
| Button | What happens |
|---|---|
| Approve and publish | Worker → `approve-post` dispatch → workflow flips `draft: false`, saves the review snapshot, rebuilds, commits |
| Request changes | Worker opens a dialog. Your notes → `revise-post` dispatch → workflow saves them to `blog-reviews/<slug>/requests/<timestamp>.md`. The rewrite routine reads open requests, rewrites the draft, pushes with `[rewrite]` in the commit message, and the workflow posts the new preview to Slack |
| Edit on GitHub | Opens the Markdown file in GitHub's editor. Commit to main, the preview rebuilds, then approve |
| Reject | Worker → `reject-post` dispatch → file renamed to `.md.rejected` |
