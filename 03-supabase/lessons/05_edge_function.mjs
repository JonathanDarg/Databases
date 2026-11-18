// 05_edge_function.mjs: calling the `whoami` Edge Function (supabase/functions/whoami).
//
// `npx supabase start` serves every function in supabase/functions at
//   http://127.0.0.1:54321/functions/v1/<name>
// Edit index.ts and the next request runs the new code (hot reload).
//
// Run (from the 03-supabase folder; run lesson 02 first so the users exist):
//   npm run lesson:functions

import { localConfig, publicClient, signedInClient, section } from './_supabase.mjs';

const cfg = localConfig();
const { client: ana, session } = await signedInClient('ana@example.com', 'ana');

section('1. Signed-in user calls the function (supabase-js sends the JWT for you)');
const { data, error } = await ana.functions.invoke('whoami');
if (error) {
  const body = await error.context?.text?.();
  console.log('  ERROR:', error.message, body ?? '');
} else {
  console.log(JSON.stringify(data, null, 2).replace(/^/gm, '  '));
}

section('2. Anonymous caller: rejected before the handler runs');
const anon = await publicClient().functions.invoke('whoami');
const body = await anon.error?.context?.json?.().catch(() => ({}));
console.log(`  HTTP ${anon.error?.context?.status ?? 'ok?!'} ${body?.code ?? ''}`);
console.log(`  ${body?.hint ?? ''}`);

section('3. The same call as plain HTTP (what any language or curl can do)');
const res = await fetch(`${cfg.url}/functions/v1/whoami`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${session.access_token}`, apikey: cfg.publishableKey },
});
console.log(`  POST /functions/v1/whoami -> HTTP ${res.status}`);
console.log(`  curl equivalent:
    curl -X POST ${cfg.url}/functions/v1/whoami \\
      -H "Authorization: Bearer <user access token>" -H "apikey: <publishable key>"`);

console.log(`
Production notes:
  - Deploy:   npx supabase functions deploy whoami
  - Secrets:  npx supabase secrets set STRIPE_KEY=sk_live_...   ->  Deno.env.get('STRIPE_KEY')
  - Schedule: pg_cron + pg_net can call a function on a cron schedule.
  - Keep functions small and stateless. They cold-start, and have CPU-time and memory limits.`);
