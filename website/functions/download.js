// GET /download  ->  302 to the newest release asset (.dmg preferred, else .zip).
// Cloudflare Pages Function. GitHub's /releases/latest only points at a web page and the asset name
// carries the version, so this is the one stable download link for the website.
// Optional secret GITHUB_TOKEN (Pages project settings) lets it work while the repo is private.
const REPO = 'moritzjuliankrause/Transcriber';
const FALLBACK = `https://github.com/${REPO}/releases/latest`;

export async function onRequestGet({ env }) {
  const headers = { 'User-Agent': 'gettranscriber.com download redirect', Accept: 'application/vnd.github+json' };
  if (env.GITHUB_TOKEN) headers.Authorization = 'Bearer ' + env.GITHUB_TOKEN;
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers, cf: { cacheTtl: 300, cacheEverything: true } });
    if (r.ok) {
      const rel = await r.json();
      const assets = rel.assets || [];
      const pick = assets.find(a => /\.dmg$/i.test(a.name)) || assets.find(a => /\.zip$/i.test(a.name));
      if (pick) return Response.redirect(pick.browser_download_url, 302);
    }
  } catch {}
  return Response.redirect(FALLBACK, 302);
}
