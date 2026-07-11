-- RPCs de ciclo de vida da sessão ao vivo (lado do host / apresentador).
-- Credencial do host: aceitamos tanto o host_secret da sessão quanto uma
-- sessão de criador (login) que seja dona do quiz daquela sessão (para o
-- criador retomar o controle se perder a URL do admin.html no meio do jogo).

create or replace function session_host_authorized(p_session_id uuid, p_credential text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1
    from game_sessions gs
    left join session_hosts sh on sh.session_id = gs.id
    left join quizzes q on q.id = gs.quiz_id
    left join creator_sessions cs on cs.token_hash = extensions.digest(p_credential, 'sha256')
    where gs.id = p_session_id
      and (
        token_matches(sh.host_secret_hash, p_credential)
        or cs.creator_id = q.creator_id
      )
  )
$$;

create or replace function session_start(p_session_token text, p_quiz_id uuid)
returns table (session_id uuid, pin text, host_secret text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_quiz quizzes%rowtype;
  v_question_count int;
  v_session_id uuid;
  v_pin text;
  v_host_secret text := generate_url_safe_token();
  v_attempt int := 0;
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);
  select * into v_quiz from quizzes where id = p_quiz_id;

  select count(*) into v_question_count from quiz_questions where quiz_id = v_quiz.id;
  if v_question_count = 0 then
    raise exception 'Adicione pelo menos uma pergunta antes de hospedar o quiz.';
  end if;

  loop
    v_attempt := v_attempt + 1;
    v_pin := lpad(floor(random() * 1000000)::int::text, 6, '0');
    begin
      insert into game_sessions (
        quiz_id, pin, status, speed_bonus_enabled, speed_bonus_pct
      ) values (
        v_quiz.id, v_pin, 'lobby', v_quiz.speed_bonus_enabled, v_quiz.speed_bonus_pct
      )
      returning id into v_session_id;
      exit;
    exception when unique_violation then
      if v_attempt >= 10 then
        raise exception 'Não foi possível gerar um código de sala. Tente novamente.';
      end if;
    end;
  end loop;

  insert into session_hosts (session_id, host_secret_hash)
  values (v_session_id, extensions.digest(v_host_secret, 'sha256'));

  insert into session_state (session_id, question_status, q_total)
  values (v_session_id, 'idle', v_question_count);

  update quizzes set last_used_at = now() where id = v_quiz.id;

  return query select v_session_id, v_pin, v_host_secret;
end;
$$;
grant execute on function session_start(text, uuid) to anon;

create or replace function session_show_question(p_session_id uuid, p_credential text, p_question_index int)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_quiz_id uuid;
  v_question quiz_questions%rowtype;
  v_total int;
begin
  if not session_host_authorized(p_session_id, p_credential) then
    raise exception 'Credencial de host inválida.';
  end if;

  select quiz_id into v_quiz_id from game_sessions where id = p_session_id;

  select * into v_question from quiz_questions
  where quiz_id = v_quiz_id
  order by ord
  offset p_question_index limit 1;

  if not found then
    raise exception 'Não há pergunta nessa posição.';
  end if;

  select count(*) into v_total from quiz_questions where quiz_id = v_quiz_id;

  update session_state
  set question_status = 'shown',
      current_question_id = v_question.id,
      q_index = p_question_index,
      q_total = v_total,
      q_text = v_question.text,
      q_options = v_question.options,
      q_points = v_question.points,
      q_media_url = v_question.media_url,
      q_media_type = v_question.media_type,
      q_seconds = coalesce(
        v_question.question_seconds,
        (select default_question_seconds from quizzes where id = v_quiz_id)
      ),
      question_started_at = null,
      reveal_correct_key = null,
      updated_at = now()
  where session_id = p_session_id;

  update game_sessions set status = 'running' where id = p_session_id and status = 'lobby';
end;
$$;
grant execute on function session_show_question(uuid, text, int) to anon;

