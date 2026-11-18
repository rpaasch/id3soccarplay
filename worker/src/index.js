// ID3Maps Worker — M0 build hosting + signing delivery.
//
// Public:
//   GET  /                → install page (itms-services)
//   GET  /manifest.plist  → OTA manifest pointing at /app.ipa
//   GET  /app.ipa         → the signed Ad Hoc IPA (from KV)
//
// CI (authenticated by GitHub Actions OIDC for this repo):
//   GET  /ci/signing      → returns SIGNING_BUNDLE_B64 (cert + profile) for the runner
//   POST /ci/upload?build=N&version=V&notes=... → stores the uploaded IPA + metadata
//
// No pre-shared secret lives in the public repo: the runner proves its identity
// with a short-lived GitHub OIDC token, which this Worker verifies against
// GitHub's JWKS and the expected repository + audience claims.

const GH_ISSUER = "https://token.actions.githubusercontent.com";
const JWKS_URL = `${GH_ISSUER}/.well-known/jwks`;

let jwksCache = null;
let jwksCacheAt = 0;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const p = url.pathname;
    try {
      if (p === "/" || p === "/index.html") return installPage(request, env);
      if (p === "/manifest.plist") return manifest(request, env);
      if (p === "/app.ipa") return serveIpa(env);
      if (p === "/ci/signing") return ciSigning(request, env);
      if (p === "/ci/upload") return ciUpload(request, env);
      if (p === "/icon.png") return servePng(env);
      if (p === "/health") return new Response("ok", { status: 200 });
      return new Response("Not found", { status: 404 });
    } catch (e) {
      return new Response("error: " + (e && e.message ? e.message : String(e)), { status: 500 });
    }
  },
};

// ---------- public ----------

async function meta(env) {
  const m = await env.STATE.get("meta", "json");
  return m || null;
}

async function installPage(request, env) {
  const origin = new URL(request.url).origin;
  const m = await meta(env);
  const ver = m ? `${m.version} (build ${m.build})` : "– endnu intet build –";
  const when = m ? new Date(m.uploadedAt).toLocaleString("da-DK") : "";
  const canInstall = !!m;
  const link = `itms-services://?action=download-manifest&amp;url=${origin}/manifest.plist`;
  const html = `<!doctype html><html lang="da"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Installér VW ID.3 Maps</title>
<style>
 :root{color-scheme:light dark}
 body{font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:0 auto;padding:2rem 1rem;line-height:1.5}
 h1{font-size:1.5rem}
 .btn{display:block;text-align:center;background:#0a84ff;color:#fff;text-decoration:none;
      padding:1rem;border-radius:12px;font-size:1.2rem;font-weight:600;margin:1.5rem 0}
 .btn.off{background:#8884;color:#8a8a8a;pointer-events:none}
 .muted{color:#8a8a8a;font-size:.9rem}
 code{background:#8883;padding:.1em .3em;border-radius:5px}
</style></head><body>
<h1>VW ID.3 Maps</h1>
<p>Build: <b>${ver}</b>${when ? ` · ${when}` : ""}</p>
<p>Åbn denne side i <b>Safari på iPhonen</b> og tryk:</p>
<a class="btn${canInstall ? "" : " off"}" href="${canInstall ? link : "#"}">Installér appen</a>
<p class="muted">Efter installation: <b>Indstillinger → Generelt → VPN og enhedsadministration</b> →
stol på udvikleren, før du åbner appen første gang.</p>
<p class="muted">Derefter: Apple Maps → din profil → <b>Køretøjer</b> → se om «VW ID.3» dukker op,
og planlæg en lang rute (fx København–Aarhus) for at se, om der foreslås ladestop.</p>
</body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

async function manifest(request, env) {
  const origin = new URL(request.url).origin;
  const m = await meta(env);
  const version = m ? m.version : "0.1.0";
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array>
    <dict>
      <key>kind</key><string>software-package</string>
      <key>url</key><string>${origin}/app.ipa</string>
    </dict>
    <dict>
      <key>kind</key><string>display-image</string>
      <key>url</key><string>${origin}/icon.png</string>
    </dict>
    <dict>
      <key>kind</key><string>full-size-image</string>
      <key>url</key><string>${origin}/icon.png</string>
    </dict>
  </array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>com.porsche.one</string>
    <key>bundle-version</key><string>${version}</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>VW ID.3 Maps</string>
  </dict>
</dict></array></dict></plist>`;
  return new Response(plist, { headers: { "content-type": "text/xml; charset=utf-8" } });
}

