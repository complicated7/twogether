-- ============================================================
-- New features: memory replies, places, letters, gratitude, quotes
-- Run this whole script once in the Supabase SQL Editor, after
-- 0000, 0001, and 0002.
-- ============================================================

-- 1. Memory replies (answers to the "on this day" pop-up) ---------

create table if not exists memory_replies (
  id uuid primary key default gen_random_uuid(),
  moment_id uuid not null references moments(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  reply_text text not null,
  created_at timestamptz not null default now(),
  unique (moment_id, user_id)
);

alter table memory_replies enable row level security;

drop policy if exists "memory_replies: select same pair" on memory_replies;
create policy "memory_replies: select same pair" on memory_replies
  for select to authenticated
  using (
    exists (
      select 1 from moments
      where moments.id = memory_replies.moment_id
        and moments.pair_id = auth_pair_id()
    )
  );

drop policy if exists "memory_replies: insert own" on memory_replies;
create policy "memory_replies: insert own" on memory_replies
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from moments
      where moments.id = memory_replies.moment_id
        and moments.pair_id = auth_pair_id()
    )
  );

-- 2. Places ("lugares que fomos") ----------------------------------

create table if not exists places (
  id uuid primary key default gen_random_uuid(),
  pair_id uuid not null references pairs(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  lat double precision not null,
  lng double precision not null,
  visited_at date,
  description text,
  wishlist boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists places_pair_id_idx on places(pair_id);

alter table places enable row level security;

drop policy if exists "places: select own pair" on places;
create policy "places: select own pair" on places
  for select to authenticated
  using (pair_id = auth_pair_id());

drop policy if exists "places: insert own pair" on places;
create policy "places: insert own pair" on places
  for insert to authenticated
  with check (pair_id = auth_pair_id() and author_id = auth.uid());

drop policy if exists "places: update own pair" on places;
create policy "places: update own pair" on places
  for update to authenticated
  using (pair_id = auth_pair_id())
  with check (pair_id = auth_pair_id());

drop policy if exists "places: delete own pair" on places;
create policy "places: delete own pair" on places
  for delete to authenticated
  using (pair_id = auth_pair_id());

-- 3. Letters (cartas seladas) ---------------------------------------

create table if not exists letters (
  id uuid primary key default gen_random_uuid(),
  pair_id uuid not null references pairs(id) on delete cascade,
  from_user_id uuid not null references auth.users(id) on delete cascade,
  to_user_id uuid not null references auth.users(id) on delete cascade,
  content text not null,
  delivery_type text not null check (delivery_type in ('immediate','date','mood')),
  delivery_date date,
  delivery_mood text,
  opened_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists letters_pair_id_idx on letters(pair_id);

alter table letters enable row level security;

-- helper condition, inlined into policies below:
--   delivery_type = 'immediate'                              -> always unlocked
--   delivery_type = 'date' and delivery_date <= current_date -> unlocked once the date arrives
--   delivery_type = 'mood' and recipient's current mood_state.mood = delivery_mood -> unlocked

drop policy if exists "letters: sender sees own sent" on letters;
create policy "letters: sender sees own sent" on letters
  for select to authenticated
  using (from_user_id = auth.uid());

drop policy if exists "letters: recipient sees when unlocked" on letters;
create policy "letters: recipient sees when unlocked" on letters
  for select to authenticated
  using (
    to_user_id = auth.uid()
    and (
      delivery_type = 'immediate'
      or (delivery_type = 'date' and delivery_date <= current_date)
      or (delivery_type = 'mood' and exists (
        select 1 from mood_state
        where mood_state.user_id = auth.uid()
          and mood_state.mood = letters.delivery_mood
      ))
    )
  );

drop policy if exists "letters: insert own pair" on letters;
create policy "letters: insert own pair" on letters
  for insert to authenticated
  with check (
    pair_id = auth_pair_id()
    and from_user_id = auth.uid()
    and to_user_id in (select user_id from profiles where pair_id = auth_pair_id() and user_id != auth.uid())
  );

drop policy if exists "letters: recipient marks opened" on letters;
create policy "letters: recipient marks opened" on letters
  for update to authenticated
  using (
    to_user_id = auth.uid()
    and (
      delivery_type = 'immediate'
      or (delivery_type = 'date' and delivery_date <= current_date)
      or (delivery_type = 'mood' and exists (
        select 1 from mood_state
        where mood_state.user_id = auth.uid()
          and mood_state.mood = letters.delivery_mood
      ))
    )
  )
  with check (to_user_id = auth.uid());

drop policy if exists "letters: sender deletes unopened" on letters;
create policy "letters: sender deletes unopened" on letters
  for delete to authenticated
  using (from_user_id = auth.uid() and opened_at is null);

-- 4. Gratitude (weekly, revealed only once both partners wrote) -----

create table if not exists gratitude_entries (
  id uuid primary key default gen_random_uuid(),
  pair_id uuid not null references pairs(id) on delete cascade,
  week_start date not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  content text not null,
  created_at timestamptz not null default now(),
  unique (pair_id, week_start, user_id)
);

alter table gratitude_entries enable row level security;

drop policy if exists "gratitude: select own or revealed" on gratitude_entries;
create policy "gratitude: select own or revealed" on gratitude_entries
  for select to authenticated
  using (
    pair_id = auth_pair_id()
    and (
      user_id = auth.uid()
      or exists (
        select 1 from gratitude_entries mine
        where mine.pair_id = gratitude_entries.pair_id
          and mine.week_start = gratitude_entries.week_start
          and mine.user_id = auth.uid()
      )
    )
  );

drop policy if exists "gratitude: insert own" on gratitude_entries;
create policy "gratitude: insert own" on gratitude_entries
  for insert to authenticated
  with check (pair_id = auth_pair_id() and user_id = auth.uid());

-- 5. Quotes ("nossas frases", text or audio) -------------------------

create table if not exists quotes (
  id uuid primary key default gen_random_uuid(),
  pair_id uuid not null references pairs(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete cascade,
  said_by uuid references auth.users(id),
  type text not null check (type in ('text','audio')),
  content text,
  audio_path text,
  context text,
  created_at timestamptz not null default now(),
  constraint quotes_has_payload check (
    (type = 'text' and content is not null)
    or (type = 'audio' and audio_path is not null)
  )
);

create index if not exists quotes_pair_id_idx on quotes(pair_id);

alter table quotes enable row level security;

drop policy if exists "quotes: select own pair" on quotes;
create policy "quotes: select own pair" on quotes
  for select to authenticated
  using (pair_id = auth_pair_id());

drop policy if exists "quotes: insert own pair" on quotes;
create policy "quotes: insert own pair" on quotes
  for insert to authenticated
  with check (pair_id = auth_pair_id() and author_id = auth.uid());

drop policy if exists "quotes: delete own pair" on quotes;
create policy "quotes: delete own pair" on quotes
  for delete to authenticated
  using (pair_id = auth_pair_id());

-- 6. Storage: allow audio (for quotes) in the shared gallery bucket --
-- Widened to also cover video, since moments already uploads video
-- files that the original 0000 migration's mime list didn't include.

update storage.buckets
set allowed_mime_types = array[
  'image/jpeg','image/png','image/webp','image/gif','image/heic',
  'video/mp4','video/quicktime','video/webm',
  'audio/webm','audio/mp4','audio/mpeg','audio/ogg'
]
where id = 'gallery-photos';
