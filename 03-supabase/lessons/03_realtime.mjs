// 03_realtime.mjs: Supabase Realtime's three features.
//
//   1. Postgres Changes : get INSERT/UPDATE/DELETE events from tables (filtered by RLS)
//   2. Broadcast        : low-latency messages between clients (chat, cursors, game state)
//   3. Presence         : shared "who's online" state that syncs across clients
//
// All three run over one WebSocket connection per client.
//
// Run (from the 03-supabase folder; run lesson 02 first so the users exist):
//   npm run lesson:realtime

import { signedInClient, section, sleep } from './_supabase.mjs';

const { client: ana, user: anaUser } = await signedInClient('ana@example.com', 'ana');
const { client: ben } = await signedInClient('ben@example.com', 'ben');

/** Resolve once a channel reaches SUBSCRIBED (or fail loudly). */
function subscribe(channel) {
  return new Promise((resolve, reject) => {
    channel.subscribe((status, err) => {
      if (status === 'SUBSCRIBED') resolve(channel);
      if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') reject(err ?? new Error(status));
    });
  });
}

// -------------------------------------------------------------------------------------
section('1. Postgres Changes: ana listens to the todos table');
const received = [];
let dbReady;
const dbReadyPromise = new Promise((resolve) => { dbReady = resolve; });
const feed = ana.channel('todos-feed')
  .on('postgres_changes',
    { event: '*', schema: 'public', table: 'todos' },   // also: filter: 'user_id=eq.<uuid>'
    (change) => received.push(change))
  .on('system', {}, (msg) => {                          // server status messages
    if (msg.extension === 'postgres_changes' && msg.status === 'ok') dbReady(msg.message);
  });
await subscribe(feed);
console.log(`  ana: channel SUBSCRIBED; server says "${await dbReadyPromise}"`);
// GOTCHA: SUBSCRIBED means the WebSocket channel joined. The server then starts reading the
// database's change stream, and writes made in that gap are not delivered. Wait for the
// "Subscribed to PostgreSQL" system message plus a short buffer. Real apps should re-fetch
// data after (re)subscribing rather than assume no events were missed.
await sleep(1500);
console.log('  Now ben and ana make some changes...');

const pub = await ben.from('todos').insert({ title: 'ben: realtime public', is_public: true }).select().single();
const priv = await ben.from('todos').insert({ title: 'ben: realtime PRIVATE' }).select().single();
await ana.from('todos').insert({ title: 'ana: realtime own' });
await ben.from('todos').update({ is_done: true }).eq('id', pub.data.id);
await ben.from('todos').delete().eq('id', priv.data.id);
await sleep(2500);   // events arrive asynchronously over the WebSocket

console.log(`  ana received ${received.length} events:`);
for (const c of received) {
  const row = c.eventType === 'DELETE' ? c.old : c.new;
  console.log(`    ${c.eventType.padEnd(6)} ${JSON.stringify(row.title ?? row)}`);
}
console.log(`  -> Ben's PRIVATE insert never reached ana: Realtime checks each event against the
     subscriber's RLS SELECT policies before sending it.
  -> But the DELETE of ben's private todo DID arrive, carrying only the primary key.
     Postgres can't evaluate RLS on a row that no longer exists, so delete events are
     not filtered. Don't put secrets in primary keys.`);

// -------------------------------------------------------------------------------------
section('2. Broadcast: client-to-client messages (never touch the database)');
const messages = [];
const anaRoom = ana.channel('room:lobby');
anaRoom.on('broadcast', { event: 'cursor' }, ({ payload }) => messages.push(payload));
const benRoom = ben.channel('room:lobby', { config: { broadcast: { ack: true } } });
await Promise.all([subscribe(anaRoom), subscribe(benRoom)]);

for (const [x, y] of [[10, 20], [15, 25], [30, 40]]) {
  await benRoom.send({ type: 'broadcast', event: 'cursor', payload: { user: 'ben', x, y } });
}
await sleep(1000);
console.log('  ana received ben\'s cursor positions:', JSON.stringify(messages));
console.log('  -> Senders don\'t receive their own broadcasts unless { broadcast: { self: true } }.');

// -------------------------------------------------------------------------------------
section("3. Presence: who's here right now");
const lobbyA = ana.channel('presence:lobby', { config: { presence: { key: anaUser.id } } });
let latestState = {};
lobbyA.on('presence', { event: 'sync' }, () => { latestState = lobbyA.presenceState(); });
lobbyA.on('presence', { event: 'join' }, ({ newPresences }) =>
  console.log('  join :', newPresences.map((p) => p.username).join(', ')));
lobbyA.on('presence', { event: 'leave' }, ({ leftPresences }) =>
  console.log('  leave:', leftPresences.map((p) => p.username).join(', ')));
const lobbyB = ben.channel('presence:lobby');

await subscribe(lobbyA);
await lobbyA.track({ username: 'ana', status: 'online' });
await subscribe(lobbyB);
await lobbyB.track({ username: 'ben', status: 'typing...' });
await sleep(1500);
const online = Object.values(latestState).flat().map((p) => `${p.username} (${p.status})`);
console.log('  ana\'s view of the lobby:', online.join(', '));

await lobbyB.untrack();
await sleep(1000);

// -------------------------------------------------------------------------------------
await ana.removeAllChannels();
await ben.removeAllChannels();
console.log(`
Production notes:
  - Postgres Changes only fires for tables in the supabase_realtime publication (migration 3).
  - It processes changes on a single thread per database. For high-volume fan-out, prefer
    Broadcast, including "broadcast from the database" via realtime.broadcast_changes() in a trigger.
  - Make Broadcast/Presence channels private ({ config: { private: true } }) and write RLS
    policies on realtime.messages to control who may join and send.

Next: npm run lesson:storage`);
process.exit(0);
