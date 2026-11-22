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
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const p = url.pathname;
    try {
      if (p === "/" || p === "/index.html") return installPage(request, env);
      if (p === "/manifest.plist") return manifest(request, env);
      if (p === "/app.ipa") return serveIpa(env);
      if (p === "/ci/signing") return ciSigning(request, env);
      if (p === "/ci/upload") return ciUpload(request, env);
      if (p === "/icon.png") return servePng(env);
      if (p === "/oauth/start") return oauthStart(request, env);
      if (p === "/oauth/callback") return oauthCallback(request, env);
      if (p === "/smartcar/webhook") return smartcarWebhook(request, env);
      if (p === "/status") return statusEndpoint(request, env, ctx);
      if (p === "/learn") return learnEndpoint(request, env);
      if (p === "/trim") return trimEndpoint(request, env);
      if (p === "/shape") return shapeEndpoint(request, env);
      if (p === "/trips") return tripsEndpoint(request, env);
      if (p === "/gps") return gpsEndpoint(request, env);
      if (p === "/drive") return driveEndpoint(request, env);
      if (p === "/health") return new Response("ok", { status: 200 });
      return new Response("Not found", { status: 404 });
    } catch (e) {
      return new Response("error: " + (e && e.message ? e.message : String(e)), { status: 500 });
    }
  },

  // Cron (every 5 min): while the car is charging, sample it so we can learn the
  // real charging curve. Idle cars are NOT polled (webhooks + /status cover that).
  async scheduled(event, env, ctx) {
    ctx.waitUntil(cronTick(env));
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
  await env.STATE.put("ipa", body); // CI: must fail loudly
  const m = {
    version: url.searchParams.get("version") || "0.1.0",
    build: url.searchParams.get("build") || "?",
    notes: url.searchParams.get("notes") || "",
    uploadedAt: Date.now(),
    bytes: body.byteLength,
  };
  await env.STATE.put("meta", JSON.stringify(m)); // CI: must fail loudly
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

// ---------- Smartcar OAuth + webhook (M1) ----------

const SC_CONNECT = "https://connect.smartcar.com/oauth/authorize";
const SC_SCOPE = "read_battery read_charge read_vehicle_info";

// v3 Connect flow: redirect with the application_id and response_type=none
// (no auth-code exchange — the v2 per-vehicle token flow is deprecated Dec 2026).
// On success Smartcar redirects back with ?user_id=..., which we store.
async function oauthStart(request, env) {
  if (!env.SMARTCAR_APPLICATION_ID) return new Response("SMARTCAR_APPLICATION_ID not set", { status: 503 });
  const origin = new URL(request.url).origin;
  const params = new URLSearchParams({
    response_type: "none", // hosted flow; data arrives via webhook, not a callback
    application_id: env.SMARTCAR_APPLICATION_ID,
    scope: SC_SCOPE,
    mode: env.SMARTCAR_MODE || "live",
    external_id: "id3maps",
  });
  // Only add our callback if a redirect URI has been registered in Smartcar.
  if (env.SMARTCAR_USE_REDIRECT === "1") {
    params.set("response_type", "none");
    params.set("redirect_uri", `${origin}/oauth/callback`);
  }
  return Response.redirect(`${SC_CONNECT}?${params.toString()}`, 302);
}

async function oauthCallback(request, env) {
  const url = new URL(request.url);
  const err = url.searchParams.get("error");
  if (err) return htmlMsg("Afvist", `Smartcar returnerede: ${err} — ${url.searchParams.get("error_description") || ""}`);
  const userId = url.searchParams.get("user_id");
  if (!userId) return htmlMsg("Mangler user_id", "Ingen user_id i callback. Tjek at redirect-URI og application_id er korrekte.");
  await kvPut(env, "smartcar_user_id", userId);
  await kvPut(env, "smartcar_connection", JSON.stringify({ userId, connectedAt: Date.now() }));
  return htmlMsg("Forbundet ✅", "Din bil er koblet til. Du kan lukke denne side. Næste skridt (jeg guider dig) er at tilføje en webhook i Smartcar-dashboardet, så batteriniveauet skubbes hertil.");
}

function htmlMsg(title, msg) {
  return new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
    `<div style="font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem">` +
    `<h1>${title}</h1><p>${msg}</p></div>`,
    { headers: { "content-type": "text/html; charset=utf-8" } }
  );
}

async function hmacHex(key, msg) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function smartcarWebhook(request, env) {
  if (request.method !== "POST") return new Response("POST only", { status: 405 });
  const amt = env.SMARTCAR_AMT;
  if (!amt) return new Response("SMARTCAR_AMT not set", { status: 503 });
  const raw = await request.text();
  let evt;
  try { evt = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }

  // VERIFY handshake: echo HMAC of the challenge.
  if (evt.eventType === "VERIFY") {
    const challenge = evt?.data?.challenge || "";
    return new Response(JSON.stringify({ challenge: await hmacHex(amt, challenge) }),
      { headers: { "content-type": "application/json" } });
  }

  // All other events must carry a valid SC-Signature over the raw body.
  const sig = request.headers.get("SC-Signature") || "";
  const expect = await hmacHex(amt, raw);
  if (sig.toLowerCase() !== expect.toLowerCase()) return new Response("bad signature", { status: 401 });

  // Smartcar's "Test webhook" button sends a fake Tesla (mode TEST, SoC 78 %).
  // Never let that reach the snapshot Maps reads.
  const isTest = String(evt?.meta?.mode || "").toUpperCase() === "TEST" || evt?.data?.vehicle?.mode === "test";
  if (isTest) {
    await kvPut(env, "smartcar_last_test_event", raw);
    return new Response("ok", { status: 200 });
  }

  if (evt.eventType !== "VEHICLE_STATE") {
    await kvPut(env, "smartcar_last_other_event", raw); // e.g. VEHICLE_ERROR for signals the car lacks
    return new Response("ok", { status: 200 });
  }
  await kvPut(env, "smartcar_last_event", raw);
  const snap = extractSnapshot(evt);
  if (snap) {
    snap.source = "webhook";
    await storeSnapshotIfNewer(env, snap);
  }
  return new Response("ok", { status: 200 });
}

// Keep whichever measurement is newest (webhook pushes and polls race).
async function storeSnapshotIfNewer(env, snap) {
  if (!memSnap || (snap.measuredAt || 0) > (memSnap.measuredAt || 0)) memSnap = snap;
  else if (snap.measuredAt === memSnap.measuredAt) memSnap = { ...memSnap, ...snap }; // poll adds power etc.
  const cur = await env.STATE.get("snapshot", "json");
  if (cur && cur.measuredAt && snap.measuredAt && cur.measuredAt > snap.measuredAt) return false;
  // A webhook knows nothing about the charge type: keep what the last poll found while charging continues.
  if (cur && cur.charging === true && snap.charging === true && !snap.chargeKind && cur.chargeKind) snap.chargeKind = cur.chargeKind;
  // Same measurement again (polls while parked): nothing new, so spend no KV writes (free tier: 1000/day).
  if (cur && cur.measuredAt === snap.measuredAt && ["soc", "charging", "wattageW", "odometerKm", "rangeKm", "minutesToFull", "chargeKind", "connector"]
      .every(k => cur[k] === snap[k])) return false;
  await kvPut(env, "snapshot", JSON.stringify(snap));
  await learn(env, snap);
  return true;
}

// Parse a VEHICLE_STATE event per Smartcar's documented shape:
// data.signals[] where each has { code, name, group, body:{unit,value}, meta }.
// SoC code = "tractionbattery-stateofcharge" (value in percent).
function extractSnapshot(evt) {
  const signals = (evt && evt.data && Array.isArray(evt.data.signals)) ? evt.data.signals : [];
  const by = {};
  for (const s of signals) if (s && s.code) by[s.code] = s;

  const soc = by["tractionbattery-stateofcharge"];
  if (!soc || !soc.body || typeof soc.body.value !== "number") return null;

  const out = { receivedAt: Date.now() };
  out.soc = soc.body.value > 1.5 ? soc.body.value / 100 : soc.body.value; // -> 0..1

  const range = by["tractionbattery-range"];
  if (range && range.body && typeof range.body.value === "number") out.rangeKm = range.body.value;

  const charging = by["charge-ischarging"];
  if (charging && charging.body && typeof charging.body.value === "boolean") out.charging = charging.body.value;

  const odo = by["odometer-traveleddistance"];
  if (odo && odo.body && typeof odo.body.value === "number" && odo.status?.value === "SUCCESS") {
    out.odometerKm = odo.body.unit === "miles" ? odo.body.value * 1.609344 : odo.body.value;
  }
  const watt = by["charge-wattage"];
  if (watt && watt.body && typeof watt.body.value === "number" && watt.status?.value === "SUCCESS") out.wattageW = watt.body.value;

  // Prefer the OEM measurement time of the SoC signal.
  const t = soc.meta && (soc.meta.oemUpdatedAt || soc.meta.retrievedAt);
  const parsed = typeof t === "number" ? t : (typeof t === "string" ? Date.parse(t) : NaN);
  out.measuredAt = isNaN(parsed) ? Date.now() : parsed;
  return out;
}

// ---------- Smartcar polling (v3, M2M app token) ----------

const SC_IAM = "https://iam.smartcar.com/oauth2/token";
const SC_API = "https://vehicle.api.smartcar.com/v3";
const POLL_MIN_INTERVAL_MS = 3 * 60 * 1000; // never poll more often than this

async function scAppToken(env) {
  const cached = await env.STATE.get("sc_app_token", "json");
  if (cached && cached.expiresAt > Date.now() + 60_000) return cached.token;
  if (!env.SMARTCAR_CLIENT_ID || !env.SMARTCAR_CLIENT_SECRET) throw new Error("smartcar client credentials not set");
  const res = await fetch(SC_IAM, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: env.SMARTCAR_CLIENT_ID,
      client_secret: env.SMARTCAR_CLIENT_SECRET,
    }).toString(),
  });
  if (!res.ok) throw new Error("smartcar token HTTP " + res.status);
  const j = await res.json();
  const ttl = Math.max(60, (j.expires_in || 3600) - 120);
  await kvPut(env, "sc_app_token", JSON.stringify({ token: j.access_token, expiresAt: Date.now() + ttl * 1000 }), { expirationTtl: ttl });
  return j.access_token;
}

