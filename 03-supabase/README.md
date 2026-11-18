# 03 · Supabase: Postgres as a Backend-as-a-Service

> **Goal:** understand what Supabase is and how its pieces fit together around one PostgreSQL
> database. Learn why Row Level Security is the center of the whole model, and be able to build,
> secure, test, and ship a Supabase backend like a professional. Everything here runs **locally
> in Docker**: no account and no cost.

**Quick start** (from this folder, Docker Desktop running):

```bash
npm install                 # Supabase CLI + supabase-js (already done if node_modules exists)
npx supabase start          # first run downloads the Docker images (several GB), then ~30 s
npm run lesson:rls          # lesson 1: RLS in raw SQL
npm run lesson:client       # lesson 2: auth + Data API from a client
```
Then open **Studio** (the dashboard) at <http://127.0.0.1:54323>.

> The local stack is ~10 containers. `supabase/config.toml` disables the `analytics` (logs)
> service to save RAM; set it back to `true` if you want the Logs pages in Studio. Stop the stack
> with `npm run stop` when you're done. Data is kept until `npx supabase stop --no-backup`.

## Contents

1. [What Supabase is](#1-what-supabase-is)
2. [Architecture: what runs where](#2-architecture-what-runs-where)
3. [Keys, roles, and JWTs](#3-keys-roles-and-jwts)
4. [Row Level Security: the heart of Supabase](#4-row-level-security-the-heart-of-supabase)
5. [Auth](#5-auth)
6. [The Data API (PostgREST) and supabase-js](#6-the-data-api-postgrest-and-supabase-js)
7. [Realtime](#7-realtime)
8. [Storage](#8-storage)
9. [Edge Functions](#9-edge-functions)
10. [It's a full Postgres: extensions and database features](#10-its-a-full-postgres)
11. [Local development and the CLI workflow](#11-local-development-and-the-cli-workflow)
12. [Going to production](#12-going-to-production)
13. [Security checklist](#13-security-checklist)
14. [Performance](#14-performance)
15. [Supabase vs Firebase vs plain Postgres vs SQLite](#15-comparison)
16. [Lock-in and self-hosting](#16-lock-in-and-self-hosting)
17. [Gotchas cheat sheet](#17-gotchas-cheat-sheet)
18. [Lessons](#18-lessons) · [Exercises](#19-exercises) · [Further reading](#20-further-reading)

---

## 1. What Supabase is

Supabase is an **open-source backend platform built around a full PostgreSQL database.** Every
project gets:

| Piece | What it gives you |
| :--- | :--- |
| **Postgres database** | A real, full Postgres (17 here), with extensions, SQL, and a direct connection string |
| **Data API** | REST (and GraphQL) endpoints **generated automatically from your schema** |
| **Auth** | Sign-up/sign-in (email, magic links, OAuth, phone, SSO, MFA, passkeys), issuing JWTs |
| **Realtime** | WebSocket subscriptions to database changes, plus broadcast messages and presence |
| **Storage** | File/object storage with access rules written as Postgres policies |
| **Edge Functions** | Server-side TypeScript (Deno) for logic that can't live in the client |
| **Studio** | A web dashboard: table editor, SQL editor, auth users, logs, advisors |

**The big idea: the database *is* the backend.** In a classic stack you write an API server
that checks permissions and then queries the database. With Supabase, **the client queries the
database (through the Data API) directly**, and permissions are enforced **inside Postgres** by
**Row Level Security (RLS)** policies. You write far less backend code. The trade-off is that
your security now lives in SQL policies you must get right.

```
 Classic:   browser ──▶ your API server (auth checks, business logic) ──▶ database
 Supabase:  browser ──▶ Supabase API (verifies JWT) ──▶ Postgres (RLS policies decide) ✔
                   └──▶ Edge Function (secrets, 3rd-party APIs, heavy logic) ──▶ Postgres
```

It's often called "the open-source Firebase alternative". The difference is that the data is
**relational SQL** instead of NoSQL documents (see topic 04 of this repo for Firebase).

---

## 2. Architecture: what runs where

Each Supabase service is its own open-source project. `npx supabase start` runs all of them as
Docker containers (`docker ps` shows them):

```
   your app: supabase-js  +  publishable key  +  (user JWT after sign-in)
        │  HTTPS + WebSocket
 ┌──────▼──────────────────────────── API gateway (:54321) ─────────────────────────────┐
 │ /auth/v1      → Auth (GoTrue, Go)          issues and refreshes JWTs                  │
 │ /rest/v1      → PostgREST (Haskell)        turns HTTP requests into SQL               │
 │ /graphql/v1   → pg_graphql (via PostgREST) GraphQL, resolved inside Postgres          │
 │ /realtime/v1  → Realtime (Elixir)          WebSockets: DB changes, broadcast, presence│
 │ /storage/v1   → Storage API (Node)         files in S3-compatible storage + metadata  │
 │ /functions/v1 → Edge Runtime (Deno)        your TypeScript functions                  │
 └──────────────────────────────────┬───────────────────────────────────────────────────┘
                                    ▼
              PostgreSQL 17 (:54322)   ◀── Studio (:54323) via postgres-meta
              auth.*  storage.*  realtime.*  public.* (your tables) ...
```

| Local URL | What |
| :--- | :--- |
| <http://127.0.0.1:54321> | API gateway: all client traffic |
| `postgresql://postgres:postgres@127.0.0.1:54322/postgres` | Direct database connection |
| <http://127.0.0.1:54323> | Studio dashboard |
| <http://127.0.0.1:54324> | Mailpit: every email Auth "sends" locally lands here |
| <http://127.0.0.1:54321/mcp> | MCP server, so AI coding tools can inspect the local project |

### What happens on every API request

```
1. Client sends:  GET /rest/v1/todos?select=title
                  apikey: <publishable key>       Authorization: Bearer <user's JWT>
2. Gateway checks the apikey.
3. PostgREST verifies the JWT signature, then, in ONE transaction:
       SET LOCAL ROLE authenticated;                          -- from the JWT "role" claim
       SELECT set_config('request.jwt.claims', '<JWT JSON>', true);
       SELECT title FROM public.todos;                        -- translated from the URL
4. Postgres applies RLS: auth.uid() reads "sub" from those claims, and the policies filter rows.
5. Rows come back as JSON.
```
**Lesson 01 does steps 3 and 4 by hand in SQL**, so there's no magic left.

---

## 3. Keys, roles, and JWTs

| Credential | Looks like | Where it may live | What it does |
| :--- | :--- | :--- | :--- |
| **Publishable key** | `sb_publishable_...` | Browser, mobile app, public repo is OK | Identifies your project. Requests run as **`anon`** unless a user JWT is attached. |
| **Secret key** | `sb_secret_...` | **Servers only** (env vars, never in client bundles) | Runs as **`service_role`**, which **bypasses RLS**. Create one per service so you can revoke them individually. |
| Legacy `anon` / `service_role` keys | long JWTs (`eyJ...`) | same rules as above | Older projects' equivalents. Supabase recommends migrating to the new keys. |
| **User access token** | JWT (`eyJ...`) | Client memory/cookie | Issued by Auth at sign-in. ~1 hour lifetime, renewed with a **refresh token**. |

**Database roles** you'll see in policies:

| Role | Who | Bypasses RLS? |
| :--- | :--- | :--- |
| `anon` | Requests with no signed-in user | No |
| `authenticated` | Requests with a valid user JWT | No |
| `service_role` | Requests using the secret key | **Yes** |
| `authenticator` | The login PostgREST uses, which then `SET ROLE`s to one of the above | n/a |
| `postgres` | You, in migrations / SQL editor / direct connections | **Yes** (`BYPASSRLS`, and it owns the tables) |

**The user JWT** carries claims your SQL can read with `auth.jwt()`: `sub` (the user id, also
`auth.uid()`), `role`, `email`, `aal` (MFA level `aal1`/`aal2`), `session_id`, `is_anonymous`,
`app_metadata` and `user_metadata`. Projects sign tokens with **asymmetric signing keys** (public
keys published at `/auth/v1/.well-known/jwks.json`), so any server can verify a token without
knowing a shared secret. The local stack signs with **ES256** (lesson 02 prints the JWT header).
Older projects use a single HS256 shared JWT secret.

---

## 4. Row Level Security: the heart of Supabase

Every table in an exposed schema (`public` by default) is reachable over HTTP by anyone with
your publishable key. **RLS is the only thing between your data and the internet.**

### 4.1 How policies work

```sql
alter table public.todos enable row level security;    -- step 1: deny everything by default

create policy "Users can read their own todos"         -- step 2: allow specific access
    on public.todos
    for select                                         -- which command: select/insert/update/delete/all
    to authenticated                                   -- which role(s)
    using ((select auth.uid()) = user_id);             -- which EXISTING rows are visible/targetable
```

| Command | `USING` (filters existing rows) | `WITH CHECK` (validates new/changed rows) |
| :--- | :---: | :---: |
| SELECT | ✔ | |
| INSERT | | ✔ |
| UPDATE | ✔ (rows you may target) | ✔ (what the row may become) |
| DELETE | ✔ | |

- **RLS enabled + no policies = no access** (except roles that bypass RLS).
- Multiple **permissive** policies (the default) are **OR**-ed. `as restrictive` policies are
  **AND**-ed on top, which is useful for "and must have MFA" rules.
- RLS **hides** rows rather than raising errors. An `UPDATE` of someone else's row "succeeds"
  with **0 rows affected**, and a forbidden `INSERT` raises
  `new row violates row-level security policy`.
- **Privileges are checked before RLS.** `GRANT`/`REVOKE` decide whether a role may use a table
  at all; policies decide which rows. Use both (migration 1 revokes writes from `anon`).

### 4.2 Policy patterns

```sql
-- Owner only
using ((select auth.uid()) = user_id)

-- Public read, owner write: two policies (see migration 1)
create policy "read public" on todos for select to anon, authenticated using (is_public);

-- Team membership: put the lookup in a SECURITY DEFINER helper in a NON-exposed schema.
-- This avoids recursive policies and slow per-row joins.
create schema if not exists private;
create function private.is_team_member(_team_id bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.team_members
                 where team_id = _team_id and user_id = (select auth.uid()));
$$;
create policy "members read team docs" on public.documents for select to authenticated
  using ((select private.is_team_member(team_id)));

-- Role-based, from app_metadata (only settable server-side). NEVER use user_metadata for this,
-- because users can edit their own user_metadata.
using ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin')

-- Require MFA for sensitive tables (restrictive = ANDed with the others)
create policy "mfa required" on public.payouts as restrictive for all to authenticated
  using ((select auth.jwt() ->> 'aal') = 'aal2');
```

### 4.3 RLS traps

| Trap | What happens | Fix |
| :--- | :--- | :--- |
| Table created with SQL, RLS never enabled | **Anyone can read and write it** (lesson 01, section 7) | `alter table ... enable row level security` in the same migration. Studio's **Security Advisor** flags it. |
| **Views** | Run with the *owner's* rights, so they **bypass RLS** | `create view v with (security_invoker = true) as ...` |
| `security definer` functions | Bypass RLS | Keep them in a non-exposed schema, `set search_path = ''`, and return only what's safe |
| Authorization based on `user_metadata` | Users can change their own metadata | Use `app_metadata` or a roles table |
| Policy without `to <role>` | Applies to every role, including `anon` | Always write `to authenticated` / `to anon` |
| `auth.uid()` evaluated per row | Slow on big tables | `(select auth.uid())` is evaluated once per query |
| Unindexed policy columns | Every query does a sequential scan | Index `user_id`, `team_id`, ... |
| Realtime `DELETE` events | Not filtered by RLS; the primary key leaks | Don't put sensitive data in PKs (lesson 03) |
| Testing only as `postgres` in the SQL editor | The owner bypasses RLS, so everything "works" | Test as `anon`/`authenticated` (lesson 01 technique, pgTAP, or the Studio role switcher) |

---

## 5. Auth

| Capability | Notes |
| :--- | :--- |
| Email + password, magic links, email OTP | Built in. Turn on **email confirmations** for production. |
| Phone / SMS OTP | Needs an SMS provider (Twilio, Vonage, MessageBird, ...) |
| OAuth / social | Google, GitHub, Apple, Azure, Discord, GitLab, Slack, ... |
| SSO (SAML) | Enterprise SSO for B2B apps |
| MFA | TOTP authenticator apps, phone. The JWT's `aal` claim tells policies whether MFA was used. |
| Passkeys / WebAuthn, Web3 wallets | Newer sign-in methods |
| Anonymous sign-ins | A real user with `is_anonymous = true` that can later be upgraded to a full account |
| Third-party auth | Accept JWTs from Clerk, Auth0, Firebase Auth, Cognito, so RLS works with their users |
| Auth hooks | Postgres/HTTP hooks: add custom JWT claims, block sign-ups, custom email/SMS senders |

**How it fits together:**
- Users live in **`auth.users`** (a schema that isn't exposed over the API). Keep app-facing
  user data in a **`public.profiles`** table filled by a trigger on sign-up (migration 1).
  **If that trigger errors, sign-up fails**, so keep it simple.
- A session is an **access token** (JWT, `jwt_expiry` default 1 h) plus a **refresh token**
  (rotating). Client libraries refresh automatically.
- **Server-side** (SSR, APIs): verify the user with `supabase.auth.getClaims()` (verifies the JWT
  signature) or `getUser()` (asks the Auth server). Don't trust `getSession()` on the server: it
  reads whatever is in the cookie. For Next.js/SvelteKit/Remix, use **`@supabase/ssr`**, which
  stores sessions in cookies.
- **Email delivery:** the built-in mailer is only for testing and is heavily rate-limited.
  Configure **custom SMTP** (Resend, SES, Postmark, ...) for production. Locally, emails go to
  Mailpit (<http://127.0.0.1:54324>).
- Set the **Site URL** and **redirect URL allowlist**, enable **CAPTCHA** on public sign-up
  forms, and review **rate limits** (`[auth.rate_limit]` in `config.toml`).

---

## 6. The Data API (PostgREST) and supabase-js

PostgREST reads your schema and serves it: every table/view becomes `/rest/v1/<name>` and every
function becomes `/rest/v1/rpc/<name>`. Change the schema and the API changes with it (it
reloads its schema cache automatically after migrations; force it with `notify pgrst, 'reload schema';`).

```js
import { createClient } from '@supabase/supabase-js'
const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY)
```

| Task | supabase-js | HTTP equivalent |
| :--- | :--- | :--- |
| Choose columns | `.from('todos').select('id, title')` | `GET /rest/v1/todos?select=id,title` |
| Join via foreign key | `.select('title, author:profiles(username)')` | `?select=title,author:profiles(username)` |
| Filter | `.eq('is_done', false)`, `.neq`, `.gt/.gte/.lt/.lte`, `.in('id', [1,2])`, `.is('x', null)` | `?is_done=eq.false&id=in.(1,2)` |
| Text search | `.ilike('title', '%milk%')`, `.textSearch('fts', 'cats & dogs')` | `?title=ilike.*milk*` |
| JSON / arrays | `.contains('tags', ['a'])`, `.eq('data->>type', 'click')` | `?tags=cs.{a}` |
| Boolean logic | `.or('is_public.eq.true,user_id.eq.<id>')`, `.not('title', 'is', null)` | `?or=(...)` |
| Sort / paginate | `.order('created_at', { ascending: false }).range(0, 19)` | `?order=created_at.desc` + `Range: 0-19` |
| One row | `.single()` (error unless exactly 1), `.maybeSingle()` (0 or 1) | `Accept: application/vnd.pgrst.object+json` |
| Count | `.select('*', { count: 'exact', head: true })` (`'estimated'` for big tables) | `Prefer: count=exact` + `HEAD` |
| Insert / upsert | `.insert(rows).select()`, `.upsert(rows, { onConflict: 'sku' })` | `POST` (+ `Prefer: resolution=merge-duplicates`) |
| Update / delete | `.update({...}).eq('id', 1).select()`, `.delete().eq('id', 1)` | `PATCH` / `DELETE` with filters |
| Call a function | `.rpc('my_todo_stats', { arg: 1 })` | `POST /rest/v1/rpc/my_todo_stats` |

Notes:
- Writes return nothing unless you chain `.select()`. **Always filter** `update`/`delete`.
  RLS limits the damage, but be explicit.
- **Bulk-insert gotcha:** inserting several objects with *different keys* sends the union of the
  keys, and a key missing from one row becomes **NULL, not the column DEFAULT**. That breaks
  `NOT NULL ... DEFAULT` columns. Pass `{ defaultToNull: false }` (lesson 02, section 3).
- Responses are capped by `max_rows` (default 1000). Paginate with `.range()`.
- Complex reads go in a **view** (`security_invoker = true`!) or an **RPC function**. Multi-step
  writes that must be atomic go in an **RPC function** (one function call = one transaction).
- **Types:** `npm run gen:types` writes `types/database.types.ts`. Then use
  `createClient<Database>(...)` and every query is type-checked against your schema.
- GraphQL is available at `/graphql/v1` (pg_graphql) if you prefer it.

---

## 7. Realtime

| Feature | Use for | How it's secured |
| :--- | :--- | :--- |
| **Postgres Changes** | Live UI updates from table INSERT/UPDATE/DELETE | Table must be in the `supabase_realtime` publication; each event is checked against the subscriber's RLS **SELECT** policies |
| **Broadcast** | Chat, cursors, multiplayer, notifications: client ↔ client, low latency | Private channels + RLS policies on `realtime.messages` |
| **Presence** | "Who's online", typing indicators | Same as Broadcast |

```js
supabase.channel('todos-feed')
  .on('postgres_changes', { event: '*', schema: 'public', table: 'todos', filter: `user_id=eq.${uid}` },
      (change) => console.log(change.eventType, change.new))
  .subscribe()
```
- `DELETE` events **can't be RLS-filtered** (the row is gone) and carry only the primary key, or
  the full old row if `replica identity full` is set, which then goes to every subscriber.
- **`SUBSCRIBED` doesn't mean "receiving database changes" yet.** The server attaches to the
  change stream just after the channel joins (it sends a `system` message, "Subscribed to
  PostgreSQL"), and writes in that gap are missed. Lesson 03 waits for that message. Real apps
  should **re-fetch after every (re)subscribe** instead of assuming no events were missed.
- Postgres Changes is convenient but processes changes on a single thread per database. At high
  volume, use **Broadcast**, including broadcasting from the database itself with
  `realtime.broadcast_changes()` / `realtime.send()` inside triggers.
- Connection and message-rate limits depend on your plan.

---

## 8. Storage

- **Buckets** hold files. **Public** buckets serve files to anyone with the URL (CDN-cached).
  **Private** buckets require a policy match or a **signed URL**.
- File metadata is a row in **`storage.objects`**, so access is written as **RLS policies on
  `storage.objects`**, using helpers like `storage.foldername(name)`, `storage.filename(name)`
  and `storage.extension(name)` (migration 3).
- Per-bucket `file_size_limit` and `allowed_mime_types` are enforced server-side.
- Signed URLs (`createSignedUrl`) for temporary read access. Signed **upload** URLs
  (`createSignedUploadUrl`) let a server authorize one upload.
- **Resumable uploads** (TUS) for large files; an **S3-compatible API** for existing S3 tools;
  **image transformations** (resize on the fly) on paid plans.
- Delete files with the **Storage API**. Deleting rows from `storage.objects` with SQL orphans
  the actual bytes.

---

## 9. Edge Functions

Server-side **TypeScript on Deno 2**, deployed globally. Use them for anything that needs a
**secret**, a **trusted environment**, or a **third-party API**: payments (Stripe), sending
email, webhooks, AI API calls, and complex validation.

```bash
npx supabase functions new whoami        # scaffold supabase/functions/whoami/index.ts
npx supabase start                       # serves all functions locally at /functions/v1/<name>
npx supabase functions deploy whoami     # deploy to your hosted project
npx supabase secrets set STRIPE_KEY=...  # available as Deno.env.get('STRIPE_KEY')
```

Current templates use **`@supabase/server`**'s `withSupabase()` wrapper, which validates the
caller and builds clients for you ([supabase/functions/whoami/index.ts](supabase/functions/whoami/index.ts)):

| `auth:` mode | Caller must send | `ctx.supabase` acts as |
| :--- | :--- | :--- |
| `'user'` (default) | A valid user JWT | That user (RLS applies). `ctx.userClaims` has id/email/role. |
| `'publishable'` | Your publishable key | `anon` (RLS applies) |
| `'secret'` / `'secret:<name>'` | A (named) secret key | Use `ctx.supabaseAdmin` (bypasses RLS) |
| `'none'` | Nothing | Public endpoint: do your own checks |

- New functions get `verify_jwt = false` in `config.toml` because `withSupabase` does the
  verification itself. The gateway-level `verify_jwt` check is the legacy approach.
- Functions get `SUPABASE_URL`, your keys, and `SUPABASE_DB_URL` as environment variables
  automatically.
- Keep them stateless and fast: they have CPU-time, wall-clock, and memory limits, and may
  cold-start. Use `EdgeRuntime.waitUntil(promise)` for work after the response is sent.
- **Call them on a schedule** with `pg_cron` + `pg_net`, or on table changes with
  **Database Webhooks**.

**Edge Function, RPC, or direct table access?** Direct table access + RLS for normal CRUD.
**RPC** for multi-step transactional logic that only touches the database. **Edge Functions**
when you need secrets, external services, or code that mustn't run in the database.

---

## 10. It's a full Postgres

Everything from topic 01 (ACID, joins, indexes, `EXPLAIN`) applies. You also get extensions
with one SQL statement (`create extension ...`) or a click in Studio:

| Extension / feature | Gives you |
| :--- | :--- |
| **pgvector** | Vector similarity search for AI/embeddings (topic 05 of this repo) |
| **pg_cron** | Scheduled jobs inside the database |
| **pg_net** | HTTP requests from SQL (webhooks, calling Edge Functions) |
| **pgmq** (Supabase Queues) | Durable message queues in Postgres |
| **PostGIS** | Geospatial types and queries |
| **pg_graphql** | The GraphQL API |
| **pg_stat_statements**, **index_advisor** | Find slow queries and suggested indexes |
| **Wrappers** (FDWs) | Query Stripe, S3, BigQuery, ... as if they were tables |
| **Vault** | Encrypted secrets stored in the database (`vault.create_secret(...)`) |

You can also connect **any Postgres client or ORM** (psql, DBeaver, Prisma, Drizzle,
SQLAlchemy) with the connection string. Supabase doesn't force you to use its API.

---

## 11. Local development and the CLI workflow

The schema lives in **version-controlled migration files** (`supabase/migrations/*.sql`), not in
dashboard clicks.

| Command | What it does |
| :--- | :--- |
| `npx supabase init` | Create `supabase/config.toml` (done for this folder) |
| `npx supabase start` / `stop` | Run / stop the local stack (`stop --no-backup` also deletes local data) |
| `npx supabase status` | URLs and keys of the local stack |
| `npx supabase migration new add_tags` | New empty, timestamped migration file to write SQL into |
| `npx supabase db reset` | **Rebuild the local DB from scratch:** all migrations, then `seed.sql` |
| `npx supabase db diff -f add_tags` | Changed tables in local Studio? Generate a migration from the difference |
| `npx supabase test db` | Run pgTAP SQL tests in `supabase/tests/` (great for RLS tests) |
| `npx supabase gen types typescript --local` | TypeScript types from your schema |
| `npx supabase login` → `link --project-ref <ref>` | Connect this folder to a hosted project |
| `npx supabase db push` | Apply new migrations to the linked (remote) project |
| `npx supabase db pull` | Capture remote schema changes into a migration |
| `npx supabase migration list` | Compare local vs remote migration history |
| `npx supabase functions deploy` / `secrets set` | Ship Edge Functions / set their secrets |
| `npx supabase db dump -f backup.sql` | Dump the linked database's schema/data |

**A professional workflow:**

```
1. npx supabase migration new <change>      write the SQL (or make it in local Studio, then db diff)
2. npx supabase db reset                    prove the migrations rebuild cleanly from zero
3. test: RLS lessons / pgTAP / app tests    as anon AND as authenticated users
4. git commit (migrations + functions + config.toml)
5. CI: supabase db push → staging, then → production  (or Supabase Branching: a preview DB per PR)
```
**Golden rule:** never change a production schema by clicking in the dashboard without capturing it
as a migration (`db pull` / `db diff`), or environments drift apart.

---

## 12. Going to production

1. **Create a project** at [supabase.com](https://supabase.com) (pick the region nearest your
   users and servers). Copy the URL and keys from *Project Settings → API Keys*.
2. **Link and deploy:** `npx supabase link --project-ref <ref>`, `npx supabase db push`,
   `npx supabase functions deploy`, `npx supabase secrets set ...`.
3. **Environment variables:** expose only the URL and publishable key to the frontend (e.g.
   `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`). The secret key goes
   only into server environments, **never** under a `NEXT_PUBLIC_`/`VITE_` prefix.
4. **Connecting servers directly:**

   | Connection | Use for | Notes |
   | :--- | :--- | :--- |
   | Direct (`db.<ref>.supabase.co:5432`) | Long-running servers, migrations | IPv6 by default (IPv4 is an add-on) |
   | Pooler, **session** mode (port 5432) | Long-running servers needing IPv4 | One server connection per client session |
   | Pooler, **transaction** mode (port 6543) | **Serverless/edge** functions with many short connections | No session state: disable prepared statements in your driver/ORM |

5. **Auth for real:** email confirmations on, custom SMTP, Site URL and redirect allowlist,
   CAPTCHA, providers configured with production credentials.
6. **Backups:** paid plans include daily backups, and **Point-in-Time Recovery** is an add-on.
   Keep your own `pg_dump`/`supabase db dump` too, and **test a restore**.
7. **Plans and limits change.** Check [supabase.com/pricing](https://supabase.com/pricing).
   At the time of writing, free projects have small database/storage quotas and **pause after a
   period of inactivity**, and paid plans add backups, more compute, read replicas, branching,
   and longer log retention.
8. **Watch it:** Studio's *Advisors* (security + performance lints), *Reports*, *Logs*, and
   *Query Performance* (`pg_stat_statements`).

---

## 13. Security checklist

- [ ] **RLS enabled on every table** in exposed schemas, each with explicit `to <role>` policies
- [ ] Security Advisor shows no errors (RLS disabled, security definer views, mutable search_path, ...)
- [ ] **Secret key only on servers.** Separate named keys per service; rotate immediately if leaked
- [ ] Authorization never relies on `user_metadata`
- [ ] Views use `security_invoker = true`. `security definer` functions live in a non-exposed schema with `set search_path = ''`
- [ ] Function `EXECUTE` revoked from `anon`/`public` unless intended (migration 2)
- [ ] Least privilege: consider `auto_expose_new_tables = false` (`config.toml`) and explicit `GRANT`s
- [ ] Email confirmation on, custom SMTP, CAPTCHA, sensible rate limits, redirect allowlist
- [ ] Storage buckets private by default, with MIME type and size limits
- [ ] Edge Functions authenticate callers (`withSupabase`) and validate input
- [ ] MFA on all dashboard accounts; least-privilege org roles
- [ ] Backups + PITR as needed, with a tested restore

---

## 14. Performance

- **RLS is part of every query.** Index the columns policies use, wrap `auth.uid()`/`auth.jwt()`
  in `(select ...)`, add `to <role>`, and move membership lookups into `security definer`
  helpers. Also filter in the client (`.eq('user_id', uid)`): it helps the planner even though
  RLS would filter anyway.
- **Select only the columns you need**, paginate with `.range()`, and prefer
  `count: 'estimated'` on large tables.
- Use `EXPLAIN ANALYZE` (as the `authenticated` role, to include policies), `pg_stat_statements`,
  and the Performance Advisor / `index_advisor`.
- **Connections:** use the pooler (transaction mode) from serverless code. Postgres connections
  are a limited resource.
- **Scale up** compute size; **scale out** reads with read replicas; move high-fan-out realtime
  to Broadcast.

---

## 15. Comparison

| | Supabase | Firebase (topic 04) | Plain PostgreSQL (topic 01) | SQLite (topic 02) |
| :--- | :--- | :--- | :--- | :--- |
| Data model | Relational SQL | NoSQL documents (Firestore) | Relational SQL | Relational SQL |
| Hosting | Managed or self-host | Managed only (Google) | You run it (or managed RDS etc.) | A file in your app |
| Client talks to DB directly | Yes, secured by RLS | Yes, secured by Security Rules | No, you write an API | n/a (embedded) |
| Auth, storage, realtime, functions | Built in | Built in | Build or buy | n/a |
| Joins, transactions, constraints | Full Postgres | Limited | Full | Full (single writer) |
| Offline-first mobile sync | Bring your own | Excellent, built in | n/a | Local by nature |
| Open source / portable | Yes, it's Postgres | No | Yes | Yes |

---

## 16. Lock-in and self-hosting

- **Your data is plain Postgres.** `pg_dump` it and restore anywhere. Your schema, RLS policies,
  and functions are standard SQL in your migration files.
- Auth users are rows in `auth.users` (bcrypt password hashes) and can be exported. Storage is
  reachable through an S3-compatible API.
- What you'd have to replace when leaving: the auto-generated API (PostgREST is open source and
  can run anywhere), Auth (GoTrue is open source), and hosted-only conveniences.
- **Self-hosting:** the official Docker Compose setup in the `supabase/supabase` GitHub repo
  (`docker/`). You then own upgrades, backups, scaling, and security. Some platform features
  (branching, PITR, managed advisors, and more) are hosted-only.

---

## 17. Gotchas cheat sheet

| Gotcha | Fix |
| :--- | :--- |
| Table readable by everyone | You forgot `enable row level security` (lesson 01, section 7) |
| Query returns `[]` instead of an error | That's RLS hiding rows. Check policies and that the user is signed in. |
| `new row violates row-level security policy` | INSERT/UPDATE failed a `WITH CHECK`, often a missing/wrong `user_id` |
| `permission denied for table` | A privilege (GRANT) problem, checked *before* RLS |
| Update/insert "worked" but returned nothing | Chain `.select()` to get rows back |
| A view leaks rows | Views bypass RLS. Add `with (security_invoker = true)`. |
| Everything works in the SQL editor, fails in the app | The SQL editor runs as `postgres` (bypasses RLS). Test as a real role. |
| Secret key ended up in the browser bundle | Rotate it now; server-only env vars |
| Sign-up fails with "Database error saving new user" | Your `auth.users` trigger threw an error |
| Emails not arriving in production | The default mailer is for testing. Configure custom SMTP. |
| Realtime sends nothing | Table not in the `supabase_realtime` publication, or RLS blocks the subscriber |
| Realtime DELETE reaches everyone | DELETE events aren't RLS-filtered; keep PKs non-sensitive |
| Serverless functions exhaust connections | Use the transaction-mode pooler (port 6543), no prepared statements |
| Prod schema differs from local | Someone clicked in the dashboard. `db pull`/`db diff`, then migrate properly |
| `getSession()` trusted on the server | Use `getClaims()`/`getUser()` to verify |
| Bulk insert fails with `null value ... violates not-null` | Rows had different keys, so missing keys became NULL. Use `{ defaultToNull: false }` |
| Realtime missed the first changes after subscribing | Wait for the `system` "Subscribed to PostgreSQL" message; re-fetch after subscribing |
| Generated types file is garbled | PowerShell's `>` can write UTF-16 or add a BOM depending on version and settings. `npm run gen:types` runs through cmd, so use it. |

---

## 18. Lessons

Run from **this folder** with the stack running (`npx supabase start`). Lessons 3 to 5 reuse the
users lesson 2 creates, so do them in order.

| # | Lesson | What you'll see | Run |
| :-: | :--- | :--- | :--- |
| 0 | [supabase/migrations/](supabase/migrations/) | **Read these first:** the schema, RLS policies, RPC functions, storage bucket, realtime publication | applied by `npx supabase start` / `npm run reset` |
| 1 | [lessons/01_rls_under_the_hood.sql](lessons/01_rls_under_the_hood.sql) | Impersonate `anon`/users in raw SQL; watch policies filter; the "no RLS" leak | `npm run lesson:rls` |
| 2 | [lessons/02_client_and_rls.mjs](lessons/02_client_and_rls.mjs) | Sign-up, JWT contents, CRUD, filters, joins, attacks blocked by RLS, RPC, raw HTTP | `npm run lesson:client` |
| 3 | [lessons/03_realtime.mjs](lessons/03_realtime.mjs) | Postgres Changes filtered by RLS (and the DELETE leak), Broadcast, Presence | `npm run lesson:realtime` |
| 4 | [lessons/04_storage.mjs](lessons/04_storage.mjs) | Upload/download with folder policies, bucket limits, signed URLs | `npm run lesson:storage` |
| 5 | [lessons/05_edge_function.mjs](lessons/05_edge_function.mjs) | Call [whoami](supabase/functions/whoami/index.ts) as a user and as anon | `npm run lesson:functions` |

Other handy scripts: `npm run reset` (rebuild DB from migrations), `npm run psql` (SQL shell
as `postgres`), `npm run gen:types`, `npm run status`, `npm run stop`.

**Explore in Studio** (<http://127.0.0.1:54323>) after lesson 2: *Table Editor* (your rows),
*Authentication* (ana and ben), *Storage*, *Database → Policies*, and the *Advisors*.

---

## 19. Exercises

1. Add an `updated_at` column to `todos` that updates itself on every change. Do it as a new
   migration (`npx supabase migration new todos_updated_at`), then `npm run reset`.
2. Add **teams**: `teams`, `team_members (team_id, user_id, role)`, and a `team_id` on todos.
   Members can read their team's todos; only team `owner`s can delete them.
3. Anonymous visitors should see profile `username`s but **not** `avatar_path`. Change it
   without touching RLS.
4. Add an **admin** who can read every todo. Where should "is admin" be stored, and why not
   `user_metadata`?
5. Change lesson 03 so ana only receives events for **her own** todos, even public ones from others.
6. After deploying, users report seeing each other's data. List what you'd check, in order.
7. You added a column by clicking in local Studio. How do you turn that into a migration?
8. RPC, Edge Function, or direct table access? (a) charge a card with Stripe, (b) mark all of
   my todos done, (c) list my todos, (d) send a welcome email after sign-up, (e) a nightly
   cleanup job.

<details>
<summary><b>Answers</b></summary>

1. ```sql
   alter table public.todos add column updated_at timestamptz not null default now();
   create extension if not exists moddatetime schema extensions;
   create trigger todos_updated_at before update on public.todos
     for each row execute function extensions.moddatetime(updated_at);
   ```
2. ```sql
   create table public.teams (id bigint generated always as identity primary key, name text not null);
   create table public.team_members (
     team_id bigint references public.teams on delete cascade,
     user_id uuid references public.profiles on delete cascade,
     role text not null default 'member' check (role in ('member', 'owner')),
     primary key (team_id, user_id));
   alter table public.teams enable row level security;
   alter table public.team_members enable row level security;
   alter table public.todos add column team_id bigint references public.teams on delete cascade;
   create index on public.todos (team_id);

   create schema if not exists private;
   create function private.team_role(_team_id bigint) returns text
   language sql stable security definer set search_path = '' as $$
     select role from public.team_members where team_id = _team_id and user_id = (select auth.uid());
   $$;
   grant usage on schema private to authenticated;

   create policy "members read team todos" on public.todos for select to authenticated
     using (team_id is not null and (select private.team_role(team_id)) is not null);
   create policy "owners delete team todos" on public.todos for delete to authenticated
     using ((select private.team_role(team_id)) = 'owner');
   -- plus policies on teams/team_members so members can see their own memberships
   ```
3. Column privileges are checked before RLS:
   ```sql
   revoke select on public.profiles from anon;
   grant select (id, username, created_at) on public.profiles to anon;
   ```
   Now `anon` selecting `avatar_path` gets `permission denied`.
4. In `app_metadata` (set only with the secret key: `auth.admin.updateUserById(id, { app_metadata: { role: 'admin' } })`)
   or an `admins` table. Policy: `using ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin')`.
   Users can update their own `user_metadata` via `auth.updateUser()`, so anyone could make
   themselves admin. (The JWT updates at the next token refresh.)
5. Add a filter: `{ event: '*', schema: 'public', table: 'todos', filter: \`user_id=eq.${anaUser.id}\` }`.
6. (1) RLS enabled on every exposed table (Security Advisor)? (2) Policies too broad (missing
   `to authenticated`, a `using (true)` left in)? (3) A view without `security_invoker`, or a
   `security definer` function returning raw rows? (4) Secret key used in client code, or a
   server using the admin client for user requests? (5) Caching or CDN serving one user's
   response to another?
7. `npx supabase db diff -f add_column_name` writes a migration from the difference between
   your migrations and the local DB. Review it, `npm run reset` to prove it rebuilds, commit it.
8. (a) Edge Function (secret Stripe key). (b) RPC (`complete_all_my_todos`: one transaction,
   RLS applies). (c) Direct table access + RLS. (d) Auth hook / database webhook → Edge Function
   (email API key). (e) `pg_cron` running SQL, or calling an Edge Function via `pg_net`.
</details>

---

## 20. Further reading

- Supabase docs: [Architecture](https://supabase.com/docs/guides/getting-started/architecture) · [Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security) · [API keys](https://supabase.com/docs/guides/api/api-keys)
- [Auth](https://supabase.com/docs/guides/auth) · [Server-side auth (SSR)](https://supabase.com/docs/guides/auth/server-side) · [Realtime](https://supabase.com/docs/guides/realtime) · [Storage](https://supabase.com/docs/guides/storage) · [Edge Functions](https://supabase.com/docs/guides/functions)
- [Local development & CLI](https://supabase.com/docs/guides/local-development) · [Database migrations](https://supabase.com/docs/guides/deployment/database-migrations) · [Testing (pgTAP)](https://supabase.com/docs/guides/database/testing)
- [Connecting to Postgres](https://supabase.com/docs/guides/database/connecting-to-postgres) · [Production checklist](https://supabase.com/docs/guides/deployment/going-into-prod) · [Self-hosting](https://supabase.com/docs/guides/self-hosting)
- [PostgREST documentation](https://postgrest.org) (what the Data API is built on)

**Next topic:** Firebase → `04-firebase/`
