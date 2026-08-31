-- ============================================================
-- Evoluir o Mascotinho: nível, XP, fome, felicidade, energia,
-- roupinhas, acessórios e quarto — cuidado junto pelo casal.
-- Run this whole script once in the Supabase SQL Editor, after
-- 0000, 0001, 0002, and 0003_new_features.sql.
-- ============================================================

-- 1) Estado do mascotinho (uma linha por casal) ---------------------

create table if not exists mascote (
  pair_id uuid primary key references pairs(id) on delete cascade,
  nivel integer not null default 1,
  xp integer not null default 0,
  xp_para_proximo integer not null default 100,
  fome numeric not null default 100 check (fome >= 0 and fome <= 100),
  felicidade numeric not null default 100 check (felicidade >= 0 and felicidade <= 100),
  energia numeric not null default 100 check (energia >= 0 and energia <= 100),
  roupa_atual text not null default 'nenhuma',
  acessorio_atual text not null default 'nenhum',
  quarto_atual text not null default 'padrao',
  ultima_atualizacao timestamptz not null default now(),
  ultimo_carinho timestamptz,
  criado_em timestamptz not null default now()
);

alter table mascote enable row level security;

drop policy if exists "mascote: select own pair" on mascote;
create policy "mascote: select own pair" on mascote
  for select to authenticated
  using (pair_id = auth_pair_id());

drop policy if exists "mascote: insert own pair" on mascote;
create policy "mascote: insert own pair" on mascote
  for insert to authenticated
  with check (pair_id = auth_pair_id());

drop policy if exists "mascote: update own pair" on mascote;
create policy "mascote: update own pair" on mascote
  for update to authenticated
  using (pair_id = auth_pair_id())
  with check (pair_id = auth_pair_id());

-- 2) Histórico de ações (pra dar transparência de quem fez o quê) ----

create table if not exists mascote_eventos (
  id bigint generated always as identity primary key,
  pair_id uuid not null references pairs(id) on delete cascade,
  autor uuid not null references auth.users(id),
  tipo text not null, -- 'momento' | 'carta' | 'login' | 'carinho'
  xp_ganho integer not null,
  criado_em timestamptz not null default now()
);

create index if not exists mascote_eventos_pair_id_idx on mascote_eventos(pair_id);

alter table mascote_eventos enable row level security;

drop policy if exists "mascote_eventos: select own pair" on mascote_eventos;
create policy "mascote_eventos: select own pair" on mascote_eventos
  for select to authenticated
  using (pair_id = auth_pair_id());

drop policy if exists "mascote_eventos: insert own" on mascote_eventos;
create policy "mascote_eventos: insert own" on mascote_eventos
  for insert to authenticated
  with check (pair_id = auth_pair_id() and autor = auth.uid());

-- ============================================================
-- Decaimento por hora (ajuste estes 3 números à vontade):
-- fome -1.5/h, felicidade -0.8/h, energia -1/h
-- ============================================================

create or replace function _mascote_aplicar_decaimento(m mascote)
returns mascote
language plpgsql
as $$
declare
  horas numeric;
  resultado mascote;
begin
  horas := greatest(0, extract(epoch from (now() - m.ultima_atualizacao)) / 3600.0);

  resultado := m;
  resultado.fome := greatest(0, m.fome - horas * 1.5);
  resultado.felicidade := greatest(0, m.felicidade - horas * 0.8);
  resultado.energia := greatest(0, m.energia - horas * 1.0);
  resultado.ultima_atualizacao := now();

  update mascote set
    fome = resultado.fome,
    felicidade = resultado.felicidade,
    energia = resultado.energia,
    ultima_atualizacao = resultado.ultima_atualizacao
  where pair_id = m.pair_id;

  return resultado;
end;
$$;

-- ============================================================
-- Cria o mascote do casal na primeira vez que alguém acessa
-- ============================================================

