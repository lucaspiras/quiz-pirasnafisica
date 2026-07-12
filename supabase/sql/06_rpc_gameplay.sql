-- RPCs do lado do participante: entrar na sala e responder perguntas.

-- O parâmetro novo com default exige apagar as assinaturas antigas: se as
-- versões coexistirem, o PostgREST não sabe qual chamar (overload ambíguo).
-- p_session_token opcional: quem estiver logado vincula a participação à
-- conta (tabela participant_accounts); convidado segue 100% anônimo.
drop function if exists session_join(text, text);
drop function if exists session_join(text, text, text);
create or replace function session_join(
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

create or replace function participant_authorized(p_session_id uuid, p_participant_id uuid, p_join_secret text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1
    from participants p
    join participant_secrets ps on ps.participant_id = p.id
    where p.id = p_participant_id
      and p.session_id = p_session_id
      and p.is_kicked = false
      and token_matches(ps.join_secret_hash, p_join_secret)
  )
$$;

create or replace function session_submit_answer(
  p_session_id uuid,
  p_participant_id uuid,
  p_join_secret text,
  p_question_id uuid,
  p_choice_key text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_state session_state%rowtype;
  v_session game_sessions%rowtype;
  v_correct_key text;
  v_response_ms int;
  v_is_correct boolean;
  v_points int := 0;
  v_bonus int := 0;
  v_time_fraction numeric;
begin
  if not participant_authorized(p_session_id, p_participant_id, p_join_secret) then
    raise exception 'Sessão de participante inválida.';
  end if;

  select * into v_state from session_state where session_id = p_session_id;
  select * into v_session from game_sessions where id = p_session_id;

  if not found or v_state.question_status <> 'open' or v_state.current_question_id <> p_question_id then
    raise exception 'Essa pergunta não está aberta para respostas no momento.';
  end if;

  v_response_ms := least(
    greatest(0, floor(extract(epoch from (now() - v_state.question_started_at)) * 1000))::int,
    v_state.q_seconds * 1000
  );

  select correct_key into v_correct_key from quiz_questions where id = p_question_id;
  v_is_correct := (v_correct_key = p_choice_key);

  if v_is_correct then
    v_points := v_state.q_points;
    if v_session.speed_bonus_enabled then
      v_time_fraction := greatest(0, (v_state.q_seconds * 1000 - v_response_ms)::numeric / (v_state.q_seconds * 1000));
      v_bonus := round(v_state.q_points * (v_session.speed_bonus_pct / 100.0) * v_time_fraction);
      v_points := v_points + v_bonus;
    end if;
  end if;

  insert into answers (session_id, question_id, participant_id, choice_key, is_correct, response_ms, points_awarded)
  values (p_session_id, p_question_id, p_participant_id, p_choice_key, v_is_correct, v_response_ms, v_points)
  on conflict (session_id, question_id, participant_id)
  do update set choice_key = excluded.choice_key,
                is_correct = excluded.is_correct,
                response_ms = excluded.response_ms,
                points_awarded = excluded.points_awarded,
                answered_at = now();
end;
$$;
grant execute on function session_submit_answer(uuid, uuid, text, uuid, text) to anon;

create or replace function participant_my_answer(
  p_session_id uuid,
  p_participant_id uuid,
  p_join_secret text,
  p_question_id uuid
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_choice text;
begin
  if not participant_authorized(p_session_id, p_participant_id, p_join_secret) then
    raise exception 'Sessão de participante inválida.';
  end if;

  select choice_key into v_choice from answers
  where session_id = p_session_id and question_id = p_question_id and participant_id = p_participant_id;

  return v_choice;
end;
$$;
grant execute on function participant_my_answer(uuid, uuid, text, uuid) to anon;
