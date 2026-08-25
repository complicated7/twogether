-- Allow either partner to edit their pair's since_date (needed for the
-- new "edit our date" feature -- previously `pairs` had no UPDATE policy
-- at all, so this was silently impossible).

drop policy if exists "pairs: update own" on pairs;
create policy "pairs: update own" on pairs
  for update to authenticated
  using (id = auth_pair_id())
  with check (id = auth_pair_id());