// Find the live, active connection (vehicle id + user id) and cache it.
async function scVehicle(env, token, forceRefresh) {
  if (!forceRefresh) {
    const cached = await env.STATE.get("sc_vehicle", "json");
    if (cached) return cached;
  }
  const res = await fetch(`${SC_API}/connections`, { headers: { authorization: `Bearer ${token}` } });
  if (!res.ok) throw new Error("smartcar connections HTTP " + res.status);
  const j = await res.json();
  const c = (j.data || []).find((x) => x.attributes?.status?.name === "ACTIVE" && x.attributes?.vehicle?.mode === "live");
  if (!c) throw new Error("no active live connection");
  const v = { vehicleId: c.relationships.vehicle.data.id, userId: c.relationships.user.data.id };
  await kvPut(env, "sc_vehicle", JSON.stringify(v), { expirationTtl: 86400 });
  return v;
}

async function scSignal(token, v, code) {
  const res = await fetch(`${SC_API}/vehicles/${v.vehicleId}/signals/${code}`, {
    headers: { authorization: `Bearer ${token}`, "sc-user-id": v.userId },
  });
  if (!res.ok) return { httpError: res.status };
  const j = await res.json();
  return { attrs: j.data?.attributes || {}, meta: j.data?.meta || {} };
}

async function pollSmartcar(env, retried) {
  memLastPoll = Date.now();
  await kvPut(env, "last_poll_at", String(Date.now()));
  const token = await scAppToken(env);
  const v = await scVehicle(env, token, !!retried);
  const needCap = !(await env.STATE.get("sc_capacity"));
  const prevSnap = await env.STATE.get("snapshot", "json");
  const wantWatt = prevSnap?.charging === true; // power is only meaningful while charging
  const skipTemp = !!(await env.STATE.get("temp_unavailable"));
  const [soc, range, chg, cap, odo, watt, temp, energy, ttc, conn] = await Promise.all([
    scSignal(token, v, "tractionbattery-stateofcharge"),
    scSignal(token, v, "tractionbattery-range"),
    scSignal(token, v, "charge-ischarging"),
    needCap ? scSignal(token, v, "tractionbattery-nominalcapacity") : Promise.resolve(null),
    scSignal(token, v, "odometer-traveleddistance"), // ERROR until the owner grants the permission
    wantWatt ? scSignal(token, v, "charge-wattage") : Promise.resolve(null),
    skipTemp ? Promise.resolve(null) : scSignal(token, v, "climate-externaltemperature"),
    wantWatt ? scSignal(token, v, "charge-energyadded") : Promise.resolve(null),
    wantWatt ? scSignal(token, v, "charge-timetocomplete") : Promise.resolve(null),
    wantWatt ? scSignal(token, v, "charge-chargingconnectortype") : Promise.resolve(null),
  ]);
  if (temp) {
    const tv = temp.attrs?.body;
    if (temp.attrs?.status?.value === "SUCCESS" && typeof tv?.value === "number") {
      const c = String(tv.unit || "").toLowerCase().startsWith("f") ? (tv.value - 32) * 5 / 9 : tv.value;
      const when = Date.parse(temp.meta?.oemUpdatedAt || "");
      const rounded = Math.round(c * 10) / 10;
      const prevTemp = await env.STATE.get("car_temp", "json");
      if (!prevTemp || prevTemp.t !== rounded) {
        await kvPut(env, "car_temp", JSON.stringify({ t: rounded, at: isNaN(when) ? Date.now() : when }));
      }
    } else {
      // Not enabled / not permitted / car can't report it: don't ask again for 30 min.
      await kvPut(env, "temp_unavailable", "1", { expirationTtl: 1800 });
    }
  }
  if (cap && cap.attrs?.body && typeof cap.attrs.body.capacity === "number") {
    // Gross kWh as selected in Smartcar Connect (e.g. 82 for an ID.3 Pro S).
    await kvPut(env, "sc_capacity", String(cap.attrs.body.capacity), { expirationTtl: 86400 });
  }
  if (soc.httpError && !retried) return pollSmartcar(env, true); // ids may be stale after a reconnect
  if (soc.httpError) throw new Error("soc HTTP " + soc.httpError);
  if (soc.attrs.status?.value !== "SUCCESS" || typeof soc.attrs.body?.value !== "number") {
    throw new Error("soc status " + (soc.attrs.status?.value || "?") + " " + JSON.stringify(soc.attrs.status?.error || ""));
  }
  const snap = { receivedAt: Date.now(), source: "poll" };
  snap.soc = soc.attrs.body.value / 100;
  const t = Date.parse(soc.meta.oemUpdatedAt || soc.meta.retrievedAt || "");
  snap.measuredAt = isNaN(t) ? Date.now() : t;
  if (range.attrs?.body && typeof range.attrs.body.value === "number") {
    const km = range.attrs.body.unit === "miles" ? range.attrs.body.value * 1.609344 : range.attrs.body.value;
    snap.rangeKm = Math.round(km * 10) / 10;
  }
  if (chg.attrs?.body && typeof chg.attrs.body.value === "boolean") snap.charging = chg.attrs.body.value;
  if (odo?.attrs?.status?.value === "SUCCESS" && typeof odo.attrs.body?.value === "number") {
    snap.odometerKm = odo.attrs.body.unit === "miles" ? odo.attrs.body.value * 1.609344 : odo.attrs.body.value;
  }
  if (watt?.attrs?.status?.value === "SUCCESS" && typeof watt.attrs.body?.value === "number") snap.wattageW = watt.attrs.body.value;
  if (energy?.attrs?.status?.value === "SUCCESS" && typeof energy.attrs.body?.value === "number") {
    snap.energyAddedKwh = energy.attrs.body.unit === "wh" ? energy.attrs.body.value / 1000 : energy.attrs.body.value;
  }
  if (ttc?.attrs?.status?.value === "SUCCESS" && typeof ttc.attrs.body?.value === "number" && ttc.attrs.body.value > 0) {
    snap.minutesToFull = Math.round(ttc.attrs.body.value);
  }
  if (conn?.attrs?.status?.value === "SUCCESS" && typeof conn.attrs.body?.value === "string") snap.connector = conn.attrs.body.value;
  if (snap.charging) snap.chargeKind = classifyCharge(snap.connector, snap.wattageW);
  await storeSnapshotIfNewer(env, snap);
  if (await env.STATE.get("last_poll_error")) await kvPut(env, "last_poll_error", "");
  return snap;
}

async function pollSafely(env) {
  try { return await pollSmartcar(env); }
  catch (e) { await kvPut(env, "last_poll_error", `${new Date().toISOString()} ${e.message || e}`); return null; }
}

// ---------- Learning from real driving and charging ----------
//
// Consumption (needs Odometer permission): every new measurement is compared with
// the previous one. Intervals where the car drove (odometer up), was not charging
// and SoC only fell are accumulated; a trip chunk is committed once it covers
// >= 25 km (SoC steps telescope, so quantisation error stays ~1 pp per chunk).
// Totals are kept per 5 C temperature band with slow forgetting.
//
// Charging: samples (SoC, kW) collected during a session are committed at the
// session's end -- but only for DC sessions (peak > 12 kW), so slow AC charging
// never pollutes the DC curve. The learned curve uses the 80th percentile of the
// last 10 samples per SoC decile and per temperature band: that approximates the
// car's own limit rather than a weak charger's.

const KM_CHUNK = 25;
const DC_MIN_KW = 12;

function tempBand(t) { return typeof t === "number" ? String(Math.floor(t / 5) * 5) : "na"; }

async function netCapacityKwh(env) {
  const gross = Number(await env.STATE.get("sc_capacity")) || 82;
  return Math.round(gross * 0.94);
}

async function learn(env, snap) {
  try {
    const log = (await env.STATE.get("measure_log", "json")) || [];
    const prevEntry = log[log.length - 1];
    log.push({ t: snap.measuredAt, soc: snap.soc, odo: snap.odometerKm ?? null, ch: snap.charging ?? null, kw: snap.wattageW ?? null, src: snap.source });
    // Diagnostic only: save at most every 2 min unless something structural changed (KV writes are scarce;
    // a fast charge reports every 1 pp, ~every 35 s). The charge session keeps its own samples.
    const structural = !prevEntry || prevEntry.ch !== (snap.charging ?? null) || prevEntry.odo !== (snap.odometerKm ?? null);
    if (structural || snap.measuredAt - (prevEntry?.savedAt ?? prevEntry?.t ?? 0) >= 2 * 60 * 1000) {
      log[log.length - 1].savedAt = snap.measuredAt;
      await kvPut(env, "measure_log", JSON.stringify(log.slice(-200)));
    }
    const t = (await outdoorTempInfo(env, null)).t;
    // Remember when the car last drove: a battery that was just driven charges much faster than a cold one.
    if (prevEntry && typeof prevEntry.odo === "number" && typeof snap.odometerKm === "number"
        && snap.odometerKm - prevEntry.odo >= 0.3 && snap.charging !== true) {
      const rd = await env.STATE.get("recent_drive", "json");
      if (!rd || snap.measuredAt - rd.at > 5 * 60 * 1000) await kvPut(env, "recent_drive", JSON.stringify({ at: snap.measuredAt }));
    }
    // VW often sends the last odometer step minutes after the car stopped (21 Nov: 27 km logged,
    // 58 km driven; the rest arrived with the charging start). Give it to the trip that just ended.
    const late = await lateOdometer(env, snap, prevEntry);
    await trackTrip(env, snap, late ? { ...prevEntry, odo: snap.odometerKm } : prevEntry, t, log);
    await learnConsumption(env, snap, t);
    await learnCharging(env, snap, t, log);
  } catch (e) {
    await kvPut(env, "learn_error", `${new Date().toISOString()} ${e.message || e}`);
  }
}

async function learnConsumption(env, snap, tempC) {
  if (typeof snap.odometerKm !== "number") return;
  const prev = await env.STATE.get("learn_anchor", "json");
  const cur = { soc: snap.soc, odo: snap.odometerKm, t: snap.measuredAt, charging: !!snap.charging };
  if (prev && cur.t <= prev.t) return; // not newer information
  // While parked or charging nothing moves: skip the write unless the odometer or charging state
  // changed, or the anchor is older than 30 min (saves hundreds of KV writes per fast charge).
  const moved = !prev || prev.odo !== cur.odo || prev.charging !== cur.charging || cur.t - prev.t > 30 * 60 * 1000;
  if (!moved) return;
  await kvPut(env, "learn_anchor", JSON.stringify(cur));
  if (!prev) return;

  const dKm = cur.odo - prev.odo;
  let dSoc = prev.soc - cur.soc;
  if (dSoc < 0 && dSoc >= -0.02) dSoc = 0; // up to 2 pp "rise" = regen / rounding jitter, not a charge
  await learnSpeed(env, { dKm, dSoc, dt: cur.t - prev.t, charging: prev.charging || cur.charging }, tempC);
  const parkedOrBad = prev.charging || cur.charging || dKm < 0.5 || dKm > 600 || dSoc < -0.005 || dSoc > 0.6
    || cur.t - prev.t > 36 * 3600 * 1000;
  let pending = await env.STATE.get("learn_pending", "json");
  if (parkedOrBad) {
    // A pure parking gap (no distance, no charging) keeps the chunk going; anything else breaks it.
    const justParked = dKm < 0.5 && !prev.charging && !cur.charging && dSoc > -0.005;
    if (!justParked && pending) await env.STATE.delete("learn_pending");
    return;
  }
  const net = await netCapacityKwh(env);
  pending = pending || { kwh: 0, km: 0, band: tempBand(tempC) };
  pending.kwh += Math.max(0, dSoc) * net;
  pending.km += dKm;
  if (pending.km < KM_CHUNK) { await kvPut(env, "learn_pending", JSON.stringify(pending)); return; }

  await env.STATE.delete("learn_pending");
  const cons = (pending.kwh / pending.km) * 100;
  if (cons < 9 || cons > 40) return; // implausible: discard (e.g. an unseen charge in between)
  const all = (await env.STATE.get("learn_cons", "json")) || {};
  const b = all[pending.band] || { kwh: 0, km: 0 };
  b.kwh += pending.kwh; b.km += pending.km;
  if (b.km > 600) { b.kwh *= 0.8; b.km *= 0.8; } // forget old driving slowly
  all[pending.band] = b;
  await kvPut(env, "learn_cons", JSON.stringify(all));
}

