// Cloudflare Worker: receives Slack button clicks and turns them into GitHub repository_dispatch events.
//
// Deploy once (free tier is plenty):  npx wrangler deploy website/scripts/slack-approve-worker.js --name transcriber-blog-approval
// Secrets (wrangler secret put …):     SLACK_SIGNING_SECRET, SLACK_BOT_TOKEN (opens the change-request dialog),
//                                      GITHUB_TOKEN (fine-grained, "Contents: write" on the repo)
// Vars:                                GITHUB_REPO = moritzjkr/Transcriber, ALLOWED_USERS = comma-separated Slack user ids (optional)
// Then set the worker URL as the Slack app's Interactivity request URL. Full setup: website/slack/README.md
//
// approve -> repository_dispatch { event_type: "approve-post", client_payload: { slug, by } }
// reject  -> repository_dispatch { event_type: "reject-post",  client_payload: { slug, by } }
// revise  -> opens a modal; on submit: repository_dispatch { event_type: "revise-post", client_payload: { slug, by, notes } }
// edit    -> a plain URL button (GitHub's editor), nothing to do here
// The GitHub workflow in .github/workflows/blog-publish.yml does the actual publishing.

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') return new Response('ok', { status: 200 });
    const body = await request.text();
    if (!(await verifySlack(request, body, env.SLACK_SIGNING_SECRET))) return new Response('bad signature', { status: 401 });

    const payload = JSON.parse(new URLSearchParams(body).get('payload') || '{}');
    const user = payload.user || {};
    const allowed = (env.ALLOWED_USERS || '').split(',').map(s => s.trim()).filter(Boolean);
    const isAllowed = !allowed.length || allowed.includes(user.id);

    if (payload.type === 'view_submission') return onSubmit(payload, env, user);
    if (payload.type !== 'block_actions' || !payload.actions || !payload.actions.length) return new Response('', { status: 200 });

    const action = payload.actions[0];
    const slug = cleanSlug(action.value);
    if (!slug || !['approve', 'reject', 'revise'].includes(action.action_id)) return new Response('', { status: 200 });
    if (!isAllowed) {
      await respond(payload.response_url, { replace_original: false, response_type: 'ephemeral', text: 'Only the blog owner can do that.' });
      return new Response('', { status: 200 });
    }

    if (action.action_id === 'revise') {
      // Open a dialog for the change notes. The message is referenced so we can update it after submit.
      const meta = JSON.stringify({ slug, channel: payload.channel && payload.channel.id, ts: payload.message && payload.message.ts, response_url: payload.response_url });
      const view = {
        type: 'modal', callback_id: 'revise-post', private_metadata: meta,
        title: { type: 'plain_text', text: 'Request changes' },
        submit: { type: 'plain_text', text: 'Send to writer' }, close: { type: 'plain_text', text: 'Cancel' },
        blocks: [
          { type: 'section', text: { type: 'mrkdwn', text: '*' + slug + '*\nSay what should change and, if you can, why. Concrete beats polite: "cut the legal section", "intro is too long, two sentences max", "I never say _in practice_".' } },
          { type: 'input', block_id: 'notes', label: { type: 'plain_text', text: 'Notes for the writer' },
            element: { type: 'plain_text_input', action_id: 'notes', multiline: true, max_length: 3000, placeholder: { type: 'plain_text', text: 'What to change, and why' } } }
        ]
      };
      const r = await slack('views.open', env, { trigger_id: payload.trigger_id, view });
      if (!r.ok) await respond(payload.response_url, { replace_original: false, response_type: 'ephemeral', text: 'Could not open the dialog: ' + r.error + '. Is SLACK_BOT_TOKEN set on the worker?' });
      return new Response('', { status: 200 });
    }

    const eventType = action.action_id === 'approve' ? 'approve-post' : 'reject-post';
    const gh = await dispatch(env, eventType, { slug, by: who(user) });
    const ok = gh.status === 204;
    const verb = action.action_id === 'approve' ? 'Approved' : 'Rejected';
    // keep the original message but swap the buttons for a status line
    const blocks = (payload.message && payload.message.blocks || []).filter(b => b.type !== 'actions');
    blocks.push({ type: 'context', elements: [{ type: 'mrkdwn', text: ok
      ? `${verb} by ${mention(user)}. ${action.action_id === 'approve' ? 'Publishing now, the page appears after the site deploys.' : 'The draft is being retired.'}`
      : `${verb} by ${mention(user)}, but GitHub refused the dispatch (HTTP ${gh.status}). Check the worker's GITHUB_TOKEN.` }] });
    await respond(payload.response_url, { replace_original: true, blocks, text: `${verb}: ${slug}` });
    return new Response('', { status: 200 });
  }
};

async function onSubmit(payload, env, user) {
  const view = payload.view || {};
  if (view.callback_id !== 'revise-post') return new Response('', { status: 200 });
  let meta = {};
  try { meta = JSON.parse(view.private_metadata || '{}'); } catch {}
  const slug = cleanSlug(meta.slug);
  const notes = (((view.state || {}).values || {}).notes || {}).notes;
  const text = notes && notes.value ? notes.value.trim() : '';
  if (!slug || !text) return json({ response_action: 'errors', errors: { notes: 'Write at least one sentence.' } });

  const gh = await dispatch(env, 'revise-post', { slug, by: who(user), notes: text });
  const ok = gh.status === 204;
  // Close the modal first (Slack waits max 3 s), then update the message.
  const status = ok
    ? `Changes requested by ${mention(user)}. The writer rewrites the draft and posts the new preview here.\n> ${text.replace(/\n/g, '\n> ')}`
    : `Change request by ${mention(user)} failed: GitHub refused the dispatch (HTTP ${gh.status}).`;
  if (meta.channel && meta.ts) {
    await slack('chat.postMessage', env, { channel: meta.channel, thread_ts: meta.ts, text: status });
  } else if (meta.response_url) {
    await respond(meta.response_url, { replace_original: false, text: status });
  }
  return json({ response_action: 'clear' });
}

function cleanSlug(v) { return String(v || '').replace(/[^a-z0-9-]/g, ''); }
function who(user) { return user.username || user.name || user.id || 'unknown'; }
function mention(user) { return user.id ? '<@' + user.id + '>' : (user.username ? '@' + user.username : 'someone'); }
function json(obj) { return new Response(JSON.stringify(obj), { status: 200, headers: { 'Content-Type': 'application/json' } }); }

async function dispatch(env, event_type, client_payload) {
  return fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + env.GITHUB_TOKEN, Accept: 'application/vnd.github+json', 'User-Agent': 'transcriber-blog-approval', 'Content-Type': 'application/json' },
    body: JSON.stringify({ event_type, client_payload })
  });
}

async function slack(method, env, body) {
  const r = await fetch('https://slack.com/api/' + method, {
    method: 'POST', headers: { 'Content-Type': 'application/json; charset=utf-8', Authorization: 'Bearer ' + (env.SLACK_BOT_TOKEN || '') },
    body: JSON.stringify(body)
  });
  return r.json();
}

async function respond(url, msg) {
  if (!url) return;
  await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(msg) });
}

async function verifySlack(request, body, secret) {
  if (!secret) return false;
  const ts = request.headers.get('x-slack-request-timestamp') || '';
  const sig = request.headers.get('x-slack-signature') || '';
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;      // replay window
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`v0:${ts}:${body}`));
  const hex = 'v0=' + [...new Uint8Array(mac)].map(b => b.toString(16).padStart(2, '0')).join('');
  if (hex.length !== sig.length) return false;
  let diff = 0;
  for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ sig.charCodeAt(i);
  return diff === 0;
}
