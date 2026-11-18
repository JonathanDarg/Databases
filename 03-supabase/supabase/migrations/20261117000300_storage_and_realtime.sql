-- Migration 3: a private storage bucket and realtime change events.

-- ---------------------------------------------------------------------------------------
-- Storage: files live in S3-compatible object storage, but their METADATA is a row in
-- storage.objects. That means file access is controlled by ordinary RLS policies.
-- Convention: each user owns the folder named after their user id:  avatars/<uid>/<file>
-- ---------------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 1048576,                 -- private, 1 MB max per file
        array['image/png', 'image/jpeg', 'image/webp', 'text/plain']);

create policy "Users can read their own avatar files"
    on storage.objects for select
    to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid()::text));

create policy "Users can upload into their own folder"
    on storage.objects for insert
    to authenticated
    with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid()::text));

create policy "Users can replace their own avatar files"
    on storage.objects for update
    to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid()::text))
    with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid()::text));

create policy "Users can delete their own avatar files"
    on storage.objects for delete
    to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid()::text));

-- ---------------------------------------------------------------------------------------
-- Realtime "Postgres Changes": Realtime reads the write-ahead log through a logical
-- replication PUBLICATION. Only tables added to it emit change events, and each
-- subscriber only receives rows that its RLS policies allow it to SELECT.
-- ---------------------------------------------------------------------------------------
alter publication supabase_realtime add table public.todos;
