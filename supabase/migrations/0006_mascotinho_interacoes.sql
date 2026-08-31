-- ============================================================
-- Mascotinho parte 3: brincar, soneca, higiene, sussurro, streak,
-- bônus de dupla e presente surpresa. Rode depois de 0000, 0001,
-- 0002, 0003_new_features.sql, 0004_mascotinho.sql e
-- 0005_mascotinho_comidinhas.sql.
-- ============================================================

-- 1) Novas colunas ---------------------------------------------------

alter table mascote add column if not exists higiene numeric not null default 100 check (higiene >= 0 and higiene <= 100);
alter table mascote add column if not exists ultimo_brincar timestamptz;
alter table mascote add column if not exists ultimo_banho timestamptz;
alter table mascote add column if not exists soneca_ate timestamptz;
alter table mascote add column if not exists streak_dias integer not null default 0;
alter table mascote add column if not exists streak_ultimo_dia date;
alter table mascote add column if not exists bonus_dupla_dia date;
alter table mascote add column if not exists bonus_dupla_autores uuid[] not null default '{}';

-- presente surpresa: um parceiro deixa uma ação "programada" que o
-- outro só vê o efeito quando entra e "descobre" o presente.
create table if not exists mascote_presentes (
  id bigint generated always as identity primary key,
  pair_id uuid not null references pairs(id) on delete cascade,
  autor uuid not null references auth.users(id),
  tipo text not null, -- 'carinho' | 'comidinha'
  comida_id text,
  mensagem text,
  criado_em timestamptz not null default now(),
  resgatado boolean not null default false,
  resgatado_em timestamptz
);

create index if not exists mascote_presentes_pair_pendente_idx
  on mascote_presentes(pair_id) where resgatado = false;

alter table mascote_presentes enable row level security;

drop policy if exists "mascote_presentes: select own pair" on mascote_presentes;
create policy "mascote_presentes: select own pair" on mascote_presentes
  for select to authenticated
  using (pair_id = auth_pair_id());

drop policy if exists "mascote_presentes: insert own pair" on mascote_presentes;
create policy "mascote_presentes: insert own pair" on mascote_presentes
  for insert to authenticated
  with check (pair_id = auth_pair_id() and autor = auth.uid());

drop policy if exists "mascote_presentes: update own pair" on mascote_presentes;
create policy "mascote_presentes: update own pair" on mascote_presentes
  for update to authenticated
  using (pair_id = auth_pair_id())
  with check (pair_id = auth_pair_id());

-- 2) Decaimento: agora também degrada a higiene bem devagar ----------

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
  -- soneca ativa acelera a recuperação de energia em vez de decair
  if m.soneca_ate is not null and m.soneca_ate > now() then
    resultado.energia := least(100, m.energia + horas * 6.0);
  else
    resultado.energia := greatest(0, m.energia - horas * 1.0);
  end if;
  resultado.higiene := greatest(0, m.higiene - horas * 0.5);
  resultado.ultima_atualizacao := now();

  update mascote set
    fome = resultado.fome,
    felicidade = resultado.felicidade,
    energia = resultado.energia,
    higiene = resultado.higiene,
    ultima_atualizacao = resultado.ultima_atualizacao
  where pair_id = m.pair_id;

  return resultado;
end;
$$;

-- 3) Streak: some 1 se o dia for consecutivo, reinicia se pulou um dia,
-- e não faz nada se já contou hoje. Chamada dentro de adicionar_xp_mascote
-- pra qualquer ação do dia contar como "cuidou dele hoje".
-- ============================================================

create or replace function _mascote_atualizar_streak(p_pair_id uuid)
returns table (streak_dias integer, streak_aumentou boolean, bonus_semanal boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  m mascote;
  hoje date := (now() at time zone 'utc')::date;
  novo_streak integer;
  aumentou boolean := false;
  bonus boolean := false;
begin
  select * into m from mascote where pair_id = p_pair_id;

  if m.streak_ultimo_dia = hoje then
    return query select m.streak_dias, false, false;
    return;
  end if;

  if m.streak_ultimo_dia = hoje - interval '1 day' then
    novo_streak := m.streak_dias + 1;
  else
    novo_streak := 1;
  end if;

  aumentou := true;
  bonus := novo_streak > 0 and novo_streak % 7 = 0;

  update mascote set streak_dias = novo_streak, streak_ultimo_dia = hoje
    where pair_id = p_pair_id;

  if bonus then
    perform adicionar_xp_mascote(p_pair_id, 20, 'streak_bonus');
  end if;

  return query select novo_streak, aumentou, bonus;
end;
$$;

-- 4) Bônus de dupla: quando os DOIS parceiros já registraram alguma
-- ação de XP no mesmo dia, dá um XP extra uma única vez por dia.
-- ============================================================

