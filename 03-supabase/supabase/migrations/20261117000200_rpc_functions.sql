-- Migration 2: Postgres functions exposed as RPC endpoints.
--
-- Any function in an exposed schema can be called over HTTP:
--   supabase.rpc('my_todo_stats')   ->   POST /rest/v1/rpc/my_todo_stats
-- Use RPC for logic that's awkward as a single REST query: aggregates, multi-step
-- writes in one transaction, or anything you want to keep next to the data.

-- SECURITY INVOKER (the default): runs as the CALLER, so RLS still applies.
-- The caller only ever counts the rows they're allowed to see.
create function public.my_todo_stats()
returns table (total bigint, done bigint, open bigint)
language sql
stable
security invoker
set search_path = ''
as $$
    select count(*),
           count(*) filter (where is_done),
           count(*) filter (where not is_done)
    from public.todos
    where user_id = (select auth.uid());
$$;

-- An atomic multi-step write: complete every open todo and return how many changed.
-- Still SECURITY INVOKER, so the UPDATE is limited by the update policy.
create function public.complete_all_my_todos()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
    changed integer;
begin
    update public.todos
       set is_done = true
     where user_id = (select auth.uid()) and not is_done;
    get diagnostics changed = row_count;
    return changed;
end;
$$;

-- SECURITY DEFINER: runs as the function OWNER (postgres) and BYPASSES RLS.
-- Useful for deliberately exposing a safe summary of data the caller can't read directly.
-- Treat these like an admin API endpoint: return only aggregates, and pin search_path.
create function public.community_stats()
returns table (users bigint, todos bigint, completion_pct numeric)
language sql
stable
security definer
set search_path = ''
as $$
    select (select count(*) from public.profiles),
           count(*),
           round(100.0 * count(*) filter (where is_done) / nullif(count(*), 0), 1)
    from public.todos;
$$;

-- Functions are executable by PUBLIC by default. Lock down who may call each one.
revoke execute on function public.my_todo_stats()         from public, anon;
revoke execute on function public.complete_all_my_todos() from public, anon;
grant  execute on function public.my_todo_stats()         to authenticated;
grant  execute on function public.complete_all_my_todos() to authenticated;
grant  execute on function public.community_stats()       to anon, authenticated;
