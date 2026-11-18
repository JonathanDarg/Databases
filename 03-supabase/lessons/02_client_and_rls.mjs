// 02_client_and_rls.mjs: Auth + the Data API from a client, with RLS doing the security.
//
// This is what your frontend code looks like. Watch for one thing in particular: the
// browser talks STRAIGHT to the database API, with no backend of your own in between.
// That's only safe because of the RLS policies in supabase/migrations.
//
// Run (from the 03-supabase folder, with `npx supabase start` running):
//   npm run lesson:client

import {
  localConfig, publicClient, adminClient, deleteUsers, decodeJwt, section, show, DEMO_PASSWORD,
} from './_supabase.mjs';

const cfg = localConfig();
const ANA = 'ana@example.com';
const BEN = 'ben@example.com';

// -------------------------------------------------------------------------------------
section('1. Connecting: a URL and a key, nothing else');
console.log(`  API URL         : ${cfg.url}`);
console.log(`  publishable key : ${cfg.publishableKey.slice(0, 20)}...  (safe in client code)`);
console.log(`  secret key      : ${cfg.secretKey.slice(0, 12)}...  (server only: bypasses RLS)`);
console.log(`  Studio dashboard: ${cfg.studioUrl}`);
await deleteUsers([ANA, BEN]);   // clean slate so the lesson is repeatable

// -------------------------------------------------------------------------------------
section('2. Sign up two users (Supabase Auth)');
const ana = publicClient();
const ben = publicClient();
const anaSignup = await ana.auth.signUp({
  email: ANA, password: DEMO_PASSWORD, options: { data: { username: 'ana' } },
});
const benSignup = await ben.auth.signUp({
  email: BEN, password: DEMO_PASSWORD, options: { data: { username: 'ben' } },
});
if (anaSignup.error || benSignup.error) throw anaSignup.error ?? benSignup.error;
const anaId = anaSignup.data.user.id;
console.log(`  ana id = ${anaId}`);
console.log(`  ben id = ${benSignup.data.user.id}`);
console.log('  (Email confirmation is OFF locally: [auth.email] enable_confirmations in config.toml.');
console.log('   In production, turn it on and the user signs in after clicking the email link.)');

const { header, payload } = decodeJwt(anaSignup.data.session.access_token);
console.log('\n  Ana\'s access token is a JWT. Every API request sends it. Inside:');
console.log(`    header : alg=${header.alg} kid=${header.kid ?? '-'}`);
console.log(`    sub    : ${payload.sub}   <- auth.uid() in SQL returns this`);
console.log(`    role   : ${payload.role}   <- PostgREST runs the query as this DB role`);
console.log(`    email  : ${payload.email}`);
console.log(`    expires: in ${Math.round((payload.exp - Date.now() / 1000) / 60)} min (refresh token renews it)`);

show('Profile row created by the signup trigger', await ana.from('profiles').select('id, username').eq('id', anaId));

// -------------------------------------------------------------------------------------
section('3. Writing data: insert + .select() returns the created rows');
const rows = [
  { title: 'buy milk' },
  { title: 'learn RLS', is_public: true },
  { title: 'write the report' },
];
show('ana bulk-inserts rows with DIFFERENT keys', await ana.from('todos').insert(rows).select());
console.log(`  -> GOTCHA: a multi-row insert sends the union of all keys (title, is_public), and a key
     missing from a row becomes NULL, not the column DEFAULT. Hence the NOT NULL error.`);
show('same insert with { defaultToNull: false }', await ana.from('todos')
  .insert(rows, { defaultToNull: false }).select('id, title, is_public, user_id'));
console.log('  -> user_id was filled in by the column default auth.uid(). The client never sent it.');

const benRows = await ben.from('todos').insert([
  { title: "ben's secret plan" },
  { title: "ben's public tip", is_public: true },
], { defaultToNull: false }).select('id, title');
show('ben inserts', benRows);
const benSecretId = benRows.data[0].id;

// -------------------------------------------------------------------------------------
section('4. Reading data: filters, ordering, counting, and joins');
show('ana: everything she can see', await ana.from('todos').select('title, is_public').order('id'));
console.log("  -> her own 3 + ben's PUBLIC tip. Ben's secret plan is invisible to her.");
show('ana: open todos matching %r%, newest first', await ana.from('todos')
  .select('title').ilike('title', '%r%').eq('is_done', false).order('created_at', { ascending: false }));
show('ana: count only, no rows', await ana.from('todos').select('*', { count: 'exact', head: true }));
show('ana: join to author via foreign key', await ana.from('todos')
  .select('title, author:profiles(username)').eq('is_public', true));
show('ana: pagination with range(0, 1)', await ana.from('todos').select('id, title').order('id').range(0, 1));

// -------------------------------------------------------------------------------------
section("5. RLS from the client: ana attacks ben's data");
show("ana UPDATEs ben's secret todo", await ana.from('todos')
  .update({ title: 'hacked' }).eq('id', benSecretId).select());
console.log('  -> No error, just [] (zero rows matched). RLS makes rows you can\'t see not exist.');
show('ana INSERTs a todo owned by ben', await ana.from('todos')
  .insert({ title: 'forged', user_id: benSignup.data.user.id }));
console.log('  -> The WITH CHECK policy rejects rows you aren\'t allowed to create.');
show("ana DELETEs ben's todo", await ana.from('todos').delete().eq('id', benSecretId).select());

// -------------------------------------------------------------------------------------
section('6. Anonymous visitor (publishable key, not signed in)');
const anon = publicClient();
show('anon reads todos', await anon.from('todos').select('title'));
show('anon inserts', await anon.from('todos').insert({ title: 'spam' }));

// -------------------------------------------------------------------------------------
section('7. RPC: calling Postgres functions');
show('ana.rpc(my_todo_stats)', await ana.rpc('my_todo_stats'));
show('ana.rpc(complete_all_my_todos)', await ana.rpc('complete_all_my_todos'));
show('ana.rpc(my_todo_stats) again', await ana.rpc('my_todo_stats'));
show('anon.rpc(community_stats)  [security definer]', await anon.rpc('community_stats'));
show('anon.rpc(my_todo_stats)    [execute revoked]', await anon.rpc('my_todo_stats'));

// -------------------------------------------------------------------------------------
section('8. The secret key bypasses RLS: what your backend/admin scripts use');
show('admin counts every todo', await adminClient().from('todos').select('*', { count: 'exact', head: true }));

// -------------------------------------------------------------------------------------
section('9. Under the hood: supabase-js is just HTTP to PostgREST');
const { data: { session } } = await ana.auth.getSession();
const restUrl = `${cfg.url}/rest/v1/todos?select=title,is_done&order=id.asc&limit=2`;
const res = await fetch(restUrl, {
  headers: { apikey: cfg.publishableKey, Authorization: `Bearer ${session.access_token}` },
});
console.log(`  GET ${restUrl.replace(cfg.url, '')}`);
console.log(`  -> HTTP ${res.status}`, JSON.stringify(await res.json()));
console.log('  The query string IS the query: select=, order=, limit=, title=eq.x, id=in.(1,2), ...');

await ana.auth.signOut();
await ben.auth.signOut();
console.log('\nDone. Open Studio to browse what was created:', cfg.studioUrl);
console.log('Next: npm run lesson:realtime');
