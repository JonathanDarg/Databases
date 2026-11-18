-- Migration 1: profiles + todos, protected by Row Level Security (RLS).
--
-- Supabase exposes every table in the `public` schema over HTTP (the Data API, powered by
-- PostgREST). RLS policies are what stop user A from reading user B's rows. Without RLS,
-- anyone holding your public (publishable/anon) key could read and write the whole table.

-- ---------------------------------------------------------------------------------------
-- profiles: public user info. auth.users (managed by Supabase Auth) is NOT exposed over the
-- API, so apps keep a 1:1 "profiles" table in public that references it.
-- ---------------------------------------------------------------------------------------
create table public.profiles (
    id          uuid primary key references auth.users (id) on delete cascade,
    username    text unique check (char_length(username) between 3 and 30),
    avatar_path text,                                   -- path inside the 'avatars' storage bucket
    created_at  timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "Profiles are readable by everyone"
    on public.profiles for select
    to anon, authenticated
    using (true);

create policy "Users can update their own profile"
    on public.profiles for update
    to authenticated
    using ((select auth.uid()) = id)
    with check ((select auth.uid()) = id);

-- Create a profile automatically whenever someone signs up.
-- SECURITY DEFINER runs with the function owner's rights (it must write to public.profiles
-- while being called from the auth schema). search_path = '' prevents search-path hijacking:
-- every object inside is schema-qualified.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.profiles (id, username)
    values (new.id, new.raw_user_meta_data ->> 'username');
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------------------
-- todos: private by default, optionally shared publicly.
-- ---------------------------------------------------------------------------------------
-- user_id references public.profiles (not auth.users) so the Data API can JOIN ("embed")
-- todos with their author:  .select('title, profiles(username)'). The API can only follow
-- foreign keys between tables it exposes, and the auth schema is not exposed.
create table public.todos (
    id         bigint generated always as identity primary key,
    user_id    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    title      text not null check (char_length(title) between 1 and 200),
    is_done    boolean not null default false,
    is_public  boolean not null default false,
    created_at timestamptz not null default now()
);

-- Index every column your policies filter on. Policies run on EVERY query.
create index todos_user_id_idx on public.todos (user_id);

alter table public.todos enable row level security;

-- One policy per operation and role is the clearest style.
-- Wrapping auth.uid() in (select ...) lets Postgres evaluate it ONCE per query instead of
-- once per row, which is a big speedup on large tables.
create policy "Anyone can read public todos"
    on public.todos for select
    to anon, authenticated
    using (is_public);

create policy "Users can read their own todos"
    on public.todos for select
    to authenticated
    using ((select auth.uid()) = user_id);

create policy "Users can create their own todos"
    on public.todos for insert
    to authenticated
    with check ((select auth.uid()) = user_id);

create policy "Users can update their own todos"
    on public.todos for update
    to authenticated
    using ((select auth.uid()) = user_id)          -- which rows you may target
    with check ((select auth.uid()) = user_id);    -- what the row may look like afterwards

create policy "Users can delete their own todos"
    on public.todos for delete
    to authenticated
    using ((select auth.uid()) = user_id);

-- Defense in depth: RLS already blocks anonymous writes (no policy allows them), but
-- removing the privilege means anon gets "permission denied" before RLS is even consulted.
revoke insert, update, delete on public.todos from anon;
