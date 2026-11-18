-- seed.sql: runs after migrations on `supabase db reset` (local only, never on production).
--
-- This lab creates its users through the real Auth API (lessons/02_client_and_rls.mjs),
-- because that's how users get created in a real app (password hashing, identities,
-- the on_auth_user_created trigger). Put reference/lookup data you always want locally here.

select 'seed.sql ran: database reset to migrations + seed' as status;
