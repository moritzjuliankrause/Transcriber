#!/usr/bin/env node
// Google Search Console helper. No dependencies: signs a service-account JWT with node:crypto.
// Env: GSC_SERVICE_ACCOUNT_JSON (the key file as one line of JSON), SITE_URL (default from website/blog/config.json).
// The service account's email must be added as a user (Full) on the Search Console property.
//
//   node scripts/gsc.mjs queries [--days 28] [--limit 200]          top queries with clicks, impressions, ctr, position
//   node scripts/gsc.mjs quickwins [--days 28]                       queries at position 5 to 20 with impressions, grouped by page
//   node scripts/gsc.mjs pages [--days 28]                           per-page totals
//   node scripts/gsc.mjs sitemap-submit [url]                        (re)submit the sitemap index
//   node scripts/gsc.mjs sitemaps                                    list submitted sitemaps and their state

import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CFG = JSON.parse(readFileSync(join(ROOT, 'website', 'blog', 'config.json'), 'utf8'));
const SITE = (process.env.SITE_URL || CFG.siteUrl).replace(/\/$/, '');
const host = new URL(SITE).hostname;
const PROPERTY = process.env.GSC_PROPERTY || ('sc-domain:' + host.replace(/^www\./, ''));   // Domain property by default

const args = process.argv.slice(2);
const cmd = args.shift();
const opt = (n, d) => { const i = args.indexOf(n); if (i < 0) return d; const v = args[i + 1]; args.splice(i, 2); return v; };
const days = Number(opt('--days', '28'));
const limit = Number(opt('--limit', '200'));

const raw = process.env.GSC_SERVICE_ACCOUNT_JSON;
if (!raw) { console.error('GSC_SERVICE_ACCOUNT_JSON missing'); process.exit(2); }
const sa = JSON.parse(raw);

async function token() {
  const now = Math.floor(Date.now() / 1000);
  const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
  const unsigned = b64({ alg: 'RS256', typ: 'JWT' }) + '.' + b64({ iss: sa.client_email, scope: 'https://www.googleapis.com/auth/webmasters', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 });
  const sig = createSign('RSA-SHA256').update(unsigned).sign(sa.private_key, 'base64url');
  const r = await fetch('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: unsigned + '.' + sig }) });
  const j = await r.json();
  if (!j.access_token) throw new Error('token: ' + JSON.stringify(j));
  return j.access_token;
}
async function api(path, method = 'GET', body) {
  const t = await token();
  const r = await fetch('https://www.googleapis.com/webmasters/v3/sites/' + encodeURIComponent(PROPERTY) + path, { method, headers: { Authorization: 'Bearer ' + t, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  if (r.status === 204) return {};
  const j = await r.json();
  if (j.error) throw new Error(j.error.message || JSON.stringify(j.error));
  return j;
}
const iso = d => d.toISOString().slice(0, 10);
const range = () => { const end = new Date(Date.now() - 2 * 86400e3); const start = new Date(end.getTime() - days * 86400e3); return { startDate: iso(start), endDate: iso(end) }; };
const out = o => process.stdout.write(JSON.stringify(o, null, 2) + '\n');

try {
  if (cmd === 'queries' || cmd === 'quickwins') {
    const j = await api('/searchAnalytics/query', 'POST', { ...range(), dimensions: ['query', 'page'], rowLimit: 5000 });
    let rows = (j.rows || []).map(r => ({ query: r.keys[0], page: r.keys[1], clicks: r.clicks, impressions: r.impressions, ctr: +(r.ctr * 100).toFixed(1), position: +r.position.toFixed(1) }));
    if (cmd === 'quickwins') {
      rows = rows.filter(r => r.position >= 5 && r.position <= 20 && r.impressions >= 10).sort((a, b) => b.impressions - a.impressions);
      const byPage = {};
      for (const r of rows) (byPage[r.page] ||= []).push(r);
      out(Object.entries(byPage).map(([page, qs]) => ({ page, impressions: qs.reduce((s, q) => s + q.impressions, 0), queries: qs.slice(0, 15) })).sort((a, b) => b.impressions - a.impressions));
    } else out(rows.sort((a, b) => b.impressions - a.impressions).slice(0, limit));
  } else if (cmd === 'pages') {
    const j = await api('/searchAnalytics/query', 'POST', { ...range(), dimensions: ['page'], rowLimit: 1000 });
    out((j.rows || []).map(r => ({ page: r.keys[0], clicks: r.clicks, impressions: r.impressions, position: +r.position.toFixed(1) })).sort((a, b) => b.impressions - a.impressions));
  } else if (cmd === 'sitemap-submit') {
    const url = args[0] || (SITE + '/sitemap.xml');
    await api('/sitemaps/' + encodeURIComponent(url), 'PUT');
    out({ submitted: url });
  } else if (cmd === 'sitemaps') {
    out((await api('/sitemaps')).sitemap || []);
  } else { console.error('usage: gsc.mjs queries|quickwins|pages|sitemap-submit|sitemaps'); process.exit(2); }
} catch (e) { console.error(String(e.message || e)); process.exit(1); }
