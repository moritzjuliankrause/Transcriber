#!/usr/bin/env node
// Lint for one post beyond what build-blog.mjs --check does: banned words and phrases from WRITING.md,
// brand mentions, quick-answer length, internal links, FAQ count. Exit 1 on hard fails.
//   node scripts/check-draft.mjs website/blog/posts/<slug>.md
import { readFileSync } from 'node:fs';
const file = process.argv[2]; if (!file) { console.error('usage: check-draft.mjs <post.md>'); process.exit(2); }
const raw = readFileSync(file, 'utf8');
const m = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/); if (!m) { console.error('no frontmatter'); process.exit(1); }
const [, fm, body] = m;
const problems = [], warnings = [];
const banned = 'delve,tapestry,landscape,robust,seamless,cutting-edge,groundbreaking,transformative,unprecedented,pivotal,leverage,harness,unlock,unleash,navigate,foster,elevate,embark,furthermore,moreover,additionally,consequently,notably,compelling,innovative,dynamic,utilize,comprehensive,paramount,meticulous,game-changer,streamline,scalable,crucial,remarkable,profound,multifaceted,nuanced,facilitate,endeavor,resonate,bolster,underscore,illuminate,empower,supercharge,skyrocket,cultivate,revolutionary,next generation,game changer,powerful,intelligent,smart'.split(',');
const phrases = ["here's the thing", "let's dive in", "it's worth noting", 'in conclusion', 'at the end of the day', "in today's world", 'when it comes to', 'that being said', 'a testament to', 'the hard part', 'not just', "isn't just"];
const text = raw.toLowerCase();
for (const w of banned) if (new RegExp('\\b' + w.replace(/[-]/g, '\\-') + '\\b', 'i').test(text)) problems.push('banned word: ' + w);
for (const p of phrases) if (text.includes(p)) problems.push('banned phrase: ' + p);
if (/[–—]/.test(raw)) problems.push('en/em dash');
if (!/^draft:\s*true/m.test(fm)) warnings.push('draft is not true (fine for a published post, wrong for a new draft)');
const faq = (fm.match(/^\s+- q:/gm) || []).length; if (faq < 4) warnings.push('only ' + faq + ' FAQ entries (want 4 to 8)');
const brand = (body.match(/\bTranscriber\b/g) || []).length; if (brand > 3) warnings.push('brand named ' + brand + ' times in body (max 3)');
const first = body.trim().split(/\n\s*\n/)[0] || ''; const sentences = first.split(/(?<=[.!?])\s+/).length;
if (sentences > 5) warnings.push('first paragraph has ' + sentences + ' sentences, the quick answer should be 2 to 4');
if (!/\]\(\/blog\/[a-z0-9-]+\/\)/.test(body)) warnings.push('no internal link to another /blog/<slug>/ post');
if (!/gettranscriber\.com\/?\)/.test(body) && !/\]\(\/\)/.test(body)) warnings.push('no link to the landing page');
const words = body.split(/\s+/).filter(Boolean).length; if (words < 600 || words > 1500) warnings.push(words + ' words (articles 700 to 1,200, comparisons 800 to 1,400)');
const h1 = (body.match(/^#\s/gm) || []).length; if (h1) problems.push('H1 in body');
if (/^##\s*(conclusion|fazit|summary)/im.test(body)) warnings.push('conclusion heading, the build renders the closing paragraph');
for (const p of problems) console.log('FAIL ' + p);
for (const w of warnings) console.log('warn ' + w);
console.log(problems.length ? 'check-draft: ' + problems.length + ' hard fail(s)' : 'check-draft: ok, ' + words + ' words');
process.exit(problems.length ? 1 : 0);
