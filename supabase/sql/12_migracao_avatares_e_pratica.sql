-- ============================================================================
-- MIGRAÇÃO: avatares emoji + modo praticar com timer/bônus
--
-- Para BANCO JÁ EXISTENTE: rode SOMENTE este arquivo, uma única vez, no
-- editor SQL do Supabase. De preferência fora de horário de jogo ao vivo
-- (as funções de placar são recriadas e ficam indisponíveis por instantes).
--
-- Para INSTALAÇÃO NOVA: pule este arquivo — os arquivos canônicos
-- (01, 03, 06, 07, 10) já incluem todas estas mudanças.
--
-- O que muda:
--   1. creators.avatar_emoji e participants.avatar_emoji (colunas novas)
--   2. creator_register/creator_login passam a devolver o avatar;
--      novo RPC creator_avatar_update
--   3. session_join aceita p_avatar_emoji (compatível com chamadas antigas)
--   4. session_scoreboard e session_current_answers devolvem o avatar
--   5. quiz_get_for_practice devolve tempos e configuração de bônus
--      (para o modo praticar pontuar igual ao jogo ao vivo)
--
-- Notas técnicas: funções com colunas de retorno alteradas precisam de DROP
-- antes do CREATE (42P13); o DROP apaga os GRANTs, por isso todos são
-- repetidos ao final de cada função.
-- ============================================================================

-- 1. Colunas novas (idempotente) --------------------------------------------

alter table creators
  add column if not exists avatar_emoji text check (char_length(avatar_emoji) <= 16);

alter table participants
  add column if not exists avatar_emoji text check (char_length(avatar_emoji) <= 16);

-- 2. Conta do criador --------------------------------------------------------

