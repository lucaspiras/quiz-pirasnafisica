-- ============================================================================
-- MIGRAÇÃO: página de perfil + login opcional de participante + histórico
--
-- Para BANCO JÁ EXISTENTE: rode SOMENTE este arquivo, uma única vez, no
-- editor SQL do Supabase. De preferência fora de horário de jogo ao vivo
-- (session_join é recriada e a entrada em salas fica indisponível por
-- instantes durante o DROP/CREATE).
--
-- Para INSTALAÇÃO NOVA: pule este arquivo — os arquivos canônicos
-- (01, 02, 03, 06, 10) já incluem todas estas mudanças.
--
-- O que muda:
--   1. Tabelas novas: participant_accounts (vínculo participante ↔ conta,
--      fora de participants por privacidade) e practice_plays (histórico
--      pessoal do modo praticar — SEM ranking público)
--   2. session_join aceita p_session_token opcional: quem estiver logado
--      pode vincular sua participação à conta (convidado segue igual)
--   3. Novo RPC creator_password_change (trocar senha estando logado)
--   4. Novo RPC practice_play_record (grava tentativa de prática do logado)
--   5. Novo RPC creator_my_participations (histórico unificado para o perfil)
--   6. public_quizzes_list corrigida: a contagem de perguntas saía dobrada
--      (o unnest das tags multiplicava as linhas antes do count)
--
-- Nenhuma tabela nova entra na publication do Realtime nem ganha policy:
-- acesso só via RPC SECURITY DEFINER (mesmo padrão de participant_secrets).
-- ============================================================================

-- 1. Tabelas novas (idempotente) ---------------------------------------------

-- Vínculo participante ↔ conta em tabela separada: participants é lida por
-- anon (Realtime transmite a linha inteira), então creator_id não pode morar
-- lá — viraria um mapa público de qual conta usa qual apelido em cada sala.
create table if not exists participant_accounts (
  participant_id  uuid primary key references participants(id) on delete cascade,
  creator_id      uuid not null references creators(id) on delete cascade,
  linked_at       timestamptz not null default now()
);
create index if not exists participant_accounts_creator_idx
  on participant_accounts(creator_id);
alter table participant_accounts enable row level security;
-- sem policies: acesso só via RPC security definer

-- Histórico pessoal do modo praticar. A pontuação é calculada no navegador e
-- o gabarito chega ao cliente, então este número é fraudável — por isso NUNCA
-- vira ranking público: só o próprio dono vê (fraude é autoengano).
create table if not exists practice_plays (
  id             uuid primary key default gen_random_uuid(),
  creator_id     uuid not null references creators(id) on delete cascade,
  quiz_id        uuid not null references quizzes(id) on delete cascade,
  score          int not null check (score >= 0),
  correct_count  int not null check (correct_count >= 0),
  total_count    int not null check (total_count >= 1),
  duration_ms    bigint check (duration_ms is null or duration_ms >= 0),
  played_at      timestamptz not null default now(),
  constraint practice_plays_counts_check check (correct_count <= total_count)
);
create index if not exists practice_plays_creator_idx
  on practice_plays(creator_id, played_at desc);
create index if not exists practice_plays_creator_quiz_idx
  on practice_plays(creator_id, quiz_id, played_at desc);
alter table practice_plays enable row level security;
-- sem policies: acesso só via RPC security definer

-- 2. session_join com login opcional ------------------------------------------