create or replace function get_or_create_mascote(p_pair_id uuid)
returns mascote
language plpgsql
security definer
set search_path = public
as $$
declare
  m mascote;
begin
  if p_pair_id != auth_pair_id() then
    raise exception 'not your pair';
  end if;

  select * into m from mascote where pair_id = p_pair_id;

  if not found then
    insert into mascote (pair_id) values (p_pair_id) returning * into m;
  end if;

  m := _mascote_aplicar_decaimento(m);
  return m;
end;
$$;

-- ============================================================
-- Soma XP (chamado a cada ação: momento, carta, login, carinho)
-- ============================================================

create or replace function adicionar_xp_mascote(
  p_pair_id uuid,
  p_quantidade integer,
  p_tipo text
)
returns table (
  mascote mascote,
  subiu_de_nivel boolean,
  niveis_ganhos integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  m mascote;
  subiu boolean := false;
  niveis integer := 0;
begin
  if p_pair_id != auth_pair_id() then
    raise exception 'not your pair';
  end if;

  m := get_or_create_mascote(p_pair_id);

  m.xp := m.xp + p_quantidade;

  while m.xp >= m.xp_para_proximo loop
    m.xp := m.xp - m.xp_para_proximo;
    m.nivel := m.nivel + 1;
    m.xp_para_proximo := round(m.xp_para_proximo * 1.25);
    subiu := true;
    niveis := niveis + 1;
  end loop;

  update mascote set
    xp = m.xp,
    nivel = m.nivel,
    xp_para_proximo = m.xp_para_proximo
  where pair_id = p_pair_id;

  insert into mascote_eventos (pair_id, autor, tipo, xp_ganho)
  values (p_pair_id, auth.uid(), p_tipo, p_quantidade);

  return query select m, subiu, niveis;
end;
$$;

-- ============================================================
-- Fazer carinho: sobe felicidade na hora + um pouco de XP,
-- com cooldown de 4h pra não virar spam de clique
-- ============================================================

create or replace function fazer_carinho_mascote(p_pair_id uuid)
returns table (mascote mascote, podia_fazer_carinho boolean)
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

  pode := m.ultimo_carinho is null or m.ultimo_carinho < now() - interval '4 hours';

  if pode then
    m.felicidade := least(100, m.felicidade + 12);
    m.energia := least(100, m.energia + 3);
    update mascote set felicidade = m.felicidade, energia = m.energia, ultimo_carinho = now()
      where pair_id = p_pair_id;
    perform adicionar_xp_mascote(p_pair_id, 5, 'carinho');
    select * into m from mascote where pair_id = p_pair_id;
  end if;

  return query select m, pode;
end;
$$;

-- ============================================================
-- Trocar roupinha / acessório / quarto equipados
-- (a checagem de nível mínimo também é feita no front-end, mas
-- fica reforçada aqui pra ninguém "trapacear" via devtools)
-- ============================================================

create or replace function equipar_item_mascote(
  p_pair_id uuid,
  p_tipo text, -- 'roupa' | 'acessorio' | 'quarto'
  p_id text,
  p_nivel_minimo integer
)
returns mascote
language plpgsql
security definer
set search_path = public
as $$
declare
  m mascote;
begin
  if p_pair_id != auth_pair_id() then
    raise exception 'not your pair';
  end if;

  m := get_or_create_mascote(p_pair_id);

  if m.nivel < p_nivel_minimo then
    raise exception 'item ainda não desbloqueado';
  end if;

  if p_tipo = 'roupa' then
    update mascote set roupa_atual = p_id where pair_id = p_pair_id returning * into m;
  elsif p_tipo = 'acessorio' then
    update mascote set acessorio_atual = p_id where pair_id = p_pair_id returning * into m;
  elsif p_tipo = 'quarto' then
    update mascote set quarto_atual = p_id where pair_id = p_pair_id returning * into m;
  else
    raise exception 'tipo inválido';
  end if;

  return m;
end;
$$;