async function serveIpa(env) {
  const ipa = await env.STATE.get("ipa", "arrayBuffer");
  if (!ipa) return new Response("No build uploaded yet", { status: 404 });
  return new Response(ipa, {
    headers: {
      "content-type": "application/octet-stream",
      "content-disposition": 'attachment; filename="ID3Maps.ipa"',
    },
  });
}

// ---------- CI (OIDC-gated) ----------

async function ciSigning(request, env) {
  const claims = await requireOIDC(request, env);
  if (claims instanceof Response) return claims;
  // Stored in KV (too large for a Worker secret); only reachable via this
  // OIDC-gated endpoint, never publicly.
  const bundle = await env.STATE.get("signing_b64");
  if (!bundle) return new Response("signing bundle not configured", { status: 503 });
  return new Response(bundle, { headers: { "content-type": "text/plain" } });
}

async function ciUpload(request, env) {
  if (request.method !== "POST") return new Response("POST only", { status: 405 });
  const claims = await requireOIDC(request, env);
  if (claims instanceof Response) return claims;
  const url = new URL(request.url);
  const body = await request.arrayBuffer();
  if (!body || body.byteLength < 1000) return new Response("empty/small ipa", { status: 400 });
  await env.STATE.put("ipa", body);
  const m = {
    version: url.searchParams.get("version") || "0.1.0",
    build: url.searchParams.get("build") || "?",
    notes: url.searchParams.get("notes") || "",
    uploadedAt: Date.now(),
    bytes: body.byteLength,
  };
  await env.STATE.put("meta", JSON.stringify(m));
  return new Response(JSON.stringify({ ok: true, ...m }), {
    headers: { "content-type": "application/json" },
  });
}

// ---------- OIDC verification ----------

async function requireOIDC(request, env) {
  const auth = request.headers.get("authorization") || "";
  const m = auth.match(/^Bearer\s+(.+)$/i);
  if (!m) return new Response("missing bearer token", { status: 401 });
  try {
    const claims = await verifyGithubOIDC(m[1]);
    if (claims.iss !== GH_ISSUER) return new Response("bad iss", { status: 403 });
    if (env.OIDC_AUDIENCE && claims.aud !== env.OIDC_AUDIENCE) return new Response("bad aud", { status: 403 });
    if (env.GH_REPO && claims.repository !== env.GH_REPO) return new Response("bad repo", { status: 403 });
    return claims;
  } catch (e) {
    return new Response("oidc verify failed: " + (e && e.message ? e.message : String(e)), { status: 403 });
  }
}

async function getJwks() {
  const now = Date.now();
  if (jwksCache && now - jwksCacheAt < 3600_000) return jwksCache;
  const res = await fetch(JWKS_URL, { cf: { cacheTtl: 3600 } });
  if (!res.ok) throw new Error("jwks fetch " + res.status);
  jwksCache = await res.json();
  jwksCacheAt = now;
  return jwksCache;
}

function b64urlToBytes(s) {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function verifyGithubOIDC(token) {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("not a jwt");
  const header = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[0])));
  const payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(parts[1])));
  if (header.alg !== "RS256") throw new Error("alg " + header.alg);

  const jwks = await getJwks();
  const jwk = (jwks.keys || []).find((k) => k.kid === header.kid);
  if (!jwk) throw new Error("kid not found");

  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"]
  );
  const data = new TextEncoder().encode(parts[0] + "." + parts[1]);
  const sig = b64urlToBytes(parts[2]);
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, sig, data);
  if (!ok) throw new Error("bad signature");

  const now = Math.floor(Date.now() / 1000);
  if (payload.exp && now > payload.exp + 60) throw new Error("expired");
  if (payload.nbf && now < payload.nbf - 60) throw new Error("not yet valid");
  return payload;
}


const ICON_B64 = "iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAIAAAB7GkOtAAAFnUlEQVR42u3VMQ0AAAgEsZ/RjW/wwEqTKrjlUj0APBQJAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAAAxABQADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAADUAHAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADADAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADADAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAMQAIAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAAA1ABwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAwABUADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAMAwAAAMAAADAAAAwDAAAAwAAAMAAADAMAAADAAAAwAAAMAwAAAMAAADAAAAwDAAAC4WZLTXQ3XrQ1MAAAAAElFTkSuQmCC";
function servePng() {
  const bin = atob(ICON_B64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new Response(bytes, { headers: { "content-type": "image/png", "cache-control": "public, max-age=86400" } });
}