// Consumption by driving speed. Measurements arrive every ~2 min while driving, so
// consecutive intervals are pooled into ~6 min windows (odometer is whole km), then
// classified by the window's average speed and added to that class's totals.
const SPEED_WIN_MS = 6 * 60 * 1000;
const SPEED_GAP_MS = 12 * 60 * 1000;

function speedClass(kmh) { return kmh < 55 ? "city" : kmh < 95 ? "road" : "motorway"; }

async function learnSpeed(env, iv, tempC) {
  let w = await env.STATE.get("learn_speed_win", "json");
  if (iv.charging || iv.dt <= 0 || iv.dt > SPEED_GAP_MS || iv.dKm < 0 || iv.dKm > 60 || iv.dSoc < 0) {
    if (w) await env.STATE.delete("learn_speed_win");
    return;
  }
  const net = await netCapacityKwh(env);
  w = w || { kwh: 0, km: 0, ms: 0, band: tempBand(tempC) };
  w.kwh += iv.dSoc * net; w.km += iv.dKm; w.ms += iv.dt;
  if (w.ms < SPEED_WIN_MS) { await kvPut(env, "learn_speed_win", JSON.stringify(w)); return; }
  await env.STATE.delete("learn_speed_win");
  if (w.km < 3) return; // standing still or parked: nothing to learn from
  const cls = speedClass(w.km / (w.ms / 3600000));
  const all = (await env.STATE.get("learn_cons_speed", "json")) || {};
  const band = (all[w.band] = all[w.band] || {});
  const c = (band[cls] = band[cls] || { kwh: 0, km: 0, ms: 0 });
  c.kwh += w.kwh; c.km += w.km; c.ms += w.ms;
  if (c.km > 400) { c.kwh *= 0.8; c.km *= 0.8; c.ms *= 0.8; }
  await kvPut(env, "learn_cons_speed", JSON.stringify(all));
}

async function learnedSpeedConsumption(env, tempC) {
  const band = ((await kvJsonCached(env, "learn_cons_speed")) || {})[tempBand(tempC)];
  const out = {};
  for (const [cls, c] of Object.entries(band || {})) {
    if (c.km >= 15) out[cls] = { kwhPer100: Math.round((c.kwh / c.km) * 1000) / 10, km: Math.round(c.km), avgKmh: Math.round(c.km / (c.ms / 3600000)) };
  }
  return out;
}

async function learnedConsumption(env, tempC) {
  const b = ((await kvJsonCached(env, "learn_cons")) || {})[tempBand(tempC)];
  if (!b || b.km < 40) return null;
  return { value: Math.round((b.kwh / b.km) * 1000) / 10, km: Math.round(b.km) };
}

// Was the car driven (>= 8 km in the hour before `startMs`)? Then the battery is warm.
function detectWarm(log, startMs) {
  const win = (log || []).filter((e) => typeof e.odo === "number" && e.t <= startMs && e.t >= startMs - 60 * 60 * 1000);
  if (win.length < 2) return false;
  const odos = win.map((e) => e.odo);
  return Math.max(...odos) - Math.min(...odos) >= 8;
}

// Average power per SoC decile for ONE session, from energy over time between consecutive samples.
// This cancels the 1 pp quantisation noise of single derived samples (63..113 kW around a true 85).
function sessionDecileKw(samples, netKwh) {
  const sum = {};
  const s = samples.slice().sort((a, b) => a.t - b.t);
  for (let k = 1; k < s.length; k++) {
    const a = s[k - 1], b = s[k];
    const ds = b.soc - a.soc, dt = (b.t - a.t) / 3600000;
    if (!(ds > 0) || !(dt > 0) || dt > 0.25) continue; // gaps over 15 min are unreliable
    const i = Math.max(0, Math.min(10, Math.round(((a.soc + b.soc) / 2) * 10)));
    const e = (sum[i] = sum[i] || { kwh: 0, h: 0 });
    e.kwh += ds * netKwh; e.h += dt;
  }
  return Object.entries(sum).filter(([, e]) => e.h >= 90 / 3600).map(([i, e]) => [Number(i), e.kwh / e.h]);
}

async function learnCharging(env, snap, tempC, log) {
  const kw = typeof snap.wattageW === "number" ? snap.wattageW / 1000 : null;
  let sess = await env.STATE.get("charge_session", "json");

  if (snap.charging === true) {
    sess = sess || { startedAt: snap.measuredAt, maxKw: 0, samples: [], band: tempBand(tempC), warm: detectWarm(log, snap.measuredAt) };
    let last = sess.samples[sess.samples.length - 1];
    // Webhooks carry SoC but no power. Derive battery-side power from the SoC slope between
    // two measurements (each SoC step is a rounding boundary, so the slope is accurate).
    let power = kw, derived = false;
    if (power == null) {
      if (!last) { // first point of a session without a power reading: keep it as the anchor for later slopes
        sess.samples.push({ t: snap.measuredAt, soc: snap.soc, kw: null, anchor: true });
        await kvPut(env, "charge_session", JSON.stringify(sess));
        return;
      }
      if (snap.soc <= last.soc || snap.measuredAt - last.t < 30000) return;
      const net = await netCapacityKwh(env);
      power = ((snap.soc - last.soc) * net) / ((snap.measuredAt - last.t) / 3600000);
      if (!(power > 1 && power < 400)) return;
      derived = true;
    }
    if (last && last.t === snap.measuredAt && last.derived && !derived) {
      sess.samples.pop(); // a real power reading replaces the derived one for the same measurement
      last = sess.samples[sess.samples.length - 1];
    }
    if (last && last.t >= snap.measuredAt) return;
    const sample = { t: snap.measuredAt, soc: snap.soc, kw: Math.round(power * 10) / 10 };
    if (derived) sample.derived = true;
    const kwUsed = power;
    if (typeof snap.energyAddedKwh === "number") sample.kwh = snap.energyAddedKwh;
    sess.samples.push(sample);
    sess.maxKw = Math.max(sess.maxKw, kwUsed);
    if (snap.connector && snap.connector !== "invalid") {
      sess.connector = snap.connector;
      const seen = (await env.STATE.get("connectors_seen", "json")) || {};
      seen[snap.connector] = (seen[snap.connector] || 0) + 1;
      await kvPut(env, "connectors_seen", JSON.stringify(seen));
    }
    await kvPut(env, "charge_session", JSON.stringify(sess));
    return;
  }
  if (snap.charging === false && sess) { // session ended
    await env.STATE.delete("charge_session");
    await checkCapacity(env, sess);
    const kind = classifyCharge(sess.connector, sess.maxKw * 1000);
    if (kind !== "dc" || sess.samples.length < 3) return; // AC or too short to learn a curve from
    const warm = sess.warm === true;
    const key = `learn_charge_${sess.band}${warm ? "_w" : ""}`; // legacy key without suffix = cold battery
    const data = (await env.STATE.get(key, "json")) || { bins: Array.from({ length: 11 }, () => []), sessions: 0 };
    for (const [i, kwAvg] of sessionDecileKw(sess.samples, await netCapacityKwh(env))) {
      data.bins[i].push(Math.round(kwAvg * 10) / 10); // one value per session and decile
      if (data.bins[i].length > 10) data.bins[i].shift();
    }
    data.sessions = (data.sessions || 0) + 1;
    data.updated = Date.now();
    await kvPut(env, key, JSON.stringify(data));
  }
}

// AC or DC? Smartcar's connector names are only known once we have seen a session,
// so the raw values are logged (/learn -> connectorsSeen). Rule: a connector that
// clearly says AC wins; otherwise DC means "DC connector AND more than AC can deliver";
// without a usable connector value, power alone decides (> 12 kW is DC).
function classifyCharge(connector, wattageW) {
  const c = String(connector || "").toLowerCase();
  const kw = typeof wattageW === "number" ? wattageW / 1000 : null;
  const dcName = /ccs|chademo|combo|dc|supercharger|gbt/.test(c);
  const acName = /type ?2|type ?1|j1772|mennekes|schuko|\bac\b/.test(c) && !dcName;
  if (acName) return "ac";
  if (kw == null) return dcName ? "dc" : null;
  return kw >= DC_MIN_KW ? "dc" : "ac";
}

// Sanity check of the battery size: energy the car says it added / SoC gained.
// Logged only (never applied): it may be measured at the charger, i.e. include losses.
async function checkCapacity(env, sess) {
  const withE = sess.samples.filter((x) => typeof x.kwh === "number");
  if (withE.length < 2) return;
  const a = withE[0], b = withE[withE.length - 1];
  const dSoc = b.soc - a.soc, dE = b.kwh - a.kwh;
  if (dSoc < 0.10 || dE < 3) return;
  const list = (await env.STATE.get("capacity_checks", "json")) || [];
  list.push({ at: b.t, kind: classifyCharge(sess.connector, sess.maxKw * 1000), dSocPct: Math.round(dSoc * 100),
    energyKwh: Math.round(dE * 10) / 10, impliedKwh: Math.round((dE / dSoc) * 10) / 10 });
  await kvPut(env, "capacity_checks", JSON.stringify(list.slice(-20)));
}

function percentile(arr, p) {
  const a = [...arr].sort((x, y) => x - y);
  return a[Math.min(a.length - 1, Math.floor(p * a.length))];
}

