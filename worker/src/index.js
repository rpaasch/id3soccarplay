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
  await env.STATE.put("smartcar_user_id", userId);
  await env.STATE.put("smartcar_connection", JSON.stringify({ userId, connectedAt: Date.now() }));
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
    await env.STATE.put("smartcar_last_test_event", raw);
    return new Response("ok", { status: 200 });
  }

  await env.STATE.put("smartcar_last_event", raw);
  const snap = extractSnapshot(evt);
  if (snap) {
    snap.source = "webhook";
    await storeSnapshotIfNewer(env, snap);
  }
  return new Response("ok", { status: 200 });
}

// Keep whichever measurement is newest (webhook pushes and polls race).
async function storeSnapshotIfNewer(env, snap) {
  const cur = await env.STATE.get("snapshot", "json");
  if (cur && cur.measuredAt && snap.measuredAt && cur.measuredAt > snap.measuredAt) return false;
  await env.STATE.put("snapshot", JSON.stringify(snap));
  await env.STATE.put("snapshot_log", JSON.stringify({ at: Date.now(), soc: snap.soc, source: snap.source }));
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
  await env.STATE.put("sc_app_token", JSON.stringify({ token: j.access_token, expiresAt: Date.now() + ttl * 1000 }), { expirationTtl: ttl });
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
  await env.STATE.put("sc_vehicle", JSON.stringify(v), { expirationTtl: 86400 });
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
  await env.STATE.put("last_poll_at", String(Date.now()));
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
      await env.STATE.put("car_temp", JSON.stringify({ t: Math.round(c * 10) / 10, at: isNaN(when) ? Date.now() : when }));
    } else {
      // Not enabled / not permitted / car can't report it: don't ask again for 30 min.
      await env.STATE.put("temp_unavailable", "1", { expirationTtl: 1800 });
    }
  }
  if (cap && cap.attrs?.body && typeof cap.attrs.body.capacity === "number") {
    // Gross kWh as selected in Smartcar Connect (e.g. 82 for an ID.3 Pro S).
    await env.STATE.put("sc_capacity", String(cap.attrs.body.capacity), { expirationTtl: 86400 });
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
  await env.STATE.put("last_poll_error", "");
  return snap;
}

async function pollSafely(env) {
  try { return await pollSmartcar(env); }
  catch (e) { await env.STATE.put("last_poll_error", `${new Date().toISOString()} ${e.message || e}`); return null; }
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
    const t = (await outdoorTempInfo(env, null)).t;
    await learnConsumption(env, snap, t);
    await learnCharging(env, snap, t);
  } catch (e) {
    await env.STATE.put("learn_error", `${new Date().toISOString()} ${e.message || e}`);
  }
}

async function learnConsumption(env, snap, tempC) {
  if (typeof snap.odometerKm !== "number") return;
  const prev = await env.STATE.get("learn_anchor", "json");
  const cur = { soc: snap.soc, odo: snap.odometerKm, t: snap.measuredAt, charging: !!snap.charging };
  if (prev && cur.t <= prev.t) return; // not newer information
  await env.STATE.put("learn_anchor", JSON.stringify(cur));
  if (!prev) return;

  const dKm = cur.odo - prev.odo;
  const dSoc = prev.soc - cur.soc;
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
  if (pending.km < KM_CHUNK) { await env.STATE.put("learn_pending", JSON.stringify(pending)); return; }

  await env.STATE.delete("learn_pending");
  const cons = (pending.kwh / pending.km) * 100;
  if (cons < 9 || cons > 40) return; // implausible: discard (e.g. an unseen charge in between)
  const all = (await env.STATE.get("learn_cons", "json")) || {};
  const b = all[pending.band] || { kwh: 0, km: 0 };
  b.kwh += pending.kwh; b.km += pending.km;
  if (b.km > 600) { b.kwh *= 0.8; b.km *= 0.8; } // forget old driving slowly
  all[pending.band] = b;
  await env.STATE.put("learn_cons", JSON.stringify(all));
}