drop function if exists creator_register(text, text, text, text);
drop function if exists creator_register(text, text, text, text, text);
create function creator_register(
  p_username text,
  p_password text,
  p_secret_question text,
  p_secret_answer text,
  p_avatar_emoji text default null
)
returns table (creator_id uuid, session_token text, is_admin boolean, avatar_emoji text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_username text := trim(p_username);
  v_avatar text := nullif(trim(coalesce(p_avatar_emoji, '')), '');
  v_id uuid;
  v_session_token text := generate_url_safe_token();
begin
  if v_username !~ '^[a-zA-Z0-9_]{3,24}$' then
    raise exception 'O usuário deve ter de 3 a 24 letras, números ou "_".';
  end if;
  if char_length(coalesce(p_password, '')) < 8 then
    raise exception 'A senha precisa ter pelo menos 8 caracteres.';
  end if;
  if char_length(coalesce(trim(p_secret_answer), '')) = 0 then
    raise exception 'Informe a resposta da pergunta secreta.';
  end if;
  if char_length(coalesce(v_avatar, '')) > 16 then
    raise exception 'Avatar inválido.';
  end if;

  begin
    insert into creators (username, password_hash, secret_question, secret_answer_hash, avatar_emoji)
    values (
      v_username,
      extensions.crypt(p_password, extensions.gen_salt('bf')),
      p_secret_question,
      extensions.crypt(normalize_secret_answer(p_secret_answer), extensions.gen_salt('bf')),
      v_avatar
    )
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Esse nome de usuário já está em uso.';
  end;

  insert into creator_sessions (creator_id, token_hash)
  values (v_id, extensions.digest(v_session_token, 'sha256'));

  return query select v_id, v_session_token, false, v_avatar;
end;
$$;
grant execute on function creator_register(text, text, text, text, text) to anon;

drop function if exists creator_login(text, text);
create function creator_login(p_username text, p_password text)
returns table (creator_id uuid, session_token text, is_admin boolean, avatar_emoji text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator creators%rowtype;
  v_session_token text := generate_url_safe_token();
begin
  select * into v_creator from creators where username = trim(p_username);

  if not found then
    raise exception 'Usuário ou senha incorretos.';
  end if;
  if v_creator.password_hash <> extensions.crypt(p_password, v_creator.password_hash) then
    raise exception 'Usuário ou senha incorretos.';
  end if;

  insert into creator_sessions (creator_id, token_hash)
  values (v_creator.id, extensions.digest(v_session_token, 'sha256'));

  update creators set last_login_at = now() where id = v_creator.id;

  return query select v_creator.id, v_session_token, v_creator.is_admin, v_creator.avatar_emoji;
end;
$$;
grant execute on function creator_login(text, text) to anon;

-- Troca do avatar de perfil (painel do criador).
create or replace function creator_avatar_update(p_session_token text, p_avatar_emoji text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_avatar text := nullif(trim(coalesce(p_avatar_emoji, '')), '');
begin
  if char_length(coalesce(v_avatar, '')) > 16 then
    raise exception 'Avatar inválido.';
  end if;
  update creators set avatar_emoji = v_avatar where id = v_creator_id;
end;
$$;
grant execute on function creator_avatar_update(text, text) to anon;

-- 3. Entrada na sala com avatar ----------------------------------------------

-- O parâmetro novo com default exige apagar a assinatura antiga: se as duas
-- versões coexistirem, o PostgREST não sabe qual chamar (overload ambíguo).
drop function if exists session_join(text, text);
drop function if exists session_join(text, text, text);
create function session_join(p_pin text, p_nickname text, p_avatar_emoji text default null)
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
begin
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

  return query select v_participant_id, v_session.id, v_join_secret;
end;
$$;
grant execute on function session_join(text, text, text) to anon;

-- 4. Placar e respostas com avatar -------------------------------------------

drop function if exists session_scoreboard(uuid);
create function session_scoreboard(p_session_id uuid)
returns table (
  participant_id uuid,
  nickname text,
  avatar_emoji text,
  total_points bigint,
  correct_count bigint,
  is_kicked boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    p.id as participant_id,
    p.nickname,
    p.avatar_emoji,
    coalesce(sum(a.points_awarded) filter (where a.counted), 0)::bigint as total_points,
    coalesce(count(*) filter (where a.counted and a.is_correct), 0)::bigint as correct_count,
    p.is_kicked
  from participants p
  left join answers a on a.participant_id = p.id and a.session_id = p_session_id
  where p.session_id = p_session_id
  group by p.id, p.nickname, p.avatar_emoji, p.is_kicked
  order by total_points desc, correct_count desc, p.nickname asc
$$;
grant execute on function session_scoreboard(uuid) to anon;

drop function if exists session_current_answers(uuid);
create function session_current_answers(p_session_id uuid)
returns table (participant_id uuid, nickname text, avatar_emoji text, choice_key text)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select p.id, p.nickname, p.avatar_emoji, a.choice_key
  from session_state s
  join answers a on a.session_id = s.session_id and a.question_id = s.current_question_id
  join participants p on p.id = a.participant_id
  where s.session_id = p_session_id
    and s.question_status in ('closed', 'revealed')
$$;
grant execute on function session_current_answers(uuid) to anon;

-- 5. Modo praticar com tempos e bônus ----------------------------------------

-- Mesma assinatura e retorno (json): create or replace simples.
create or replace function quiz_get_for_practice(p_quiz_id uuid, p_session_token text default null)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_quiz quizzes%rowtype;
  v_creator_id uuid;
  v_result json;
begin
  select * into v_quiz from quizzes where id = p_quiz_id;
  if not found then
    raise exception 'Quiz não encontrado.';
  end if;

  if v_quiz.visibility <> 'public' then
    if p_session_token is null then
      raise exception 'Este quiz não está disponível para prática.';
    end if;
    v_creator_id := creator_id_from_session(p_session_token);
    if v_quiz.creator_id <> v_creator_id then
      raise exception 'Este quiz não está disponível para prática.';
    end if;
  end if;

  select json_build_object(
    'id', v_quiz.id,
    'title', v_quiz.title,
    'description', v_quiz.description,
    'default_question_seconds', v_quiz.default_question_seconds,
    'speed_bonus_enabled', v_quiz.speed_bonus_enabled,
    'speed_bonus_pct', v_quiz.speed_bonus_pct,
    'questions', coalesce((
      select json_agg(
        json_build_object(
          'id', q.id,
          'text', q.text,
          'options', q.options,
          'correct_key', q.correct_key,
          'points', q.points,
          'media_url', q.media_url,
          'media_type', q.media_type,
          'question_seconds', q.question_seconds,
          'tags', q.tags
        ) order by q.ord
      )
      from quiz_questions q where q.quiz_id = v_quiz.id
    ), '[]'::json)
  ) into v_result;

  return v_result;
end;
$$;
grant execute on function quiz_get_for_practice(uuid, text) to anon;