async function learnedChargeCurve(env, tempC, warm) {
  const base = `learn_charge_${tempBand(tempC)}`;
  const curveOf = (d) => {
    if (!d) return null;
    const curve = d.bins.map((v) => (v.length ? Math.round(percentile(v, 0.8) * 10) / 10 : null));
    return curve.filter((x) => x != null).length >= 3 ? { curveKw: curve, sessions: d.sessions || 0 } : null;
  };
  // A recently driven (warm) battery uses its own curve when there is one, else the cold curve (the safe side).
  if (warm) { const w = curveOf(await kvJsonCached(env, `${base}_w`)); if (w) return { ...w, warm: true }; }
  const own = curveOf(await kvJsonCached(env, base));
  if (own) return own;
  // Nothing learned in this 5 C band: borrow the nearest band (+-5, then +-10 C) rather than fall
  // back to the generic curve. Same warm/cold preference.
  const band = Number(tempBand(tempC));
  if (!isFinite(band)) return null;
  for (const d of [5, -5, 10, -10]) {
    const nb = `learn_charge_${band + d}`;
    if (warm) { const w = curveOf(await kvJsonCached(env, `${nb}_w`)); if (w) return { ...w, warm: true, borrowedBand: band + d }; }
    const c = curveOf(await kvJsonCached(env, nb));
    if (c) return { ...c, borrowedBand: band + d };
  }
  return null;
}

async function cronTick(env) {
  // A trip ends 30 min after the last movement even if the sleeping car sends nothing more.
  const open = await env.STATE.get("trip_current", "json");
  if (open && open.endAt && Date.now() - open.endAt >= 15 * 60 * 1000) await finishTrip(env, open, open.lastDriving);
  else if (open && !open.endAt && Date.now() - open.lastMoveT >= TRIP_END_IDLE_MS + 60 * 1000) await finishTrip(env, open, open.lastDriving);
  const snap = await env.STATE.get("snapshot", "json");
  if (!snap || snap.charging !== true) return;
  const lastPoll = Number((await env.STATE.get("last_poll_at")) || 0);
  // Unknown wattage at charging start counts as possibly DC, so the first minutes of a
  // fast charge are sampled. Only a known low power (AC) slows polling to ~30 min.
  const knownAc = snap.wattageW != null && snap.wattageW / 1000 < DC_MIN_KW;
  // DC/unknown: every ~2 min (cron runs each minute; identical measurements cost no KV writes). AC: every ~30 min.
  if (Date.now() - lastPoll < (knownAc ? 28 : 1.9) * 60 * 1000) return;
  await pollSafely(env);
}

// ---------- Trip log + calibration ----------
//
// Every drive becomes a trip record: km, SoC used, average outdoor temperature, km per Maps
// speed bin (from ~2-min odometer windows), time driven, and whether it was a cold start. For
// each trip the PURE physics model (same bins + heating power Maps gets) predicts the energy;
// actual / predicted per temperature is the calibration that replaces both the car's own
// estimate and the fixed safety margin. Energy-weighted (sum/sum) so short, coarse trips
// (SoC reports whole percent = 0.77 kWh) cannot dominate.

// VW reports the odometer only about every 20 min while driving (SoC every 2-3 min), so a trip
// ends after 30 min without odometer movement AND without SoC falling (or when charging starts).
const TRIP_END_IDLE_MS = 30 * 60 * 1000;
const WINDOW_MAX_MS = 45 * 60 * 1000; // odometer windows up to this long are still classified by speed
const TRIP_MIN_KM = 5;
const r1 = (x) => Math.round(x * 10) / 10;

function physicsParts(tempC) {
  const T = typeof tempC === "number" ? tempC : 8;
  return {
    trac: BIN_KMH.map(physicsKwhPer100),
    kt: Math.min(1.3, Math.max(1, 1 + 0.012 * (15 - T))),
    auxKw: Math.min(3, Math.max(0.4, 0.4 + 0.08 * (15 - T))),
  };
}
const speedBin = (kmh) => Math.max(0, Math.min(9, Math.floor(kmh / 20)));

// Cold start: after >= 1 h parked the cabin (and battery) are warmed up during the first ~15 min,
// on top of the steady heating. ~100 W per degree below 15 C, 0.5-2.5 kW.
const COLD_PARK_H = 1;
const WARMUP_H = 0.25;
function coldBoostKw(tempC) {
  const T = typeof tempC === "number" ? tempC : 8;
  return Math.min(2.5, Math.max(0.5, 0.1 * (15 - T)));
}
const isColdStart = (parkedH) => parkedH == null || parkedH >= COLD_PARK_H;

function predictTripKwh(binKm, hours, tempC, coldStart) {
  const p = physicsParts(tempC);
  return binKm.reduce((a, km, i) => a + (km * p.trac[i] * p.kt) / 100, 0) + p.auxKw * hours
    + (coldStart ? coldBoostKw(tempC) * Math.min(hours, WARMUP_H) : 0);
}

// The car reports nothing while asleep, so a trip's start is found by walking back from the first
// odometer change through the measurements just before it while SoC was already falling (VW
// updates SoC every 2-3 min but the odometer only every ~20 min). A gap of more than 30 min, a
// charge or the previous trip's end stops the walk.
function tripStartFrom(log, prevEntry, afterT) {
  const entries = (log || []).slice(0, -1).filter((e) => typeof e.odo === "number" && e.t > afterT && e.t <= prevEntry.t);
  let start = prevEntry;
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (e.t >= start.t) continue;
    if (start.t - e.t > TRIP_END_IDLE_MS || e.ch === true || e.soc <= start.soc || e.odo !== prevEntry.odo) break; // only while SoC was really falling
    start = e;
  }
  return { t: start.t, soc: start.soc, odo: start.odo };
}

const CARPLAY_GRACE_MS = 3 * 60 * 1000;

async function trackTrip(env, snap, prevEntry, tempC, log) {
  if (typeof snap.odometerKm !== "number") return;
  let trip = await env.STATE.get("trip_current", "json");
  const now = { t: snap.measuredAt, soc: snap.soc, odo: snap.odometerKm };
  // CarPlay disconnected (Shortcuts "Slut kørsel"): the first measurement after that is the
  // trip's final state (VW reports SoC/odometer a minute or two after parking).
  if (trip && trip.endAt && now.t >= trip.endAt) {
    const fresh = now.t - trip.endAt <= 15 * 60 * 1000 && snap.charging !== true && now.odo >= trip.last.odo;
    await finishTrip(env, trip, fresh ? now : trip.lastDriving);
    return;
  }
  // First close a trip whose last movement is long ago: the car slept in between, and this
  // measurement belongs to whatever happens next, not to the old trip.
  if (trip && !trip.endAt && now.t - trip.lastMoveT >= TRIP_END_IDLE_MS) {
    await finishTrip(env, trip, trip.lastDriving);
    trip = null;
  }
  if (!trip) {
    if (snap.charging === true || !prevEntry || typeof prevEntry.odo !== "number" || now.odo - prevEntry.odo < 0.5) return;
    const lastEnd = await env.STATE.get("trip_last_end", "json");
    const start = tripStartFrom(log, prevEntry, lastEnd ? lastEnd.t : 0);
    trip = { start, last: start, lastMoveT: start.t, lastOdoT: start.t, lastDriving: start, binKm: Array(10).fill(0), unbinnedKm: 0,
      driveMs: 0, tempSum: 0, tempN: 0, parkedH: lastEnd ? r1((start.t - lastEnd.t) / 3600000) : null };
  }
  // Same timestamp but a newer odometer (two reports of one moment) still counts as movement.
  if (now.t < trip.last.t || (now.t === trip.last.t && now.odo <= trip.last.odo)) return;
  const dKm = now.odo - trip.last.odo, dt = now.t - trip.last.t;
  if (snap.charging === true) return finishTrip(env, trip, trip.lastDriving); // charging ends the trip
  if (dKm > 0 || now.soc < trip.last.soc - 0.005) trip.lastMoveT = now.t; // odometer or SoC still moving
  if (dKm > 0) {
    // Speed = km since the previous odometer CHANGE / time since then (SoC reports in between
    // carry the same odometer value and must not shrink the window).
    const odoMs = now.t - (trip.lastOdoT ?? trip.last.t);
    trip.lastOdoT = now.t;
    if (odoMs <= WINDOW_MAX_MS) {
      // The odometer reports whole km: a 2-min window at 110 km/h reads 3 or 4 km (90 or 120 km/h),
      // which overstates air drag. Pool windows until >= 5 km or >= 8 min before classifying.
      trip.pend = trip.pend || { km: 0, ms: 0 };
      trip.pend.km += dKm; trip.pend.ms += odoMs;
      if ((trip.pend.km >= 5 && trip.pend.ms >= 2 * 60 * 1000) || trip.pend.ms >= 8 * 60 * 1000) flushPend(trip);
    } else trip.unbinnedKm += dKm; // a long gap: speed unknown, spread later like the rest of the trip
    if (typeof tempC === "number") { trip.tempSum += tempC; trip.tempN++; }
  }
  if (dt <= WINDOW_MAX_MS) trip.driveMs += dt; // includes stops at lights: heating runs then too
  trip.last = now;
  if (trip.lastMoveT === now.t) trip.lastDriving = now; // the trip's end = last moment anything moved
  await kvPut(env, "trip_current", JSON.stringify(trip));
}

function flushPend(trip, final) {
  if (!trip.pend || !(trip.pend.km > 0)) return;
  if (!(trip.pend.ms > 0)) { if (final) { trip.unbinnedKm += trip.pend.km; trip.pend = { km: 0, ms: 0 }; } return; } // no time yet: wait
  trip.binKm[speedBin(trip.pend.km / (trip.pend.ms / 3600000))] += trip.pend.km;
  trip.pend = { km: 0, ms: 0 };
}