async function learnedConsumption(env, tempC) {
  const b = ((await env.STATE.get("learn_cons", "json")) || {})[tempBand(tempC)];
  if (!b || b.km < 40) return null;
  return { value: Math.round((b.kwh / b.km) * 1000) / 10, km: Math.round(b.km) };
}

async function learnCharging(env, snap, tempC) {
  const kw = typeof snap.wattageW === "number" ? snap.wattageW / 1000 : null;
  let sess = await env.STATE.get("charge_session", "json");

  if (snap.charging === true) {
    if (kw == null) return; // no power reading with this measurement
    sess = sess || { startedAt: snap.measuredAt, maxKw: 0, samples: [], band: tempBand(tempC) };
    const last = sess.samples[sess.samples.length - 1];
    if (last && last.t >= snap.measuredAt) return;
    const sample = { t: snap.measuredAt, soc: snap.soc, kw: Math.round(kw * 10) / 10 };
    if (typeof snap.energyAddedKwh === "number") sample.kwh = snap.energyAddedKwh;
    sess.samples.push(sample);
    sess.maxKw = Math.max(sess.maxKw, kw);
    if (snap.connector && snap.connector !== "invalid") {
      sess.connector = snap.connector;
      const seen = (await env.STATE.get("connectors_seen", "json")) || {};
      seen[snap.connector] = (seen[snap.connector] || 0) + 1;
      await env.STATE.put("connectors_seen", JSON.stringify(seen));
    }
    await env.STATE.put("charge_session", JSON.stringify(sess));
    return;
  }
  if (snap.charging === false && sess) { // session ended
    await env.STATE.delete("charge_session");
    await checkCapacity(env, sess);
    const kind = classifyCharge(sess.connector, sess.maxKw * 1000);
    if (kind !== "dc" || sess.samples.length < 3) return; // AC or too short to learn a curve from
    const key = `learn_charge_${sess.band}`;
    const data = (await env.STATE.get(key, "json")) || { bins: Array.from({ length: 11 }, () => []), sessions: 0 };
    for (const sm of sess.samples) {
      const i = Math.max(0, Math.min(10, Math.round(sm.soc * 10)));
      data.bins[i].push(sm.kw);
      if (data.bins[i].length > 10) data.bins[i].shift();
    }
    data.sessions = (data.sessions || 0) + 1;
    data.updated = Date.now();
    await env.STATE.put(key, JSON.stringify(data));
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
  await env.STATE.put("capacity_checks", JSON.stringify(list.slice(-20)));
}

function percentile(arr, p) {
  const a = [...arr].sort((x, y) => x - y);
  return a[Math.min(a.length - 1, Math.floor(p * a.length))];
}

async function learnedChargeCurve(env, tempC) {
  const d = await env.STATE.get(`learn_charge_${tempBand(tempC)}`, "json");
  if (!d) return null;
  const curve = d.bins.map((v) => (v.length ? Math.round(percentile(v, 0.8) * 10) / 10 : null));
  return curve.filter((x) => x != null).length >= 3 ? { curveKw: curve, sessions: d.sessions || 0 } : null;
}

async function cronTick(env) {
  const snap = await env.STATE.get("snapshot", "json");
  if (!snap || snap.charging !== true) return;
  const lastPoll = Number((await env.STATE.get("last_poll_at")) || 0);
  const dc = (snap.wattageW || 0) / 1000 >= DC_MIN_KW;
  // DC: every ~5 min (Smartcar's VW data refreshes every 4-5 min). AC: only every ~30 min.
  if (Date.now() - lastPoll < (dc ? 4.5 : 28) * 60 * 1000) return;
  await pollSafely(env);
}

async function learnEndpoint(request, env) {
  const url = new URL(request.url);
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "") || url.searchParams.get("token");
  if (!env.STATUS_TOKEN || token !== env.STATUS_TOKEN) return new Response("unauthorized", { status: 401 });
  const out = {
    anchor: await env.STATE.get("learn_anchor", "json"),
    pending: await env.STATE.get("learn_pending", "json"),
    consumption: await env.STATE.get("learn_cons", "json"),
    chargeSession: await env.STATE.get("charge_session", "json"),
    learnError: (await env.STATE.get("learn_error")) || null,
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
const WEATHER_TTL_MS = 30 * 60 * 1000;

async function refreshWeather(env) {
  try {
    // Generic central-Denmark coordinates (no personal location is sent).
    const r = await fetch("https://api.open-meteo.com/v1/forecast?latitude=55.7&longitude=11.5&current=temperature_2m",
      { signal: AbortSignal.timeout(3000) });
    if (!r.ok) return null;
    const t = (await r.json())?.current?.temperature_2m;
    if (typeof t !== "number") return null;
    await env.STATE.put("weather", JSON.stringify({ t, at: Date.now() }));
    return t;
  } catch { return null; }
}

async function outdoorTempInfo(env, ctx) {
  const car = await env.STATE.get("car_temp", "json");
  if (car && Date.now() - car.at < 3 * 3600 * 1000) return { t: car.t, source: "car" };
  const t = await outdoorTemp(env, ctx);
  return { t, source: "weather" };
}

async function outdoorTemp(env, ctx) {
  const c = await env.STATE.get("weather", "json");
  if (c && Date.now() - c.at < WEATHER_TTL_MS) return c.t;
  if (c) { // stale: answer now, refresh for next time
    if (ctx && ctx.waitUntil) ctx.waitUntil(refreshWeather(env));
    return c.t;
  }
  return refreshWeather(env); // nothing cached yet
}

async function buildModel(env, snap, ctx) {
  const gross = Number(await env.STATE.get("sc_capacity")) || 82;
  const net = Math.round(gross * 0.94);
  const model = { capacityKwhNet: net, referenceTempC: REF_TEMP_C };

  const ti = await outdoorTempInfo(env, ctx);
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
  }
  // Real driving beats the car's estimate once we have >= 40 km in this temperature band.
  const lc = await learnedConsumption(env, t);
  if (lc) { model.consumptionKwhPer100 = lc.value; model.consumptionSource = "learned"; model.learnedKm = lc.km; }
  const cc = await learnedChargeCurve(env, t);
  if (cc) { model.chargeCurveKw = cc.curveKw; model.chargeSessions = cc.sessions; }
  return model;
}

async function statusEndpoint(request, env, ctx) {
  const url = new URL(request.url);
  const token = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "") || url.searchParams.get("token");
  if (!env.STATUS_TOKEN || token !== env.STATUS_TOKEN) return new Response("unauthorized", { status: 401 });

  let snap = await env.STATE.get("snapshot", "json");
  const lastPoll = Number((await env.STATE.get("last_poll_at")) || 0);
  const force = url.searchParams.get("refresh") === "1";
  const due = force || Date.now() - lastPoll > POLL_MIN_INTERVAL_MS;

  if (due) {
    if (!snap || force) {
      await pollSafely(env); // nothing to show yet: wait for it
      snap = await env.STATE.get("snapshot", "json");
    } else if (ctx && ctx.waitUntil) {
      ctx.waitUntil(pollSafely(env)); // answer fast, refresh for the next call
    }
  }

  const lastError = (await env.STATE.get("last_poll_error")) || null;
  if (!snap) {
    return new Response(JSON.stringify({ available: false, lastError }), { headers: { "content-type": "application/json" } });
  }
  const ageSec = Math.round((Date.now() - (snap.measuredAt || snap.receivedAt)) / 1000);
  const model = await buildModel(env, snap, ctx);
  return new Response(JSON.stringify({ available: true, ageSeconds: ageSec, lastError, model, ...snap }),
    { headers: { "content-type": "application/json" } });
}
