#!/usr/bin/env node
// Tells search engines about new URLs. Reads the live sitemaps, compares with status/indexed.json,
// submits new URLs to IndexNow (Bing, Yandex, Naver, Seznam share the endpoint) and, on Sundays or
// with --sitemap, resubmits the sitemap index to Google via scripts/gsc.mjs. Google has no public
// per-URL API for normal sites, the sitemap ping is what there is.
// Env: INDEXNOW_KEY (the key; website/<key>.txt must exist with the key as content), SITE_URL optional.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const CFG = JSON.parse(readFileSync(join(ROOT, 'website', 'blog', 'config.json'), 'utf8'));
const SITE = (process.env.SITE_URL || CFG.siteUrl).replace(/\/$/, '');
const KEY = process.env.INDEXNOW_KEY || '';
const STATE = join(ROOT, 'status', 'indexed.json');
const force = process.argv.includes('--all');
const wantSitemap = process.argv.includes('--sitemap') || new Date().getUTCDay() === 0;

async function urlsFrom(sitemapUrl, seen = new Set()) {
  const xml = await (await fetch(sitemapUrl)).text();
  const locs = [...xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/g)].map(m => m[1]);
  const isIndex = /<sitemapindex/i.test(xml);
  for (const l of locs) { if (isIndex) await urlsFrom(l, seen); else seen.add(l); }
  return seen;
}
const all = [...await urlsFrom(SITE + '/sitemap.xml')].filter(u => !u.includes('/blog/preview/'));
const done = existsSync(STATE) ? JSON.parse(readFileSync(STATE, 'utf8')) : {};
const fresh = force ? all : all.filter(u => !done[u]);
const report = { total: all.length, new: fresh.length, indexnow: null, sitemap: null };

if (fresh.length) {
  if (!KEY) report.indexnow = 'skipped: INDEXNOW_KEY missing';
  else {
    const r = await fetch('https://api.indexnow.org/indexnow', { method: 'POST', headers: { 'Content-Type': 'application/json; charset=utf-8' }, body: JSON.stringify({ host: new URL(SITE).hostname, key: KEY, keyLocation: SITE + '/' + KEY + '.txt', urlList: fresh }) });
    report.indexnow = 'HTTP ' + r.status;
    if (r.status === 200 || r.status === 202) { const now = new Date().toISOString(); for (const u of fresh) done[u] = now; }
  }
}
if (wantSitemap) {
  try { report.sitemap = process.env.GSC_SERVICE_ACCOUNT_JSON ? execSync('node scripts/gsc.mjs sitemap-submit', { cwd: ROOT, encoding: 'utf8' }).trim() : 'skipped: GSC_SERVICE_ACCOUNT_JSON missing'; }
  catch (e) { report.sitemap = 'failed: ' + (e.stderr || e.message).toString().trim(); }
}
mkdirSync(dirname(STATE), { recursive: true });
writeFileSync(STATE, JSON.stringify(done, null, 2) + '\n');
console.log(JSON.stringify(report));
