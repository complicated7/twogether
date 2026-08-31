-- ============================================================
-- Comidinhas do Mascotinho: alimentar recupera fome (+ um
-- pouquinho de felicidade/energia e XP), com cooldown pra não
-- virar spam de clique. Rode este script no SQL Editor do
-- Supabase depois de 0000, 0001, 0002, 0003_new_features.sql
-- e 0004_mascotinho.sql.
-- ============================================================

alter table mascote add column if not exists ultimo_alimento timestamptz;
alter table mascote add column if not exists ultima_comida text;

-- ============================================================
-- Alimentar: sobe fome na hora + um pouco de felicidade/energia
-- e XP, com cooldown de 2h (a fome cai ~1.5/h, então dá pra
-- alimentar várias vezes ao longo do dia sem virar spam).
-- ============================================================

create or replace function alimentar_mascote(p_pair_id uuid, p_comida_id text)
returns table (mascote mascote, podia_alimentar boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  m mascote;
  pode boolean;
begin
  if p_pair_id != auth_pair_id() then
    raise exception 'not your pair';
  end if;

  m := get_or_create_mascote(p_pair_id);

  pode := m.ultimo_alimento is null or m.ultimo_alimento < now() - interval '2 hours';

  if pode then
    m.fome := least(100, m.fome + 25);
    m.felicidade := least(100, m.felicidade + 4);
    m.energia := least(100, m.energia + 2);
    update mascote set
      fome = m.fome,
      felicidade = m.felicidade,
      energia = m.energia,
      ultimo_alimento = now(),
      ultima_comida = p_comida_id
    where pair_id = p_pair_id;
    perform adicionar_xp_mascote(p_pair_id, 5, 'comidinha');
    select * into m from mascote where pair_id = p_pair_id;
  end if;

  return query select m, pode;
end;
$$;