async function finishTrip(env, trip, end) {
  flushPend(trip, true);
  try { await env.STATE.delete("trip_current"); } catch { /* best effort */ }
  // Kept briefly so a CarPlay blip (end + start within a few minutes) can reopen the same trip.
  await kvPut(env, "trip_last_closed", JSON.stringify({ trip, closedAt: Date.now() }));
  await kvPut(env, "trip_last_end", JSON.stringify({ t: end.t }));
  let km = end.odo - trip.start.odo;
  const dSoc = trip.start.soc - end.soc;
  // VW's odometer can lag far behind (22 Nov: 10 km reported only after the trip ended). If the
  // battery clearly dropped, take the distance from the iPhone's GPS segments for the same time.
  let odoTo = end.odo;
  if (km < TRIP_MIN_KM && dSoc >= 0.02) {
    const g = gpsFor({ start: trip.start.t, end: end.t, km: 0 }, await env.STATE.get("gps_segments", "json"));
    if (g && g.km >= TRIP_MIN_KM) { km = r1(g.km); odoTo = trip.start.odo + km; }
  }
  if (km < TRIP_MIN_KM || dSoc < 0) return;
  const binKm = trip.binKm.slice();
  const binned = binKm.reduce((a, b) => a + b, 0);
  // Time on the road = start .. last movement (heating runs the whole time, also at lights).
  let hours = (end.t - trip.start.t) / 3600000;
  if (trip.unbinnedKm > 0) {
    if (binned > 0) for (let i = 0; i < 10; i++) binKm[i] += (trip.unbinnedKm * binKm[i]) / binned;
    else binKm[speedBin(hours > 0 ? km / hours : 60)] += trip.unbinnedKm;
  }
  if (!(hours > 0.05)) hours = km / 60;
  const tempC = trip.tempN ? trip.tempSum / trip.tempN : null;
  const kwh = dSoc * (await netCapacityKwh(env));
  const coldStart = isColdStart(trip.parkedH);
  const predicted = predictTripKwh(binKm, hours, tempC, coldStart);
  const rec = {
    start: trip.start.t, end: end.t, km: r1(km), socFrom: trip.start.soc, socTo: end.soc,
    kwh: r1(kwh), kwhPer100: r1((kwh / km) * 100), tempC: tempC == null ? null : r1(tempC),
    avgKmh: Math.round(km / hours), binKm: binKm.map(r1),
    predictedKwh: r1(predicted), predictedPer100: r1((predicted / km) * 100), ratio: Math.round((kwh / predicted) * 100) / 100,
    cold: coldStart, parkedH: trip.parkedH, odoFrom: trip.start.odo, odoTo,
  };
  applyGps(rec, await env.STATE.get("gps_segments", "json"));
  const trips = (await env.STATE.get("trips", "json")) || [];
  // What Maps was actually given for this trip: the physics prediction times the calibration
  // in force when the trip started (from the trips before it).
  const bandsBefore = await getBands(env, trips);
  rec.mapsFactor = bandCalibration(bandsBefore, trips, rec.tempC)?.factor ?? 1;
  // The same trip can be finished twice (KV is eventually consistent across isolates, so a stale
  // trip_current may be seen once more). Keep one record per start: the longer one.
  const dup = trips.findIndex((x) => x.start === rec.start);
  if (dup >= 0) {
    if (rec.km >= trips[dup].km) trips[dup] = { ...rec, mapsFactor: trips[dup].mapsFactor ?? rec.mapsFactor };
  } else trips.push(rec);
  await kvPut(env, "trips", JSON.stringify(trips.slice(-100)));
  await recordBand(env, trips, bandsBefore);
}

async function lateOdometer(env, snap, prevEntry) {
  if (typeof snap.odometerKm !== "number" || !prevEntry || typeof prevEntry.odo !== "number" || snap.odometerKm <= prevEntry.odo) return false;
  if (await env.STATE.get("trip_current")) return false; // a trip is running: it gets the km normally
  const trips = (await env.STATE.get("trips", "json")) || [];
  const last = trips[trips.length - 1];
  if (!last || typeof last.odoTo !== "number" || snap.odometerKm <= last.odoTo) return false;
  const after = snap.measuredAt - last.end;
  if (after < 0 || after > 30 * 60 * 1000) return false;
  // Not driven since: the battery has not dropped further (or it is charging).
  if (snap.charging !== true && snap.soc < last.socTo - 0.01) return false;
  const extra = snap.odometerKm - last.odoTo;
  if (extra > last.km * 3 + 20) return false; // implausible: leave it
  const km = last.km + extra;
  const f = km / last.km;
  const binKm = (last.binKm || []).map((k) => k * f);
  const hours = (last.end - last.start) / 3600000;
  const predicted = binKm.length === 10 ? predictTripKwh(binKm, hours, last.tempC, last.cold) : last.predictedKwh * f;
  Object.assign(last, {
    km: r1(km), odoTo: snap.odometerKm, binKm: binKm.map(r1), kwhPer100: r1((last.kwh / km) * 100),
    avgKmh: hours > 0 ? Math.round(km / hours) : last.avgKmh,
    predictedKwh: r1(predicted), predictedPer100: r1((predicted / km) * 100),
    ratio: Math.round((last.kwh / predicted) * 100) / 100, lateOdoKm: r1(extra),
  });
  await kvPut(env, "trips", JSON.stringify(trips));
  await recordBand(env, trips, await getBands(env, trips));
  return true;
}

// ---------- Temperature bands: long-term memory of the trip calibration ----------
// Each 5 C band (same bands as the charge curves: "0" = 0..5 C) keeps its own last BAND_KEEP
// counted trips, so winter is still known in spring after the trip list (100) has moved on.
// Maps gets the factor of today's band; with too little data the two nearest bands are blended.
const BAND_KEEP = 15;
const BAND_MIN_KM = 40;

function tripCounts(x) {
  return x.km >= 20 && x.predictedKwh > 0 && x.ratio > 0.5 && x.ratio < 2.5 && typeof x.tempC === "number";
}

// Insert or replace (by start time) one trip; a trip only ever sits in one band.
function upsertBand(bands, x) {
  for (const k of Object.keys(bands)) bands[k] = bands[k].filter((e) => e.s !== x.start);
  if (!tripCounts(x)) return;
  const b = tempBand(x.tempC);
  const list = (bands[b] ||= []);
  list.push({ s: x.start, km: r1(x.km), kwh: r1(x.kwh), pred: r1(x.predictedKwh) });
  list.sort((a, c) => a.s - c.s);
  bands[b] = list.slice(-BAND_KEEP);
}

function bandsFromTrips(trips) {
  const bands = {};
  for (const x of joinShortStops(trips)) upsertBand(bands, x);
  return bands;
}

// Stored bands, or (first time) rebuilt from the trip list.
async function getBands(env, trips) {
  return (await env.STATE.get("temp_bands", "json")) || bandsFromTrips(trips);
}

// After a trip was added or changed: (re)place the newest trip (joined across a short stop).
async function recordBand(env, trips, bands) {
  const last = joinShortStops(trips.slice(-6)).at(-1);
  if (last) upsertBand(bands, last);
  await kvPut(env, "temp_bands", JSON.stringify(bands));
}

function bandSummary(bands) {
  const out = {};
  for (const [b, list] of Object.entries(bands || {})) {
    const km = list.reduce((a, e) => a + e.km, 0), kwh = list.reduce((a, e) => a + e.kwh, 0), pred = list.reduce((a, e) => a + e.pred, 0);
    if (pred > 0) out[b] = { km: Math.round(km), n: list.length, factor: Math.round((kwh / pred) * 100) / 100 };
  }
  return out;
}

function bandCalibration(bands, trips, tempC) {
  const all = () => { const a = tripCalibration(trips, null); return a ? { ...a, scope: "all" } : null; };
  if (typeof tempC !== "number") return all();
  const sum = bandSummary(bands);
  const own = sum[tempBand(tempC)];
  if (own && own.km >= BAND_MIN_KM) return { ...own, scope: "band", band: Number(tempBand(tempC)) };
  const centre = (b) => b + 2.5;
  const usable = Object.keys(sum).filter((k) => sum[k].km >= BAND_MIN_KM).map(Number);
  const below = usable.filter((b) => centre(b) <= tempC && tempC - centre(b) <= 10).sort((a, b) => b - a)[0];
  const above = usable.filter((b) => centre(b) >= tempC && centre(b) - tempC <= 10).sort((a, b) => a - b)[0];
  if (below != null && above != null && below !== above) {
    const w = (tempC - centre(below)) / (centre(above) - centre(below));
    const f = sum[below].factor * (1 - w) + sum[above].factor * w;
    return { factor: Math.round(f * 100) / 100, km: sum[below].km + sum[above].km, n: sum[below].n + sum[above].n, scope: "blend", bands: [below, above] };
  }
  const one = below ?? above;
  if (one != null) return { ...sum[one], scope: "nearby", band: one };
  return all();
}

// ---------- iPhone GPS aggregates (no positions: seconds/km per speed bin, metres up/down) ----------
const ALT_GAIN_WH_PER_M = 7.5;  // id3.json vehicle_altitude_gain_consumption_wh_per_m (what Maps uses)
const ALT_LOSS_WH_PER_M = 5.5;  // ... _loss_ (recovered)

function gpsFor(trip, segs) {
  const lo = trip.start - 10 * 60 * 1000, hi = trip.end + 10 * 60 * 1000;
  const hit = (segs || []).filter((g) => g.end >= lo && g.start <= hi);
  if (!hit.length) return null;
  const g = { binSec: Array(10).fill(0), binKm: Array(10).fill(0), gainM: 0, lossM: 0 };
  for (const x of hit) {
    for (let i = 0; i < 10; i++) { g.binSec[i] += x.binSec[i] || 0; g.binKm[i] += x.binKm[i] || 0; }
    g.gainM += x.gainM || 0; g.lossM += x.lossM || 0;
  }
  g.km = g.binKm.reduce((a, b) => a + b, 0);
  return g.km >= 0.7 * trip.km ? g : null; // GPS must cover most of the trip
}

// Re-predict a trip from the GPS speed profile + elevation (mutates `rec`). True when applied.
function applyGps(rec, segs) {
  if (rec.source === "gps") return false;
  const g = gpsFor(rec, segs);
  if (!g) return false;
  const scale = rec.km / g.km; // the odometer is the distance truth; GPS gives the shape
  const binKm = g.binKm.map((k) => k * scale);
  const hours = g.binSec.reduce((a, b) => a + b, 0) / 3600;
  const p = physicsParts(rec.tempC);
  const elevKwh = (g.gainM * ALT_GAIN_WH_PER_M - g.lossM * ALT_LOSS_WH_PER_M) / 1000;
  const predicted = binKm.reduce((a, km, i) => a + (km * p.trac[i] * p.kt) / 100, 0) + p.auxKw * hours + elevKwh
    + (rec.cold ? coldBoostKw(rec.tempC) * Math.min(hours, WARMUP_H) : 0);
  if (!(predicted > 0)) return false;
  Object.assign(rec, {
    source: "gps", binKm: binKm.map(r1), gainM: Math.round(g.gainM), lossM: Math.round(g.lossM),
    avgKmh: Math.round(rec.km / hours),
    predictedKwh: r1(predicted), predictedPer100: r1((predicted / rec.km) * 100),
    ratio: Math.round((rec.kwh / predicted) * 100) / 100,
  });
  return true;
}

