#!/usr/bin/env node
// Collects everything the writing routines read, into keywords/data/*.json. Runs in GitHub Actions
// with the secrets; the routines only read the files. Each file carries a fetchedAt timestamp.
//
//   overview.json     volume/difficulty/intent for: backlog keywords, seed keywords, top suggestions, competitor keywords
//   suggestions.json  keyword ideas per seed (from site-config lanes), with volume and difficulty
//   competitors.json  keywords one competitor domain ranks for (rotates daily through the list)
//   serp.json         live top 10 for the 12 strongest unshipped candidates (for the competitor pass)
//   quickwins.json    Search Console queries at position 5 to 20, grouped by page (empty until data exists)
//   gsc-pages.json    per-page totals from Search Console

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'keywords', 'data');
mkdirSync(OUT, { recursive: true });
const now = new Date().toISOString();
const run = (script, args) => { try { return JSON.parse(execFileSync('node', [join(ROOT, 'scripts', script), ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })); } catch (e) { console.error(`${script} ${args[0]}: ${(e.stderr || e.message).toString().trim().slice(0, 200)}`); return null; } };
const save = (name, data) => { writeFileSync(join(OUT, name), JSON.stringify({ fetchedAt: now, ...data }, null, 1) + '\n'); console.log(name, 'written'); };

const SEEDS = ['record zoom call mac', 'record teams meeting mac', 'transcribe google meet', 'record facetime call', 'meeting transcription without bot', 'offline transcription mac', 'local transcription', 'summarize meeting transcript', 'transcript to srt', 'call transcription app mac', 'record system audio mac', 'speaker diarization'];
const COMPETITORS = ['otter.ai', 'fireflies.ai', 'tldv.io', 'fathom.video', 'granola.ai', 'krisp.ai', 'goodsnooze.gumroad.com'];

// Relevance filter for candidates: competitor domains rank for their own brand and for unrelated terms.
const TOPIC = /\b(record|recording|transcri|meeting|call|calls|note|notes|audio|speaker|diariz|subtitle|srt|summar|zoom|teams|meet|facetime|whatsapp|webex|discord|slack|huddle|mac|macos|offline|local|privacy|gdpr|alternative|alternatives|vs|dictat|voice|interview|podcast)\b/i;
const relevant = k => TOPIC.test(k);
const backlog = existsSync(join(ROOT, 'website/blog/BACKLOG.md')) ? [...readFileSync(join(ROOT, 'website/blog/BACKLOG.md'), 'utf8').matchAll(/^\s+keyword: (.+)$/gm)].map(m => m[1].trim()) : [];
const shipped = existsSync(join(ROOT, 'keywords/shipped.json')) ? Object.keys(JSON.parse(readFileSync(join(ROOT, 'keywords/shipped.json'), 'utf8'))) : [];

if (process.env.DATAFORSEO_AUTH) {
  const suggestions = {};
  for (const s of SEEDS) { const r = run('dataforseo.mjs', ['suggest', s, '--limit', '30']); if (r) suggestions[s] = r; }
  save('suggestions.json', { seeds: suggestions });

  const day = new Date().getUTCDay();
  const comp = COMPETITORS[day % COMPETITORS.length];
  const ranked = run('dataforseo.mjs', ['ranked', comp, '--limit', '60']);
  const prev = existsSync(join(OUT, 'competitors.json')) ? JSON.parse(readFileSync(join(OUT, 'competitors.json'), 'utf8')).domains || {} : {};
  if (ranked) prev[comp] = { fetchedAt: now, keywords: ranked };
  save('competitors.json', { domains: prev });

  const pool = new Map();
  for (const k of backlog) pool.set(k.toLowerCase(), 'backlog');
  for (const list of Object.values(suggestions)) for (const k of list.slice(0, 15)) pool.set(k.keyword.toLowerCase(), 'suggestion');
  for (const d of Object.values(prev)) for (const k of (d.keywords || []).slice(0, 20)) if (k.keyword) pool.set(k.keyword.toLowerCase(), 'competitor');
  const kws = [...pool.keys()].slice(0, 300);
  const overview = [];
  for (let i = 0; i < kws.length; i += 100) { const r = run('dataforseo.mjs', ['overview', ...kws.slice(i, i + 100)]); if (r) overview.push(...r.map(x => ({ ...x, source: pool.get(x.keyword.toLowerCase()), relevant: relevant(x.keyword) }))); }
  save('overview.json', { keywords: overview });

  const candidates = overview.filter(k => k.relevant && k.volume >= 20 && (k.difficulty ?? 0) <= 30 && !shipped.includes(k.keyword.toLowerCase()) && !COMPETITORS.some(d => k.keyword.toLowerCase().replace(/\s+/g, '').includes(d.split('.')[0]))).sort((a, b) => b.volume - a.volume).slice(0, 12);
  const serp = {};
  for (const c of candidates) { const r = run('dataforseo.mjs', ['serp', c.keyword]); if (r) serp[c.keyword] = r; }
  save('serp.json', { candidates: candidates.map(c => c.keyword), results: serp });
} else console.log('DATAFORSEO_AUTH missing, keyword files not refreshed');

if (process.env.GSC_SERVICE_ACCOUNT_JSON) {
  const qw = run('gsc.mjs', ['quickwins']); save('quickwins.json', { pages: qw || [] });
  const pg = run('gsc.mjs', ['pages']); save('gsc-pages.json', { pages: pg || [] });
} else console.log('GSC_SERVICE_ACCOUNT_JSON missing, Search Console files not refreshed');
