// Shared helpers for the lessons: read the local stack's URL and keys, and build clients.
//
// In a real app you'd put these in environment variables:
//   SUPABASE_URL=...                (safe to expose)
//   SUPABASE_PUBLISHABLE_KEY=...    (safe to expose in browsers/mobile apps; RLS protects data)
//   SUPABASE_SECRET_KEY=...         (SERVER ONLY. Bypasses RLS. Never ship it to a client.)
// Here we ask the CLI for them so the lessons work with zero setup.

import { execSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';

let config;

export function localConfig() {
  if (config) return config;
  let out;
  try {
    out = execSync('npx supabase status -o json', {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch {
    console.error('Supabase is not running. Start it first:  npx supabase start');
    process.exit(1);
  }
  const s = JSON.parse(out.slice(out.indexOf('{')));
  config = {
    url: s.API_URL,
    publishableKey: s.PUBLISHABLE_KEY ?? s.ANON_KEY,
    secretKey: s.SECRET_KEY ?? s.SERVICE_ROLE_KEY,
    studioUrl: s.STUDIO_URL,
    dbUrl: s.DB_URL,
  };
  return config;
}

// Node scripts don't have browser storage, so don't try to persist sessions.
const serverAuth = { auth: { persistSession: false, autoRefreshToken: false } };

/** A client with only the publishable key: what a browser or mobile app has before login. */
export function publicClient() {
  const { url, publishableKey } = localConfig();
  return createClient(url, publishableKey, serverAuth);
}

/** A client with the secret key: bypasses RLS. Backend/admin scripts ONLY. */
export function adminClient() {
  const { url, secretKey } = localConfig();
  return createClient(url, secretKey, serverAuth);
}

export const DEMO_PASSWORD = 'local-demo-password-123';

/** Make sure a demo user exists (via the admin API), then return a client signed in as them. */
export async function signedInClient(email, username) {
  const admin = adminClient();
  const { error: createError } = await admin.auth.admin.createUser({
    email,
    password: DEMO_PASSWORD,
    email_confirm: true,
    user_metadata: { username },
  });
  if (createError && !/already/i.test(createError.message)) throw createError;

  const client = publicClient();
  const { data, error } = await client.auth.signInWithPassword({ email, password: DEMO_PASSWORD });
  if (error) throw error;
  return { client, user: data.user, session: data.session };
}

/** Delete demo users by email. Their profiles, todos, etc. cascade-delete with them. */
export async function deleteUsers(emails) {
  const admin = adminClient();
  const { data, error } = await admin.auth.admin.listUsers({ perPage: 1000 });
  if (error) throw error;
  for (const u of data.users.filter((u) => emails.includes(u.email))) {
    // Storage objects must be removed through the Storage API (not just the DB row).
    const { data: files } = await admin.storage.from('avatars').list(u.id);
    if (files?.length) await admin.storage.from('avatars').remove(files.map((f) => `${u.id}/${f.name}`));
    await admin.auth.admin.deleteUser(u.id);
  }
}

/** Decode a JWT's payload (no verification, just to look inside). */
export function decodeJwt(token) {
  const [header, payload] = token.split('.').slice(0, 2).map((part) =>
    JSON.parse(Buffer.from(part, 'base64url').toString('utf8')));
  return { header, payload };
}

export function section(title) {
  console.log(`\n=== ${title} ===`);
}

/** Print a supabase-js result as either the data or the error. */
export function show(label, { data, error, count }) {
  if (error) {
    console.log(`  ${label}: ERROR ${error.code ?? ''} ${error.message}`);
  } else {
    const hasCount = count !== undefined && count !== null;
    if (hasCount && data === null) console.log(`  ${label}: count = ${count}`);   // head: true
    else console.log(`  ${label}${hasCount ? ` (count=${count})` : ''}:`, JSON.stringify(data));
  }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