async function gpsEndpoint(request, env) {
  const url = new URL(request.url);
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "") || url.searchParams.get("token");
  if (!env.STATUS_TOKEN || token !== env.STATUS_TOKEN) return new Response("unauthorized", { status: 401 });
  const segs = (await env.STATE.get("gps_segments", "json")) || [];
  if (request.method === "POST") {
    let body;
    try { body = await request.json(); } catch { return new Response("bad json", { status: 400 }); }
    const num = (x) => (typeof x === "number" && isFinite(x) ? x : 0);
    for (const x of (body.segments || []).slice(0, 50)) {
      if (!Array.isArray(x.binSec) || !Array.isArray(x.binKm) || x.binSec.length !== 10 || x.binKm.length !== 10) continue;
      const seg = { start: num(x.start), end: num(x.end), binSec: x.binSec.map(num), binKm: x.binKm.map(num), gainM: num(x.gainM), lossM: num(x.lossM) };
      if (!(seg.end > seg.start) || segs.some((y) => y.start === seg.start)) continue;
      segs.push(seg);
    }
    segs.sort((a, b) => a.start - b.start);
    await kvPut(env, "gps_segments", JSON.stringify(segs.slice(-200)));
    // Trips that already ended get their prediction redone from GPS.
    const trips = (await env.STATE.get("trips", "json")) || [];
    let changed = 0;
    for (const t of trips.slice(-20)) if (applyGps(t, segs)) changed++;
    if (changed) await kvPut(env, "trips", JSON.stringify(trips));
    return new Response(JSON.stringify({ ok: true, stored: segs.length, tripsUpdated: changed }), { headers: { "content-type": "application/json" } });
  }
  return new Response(JSON.stringify({ segments: segs.slice(-20) }), { headers: { "content-type": "application/json" } });
}

// actual/predicted for trips near this temperature (+-4 C), else over all trips; >= 40 km needed.
// Trips split by a short stop (CarPlay off/on, < 10 min) are joined for calibration: the SoC at
// the split is VW's (late, whole-percent) value, so the energy is misattributed between the parts
// (21 Nov: x1.88 then x0.55, together x1.28).
function joinShortStops(trips) {
  const out = [];
  for (const t of trips || []) {
    const p = out[out.length - 1];
    if (p && typeof t.start === "number" && typeof p.end === "number" && t.start - p.end <= 10 * 60e3 && t.start >= p.end - 60e3) {
      const km = p.km + t.km, kwh = p.kwh + t.kwh, predictedKwh = (p.predictedKwh || 0) + (t.predictedKwh || 0);
      const mapsKwh = typeof p.mapsKwh === "number" && typeof t.mapsKwh === "number" ? p.mapsKwh + t.mapsKwh : undefined;
      const tempC = typeof p.tempC === "number" && typeof t.tempC === "number" ? (p.tempC * p.km + t.tempC * t.km) / km : (p.tempC ?? t.tempC);
      const hours = (t.end - p.start) / 3600e3;
      out[out.length - 1] = {
        ...p, end: t.end, km, kwh, predictedKwh, tempC, socTo: t.socTo,
        ratio: predictedKwh > 0 ? Math.round(kwh / predictedKwh * 100) / 100 : p.ratio,
        kwhPer100: Math.round(kwh / km * 1000) / 10, predictedPer100: Math.round(predictedKwh / km * 1000) / 10,
        avgKmh: hours > 0 ? Math.round(km / hours) : p.avgKmh, joined: (p.joined || 1) + 1, mapsKwh,
      };
    } else out.push(t);
  }
  return out;
}

function tripCalibration(trips, tempC) {
  // >= 20 km: SoC is reported in whole percent, so a 10 km trip (3 pp) is +-33 % uncertain.
  const ok = joinShortStops(trips).filter((x) => x.km >= 20 && x.predictedKwh > 0 && x.ratio > 0.5 && x.ratio < 2.5);
  const pick = (arr) => {
    const a = arr.slice(-10);
    const km = a.reduce((s, x) => s + x.km, 0);
    if (km < 40) return null;
    const f = a.reduce((s, x) => s + x.kwh, 0) / a.reduce((s, x) => s + x.predictedKwh, 0);
    return { factor: Math.round(f * 100) / 100, km: Math.round(km), n: a.length };
  };
  const near = typeof tempC === "number" ? pick(ok.filter((x) => typeof x.tempC === "number" && Math.abs(x.tempC - tempC) <= 4)) : null;
  if (near) return { ...near, scope: "temperature" };
  const all = pick(ok);
  return all ? { ...all, scope: "all" } : null;
}

// Shortcuts automation on CarPlay connect/disconnect (app intents "Start/Slut kørsel"): exact trip
// boundaries. The odometer-based detection stays as the fallback when no event arrives.
async function driveEndpoint(request, env) {
  const url = new URL(request.url);
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "") || url.searchParams.get("token");
  if (!env.STATUS_TOKEN || token !== env.STATUS_TOKEN) return new Response("unauthorized", { status: 401 });
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ events: (await env.STATE.get("drive_events", "json")) || [] }), { headers: { "content-type": "application/json" } });
  }
  let body;
  try { body = await request.json(); } catch { return new Response("bad json", { status: 400 }); }
  const event = body.event;
  if (event !== "start" && event !== "end") return new Response("event must be start|end", { status: 400 });
  const at = typeof body.at === "number" && Math.abs(body.at - Date.now()) < 3600e3 ? body.at : Date.now();
  const events = (await env.STATE.get("drive_events", "json")) || [];
  events.push({ event, at });
  await kvPut(env, "drive_events", JSON.stringify(events.slice(-50)));

  let trip = await env.STATE.get("trip_current", "json");
  let note = "";
  if (event === "start") {
    if (trip && trip.endAt && at - trip.endAt < CARPLAY_GRACE_MS) {
      delete trip.endAt; // CarPlay dropped for a moment: same trip
      await kvPut(env, "trip_current", JSON.stringify(trip));
      return new Response(JSON.stringify({ ok: true, note: "trip resumed after a short CarPlay drop" }), { headers: { "content-type": "application/json" } });
    }
    if (trip && trip.endAt) { await finishTrip(env, trip, trip.lastDriving); trip = null; }
    if (!trip) {
      // The trip was already closed by the measurement right after the blip: reopen it.
      const closed = await env.STATE.get("trip_last_closed", "json");
      const ended = closed?.trip?.endAt;
      if (closed && typeof ended === "number" && at - ended < CARPLAY_GRACE_MS && Date.now() - closed.closedAt < 30 * 60e3) {
        trip = closed.trip;
        delete trip.endAt;
        const trips = (await env.STATE.get("trips", "json")) || [];
        const kept = trips.filter((x) => x.start !== trip.start.t);
        if (kept.length !== trips.length) await kvPut(env, "trips", JSON.stringify(kept));
        await kvPut(env, "trip_current", JSON.stringify(trip));
        try { await env.STATE.delete("trip_last_closed"); } catch { /* best effort */ }
        return new Response(JSON.stringify({ ok: true, note: "trip reopened after a short CarPlay drop" }), { headers: { "content-type": "application/json" } });
      }
    }
    if (!trip) {
      const snap = newerSnap(await env.STATE.get("snapshot", "json"), memSnap);
      if (snap && typeof snap.odometerKm === "number" && snap.charging !== true) {
        const lastEnd = await env.STATE.get("trip_last_end", "json");
        const start = { t: at, soc: snap.soc, odo: snap.odometerKm }; // parked values, CarPlay's time
        trip = { start, last: start, lastMoveT: at, lastOdoT: at, lastDriving: start, binKm: Array(10).fill(0), unbinnedKm: 0,
          driveMs: 0, tempSum: 0, tempN: 0, parkedH: lastEnd ? r1((at - lastEnd.t) / 3600000) : null, startedBy: "carplay" };
        await kvPut(env, "trip_current", JSON.stringify(trip));
        note = "trip started";
      } else note = "no usable snapshot (charging or no odometer)";
    } else note = "trip already running";
  } else if (trip) {
    trip.endAt = at;
    await kvPut(env, "trip_current", JSON.stringify(trip));
    note = "trip ends with the next measurement (or in 15 min)";
  } else note = "no open trip";
  return new Response(JSON.stringify({ ok: true, note }), { headers: { "content-type": "application/json" } });
}

// kWh Maps was given per trip. Older trips have no stored factor: use the calibration the trips
// before them gave (what the Worker would have sent at that time; 1 before there was one).
function withMapsKwh(trips) {
  return trips.map((t, i) => {
    const f = typeof t.mapsFactor === "number" ? t.mapsFactor : (tripCalibration(trips.slice(0, i), t.tempC)?.factor ?? 1);
    return { ...t, mapsFactor: f, mapsKwh: t.predictedKwh * f };
  });
}

// One row per 5 C band from the coldest to the warmest known (and today's): consumption factor
// and how much of the charge curve is learned with a warm / cold battery.
async function bandRows(env, bands, tempC) {
  const sum = bandSummary(bands);
  const charge = {};
  const list = await env.STATE.list({ prefix: "learn_charge_" });
  for (const k of list.keys) {
    const m = k.name.match(/^learn_charge_(-?\d+)(_w)?$/);
    if (!m) continue;
    const d = await env.STATE.get(k.name, "json");
    const pts = (d?.bins || []).filter((b) => b.length).length;
    (charge[m[1]] ||= {})[m[2] ? "warm" : "cold"] = pts;
  }
  const keys = [...Object.keys(sum), ...Object.keys(charge)].map(Number);
  const now = typeof tempC === "number" ? Number(tempBand(tempC)) : null;
  if (now != null) keys.push(now);
  if (!keys.length) return [];
  const rows = [];
  for (let b = Math.max(...keys); b >= Math.min(...keys); b -= 5) {
    const s = sum[String(b)];
    rows.push({
      band: b, km: s?.km ?? 0, n: s?.n ?? 0, factor: s && s.km >= BAND_MIN_KM ? s.factor : null,
      chargeWarm: charge[String(b)]?.warm ?? 0, chargeCold: charge[String(b)]?.cold ?? 0, current: b === now,
    });
  }
  return rows;
}

async function tripsEndpoint(request, env) {
  const url = new URL(request.url);
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "") || url.searchParams.get("token");
  if (!env.STATUS_TOKEN || token !== env.STATUS_TOKEN) return new Response("unauthorized", { status: 401 });
  const trips = (await env.STATE.get("trips", "json")) || [];
  const t = (await outdoorTempInfo(env, null)).t;
  const bands = await getBands(env, trips);
  return new Response(JSON.stringify({
    // Shown as driven: parts split by a short stop are one trip; `counted` = used for calibration.
    trips: joinShortStops(withMapsKwh(trips)).slice(-50).reverse().map((x) => ({
      ...x, counted: x.km >= 20 && x.ratio > 0.5 && x.ratio < 2.5,
      mapsPer100: r1((x.mapsKwh / x.km) * 100), mapsRatio: Math.round((x.kwh / x.mapsKwh) * 100) / 100,
    })),
    current: await env.STATE.get("trip_current", "json"),
    calibration: bandCalibration(bands, trips, t), temperatureC: t,
    bands: await bandRows(env, bands, t),
  }), { headers: { "content-type": "application/json" } });
}