create or replace function session_open_timer(p_session_id uuid, p_credential text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not session_host_authorized(p_session_id, p_credential) then
    raise exception 'Credencial de host inválida.';
  end if;

  update session_state
  set question_status = 'open', question_started_at = now(), updated_at = now()
  where session_id = p_session_id and question_status = 'shown';

  if not found then
    raise exception 'A pergunta precisa estar exibida antes de abrir o tempo.';
  end if;
end;
$$;
grant execute on function session_open_timer(uuid, text) to anon;

create or replace function session_close_timer(p_session_id uuid, p_credential text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not session_host_authorized(p_session_id, p_credential) then
    raise exception 'Credencial de host inválida.';
  end if;

  update session_state
  set question_status = 'closed', updated_at = now()
  where session_id = p_session_id and question_status = 'open';

  if not found then
    raise exception 'Não há tempo aberto para fechar.';
  end if;
end;
$$;
grant execute on function session_close_timer(uuid, text) to anon;

create or replace function session_reveal(p_session_id uuid, p_credential text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_question_id uuid;
  v_correct_key text;
begin
  if not session_host_authorized(p_session_id, p_credential) then
    raise exception 'Credencial de host inválida.';
  end if;

  select current_question_id into v_question_id
  from session_state
  where session_id = p_session_id and question_status = 'closed';

  if not found then
    raise exception 'Feche o tempo da pergunta antes de revelar.';
  end if;

  select correct_key into v_correct_key from quiz_questions where id = v_question_id;

  update session_state
  set question_status = 'revealed', reveal_correct_key = v_correct_key, updated_at = now()
  where session_id = p_session_id;

  update answers
  set counted = true
  where session_id = p_session_id and question_id = v_question_id;
end;
$$;
grant execute on function session_reveal(uuid, text) to anon;

create or replace function session_next_or_finish(p_session_id uuid, p_credential text)
returns table (finished boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_index int;
  v_total int;
begin
  if not session_host_authorized(p_session_id, p_credential) then
    raise exception 'Credencial de host inválida.';
  end if;

  select q_index, q_total into v_index, v_total
  from session_state where session_id = p_session_id and question_status = 'revealed';

  if not found then
    raise exception 'Revele a pergunta atual antes de avançar.';
  end if;

  if v_index + 1 < v_total then
    perform session_show_question(p_session_id, p_credential, v_index + 1);
    return query select false;
  else
    update game_sessions set status = 'finished', ended_at = now() where id = p_session_id;
    return query select true;
  end if;
end;
$$;
grant execute on function session_next_or_finish(uuid, text) to anon;

create or replace function session_kick_participant(p_session_id uuid, p_credential text, p_participant_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not session_host_authorized(p_session_id, p_credential) then
    raise exception 'Credencial de host inválida.';
  end if;

  update participants set is_kicked = true
  where id = p_participant_id and session_id = p_session_id;

  if not found then
    raise exception 'Participante não encontrado nesta sessão.';
  end if;
end;
$$;
grant execute on function session_kick_participant(uuid, text, uuid) to anon;

create or replace function session_end(p_session_id uuid, p_credential text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not session_host_authorized(p_session_id, p_credential) then
    raise exception 'Credencial de host inválida.';
  end if;

  update game_sessions set status = 'finished', ended_at = now()
  where id = p_session_id and status <> 'finished';
end;
$$;
grant execute on function session_end(uuid, text) to anon;

-- Anon-callable, sem segredo: não é sensível (só diz quanto tempo já passou
-- na pergunta aberta). Usada pelo cliente para calibrar o relógio local
-- (performance.now()) uma única vez por pergunta.
create or replace function quiz_elapsed_ms(p_session_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public, extensions
as $$
  select case
    when question_status = 'open' and question_started_at is not null
      then greatest(0, floor(extract(epoch from (now() - question_started_at)) * 1000))::bigint
    else null
  end
  from session_state
  where session_id = p_session_id
$$;
grant execute on function quiz_elapsed_ms(uuid) to anon;
