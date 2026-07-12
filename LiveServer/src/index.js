// Ears Live Transcript relay — Worker entry.
//
// Pairing flow:
//   Ears app  → POST /sessions {deepgramKey}      → {code, appToken}
//   Guest     → GET  /                             → join page
//   Guest     → POST /join {code, name}            → {token}
//   Ears app  → WS   /app?code&token[&since=seq]   → transcript events
//   Guest     → WS   /guest?code&token&format&rate → audio up, self-view down
//
// Each session lives in one LiveSession Durable Object addressed by its code.

import { LiveSession } from "./session.js";
import guestPage from "./guest.html";
import viewerPage from "./share.html";
import sitePage from "./site.html";

export { LiveSession };

const CODE_ATTEMPTS = 5;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/") {
      return new Response(sitePage, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }

    // The guest join page moved here when the marketing site took "/".
    if (request.method === "GET" && url.pathname === "/join") {
      return new Response(guestPage, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }

    if (request.method === "POST" && url.pathname === "/sessions") {
      if (await rateLimited(env, request, "sessions", 20, 60 * 60 * 1000)) {
        return json({ error: "Too many sessions from this address — try later." }, 429);
      }
      return createSession(request, env);
    }

    if (request.method === "POST" && url.pathname === "/join") {
      // Tight limit: 6-digit codes must not be brute-forceable.
      if (await rateLimited(env, request, "join", 15, 60 * 1000)) {
        return json({ error: "Too many attempts — wait a minute and try again." }, 429);
      }
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "Bad request." }, 400);
      }
      const code = normalizeCode(body.code);
      if (!code) return json({ error: "That code doesn't look right — it's 6 digits." }, 400);
      return sessionStub(env, code).fetch("https://do/join", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: String(body.name ?? "").slice(0, 40) }),
      });
    }

    if (url.pathname === "/app" || url.pathname === "/guest") {
      const code = normalizeCode(url.searchParams.get("code"));
      if (!code) return json({ error: "Missing code." }, 400);
      return sessionStub(env, code).fetch(request);
    }

    // Live share: host publishes the meeting transcript; anyone with the
    // link watches. The unguessable token is the credential.
    if (request.method === "POST" && url.pathname === "/shares") {
      if (await rateLimited(env, request, "shares", 20, 60 * 60 * 1000)) {
        return json({ error: "Too many shares from this address — try later." }, 429);
      }
      const token = randomToken();
      const publishKey = randomToken();
      const stub = shareStub(env, token);
      await stub.fetch("https://do/share-init", {
        method: "POST",
        body: JSON.stringify({ publishKey }),
      });
      return json({ token, publishKey, viewURL: `${url.origin}/v/${token}` });
    }

    if (request.method === "GET" && url.pathname.startsWith("/v/")) {
      return new Response(viewerPage, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }

    if (url.pathname === "/publish" || url.pathname === "/watch") {
      const token = url.searchParams.get("token") ?? "";
      if (token.length < 20) return json({ error: "Missing token." }, 400);
      return shareStub(env, token).fetch(request);
    }

    return json({ error: "Not found." }, 404);
  },
};

function shareStub(env, token) {
  return env.SESSIONS.get(env.SESSIONS.idFromName("share:" + token));
}

/// True when this client address exceeded `limit` calls per window.
async function rateLimited(env, request, bucket, limit, windowMs) {
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const stub = env.SESSIONS.get(env.SESSIONS.idFromName("limiter:global"));
  const response = await stub.fetch("https://do/ratelimit", {
    method: "POST",
    body: JSON.stringify({ key: `${bucket}:${ip}`, limit, windowMs }),
  });
  return response.status === 429;
}

async function createSession(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Bad request." }, 400);
  }
  const deepgramKey = String(body.deepgramKey ?? "").trim();
  if (!deepgramKey) return json({ error: "Missing deepgramKey." }, 400);

  const appToken = randomToken();
  // A code already carrying an active session answers 409 — roll a new one.
  for (let attempt = 0; attempt < CODE_ATTEMPTS; attempt++) {
    const code = randomCode();
    const response = await sessionStub(env, code).fetch("https://do/init", {
      method: "POST",
      body: JSON.stringify({ deepgramKey, appToken, code }),
    });
    if (response.ok) return json({ code, appToken });
  }
  return json({ error: "Could not allocate a code — try again." }, 503);
}

function sessionStub(env, code) {
  return env.SESSIONS.get(env.SESSIONS.idFromName("live:" + code));
}

function normalizeCode(raw) {
  const digits = String(raw ?? "").replace(/\D/g, "");
  return digits.length === 6 ? digits : null;
}

function randomCode() {
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  return String(100000 + (buf[0] % 900000));
}

function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