create or replace function _mascote_checar_bonus_dupla(p_pair_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  m mascote;
  hoje date := (now() at time zone 'utc')::date;
  autores uuid[];
  ja_deu_hoje boolean;
begin
  select * into m from mascote where pair_id = p_pair_id;

  ja_deu_hoje := m.bonus_dupla_dia = hoje;
  autores := case when ja_deu_hoje then m.bonus_dupla_autores else '{}'::uuid[] end;

  if not (auth.uid() = any(autores)) then
    autores := array_append(autores, auth.uid());
  end if;

  update mascote set bonus_dupla_dia = hoje, bonus_dupla_autores = autores
    where pair_id = p_pair_id;

  if not ja_deu_hoje and array_length(autores, 1) is not null and array_length(autores, 1) >= 2 then
    perform adicionar_xp_mascote(p_pair_id, 15, 'dupla_bonus');
    return true;
  end if;

  return false;
end;
$$;

-- 5) adicionar_xp_mascote agora também atualiza streak e bônus de dupla,
-- e devolve isso pro front mostrar os toasts certos.
-- ============================================================

create or replace function adicionar_xp_mascote(
  p_pair_id uuid,
  p_quantidade integer,
  p_tipo text
)
returns table (
  mascote mascote,
  subiu_de_nivel boolean,
  niveis_ganhos integer,
  streak_dias integer,
  streak_aumentou boolean,
  streak_bonus_semanal boolean,
  ganhou_bonus_dupla boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  m mascote;
  subiu boolean := false;
  niveis integer := 0;
  r_streak record;
  r_dupla boolean := false;
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

  -- evita recursão infinita: os próprios bônus (streak/dupla) não
  -- disparam de novo o streak/dupla
  if p_tipo not in ('streak_bonus', 'dupla_bonus') then
    select * into r_streak from _mascote_atualizar_streak(p_pair_id);
    r_dupla := _mascote_checar_bonus_dupla(p_pair_id);
  else
    r_streak := row(coalesce((select streak_dias from mascote where pair_id = p_pair_id), 0), false, false);
  end if;

  select * into m from mascote where pair_id = p_pair_id;

  return query select m, subiu, niveis, r_streak.streak_dias, r_streak.streak_aumentou, r_streak.bonus_semanal, r_dupla;
end;
$$;

-- 6) Brincar: gasta energia, dá bastante felicidade + XP.
-- Cooldown de 3h.
-- ============================================================

create or replace function brincar_mascote(p_pair_id uuid)
returns table (mascote mascote, podia_brincar boolean)
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

  pode := m.ultimo_brincar is null or m.ultimo_brincar < now() - interval '3 hours';

  if pode then
    if m.energia < 10 then
      pode := false;
    else
      m.felicidade := least(100, m.felicidade + 18);
      m.energia := greatest(0, m.energia - 12);
      update mascote set felicidade = m.felicidade, energia = m.energia, ultimo_brincar = now()
        where pair_id = p_pair_id;
      perform adicionar_xp_mascote(p_pair_id, 8, 'brincar');
      select * into m from mascote where pair_id = p_pair_id;
    end if;
  end if;

  return query select m, pode;
end;
$$;

-- 7) Soneca: trava o mood em "sleepy" e acelera a recuperação de
-- energia pelas próximas 2h (ver _mascote_aplicar_decaimento acima).
-- ============================================================

create or replace function colocar_para_dormir_mascote(p_pair_id uuid)
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

  update mascote set soneca_ate = now() + interval '2 hours'
    where pair_id = p_pair_id returning * into m;

  return m;
end;
$$;

-- 8) Banho: restaura a higiene. Cooldown de 6h (decai bem devagar).
-- ============================================================

create or replace function dar_banho_mascote(p_pair_id uuid)
returns table (mascote mascote, podia_dar_banho boolean)
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

  pode := m.ultimo_banho is null or m.ultimo_banho < now() - interval '6 hours';

  if pode then
    m.higiene := 100;
    m.felicidade := least(100, m.felicidade + 5);
    update mascote set higiene = m.higiene, felicidade = m.felicidade, ultimo_banho = now()
      where pair_id = p_pair_id;
    perform adicionar_xp_mascote(p_pair_id, 6, 'banho');
    select * into m from mascote where pair_id = p_pair_id;
  end if;

  return query select m, pode;
