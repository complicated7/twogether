-- Creates the gallery-photos storage bucket. Must run before 0001, which
-- assumes this bucket already exists (it switches it to private and adds
-- RLS policies, but never creates it -- on the original project this
-- bucket had already been created by hand before migrations existed).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'gallery-photos',
  'gallery-photos',
  true,
  10485760, -- 10 MB per file
  array['image/jpeg','image/png','image/webp','image/gif','image/heic']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
