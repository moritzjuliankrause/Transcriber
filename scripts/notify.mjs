#!/usr/bin/env node
// Posts a short status message to the blog Slack channel (same bot as the approval cards).
// Env: SLACK_BOT_TOKEN, SLACK_CHANNEL.   node scripts/notify.mjs "<title>" "<text>" [ok|warn|error]
const [title, text, level = 'ok'] = process.argv.slice(2);
const token = process.env.SLACK_BOT_TOKEN, channel = process.env.SLACK_CHANNEL;
if (!token || !channel) { console.error('SLACK_BOT_TOKEN / SLACK_CHANNEL missing'); process.exit(2); }
const color = { ok: '#2e9e5b', warn: '#e8912d', error: '#d33' }[level] || '#8a8f9c';
const icon = { ok: '✅', warn: '⚠️', error: '❌' }[level] || 'ℹ️';
const r = await fetch('https://slack.com/api/chat.postMessage', { method: 'POST', headers: { 'Content-Type': 'application/json; charset=utf-8', Authorization: 'Bearer ' + token },
  body: JSON.stringify({ channel, text: `${icon} ${title}: ${text}`, attachments: [{ color, blocks: [
    { type: 'section', text: { type: 'mrkdwn', text: `${icon} *${title}*\n${text || ''}` } },
    { type: 'context', elements: [{ type: 'mrkdwn', text: new Date().toISOString().slice(0, 16).replace('T', ' ') + ' UTC · routine status' }] }
  ] }] }) });
const j = await r.json();
if (!j.ok) { console.error('Slack error: ' + j.error); process.exit(1); }
console.log('notified');
