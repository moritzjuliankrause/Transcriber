// Cloudflare Worker: receives Slack button clicks and turns them into GitHub repository_dispatch events.
//
// Deploy once (free tier is plenty):  npx wrangler deploy website/scripts/slack-approve-worker.js --name transcriber-blog-approval
// Secrets (wrangler secret put …):     SLACK_SIGNING_SECRET, GITHUB_TOKEN (fine-grained, "Contents: write" on the repo)
// Vars:                                GITHUB_REPO = moritzjkr/Transcriber, ALLOWED_USERS = comma-separated Slack user ids (optional)
// Then set the worker URL as the Slack app's Interactivity request URL.
//
// approve -> repository_dispatch { event_type: "approve-post", client_payload: { slug } }
// reject  -> repository_dispatch { event_type: "reject-post",  client_payload: { slug } }
// The GitHub workflow in .github/workflows/blog-publish.yml does the actual publishing.

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') return new Response('ok', { status: 200 });
    const body = await request.text();
    if (!(await verifySlack(request, body, env.SLACK_SIGNING_SECRET))) return new Response('bad signature', { status: 401 });

    const payload = JSON.parse(new URLSearchParams(body).get('payload') || '{}');
    if (payload.type !== 'block_actions' || !payload.actions || !payload.actions.length) return new Response('', { status: 200 });

    const action = payload.actions[0];
    const slug = String(action.value || '').replace(/[^a-z0-9-]/g, '');
    const user = payload.user || {};
    const allowed = (env.ALLOWED_USERS || '').split(',').map(s => s.trim()).filter(Boolean);
    if (allowed.length && !allowed.includes(user.id)) {
      await respond(payload.response_url, { replace_original: false, response_type: 'ephemeral', text: 'Only the blog owner can approve posts.' });
      return new Response('', { status: 200 });
    }
    if (!slug || !['approve', 'reject'].includes(action.action_id)) return new Response('', { status: 200 });

    const eventType = action.action_id === 'approve' ? 'approve-post' : 'reject-post';
    const gh = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + env.GITHUB_TOKEN, Accept: 'application/vnd.github+json', 'User-Agent': 'transcriber-blog-approval', 'Content-Type': 'application/json' },
      body: JSON.stringify({ event_type: eventType, client_payload: { slug, by: user.username || user.name || user.id } })
    });

    const who = user.username ? '@' + user.username : 'someone';
    const ok = gh.status === 204;
    const verb = action.action_id === 'approve' ? 'Approved' : 'Rejected';
    // keep the original message but swap the buttons for a status line
    const blocks = (payload.message && payload.message.blocks || []).filter(b => b.type !== 'actions');
    blocks.push({ type: 'context', elements: [{ type: 'mrkdwn', text: ok
      ? `${verb} by ${who}. ${action.action_id === 'approve' ? 'Publishing now, the page appears after the site deploys.' : 'The draft is being retired.'}`
      : `${verb} by ${who}, but GitHub refused the dispatch (HTTP ${gh.status}). Check the worker's GITHUB_TOKEN.` }] });
    await respond(payload.response_url, { replace_original: true, blocks, text: `${verb}: ${slug}` });
    return new Response('', { status: 200 });
  }
};

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
