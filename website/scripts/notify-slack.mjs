#!/usr/bin/env node
// Posts a draft blog post to Slack for approval, with Approve / Reject buttons.
//
//   SLACK_BOT_TOKEN=xoxb-…  SLACK_CHANNEL=C0123…  node website/scripts/notify-slack.mjs <slug> [--rewrite]
//
// --rewrite announces a rewritten draft (after a change request) instead of a new one.
//
// The buttons only work once the Slack app's Interactivity request URL points at the worker in
// website/scripts/slack-approve-worker.js (see website/blog/README.md). Without it, this is still a
// useful notification with a preview link.

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CFG = JSON.parse(readFileSync(join(ROOT, 'blog', 'config.json'), 'utf8'));
const args = process.argv.slice(2);
const rewrite = args.includes('--rewrite');
const slug = args.find(a => !a.startsWith('--'));
if (!slug) { console.error('usage: notify-slack.mjs <slug>'); process.exit(2); }
const file = join(ROOT, 'blog', 'posts', slug + '.md');
if (!existsSync(file)) { console.error('no such post: ' + file); process.exit(2); }
const token = process.env.SLACK_BOT_TOKEN, channel = process.env.SLACK_CHANNEL;
if (!token || !channel) { console.error('SLACK_BOT_TOKEN and SLACK_CHANNEL are required'); process.exit(2); }

const raw = readFileSync(file, 'utf8');
const fm = raw.match(/^---\r?\n([\s\S]*?)\r?\n---/);
const get = k => { const m = fm && fm[1].match(new RegExp('^' + k + ':\\s*(.*)$', 'm')); return m ? m[1].trim().replace(/^["']|["']$/g, '') : ''; };
const title = get('title') || slug, description = get('description'), keyword = get('keyword');
const wordCount = raw.slice(fm ? fm[0].length : 0).split(/\s+/).filter(Boolean).length;
const preview = CFG.siteUrl.replace(/\/$/, '') + '/blog/preview/' + slug + '/';
const editUrl = CFG.repoUrl.replace(/\/$/, '') + '/edit/main/website/blog/posts/' + slug + '.md';

// Open change requests, if any, so the rewrite message shows what was asked for.
const reqDir = join(ROOT, '..', 'blog-reviews', slug, 'requests');
let requests = [];
if (rewrite && existsSync(reqDir)) {
  const { readdirSync } = await import('node:fs');
  requests = readdirSync(reqDir).filter(f => f.endsWith('.md')).sort().slice(-3)
    .map(f => readFileSync(join(reqDir, f), 'utf8').replace(/^---[\s\S]*?---\s*/, '').trim());
}

const headline = (rewrite ? 'Rewritten draft: ' : 'New blog draft: ') + title;
const blocks = [
  { type: 'header', text: { type: 'plain_text', text: headline, emoji: false } },
  { type: 'section', text: { type: 'mrkdwn', text: description || '_no description_' } },
  { type: 'section', fields: [
    { type: 'mrkdwn', text: '*Keyword*\n' + (keyword || 'n/a') },
    { type: 'mrkdwn', text: '*Length*\n' + wordCount + ' words' },
    { type: 'mrkdwn', text: '*Slug*\n`' + slug + '`' },
    { type: 'mrkdwn', text: '*Preview*\n<' + preview + '|open draft>' }
  ] },
  ...(requests.length ? [{ type: 'section', text: { type: 'mrkdwn', text: '*Addressed:*\n> ' + requests.join('\n> ').replace(/\n/g, '\n> ') } }] : []),
  { type: 'context', elements: [ { type: 'mrkdwn', text: 'Small fixes: *Edit on GitHub*, commit to main, then approve. Bigger changes: *Request changes* with a note, the writer rewrites and posts the new preview here. Either way the writer learns from the difference between its draft and what you approve.' } ] },
  { type: 'actions', block_id: 'blog-approval:' + slug, elements: [
    { type: 'button', style: 'primary', text: { type: 'plain_text', text: 'Approve and publish' }, action_id: 'approve', value: slug,
      confirm: { title: { type: 'plain_text', text: 'Publish this post?' }, text: { type: 'mrkdwn', text: '*' + title + '* goes live on the blog.' }, confirm: { type: 'plain_text', text: 'Publish' }, deny: { type: 'plain_text', text: 'Not yet' } } },
    { type: 'button', text: { type: 'plain_text', text: 'Request changes' }, action_id: 'revise', value: slug },
    { type: 'button', text: { type: 'plain_text', text: 'Edit on GitHub' }, action_id: 'edit', url: editUrl, value: slug },
    { type: 'button', style: 'danger', text: { type: 'plain_text', text: 'Reject' }, action_id: 'reject', value: slug }
  ] }
];

const res = await fetch('https://slack.com/api/chat.postMessage', {
  method: 'POST', headers: { 'Content-Type': 'application/json; charset=utf-8', Authorization: 'Bearer ' + token },
  body: JSON.stringify({ channel, text: headline + ' ' + preview, blocks })
});
const json = await res.json();
if (!json.ok) { console.error('Slack error: ' + json.error); process.exit(1); }
console.log('Posted to Slack: ' + headline);
