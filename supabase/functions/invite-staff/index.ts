// invite-staff -- sends a Supabase invite email so a staff member can set a
// password and sign in without Google.
//
// WHY A FUNCTION AT ALL: inviting a user is an admin-API call, and the key it
// needs would be readable by anyone if it sat in index.html. Public sign-up is
// turned OFF on the project, so this is the only way an account gets created.
//
// The caller's own JWT decides whether they may invite: this asks GoTrue who
// they are, then reads public.staff with THEIR token, so the is_admin check is
// the same row-level security the app uses. The service-role key is used only
// for the invite itself, never to answer "who is this".
//
// Deploy: supabase functions deploy invite-staff --project-ref jkrsdvjrnsrjowhaobsr
// (SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY are provided
// by the platform -- no secrets to set.)

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// The app is served from GitHub Pages; localhost is for working on it.
const ALLOWED_ORIGINS = [
  "https://amadc0ck.github.io",
  "http://localhost:8765",
  "http://127.0.0.1:8765",
];

function cors(origin: string | null) {
  const allow = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function json(body: unknown, status: number, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...cors(origin) },
  });
}

Deno.serve(async (req) => {
  const origin = req.headers.get("Origin");
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(origin) });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405, origin);

  const auth = req.headers.get("Authorization") || "";
  if (!auth.toLowerCase().startsWith("bearer ")) return json({ error: "Sign in first." }, 401, origin);

  // 1. Who is calling?
  const meRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: ANON_KEY },
  });
  if (!meRes.ok) return json({ error: "Your session has expired — sign in again." }, 401, origin);
  const me = await meRes.json();
  const callerEmail = String(me?.email || "").toLowerCase();
  if (!callerEmail) return json({ error: "Your account has no email address." }, 403, origin);

  // 2. Are they an admin? Asked with the caller's token, so RLS decides.
  const staffRes = await fetch(
    `${SUPABASE_URL}/rest/v1/staff?select=email,is_admin&email=eq.${encodeURIComponent(callerEmail)}`,
    { headers: { Authorization: auth, apikey: ANON_KEY } },
  );
  const staffRows = staffRes.ok ? await staffRes.json() : [];
  if (!staffRows[0]?.is_admin) return json({ error: "Only an admin can send invites." }, 403, origin);

  // 3. Validate the request.
  let body: { email?: string; redirect_to?: string; mode?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Expected JSON." }, 400, origin);
  }
  const email = String(body.email || "").trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "That doesn't look like an email address." }, 400, origin);

  // Only ever invite someone already on the staff list: the invite creates an
  // account, and an account that can't get past the staff gate is just noise.
  const targetRes = await fetch(
    `${SUPABASE_URL}/rest/v1/staff?select=email&email=eq.${encodeURIComponent(email)}`,
    { headers: { Authorization: auth, apikey: ANON_KEY } },
  );
  const targetRows = targetRes.ok ? await targetRes.json() : [];
  if (!targetRows.length) return json({ error: "Add them to the staff list first." }, 400, origin);

  if (body.mode === "temp_password") return await setTempPassword(email, callerEmail, origin);

  const redirectTo = ALLOWED_ORIGINS.some((o) => String(body.redirect_to || "").startsWith(o))
    ? String(body.redirect_to)
    : `${ALLOWED_ORIGINS[0]}/rbg-plant-data-app/`;

  // 4. Send the invite. GoTrue returns 422 when the user already exists, which
  // is the normal "they were invited before" case -- fall back to a magic link
  // so the person still gets a way in.
  const inviteUrl = `${SUPABASE_URL}/auth/v1/invite?redirect_to=${encodeURIComponent(redirectTo)}`;
  const invite = await fetch(inviteUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_KEY}`,
      apikey: SERVICE_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ email, data: { invited_by: callerEmail } }),
  });

  if (invite.ok) return json({ ok: true, sent: "invite", email }, 200, origin);

  const detail = await invite.text();
  if (invite.status === 422 || /already been registered|already exists/i.test(detail)) {
    const recover = await fetch(`${SUPABASE_URL}/auth/v1/recover?redirect_to=${encodeURIComponent(redirectTo)}`, {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ email }),
    });
    if (recover.ok) return json({ ok: true, sent: "reset", email }, 200, origin);
    return json({ error: `Already has an account, and the reset email failed: ${await recover.text()}` }, 502, origin);
  }
  // The built-in mailer is rate limited (a few per hour) -- say so plainly.
  if (invite.status === 429) return json({ error: "Supabase's email limit was hit. Wait an hour or set up a mail sender." }, 429, origin);
  return json({ error: `Invite failed: ${detail}` }, 502, origin);
});

// TEMPORARY PASSWORD -- for when the invite email lands in spam and the link
// expires before it's found. No email is sent: the admin reads the password
// off the screen and hands it over (text, phone, in person). The account is
// created already confirmed, and must_change_password sends the person to
// the app's "Set your password" screen on first sign-in.
//
// The flag lives in user_metadata, which the user can write themselves --
// that's what lets the app clear it in the same PUT /user that sets the new
// password. The cost: someone determined could clear it without changing
// the password. Acceptable for staff accounts; app_metadata would need a
// second server round trip to clear.
const ADMIN_HEADERS = {
  Authorization: `Bearer ${SERVICE_KEY}`,
  apikey: SERVICE_KEY,
  "Content-Type": "application/json",
};

// No 0/O, 1/l/I: it gets read aloud or retyped from a text message.
function makeTempPassword(len = 12) {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(len));
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
}

// GoTrue's admin list has no email filter, so page through it. Staff lists
// are tens of people; one page almost always does.
async function findUserId(email: string): Promise<string | null> {
  for (let page = 1; page <= 20; page++) {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users?page=${page}&per_page=200`, { headers: ADMIN_HEADERS });
    if (!res.ok) throw new Error(`Couldn't list users: ${await res.text()}`);
    const users = (await res.json()).users || [];
    const hit = users.find((u: { email?: string }) => String(u.email || "").toLowerCase() === email);
    if (hit) return hit.id;
    if (users.length < 200) return null;
  }
  return null;
}

async function setTempPassword(email: string, callerEmail: string, origin: string | null) {
  const password = makeTempPassword();
  const user_metadata = { must_change_password: true, temp_password_by: callerEmail };
  try {
    const create = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
      method: "POST",
      headers: ADMIN_HEADERS,
      body: JSON.stringify({ email, password, email_confirm: true, user_metadata }),
    });
    if (create.ok) return json({ ok: true, sent: "temp_password", email, password }, 200, origin);

    const detail = await create.text();
    if (!(create.status === 422 || /already been registered|already exists/i.test(detail))) {
      return json({ error: `Couldn't create the account: ${detail}` }, 502, origin);
    }
    // Already has an account -- usually from the invite that went to spam.
    // email_confirm here also unsticks an invite that was never accepted.
    const id = await findUserId(email);
    if (!id) return json({ error: "The account exists but couldn't be found to update." }, 502, origin);
    const update = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${id}`, {
      method: "PUT",
      headers: ADMIN_HEADERS,
      body: JSON.stringify({ password, email_confirm: true, user_metadata }),
    });
    if (!update.ok) return json({ error: `Couldn't set the password: ${await update.text()}` }, 502, origin);
    return json({ ok: true, sent: "temp_password", email, password }, 200, origin);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 502, origin);
  }
}
