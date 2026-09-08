#!/usr/bin/env node
// DataForSEO helper for the keyword routines. No dependencies. Reads DATAFORSEO_AUTH (login:password, plain
// or already base64) from the environment. Prints JSON to stdout.
//
//   node scripts/dataforseo.mjs overview   "record teams meeting mac" ["second keyword" ...]   volume, cpc, competition, difficulty
//   node scripts/dataforseo.mjs suggest    "record call mac" [--limit 40]                       keyword ideas with volume
//   node scripts/dataforseo.mjs serp       "record teams meeting mac"                           live top 10 organic results
//   node scripts/dataforseo.mjs ranked     otter.ai [--limit 50]                                keywords a competitor domain ranks for
//
// Options: --lang en|de (default en), --loc 2840 (US) | 2276 (DE) | 2826 (UK), default 2840 for en and 2276 for de.

const API = 'https://api.dataforseo.com/v3';
const args = process.argv.slice(2);
const cmd = args.shift();
const opt = (name, def) => { const i = args.indexOf(name); if (i < 0) return def; const v = args[i + 1]; args.splice(i, 2); return v; };
const lang = opt('--lang', 'en');
const limit = Number(opt('--limit', '40'));
const loc = Number(opt('--loc', lang === 'de' ? '2276' : '2840'));
const auth = process.env.DATAFORSEO_AUTH || '';
if (!auth) { console.error('DATAFORSEO_AUTH missing (login:password)'); process.exit(2); }
const basic = /^[A-Za-z0-9+/=]+$/.test(auth) && !auth.includes(':') ? auth : Buffer.from(auth).toString('base64');

async function post(path, body, attempt = 1) {
  const r = await fetch(API + path, { method: 'POST', headers: { Authorization: 'Basic ' + basic, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const j = await r.json();
  // 40104 ("verify your account") and 5xx show up intermittently right after signup; retry a few times.
  if ((j.status_code === 40104 || j.status_code >= 50000) && attempt < 5) { await new Promise(res => setTimeout(res, 1500 * attempt)); return post(path, body, attempt + 1); }
  if (j.status_code !== 20000) throw new Error('DataForSEO ' + j.status_code + ' ' + j.status_message);
  const task = j.tasks && j.tasks[0];
  if (!task || task.status_code !== 20000) throw new Error('DataForSEO task ' + (task ? task.status_code + ' ' + task.status_message : 'missing'));
  return task.result || [];
}
const out = o => process.stdout.write(JSON.stringify(o, null, 2) + '\n');

try {
  if (cmd === 'overview') {
    const keywords = args.filter(Boolean);
    if (!keywords.length) throw new Error('keywords missing');
    const res = await post('/dataforseo_labs/google/keyword_overview/live', [{ keywords, language_code: lang, location_code: loc }]);
    const items = (res[0] && res[0].items) || [];
    out(items.map(i => ({
      keyword: i.keyword,
      volume: i.keyword_info && i.keyword_info.search_volume,
      cpc: i.keyword_info && i.keyword_info.cpc,
      competition: i.keyword_info && i.keyword_info.competition_level,
      difficulty: i.keyword_properties && i.keyword_properties.keyword_difficulty,
      intent: i.search_intent_info && i.search_intent_info.main_intent,
      trend: i.keyword_info && i.keyword_info.monthly_searches ? i.keyword_info.monthly_searches.slice(0, 6).map(m => m.search_volume) : null
    })));
  } else if (cmd === 'suggest') {
    const seed = args[0]; if (!seed) throw new Error('seed keyword missing');
    const res = await post('/dataforseo_labs/google/keyword_suggestions/live', [{ keyword: seed, language_code: lang, location_code: loc, limit, include_seed_keyword: true, order_by: ['keyword_info.search_volume,desc'] }]);
    const items = (res[0] && res[0].items) || [];
    out(items.map(i => ({ keyword: i.keyword, volume: i.keyword_info && i.keyword_info.search_volume, difficulty: i.keyword_properties && i.keyword_properties.keyword_difficulty, intent: i.search_intent_info && i.search_intent_info.main_intent })).filter(k => k.volume));
  } else if (cmd === 'serp') {
    const keyword = args[0]; if (!keyword) throw new Error('keyword missing');
    const res = await post('/serp/google/organic/live/regular', [{ keyword, language_code: lang, location_code: loc, depth: 10 }]);
    const items = ((res[0] && res[0].items) || []).filter(i => i.type === 'organic');
    out(items.map(i => ({ rank: i.rank_absolute, title: i.title, url: i.url, domain: i.domain, description: i.description })));
  } else if (cmd === 'ranked') {
    const target = args[0]; if (!target) throw new Error('domain missing');
    const res = await post('/dataforseo_labs/google/ranked_keywords/live', [{ target, language_code: lang, location_code: loc, limit, order_by: ['keyword_data.keyword_info.search_volume,desc'] }]);
    const items = (res[0] && res[0].items) || [];
    out(items.map(i => ({ keyword: i.keyword_data.keyword, volume: i.keyword_data.keyword_info && i.keyword_data.keyword_info.search_volume, difficulty: i.keyword_data.keyword_properties && i.keyword_data.keyword_properties.keyword_difficulty, position: i.ranked_serp_element && i.ranked_serp_element.serp_item && i.ranked_serp_element.serp_item.rank_absolute, url: i.ranked_serp_element && i.ranked_serp_element.serp_item && i.ranked_serp_element.serp_item.url })));
  } else {
    console.error('usage: dataforseo.mjs overview|suggest|serp|ranked ...'); process.exit(2);
  }
} catch (e) { console.error(String(e.message || e)); process.exit(1); }