-- O parâmetro novo com default exige apagar as assinaturas antigas: se as
-- versões coexistirem, o PostgREST não sabe qual chamar (overload ambíguo).
drop function if exists session_join(text, text);
drop function if exists session_join(text, text, text);
create function session_join(
  p_pin text,
  p_nickname text,
  p_avatar_emoji text default null,
  p_session_token text default null
)
returns table (participant_id uuid, session_id uuid, join_secret text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_session game_sessions%rowtype;
  v_nickname text := trim(p_nickname);
  v_avatar text := nullif(trim(coalesce(p_avatar_emoji, '')), '');
  v_join_secret text := generate_url_safe_token();
  v_participant_id uuid;
  v_creator_id uuid;
begin
  -- Valida o login ANTES de criar o participante: token expirado falha aqui
  -- e o cliente oferece entrar como convidado, sem deixar participante órfão.
  if p_session_token is not null then
    v_creator_id := creator_id_from_session(p_session_token);
  end if;

  if char_length(v_nickname) = 0 or char_length(v_nickname) > 24 then
    raise exception 'O apelido precisa ter entre 1 e 24 caracteres.';
  end if;
  if char_length(coalesce(v_avatar, '')) > 16 then
    raise exception 'Avatar inválido.';
  end if;

  select * into v_session from game_sessions
  where pin = p_pin and status <> 'finished'
  order by created_at desc
  limit 1;

  if not found then
    raise exception 'Nenhuma sala ativa encontrada com esse código.';
  end if;

  if exists (
    select 1 from participants p
    where p.session_id = v_session.id and lower(p.nickname) = lower(v_nickname)
  ) then
    raise exception 'Esse apelido já está em uso nesta sala. Escolha outro.';
  end if;

  begin
    insert into participants (session_id, nickname, avatar_emoji)
    values (v_session.id, v_nickname, v_avatar)
    returning id into v_participant_id;
  exception when unique_violation then
    raise exception 'Esse apelido já está em uso nesta sala. Escolha outro.';
  end;

  insert into participant_secrets (participant_id, join_secret_hash)
  values (v_participant_id, extensions.digest(v_join_secret, 'sha256'));

  if v_creator_id is not null then
    insert into participant_accounts (participant_id, creator_id)
    values (v_participant_id, v_creator_id);
  end if;

  return query select v_participant_id, v_session.id, v_join_secret;
end;
$$;
grant execute on function session_join(text, text, text, text) to anon;

-- 3. Trocar senha estando logado -----------------------------------------------

-- Diferente do creator_recover_reset (fluxo não autenticado, derruba tudo):
-- aqui quem troca está presente e autenticado, então a sessão atual sobrevive
-- e só os OUTROS aparelhos são desconectados (proteção contra sessão roubada).
create or replace function creator_password_change(
  p_session_token text,
  p_current_password text,
  p_new_password text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_creator creators%rowtype;
begin
  if char_length(coalesce(p_new_password, '')) < 8 then
    raise exception 'A nova senha precisa ter pelo menos 8 caracteres.';
  end if;

  select * into v_creator from creators where id = v_creator_id;

  if v_creator.password_hash <> extensions.crypt(p_current_password, v_creator.password_hash) then
    raise exception 'Senha atual incorreta.';
  end if;

  update creators
  set password_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf'))
  where id = v_creator_id;

  delete from creator_sessions
  where creator_id = v_creator_id
    and token_hash <> extensions.digest(p_session_token, 'sha256');
end;
$$;
grant execute on function creator_password_change(text, text, text) to anon;

-- 4. Registrar tentativa de prática --------------------------------------------

create or replace function practice_play_record(
  p_session_token text,
  p_quiz_id uuid,
  p_score int,
  p_correct_count int,
  p_total_count int,
  p_duration_ms bigint default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_quiz quizzes%rowtype;
  v_max_score int;
begin
  select * into v_quiz from quizzes where id = p_quiz_id;
  if not found then
    raise exception 'Quiz não encontrado.';
  end if;
  -- Mesma regra do quiz_get_for_practice: público, ou quiz do próprio usuário.
  if v_quiz.visibility <> 'public' and v_quiz.creator_id <> v_creator_id then
    raise exception 'Este quiz não está disponível para prática.';
  end if;

  if coalesce(p_score, -1) < 0 or coalesce(p_correct_count, -1) < 0
     or coalesce(p_total_count, 0) < 1 or p_correct_count > p_total_count then
    raise exception 'Resultado inválido.';
  end if;
  -- Teto folgado de plausibilidade: o bônus de velocidade chega a no máximo
  -- 100% dos pontos base, então nada legítimo passa de 2x a soma dos pontos.
  select coalesce(sum(points), 0) * 2 into v_max_score
  from quiz_questions where quiz_id = p_quiz_id;
  if p_score > greatest(v_max_score, 1) then
    raise exception 'Resultado inválido.';
  end if;

  insert into practice_plays (creator_id, quiz_id, score, correct_count, total_count, duration_ms)
  values (v_creator_id, p_quiz_id, p_score, p_correct_count, p_total_count, p_duration_ms);

  -- Anti-flood simples: guarda só as 20 tentativas mais recentes por quiz.
  delete from practice_plays pp
  where pp.creator_id = v_creator_id and pp.quiz_id = p_quiz_id
    and pp.id not in (
      select p2.id from practice_plays p2
      where p2.creator_id = v_creator_id and p2.quiz_id = p_quiz_id
      order by p2.played_at desc, p2.id desc
      limit 20
    );
end;
$$;
grant execute on function practice_play_record(text, uuid, int, int, int, bigint) to anon;

-- 5. Histórico unificado para a página de perfil --------------------------------

-- Devolve json {live: [...], practice: [...]} numa chamada só. A posição nos
-- jogos ao vivo usa o mesmo agregado do session_scoreboard, excluindo expulsos
-- do ranking (mesmo critério da página de resultado).
create or replace function creator_my_participations(p_session_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_result json;
begin
  select json_build_object(
    'live', coalesce((
      select json_agg(json_build_object(
        'session_id', t.session_id,
        'quiz_title', t.quiz_title,
        'nickname', t.nickname,
        'avatar_emoji', t.avatar_emoji,
        'played_at', t.played_at,
        'session_status', t.status,
        'total_points', t.total_points,
        'correct_count', t.correct_count,
        'position', t.position,
        'participants_count', t.participants_count,
        'was_kicked', t.was_kicked
      ) order by t.played_at desc)
      from (
        with mine as (
          select p.id as participant_id, p.session_id, p.nickname,
                 p.avatar_emoji, p.is_kicked
          from participant_accounts pa
          join participants p on p.id = pa.participant_id
          where pa.creator_id = v_creator_id
        ),
        placar as (
          select p.session_id, p.id as participant_id,
                 coalesce(sum(a.points_awarded) filter (where a.counted), 0)::bigint as total_points,
                 coalesce(count(*) filter (where a.counted and a.is_correct), 0)::bigint as correct_count,
                 rank() over (
                   partition by p.session_id
                   order by coalesce(sum(a.points_awarded) filter (where a.counted), 0) desc,
                            coalesce(count(*) filter (where a.counted and a.is_correct), 0) desc
                 ) as position,
                 count(*) over (partition by p.session_id) as participants_count
          from participants p
          left join answers a on a.participant_id = p.id
          where p.session_id in (select session_id from mine)
            and not p.is_kicked
          group by p.session_id, p.id
        )
        select m.session_id, q.title as quiz_title, m.nickname, m.avatar_emoji,
               coalesce(gs.ended_at, gs.created_at) as played_at, gs.status,
               coalesce(pl.total_points, 0) as total_points,
               coalesce(pl.correct_count, 0) as correct_count,
               pl.position, pl.participants_count,
               m.is_kicked as was_kicked
        from mine m
        join game_sessions gs on gs.id = m.session_id
        join quizzes q on q.id = gs.quiz_id
        left join placar pl on pl.participant_id = m.participant_id
        order by coalesce(gs.ended_at, gs.created_at) desc
        limit 50
      ) t
    ), '[]'::json),
    'practice', coalesce((
      select json_agg(json_build_object(
        'quiz_id', pp.quiz_id,
        'quiz_title', q.title,
        'score', pp.score,
        'correct_count', pp.correct_count,
        'total_count', pp.total_count,
        'duration_ms', pp.duration_ms,
        'played_at', pp.played_at
      ) order by pp.played_at desc)
      from (
        select * from practice_plays
        where creator_id = v_creator_id
        order by played_at desc
        limit 50
      ) pp
      join quizzes q on q.id = pp.quiz_id
    ), '[]'::json)
  ) into v_result;

  return v_result;
end;
$$;
grant execute on function creator_my_participations(text) to anon;

-- 6. Correção: contagem de perguntas dobrada em public_quizzes_list -------------

create or replace function public_quizzes_list(p_tags text[] default null)
returns table (
  quiz_id uuid,
  title text,
  description text,
  question_count bigint,
  tags text[]
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    z.id,
    z.title,
    z.description,
    -- distinct: o unnest lateral das tags repete cada pergunta uma vez por tag,
    -- então count(q.id) contaria em dobro/triplo.
    count(distinct q.id),
    coalesce(array_agg(distinct t) filter (where t is not null), '{}')
  from quizzes z
  left join quiz_questions q on q.quiz_id = z.id
  left join lateral unnest(q.tags) as t on true
  where z.visibility = 'public'
    and (
      p_tags is null or array_length(p_tags, 1) is null
      or exists (select 1 from quiz_questions q2 where q2.quiz_id = z.id and q2.tags && p_tags)
    )
  group by z.id, z.title, z.description, z.updated_at
  order by z.updated_at desc
$$;
grant execute on function public_quizzes_list(text[]) to anon;