// ---------- Consumption shape over Maps' 10 consumption values ----------
// Hypothesis (being tested): the 10 values are speed bins, slow -> fast. Assumed mapping:
// 0-3 city, 4-6 country road, 7-9 motorway. The app multiplies the baseline vector by the
// shape element-wise and then rescales its mean to the consumption figure, so a shape only
// redistributes consumption between speeds; the overall mean is unchanged.
const SHAPE_TESTS = {
  "test-fast": [0.7, 0.7, 0.7, 0.7, 1, 1, 1, 1.45, 1.45, 1.45],
  "test-slow": [1.45, 1.45, 1.45, 1.45, 1, 1, 1, 0.7, 0.7, 0.7],
  "test-mid": [1, 1, 1, 1, 1, 1.6, 1.6, 1, 1, 1], // only ~100-140 km/h if bins are ~20 km/h wide
};
// Confirmed by route tests on 2026-11-19 (only bins 5-6 dearer => Maps added a charging stop on a
// 175 km motorway route; city route unchanged): the bins are ~20 km/h wide, 0-20 ... 180-200 km/h.
const SHAPE_BINS = { city: [0, 1, 2], road: [3, 4], motorway: [5, 6, 7, 8, 9] };
const BIN_KMH = [10, 30, 50, 70, 90, 110, 130, 150, 170, 190];
// Typical share of distance per bin (Danish mixed driving), used only to anchor the curve so the
// distance-weighted average equals the measured/estimated consumption.
const BIN_MIX = [0.03, 0.12, 0.15, 0.12, 0.18, 0.2, 0.15, 0.05, 0, 0];

// Traction energy of an ID.3 (CdA ~0.63 m2, ~1.9 t, rolling 0.010, drivetrain 85 %), kWh/100 km.
function physicsKwhPer100(kmh) {
  const v = kmh / 3.6;
  const newtons = 0.5 * 1.25 * 0.63 * v * v + 0.010 * 1900 * 9.81;
  return newtons / 3.6 / 0.85 / 10;
}

// Speed bins (traction only, kWh/100 km) + auxiliary power (W) for Maps, anchored to `overall`.
// Winter overhead is split physically: cold air/tyres raise traction a little (kt), cabin and
// battery heating are a POWER (W) that Maps applies per hour -- so a 10 km/h queue costs more per
// km than the motorway, as in reality. Whatever remains is spread proportionally (s) so that the
// distance-weighted mix equals the measured/estimated consumption.
function physicsBins(overall, tempC) {
  if (!(overall > 5)) return null;
  const T = typeof tempC === "number" ? tempC : 8;
  const kt = Math.min(1.3, Math.max(1, 1 + 0.012 * (15 - T)));
  const auxKw = Math.min(3, Math.max(0.4, 0.4 + 0.08 * (15 - T)));
  const sumMix = BIN_MIX.reduce((a, b) => a + b, 0);
  const trac = BIN_KMH.map(physicsKwhPer100);
  const w = BIN_MIX.reduce((a, m, i) => a + m * trac[i], 0) / sumMix;
  const perKw = BIN_MIX.reduce((a, m, i) => a + m * (100 / BIN_KMH[i]), 0) / sumMix; // kWh/100 km per kW
  const s = Math.min(1.6, Math.max(0.7, overall / (kt * w + auxKw * perKw)));
  return {
    bins: trac.map((x) => Math.round(Math.min(60, Math.max(4, x * kt * s)) * 10) / 10),
    auxW: Math.round(auxKw * s * 1000),
  };
}

function consumptionShape(mode, bySpeed) {
  if (SHAPE_TESTS[mode]) return SHAPE_TESTS[mode];
  if (mode !== "learned" || !bySpeed) return null;
  const vals = Object.values(bySpeed).map((c) => c.kwhPer100).filter((v) => v > 0);
  if (vals.length < 2) return null; // need at least two speed classes to say anything
  const mean = vals.reduce((a, b) => a + b, 0) / vals.length;
  const shape = Array(10).fill(1);
  for (const [cls, idx] of Object.entries(SHAPE_BINS)) {
    const v = bySpeed[cls]?.kwhPer100;
    if (v > 0) for (const i of idx) shape[i] = Math.round(Math.min(1.8, Math.max(0.55, v / mean)) * 100) / 100;
  }
  return shape;
}

async function shapeEndpoint(request, env) {
  const url = new URL(request.url);
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "") || url.searchParams.get("token");
  if (!env.STATUS_TOKEN || token !== env.STATUS_TOKEN) return new Response("unauthorized", { status: 401 });
  const set = url.searchParams.get("set");
  if (set !== null) {
    if (!["off", "physics", "learned", ...Object.keys(SHAPE_TESTS)].includes(set)) return new Response("set must be off|physics|learned|test-fast|test-slow|test-mid", { status: 400 });
    await kvPut(env, "consumption_shape_mode", set);
  }
  const mode = (await env.STATE.get("consumption_shape_mode")) || "physics";
  return new Response(JSON.stringify({ mode, tests: SHAPE_TESTS, bins: SHAPE_BINS }), { headers: { "content-type": "application/json" } });
}

async function trimEndpoint(request, env) {
  const url = new URL(request.url);
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "") || url.searchParams.get("token");
  if (!env.STATUS_TOKEN || token !== env.STATUS_TOKEN) return new Response("unauthorized", { status: 401 });
  for (const [param, key] of [["set", "consumption_trim"], ["setLearned", "consumption_trim_learned"]]) {
    const raw = url.searchParams.get(param);
    if (raw === null) continue;
    const v = Number(raw);
    if (!(v >= 0.7 && v <= 1.6)) return new Response("trim must be 0.7-1.6", { status: 400 });
    await kvPut(env, key, String(v));
  }
  return new Response(JSON.stringify({
    carEstimateTrim: Number(await env.STATE.get("consumption_trim")) || DEFAULT_CONSUMPTION_TRIM,
    learnedTrim: Number(await env.STATE.get("consumption_trim_learned")) || 1.0,
    note: "set= adjusts the car-estimate margin, setLearned= the margin on measured consumption (Maps calibration)",
  }), { headers: { "content-type": "application/json" } });
}

async function learnEndpoint(request, env) {
  const url = new URL(request.url);
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "") || url.searchParams.get("token");
  if (!env.STATUS_TOKEN || token !== env.STATUS_TOKEN) return new Response("unauthorized", { status: 401 });
  const out = {
    anchor: await env.STATE.get("learn_anchor", "json"),
    pending: await env.STATE.get("learn_pending", "json"),
    consumption: await env.STATE.get("learn_cons", "json"),
    consumptionBySpeedRaw: await env.STATE.get("learn_cons_speed", "json"),
    chargeSession: await env.STATE.get("charge_session", "json"),
    learnError: (await env.STATE.get("learn_error")) || null,
    recentMeasurements: ((await env.STATE.get("measure_log", "json")) || []).slice(-15),
    connectorsSeen: await env.STATE.get("connectors_seen", "json"),
    capacityChecks: await env.STATE.get("capacity_checks", "json"),
    chargeBands: {},
  };
  const list = await env.STATE.list({ prefix: "learn_charge_" });
  for (const k of list.keys) {
    const d = await env.STATE.get(k.name, "json");
    out.chargeBands[k.name.replace("learn_charge_", "")] = {
      sessions: d.sessions, samplesPerDecile: d.bins.map((b) => b.length), p80kW: d.bins.map((b) => (b.length ? percentile(b, 0.8) : null)),
    };
  }
  return new Response(JSON.stringify(out, null, 1), { headers: { "content-type": "application/json" } });
}

// ---------- Dynamic model hints (capacity, consumption, charging) ----------
//
// The iOS app ships a baseline profile (id3.json). These hints let it adapt:
//  * capacityKwhNet       from Smartcar NominalCapacity (gross) x 0.94
//  * consumptionKwhPer100 implied by the car's OWN range estimate:
//                         net kWh / (range / SoC) -- it tracks cold weather,
//                         driving style and HVAC without us modelling them.
//  * chargePowerScale     relative to the baseline curve, which is calibrated
//                         to ~6 C. Heuristic until real sessions are logged.

const REF_TEMP_C = 6;
// Interim margin: the car's own estimate is a mixed-driving average, motorway use at ~6 C is
// clearly higher. Replaced by data from real trips and Maps' predictions (see /trim).
const DEFAULT_CONSUMPTION_TRIM = 1.15;
const WEATHER_TTL_MS = 30 * 60 * 1000;

async function refreshWeather(env) {
  try {
    // Generic central-Denmark coordinates (no personal location is sent).
    const r = await fetch("https://api.open-meteo.com/v1/forecast?latitude=55.7&longitude=11.5&current=temperature_2m",
      { signal: AbortSignal.timeout(3000) });
    if (!r.ok) return null;
    const t = (await r.json())?.current?.temperature_2m;
    if (typeof t !== "number") return null;
    await kvPut(env, "weather", JSON.stringify({ t, at: Date.now() }));
    return t;
  } catch { return null; }
}

// KV writes can fail (e.g. the free plan's 1000 writes/day). A failed write must never take
// /status or the webhook down, so writes are best effort and the newest measurement is also
// kept in this isolate's memory, which /status prefers when it is newer than KV's copy.
let kvWriteError = null;
async function kvPut(env, key, value, opts) {
  try { await env.STATE.put(key, value, opts); kvWriteError = null; }
  catch (e) { kvWriteError = `${new Date().toISOString()} ${e.message || e}`; }
}
let memSnap = null;
let memLastPoll = 0;
const newerSnap = (a, b) => (!a ? b : !b ? a : ((b.measuredAt || 0) > (a.measuredAt || 0) ? b : a));

// Rarely-changing keys: let Cloudflare's edge cache answer (cacheTtl >= 30 s) instead of a cold
// KV round trip. /status must be fast: Maps waits for it, and a slow answer means a timeout.
const kvJsonCached = (env, key, ttl = 60) => env.STATE.get(key, { type: "json", cacheTtl: ttl });
const kvTextCached = (env, key, ttl = 60) => env.STATE.get(key, { type: "text", cacheTtl: ttl });

async function outdoorTempInfo(env, ctx) {
  const car = await kvJsonCached(env, "car_temp");
  if (car && Date.now() - car.at < 3 * 3600 * 1000) return { t: car.t, source: "car" };
  const t = await outdoorTemp(env, ctx);
  return { t, source: "weather" };
}

async function outdoorTemp(env, ctx) {
  const c = await kvJsonCached(env, "weather");
  if (c && Date.now() - c.at < WEATHER_TTL_MS) return c.t;
  if (c) { // stale: answer now, refresh for next time
    if (ctx && ctx.waitUntil) ctx.waitUntil(refreshWeather(env));
    return c.t;
  }
  return refreshWeather(env); // nothing cached yet
}

