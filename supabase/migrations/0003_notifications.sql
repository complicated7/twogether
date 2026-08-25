-- ============================================================
-- Notifications: in-app notification feed + web push subscriptions.
-- Run after 0002_pairs_update_policy.sql.
-- ============================================================

-- 1. In-app notification feed (one row per recipient) ----------------
create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text,
  message text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_user_id_idx on notifications(user_id);

alter table notifications enable row level security;

drop policy if exists "notifications: select own" on notifications;
create policy "notifications: select own" on notifications
  for select to authenticated
  using (user_id = auth.uid());

-- Insert is restricted to "you may only notify your own partner", not
-- yourself or a stranger -- enforced via auth_pair_id() from 0001.
drop policy if exists "notifications: insert for partner" on notifications;
create policy "notifications: insert for partner" on notifications
  for insert to authenticated
  with check (
    user_id in (select p.user_id from profiles p where p.pair_id = auth_pair_id())
    and user_id != auth.uid()
  );

drop policy if exists "notifications: update own" on notifications;
create policy "notifications: update own" on notifications
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- 2. Web push subscriptions (one row per user's browser/device) ------
create table if not exists push_subscriptions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  subscription jsonb not null,
  created_at timestamptz not null default now()
);

alter table push_subscriptions enable row level security;

drop policy if exists "push_subscriptions: select own" on push_subscriptions;
create policy "push_subscriptions: select own" on push_subscriptions
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "push_subscriptions: upsert own" on push_subscriptions;
create policy "push_subscriptions: insert own" on push_subscriptions
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists "push_subscriptions: update own" on push_subscriptions;
create policy "push_subscriptions: update own" on push_subscriptions
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Note: the actual push send (contacting the browser's push endpoint)
-- happens in the `send-push` Edge Function using the service role key,
-- since only that key is allowed to read a *partner's* subscription --
-- the policies above intentionally only let a user read their own.
