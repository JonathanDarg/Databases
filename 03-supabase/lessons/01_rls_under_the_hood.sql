-- 01_rls_under_the_hood.sql
--
-- Every Supabase API request ends up as SQL that looks like this lesson: switch to a
-- database ROLE taken from the JWT, store the JWT claims in a setting, run the query.
-- Row Level Security policies then filter rows using auth.uid() (read from those claims).
--
-- Run (from the 03-supabase folder, with `npx supabase start` running):
--   npm run lesson:rls
--
-- Everything runs inside ONE transaction that is rolled back at the end, so the
-- database is left untouched. ON_ERROR_ROLLBACK makes psql undo only the failing
-- statement, so the expected errors below don't abort the whole transaction.

\set ON_ERROR_ROLLBACK on
\pset pager off
\pset footer off
begin;

\echo
\echo '=== 1. The database roles behind the API ==='
select rolname, rolbypassrls as bypasses_rls, rolcanlogin as can_login
from pg_roles
where rolname in ('postgres', 'authenticator', 'anon', 'authenticated', 'service_role')
order by rolname;
\echo 'PostgREST logs in as "authenticator", then per request does SET ROLE to the "role"'
\echo 'claim in the JWT: anon (no user), authenticated (signed-in user), or service_role.'

\echo
\echo '=== 2. Two users sign up (inserted directly here; the real app uses the Auth API) ==='
insert into auth.users (id, email, raw_user_meta_data, aud, role) values
    ('11111111-1111-1111-1111-111111111111', 'ana@example.com', '{"username":"ana"}', 'authenticated', 'authenticated'),
    ('22222222-2222-2222-2222-222222222222', 'ben@example.com', '{"username":"ben"}', 'authenticated', 'authenticated');
\echo 'The on_auth_user_created trigger created their profiles:'
select id, username from public.profiles order by username;

\echo
\echo '=== 3. As postgres (table owner, RLS not applied): seed some todos ==='
insert into public.todos (user_id, title, is_public) values
    ('11111111-1111-1111-1111-111111111111', 'ana: private todo', false),
    ('11111111-1111-1111-1111-111111111111', 'ana: public todo',  true),
    ('22222222-2222-2222-2222-222222222222', 'ben: private todo', false);
select u.username, t.title, t.is_public
from public.todos t join public.profiles u on u.id = t.user_id order by t.id;

\echo
\echo '=== 4. Simulate an ANONYMOUS request (publishable/anon key, no user) ==='
set local role anon;
select current_user as db_role, auth.uid() as user_id;
\echo 'SELECT returns only rows a policy allows (the public todo):'
select title from public.todos order by id;
\echo 'INSERT is refused outright (privilege revoked in migration 1):'
insert into public.todos (user_id, title) values ('11111111-1111-1111-1111-111111111111', 'anon write');
reset role;

\echo
\echo '=== 5. Simulate a request from ANA (authenticated, JWT sub = ana''s id) ==='
set local role authenticated;
select set_config('request.jwt.claims',
                  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
select current_user as db_role, auth.uid() as user_id, auth.jwt() ->> 'role' as jwt_role;
\echo 'Ana sees her own todos plus public ones, never ben''s private todo:'
select title from public.todos order by id;
\echo 'Ana tries to edit ben''s todo. NO ERROR, just 0 rows: RLS hides rows, it does not reject them:'
update public.todos set title = 'hacked by ana' where title = 'ben: private todo';
\echo 'Ana tries to create a todo owned by ben. WITH CHECK rejects it:'
insert into public.todos (user_id, title) values ('22222222-2222-2222-2222-222222222222', 'forged');
\echo 'RPC functions (security invoker) see the same filtered world:'
select * from public.my_todo_stats();
\echo 'A security DEFINER function sees everything, so it must only return safe aggregates:'
select * from public.community_stats();
\echo 'RLS is literally added to your query plan as a filter:'
explain (costs off) select title from public.todos;
reset role;

\echo
\echo '=== 6. service_role (secret key) BYPASSES RLS: server-side use only ==='
set local role service_role;
select current_user as db_role, count(*) as todos_visible from public.todos;
reset role;

\echo
\echo '=== 7. The #1 Supabase security mistake: a public table without RLS ==='
create table public.leaky_secrets (secret text);
insert into public.leaky_secrets values ('the admin password is hunter2');
set local role anon;
\echo 'RLS NOT enabled. Anyone with your public key can read it:'
select * from public.leaky_secrets;
reset role;
alter table public.leaky_secrets enable row level security;
set local role anon;
\echo 'RLS enabled with no policies = deny everything:'
select * from public.leaky_secrets;
reset role;

\echo
\echo '=== 8. List every policy in the public schema ==='
select tablename, policyname, cmd, roles::text, qual as using_expr
from pg_policies where schemaname = 'public' order by tablename, cmd, policyname;

rollback;
\echo
\echo 'Rolled back: the database is unchanged. Next: npm run lesson:client'