end;
$$;

-- 9) Sussurro: guarda o texto (opcional, só pra transparência de casal)
-- e devolve uma fala aleatória. Não mexe em stats nem em XP -
-- é só carinho/diversão.
-- ============================================================

create table if not exists mascote_sussurros (
  id bigint generated always as identity primary key,
  pair_id uuid not null references pairs(id) on delete cascade,
  autor uuid not null references auth.users(id),
  texto text not null,
  criado_em timestamptz not null default now()
);

alter table mascote_sussurros enable row level security;

drop policy if exists "mascote_sussurros: select own pair" on mascote_sussurros;
create policy "mascote_sussurros: select own pair" on mascote_sussurros
  for select to authenticated
  using (pair_id = auth_pair_id());

drop policy if exists "mascote_sussurros: insert own" on mascote_sussurros;
create policy "mascote_sussurros: insert own" on mascote_sussurros
  for insert to authenticated
  with check (pair_id = auth_pair_id() and autor = auth.uid());

create or replace function sussurrar_mascote(p_pair_id uuid, p_texto text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  novo_id bigint;
begin
  if p_pair_id != auth_pair_id() then
    raise exception 'not your pair';
  end if;

  insert into mascote_sussurros (pair_id, autor, texto)
  values (p_pair_id, auth.uid(), left(p_texto, 300))
  returning id into novo_id;

  return novo_id;
end;
$$;

-- 10) Presente surpresa: um parceiro registra, o outro resgata.
-- Resgatar aplica o mesmo efeito de carinho/comidinha e some da lista.
-- ============================================================

create or replace function deixar_presente_mascote(p_pair_id uuid, p_tipo text, p_comida_id text, p_mensagem text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  novo_id bigint;
begin
  if p_pair_id != auth_pair_id() then
    raise exception 'not your pair';
  end if;
  if p_tipo not in ('carinho', 'comidinha') then
    raise exception 'tipo inválido';
  end if;

  insert into mascote_presentes (pair_id, autor, tipo, comida_id, mensagem)
  values (p_pair_id, auth.uid(), p_tipo, p_comida_id, nullif(left(coalesce(p_mensagem, ''), 200), ''))
  returning id into novo_id;

  return novo_id;
end;
$$;

create or replace function listar_presentes_pendentes_mascote(p_pair_id uuid)
returns setof mascote_presentes
language sql
security invoker
as $$
  select * from mascote_presentes
  where pair_id = p_pair_id
    and resgatado = false
    and autor != auth.uid()
  order by criado_em asc;
$$;

create or replace function resgatar_presente_mascote(p_pair_id uuid, p_presente_id bigint)
returns table (mascote mascote, presente mascote_presentes)
language plpgsql
security definer
set search_path = public
as $$
declare
  m mascote;
  p mascote_presentes;
begin
  if p_pair_id != auth_pair_id() then
    raise exception 'not your pair';
  end if;

  select * into p from mascote_presentes
    where id = p_presente_id and pair_id = p_pair_id and resgatado = false
    for update;

  if not found then
    raise exception 'presente não encontrado ou já resgatado';
  end if;
  if p.autor = auth.uid() then
    raise exception 'não dá pra resgatar seu próprio presente';
  end if;

  m := get_or_create_mascote(p_pair_id);

  if p.tipo = 'comidinha' then
    m.fome := least(100, m.fome + 25);
    m.felicidade := least(100, m.felicidade + 4);
    m.energia := least(100, m.energia + 2);
    update mascote set fome = m.fome, felicidade = m.felicidade, energia = m.energia,
      ultima_comida = p.comida_id
      where pair_id = p_pair_id;
  else
    m.felicidade := least(100, m.felicidade + 12);
    m.energia := least(100, m.energia + 3);
    update mascote set felicidade = m.felicidade, energia = m.energia
      where pair_id = p_pair_id;
  end if;

  perform adicionar_xp_mascote(p_pair_id, 5, 'presente');

  update mascote_presentes set resgatado = true, resgatado_em = now()
    where id = p_presente_id;

  select * into m from mascote where pair_id = p_pair_id;
  select * into p from mascote_presentes where id = p_presente_id;

  return query select m, p;
end;
$$;