async function buildModel(env, snap, ctx) {
  // Independent reads run in parallel: sequential cold KV reads were what made /status slow.
  const [grossRaw, ti, estPrev, trimCarRaw, trimLearnedRaw, recentDrive, shapeMode, trips, openTrip] = await Promise.all([
    kvTextCached(env, "sc_capacity", 300),
    outdoorTempInfo(env, ctx),
    kvJsonCached(env, "cons_estimate"),
    kvTextCached(env, "consumption_trim"),
    kvTextCached(env, "consumption_trim_learned"),
    env.STATE.get("recent_drive", "json"),
    env.STATE.get("consumption_shape_mode"),
    kvJsonCached(env, "trips"),
    env.STATE.get("trip_current", "json"),
  ]);
  const warm = !!(recentDrive && Date.now() - recentDrive.at < 45 * 60 * 1000);
  const net = Math.round((Number(grossRaw) || 82) * 0.94);
  const model = { capacityKwhNet: net, referenceTempC: REF_TEMP_C };
  const t = ti.t;
  if (typeof t === "number") {
    model.temperatureC = Math.round(t * 10) / 10;
    model.temperatureSource = ti.source; // "car" (the car's own thermometer) or "weather"
    const scale = Math.min(2.0, Math.max(0.55, 1 + 0.08 * (t - REF_TEMP_C)));
    model.chargePowerScale = Math.round(scale * 20) / 20; // steps of 0.05: keeps Maps from re-routing on noise
  }
  if (snap && snap.soc >= 0.15 && snap.rangeKm > 0) {
    const kmAt100 = snap.rangeKm / snap.soc;
    model.consumptionKwhPer100 = Math.round((net * 100 / kmAt100) * 10) / 10;
    model.consumptionSource = "car-estimate";
    // Remember it: below 15 % range/SoC is too noisy to trust, but Maps still needs a realistic
    // number exactly then. Written rarely (>= 3 % change or older than 6 h) to spare KV writes.
    try {
      const prev = estPrev;
      if (!prev || Math.abs(prev.v - model.consumptionKwhPer100) / prev.v >= 0.03 || Date.now() - prev.at > 6 * 3600 * 1000) {
        await kvPut(env, "cons_estimate", JSON.stringify({ v: model.consumptionKwhPer100, at: Date.now() }));
      }
    } catch { /* best effort */ }
  } else if (snap) {
    const prev = estPrev;
    if (prev && typeof prev.v === "number") { model.consumptionKwhPer100 = prev.v; model.consumptionSource = "car-estimate"; }
  }
  // Real driving beats the car's estimate once we have >= 40 km in this temperature band.
  const [lc, bySpeed, cc] = await Promise.all([
    learnedConsumption(env, t), learnedSpeedConsumption(env, t), learnedChargeCurve(env, t, warm),
  ]);
  if (lc) { model.consumptionKwhPer100 = lc.value; model.consumptionSource = "learned"; model.learnedKm = lc.km; }
  // Calibration against Maps' own predictions (see /trim). Maps follows the numbers it is
  // given, so if its arrival SoC is consistently too optimistic this factor lifts them.
  const isLearned = model.consumptionSource === "learned";
  const trim = Number(isLearned ? trimLearnedRaw : trimCarRaw) || (isLearned ? 1.0 : DEFAULT_CONSUMPTION_TRIM);
  if (model.consumptionKwhPer100) {
    model.consumptionTrim = trim;
    model.consumptionKwhPer100 = Math.round(model.consumptionKwhPer100 * trim * 10) / 10;
  }
  if (Object.keys(bySpeed).length) model.consumptionBySpeed = bySpeed;
  const mode = shapeMode || "physics"; // default since the bin meaning was confirmed
  const cal = mode === "physics" ? bandCalibration((await kvJsonCached(env, "temp_bands")) || bandsFromTrips(trips || []), trips || [], t) : null;
  if (cal) {
    // Calibrated by your own trips: physics x (actual/predicted). Replaces car estimate + margin.
    const p = physicsParts(t);
    const f = cal.factor * (Number(trimLearnedRaw) || 1.0);
    model.consumptionBinsKwhPer100 = p.trac.map((x) => Math.round(Math.min(60, Math.max(4, x * p.kt * f)) * 10) / 10);
    model.auxPowerW = Math.round(p.auxKw * f * 1000);
    const sumMix = BIN_MIX.reduce((a, b) => a + b, 0);
    model.consumptionKwhPer100 = r1(BIN_MIX.reduce((a, m, i) => a + m * (model.consumptionBinsKwhPer100[i] + (model.auxPowerW / 1000 / BIN_KMH[i]) * 100), 0) / sumMix);
    model.consumptionSource = "trips";
    model.consumptionTrim = Number(trimLearnedRaw) || 1.0;
    model.tripCalibration = cal;
    model.consumptionShapeMode = "trips";
  } else if (mode === "physics" && model.consumptionKwhPer100) {
    const ph = physicsBins(model.consumptionKwhPer100, t);
    if (ph) { model.consumptionBinsKwhPer100 = ph.bins; model.auxPowerW = ph.auxW; model.consumptionShapeMode = "physics"; }
  } else {
    const shape = consumptionShape(mode, bySpeed);
    if (shape) { model.consumptionShape = shape; model.consumptionShapeMode = mode; }
  }
  if (cc) {
    model.chargeCurveKw = cc.curveKw; model.chargeSessions = cc.sessions; model.chargeCurveWarm = !!cc.warm;
    if (cc.borrowedBand != null) model.chargeCurveBand = cc.borrowedBand;
  }
  model.batteryWarm = warm;
  // Cold start: extra heating power while the car warms up. Applies when planning from a car
  // that has been parked >= 1 h, and during the first 15 min of a trip that started cold. Maps
  // applies it to the whole route; the extension's next push removes it once warmed up.
  if (model.auxPowerW) {
    const now = Date.now();
    const parkedH = recentDrive ? (now - recentDrive.at) / 3600000 : null;
    const cold = openTrip
      ? isColdStart(openTrip.parkedH) && now - openTrip.start.t < WARMUP_H * 3600000
      : isColdStart(parkedH);
    if (cold) {
      const boostW = Math.round(coldBoostKw(t) * 1000);
      model.auxPowerW += boostW;
      model.coldStartBoostW = boostW;
      // Reflect it in the mean so the extension sees a model change and re-pushes when it ends.
      const sumMix = BIN_MIX.reduce((a, b) => a + b, 0);
      const perKw = BIN_MIX.reduce((a, m, i) => a + m * (100 / BIN_KMH[i]), 0) / sumMix;
      model.consumptionKwhPer100 = r1(model.consumptionKwhPer100 + (boostW / 1000) * perKw);
    }
  }
  return model;
}

// While driving, VW reports the SoC only every 2-8 min. Between reports, project it forward with
// this drive's own drop rate, so Maps is not left on a value that is minutes old (it then shows
// "connection lost"). Conservative: only during an open trip, 1-15 min after the last report,
// and never more than 3 pp below it.
async function estimateSocNow(env, snap) {
  if (snap.charging === true || typeof snap.soc !== "number" || typeof snap.measuredAt !== "number") return null;
  const age = Date.now() - snap.measuredAt;
  if (age < 60e3 || age > 15 * 60e3) return null;
  const trip = await kvJsonCached(env, "trip_current", 30);
  if (!trip || trip.endAt) return null;
  const log = (await kvJsonCached(env, "measure_log", 30)) || [];
  const recent = log.filter((e) => e.ch !== true && typeof e.soc === "number" && e.t <= snap.measuredAt && snap.measuredAt - e.t <= 20 * 60e3);
  const first = recent[0];
  if (!first || snap.measuredAt - first.t < 5 * 60e3) return null;
  const rate = (first.soc - snap.soc) / (snap.measuredAt - first.t); // per ms
  if (!(rate > 0)) return null;
  return Math.round((snap.soc - Math.min(0.03, rate * age)) * 1000) / 1000;
}

async function statusEndpoint(request, env, ctx) {
  const url = new URL(request.url);
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "") || url.searchParams.get("token");
  if (!env.STATUS_TOKEN || token !== env.STATUS_TOKEN) return new Response("unauthorized", { status: 401 });

  let [snap, lastPollRaw, lastErrorRaw] = await Promise.all([
    env.STATE.get("snapshot", "json"), env.STATE.get("last_poll_at"), env.STATE.get("last_poll_error"),
  ]);
  snap = newerSnap(snap, memSnap);
  const lastPoll = Math.max(Number(lastPollRaw || 0), memLastPoll);
  const force = url.searchParams.get("refresh") === "1";
  // Fresh or charging: poll often. Parked with old data: every 15 min is plenty (saves KV writes).
  const active = snap && (snap.charging === true || Date.now() - (snap.measuredAt || 0) < 15 * 60 * 1000);
  const due = force || Date.now() - lastPoll > (active ? POLL_MIN_INTERVAL_MS : 15 * 60 * 1000);

  if (due) {
    if (!snap || force) {
      await pollSafely(env); // nothing to show yet: wait for it
      snap = newerSnap(await env.STATE.get("snapshot", "json"), memSnap);
    } else if (ctx && ctx.waitUntil) {
      ctx.waitUntil(pollSafely(env)); // answer fast, refresh for the next call
    }
  }

  const lastError = lastErrorRaw || null;
  if (!snap) {
    return new Response(JSON.stringify({ available: false, lastError }), { headers: { "content-type": "application/json" } });
  }
  const ageSec = Math.round((Date.now() - (snap.measuredAt || snap.receivedAt)) / 1000);
  const model = await buildModel(env, snap, ctx);
  // While charging: this session's samples (SoC, kW) for the app's live charging chart.
  let chargeSession = null;
  if (snap.charging === true) {
    const sess = await env.STATE.get("charge_session", "json");
    if (sess) {
      chargeSession = { startedAt: sess.startedAt, warm: !!sess.warm,
        samples: (sess.samples || []).filter((x) => typeof x.kw === "number").slice(-120).map((x) => ({ t: x.t, soc: x.soc, kw: x.kw })) };
      // Webhook snapshots carry no power: show the latest session sample instead of nothing.
      const last = chargeSession.samples[chargeSession.samples.length - 1];
      if (typeof snap.wattageW !== "number" && last) snap = { ...snap, wattageW: Math.round(last.kw * 1000) };
    }
  }
  const socEstimate = await estimateSocNow(env, snap);
  return new Response(JSON.stringify({ available: true, ageSeconds: ageSec, lastError, kvWriteError, model, chargeSession, socEstimate, ...snap }),
    { headers: { "content-type": "application/json" } });
}
