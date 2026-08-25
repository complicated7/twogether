-- ============================================================
-- Pairing system: tables, RLS, and rate limiting
-- Run this whole script once in the Supabase SQL Editor, after
-- 0000_gallery_bucket.sql.
-- ============================================================

-- 1. Core tables --------------------------------------------------

create table if not exists pairs (
  id uuid primary key default gen_random_uuid(),
  invite_code text unique not null default upper(substr(md5(random()::text), 1, 6)),
  since_date date not null default current_date,
  created_at timestamptz not null default now()
);

create table if not exists profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  pair_id uuid not null references pairs(id) on delete cascade,
  display_name text not null default 'Someone',
  created_at timestamptz not null default now()
);

create index if not exists profiles_pair_id_idx on profiles(pair_id);

-- 2. Redesign mood_state: one row per user instead of one global row.
-- The old single shared row (id=1) is dropped here; its value is
-- migrated back in by hand once both real accounts exist (separate
-- script, not part of this one).
drop table if exists mood_state cascade;

create table mood_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  mood text not null default 'happy',
  updated_at timestamptz not null default now()
);

-- 3. Rate-limit support table --------------------------------------
create table if not exists upload_log (
  id bigint generated always as identity primary key,
  pair_id uuid not null,
  created_at timestamptz not null default now()
);

-- 4. Helper: caller's pair_id. security definer so it can read
-- `profiles` from inside another table's RLS policy without
-- recursing into `profiles`' own RLS.
create or replace function auth_pair_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select pair_id from profiles where user_id = auth.uid()
$$;

-- 5. Pairing RPC: create a new pair, or join one by invite code.
-- Called once from the client right after signup.
create or replace function create_or_join_pair(p_display_name text, p_invite_code text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pair_id uuid;
  v_member_count int;
begin
  if exists (select 1 from profiles where user_id = auth.uid()) then
    raise exception 'You already belong to a pair';
  end if;

  if p_invite_code is null then
    insert into pairs default values returning id into v_pair_id;
  else
    select id into v_pair_id from pairs where invite_code = upper(p_invite_code);
    if v_pair_id is null then
      raise exception 'Invalid invite code';
    end if;
    select count(*) into v_member_count from profiles where pair_id = v_pair_id;
    if v_member_count >= 2 then
      raise exception 'That pair is already full';
    end if;
  end if;

  insert into profiles (user_id, pair_id, display_name)
  values (auth.uid(), v_pair_id, p_display_name);

  return v_pair_id;
end;
$$;

-- 6. RLS: pairs, profiles, mood_state -------------------------------
alter table pairs enable row level security;
alter table profiles enable row level security;
alter table mood_state enable row level security;
alter table upload_log enable row level security;
-- (upload_log has no policies at all -- only the security-definer
-- trigger function below can touch it; direct client access is denied.)

drop policy if exists "pairs: select own" on pairs;
create policy "pairs: select own" on pairs
  for select to authenticated
  using (id = auth_pair_id());

drop policy if exists "pairs: insert any authenticated" on pairs;
create policy "pairs: insert any authenticated" on pairs
  for insert to authenticated
  with check (true);

drop policy if exists "profiles: select own pair" on profiles;
create policy "profiles: select own pair" on profiles
  for select to authenticated
  using (pair_id = auth_pair_id() or user_id = auth.uid());

drop policy if exists "profiles: insert own" on profiles;
create policy "profiles: insert own" on profiles
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists "mood_state: select own pair" on mood_state;
create policy "mood_state: select own pair" on mood_state
  for select to authenticated
  using (user_id = auth.uid() or user_id in (select user_id from profiles where pair_id = auth_pair_id()));

drop policy if exists "mood_state: insert own" on mood_state;
create policy "mood_state: insert own" on mood_state
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists "mood_state: update own" on mood_state;
create policy "mood_state: update own" on mood_state
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- 7. Storage: gallery-photos becomes private + pair-scoped ----------
-- Previously this bucket was fully public (read/insert/delete for
-- anyone with the anon key). Switch it to private and scope every
-- operation to the caller's pair via a {pair_id}/{filename} path.
update storage.buckets set public = false where id = 'gallery-photos';

drop policy if exists "gallery-photos read" on storage.objects;
drop policy if exists "gallery-photos upload" on storage.objects;
drop policy if exists "gallery-photos delete" on storage.objects;

create policy "gallery-photos: pair read" on storage.objects
  for select to authenticated
  using (bucket_id = 'gallery-photos' and (storage.foldername(name))[1] = auth_pair_id()::text);

create policy "gallery-photos: pair insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'gallery-photos' and (storage.foldername(name))[1] = auth_pair_id()::text);

create policy "gallery-photos: pair delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'gallery-photos' and (storage.foldername(name))[1] = auth_pair_id()::text);

-- 8. Rate limiting ----------------------------------------------------

-- Mood updates: silently coalesce anything faster than once/second per
-- user (blunts a scripted spam loop without erroring on a real person
-- clicking through a couple of mood buttons quickly).
create or replace function enforce_mood_rate_limit()
returns trigger
language plpgsql
as $$
begin
  if OLD.updated_at is not null and now() - OLD.updated_at < interval '1 second' then
    return null;
  end if;
  NEW.updated_at := now();
  return NEW;
end;
$$;

drop trigger if exists mood_rate_limit on mood_state;
create trigger mood_rate_limit
  before update on mood_state
  for each row execute function enforce_mood_rate_limit();

-- Gallery uploads: cap at 30/hour per pair.
create or replace function enforce_upload_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pair_id uuid;
  v_recent_count int;
begin
  if NEW.bucket_id != 'gallery-photos' then
    return NEW;
  end if;
  v_pair_id := auth_pair_id();
  select count(*) into v_recent_count from upload_log
    where pair_id = v_pair_id and created_at > now() - interval '1 hour';
  if v_recent_count >= 30 then
    raise exception 'Upload limit reached -- try again in a bit';
  end if;
  insert into upload_log (pair_id) values (v_pair_id);
  return NEW;
end;
$$;

drop trigger if exists gallery_upload_rate_limit on storage.objects;
create trigger gallery_upload_rate_limit
  before insert on storage.objects
  for each row execute function enforce_upload_rate_limit();
