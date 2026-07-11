-- RPCs de autoria: criar/editar quiz e perguntas.
-- Toda função (exceto quiz_create) recebe p_session_token (sessão do
-- criador logado) + p_quiz_id, e confere que o quiz pertence ao criador
-- daquela sessão antes de qualquer leitura/escrita sensível.

create or replace function assert_owns_quiz(p_creator_id uuid, p_quiz_id uuid)
returns void
language plpgsql
stable
as $$
begin
  if not exists (select 1 from quizzes where id = p_quiz_id and creator_id = p_creator_id) then
    raise exception 'Quiz não encontrado ou você não tem acesso a ele.';
  end if;
end;
$$;

create or replace function validate_options(p_options jsonb, p_correct_key text)
returns void
language plpgsql
immutable
as $$
declare
  v_keys text[];
begin
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) < 2
     or jsonb_array_length(p_options) > 4 then
    raise exception 'A pergunta precisa ter entre 2 e 4 alternativas.';
  end if;

  select array_agg(opt ->> 'key') into v_keys
  from jsonb_array_elements(p_options) as opt;

  if exists (
    select 1 from jsonb_array_elements(p_options) as opt
    where coalesce(opt ->> 'key', '') = '' or coalesce(opt ->> 'label', '') = ''
  ) then
    raise exception 'Todas as alternativas precisam ter texto e identificador.';
  end if;

  if not (p_correct_key = any(v_keys)) then
    raise exception 'A alternativa correta precisa ser uma das opções informadas.';
  end if;
end;
$$;

create or replace function quiz_create(p_session_token text, p_title text, p_description text default null)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_id uuid;
begin
  if char_length(trim(p_title)) = 0 then
    raise exception 'Dê um título para o quiz.';
  end if;

  insert into quizzes (creator_id, title, description)
  values (v_creator_id, trim(p_title), nullif(trim(p_description), ''))
  returning id into v_id;

  return v_id;
end;
$$;
grant execute on function quiz_create(text, text, text) to anon;

create or replace function quiz_get_for_edit(p_session_token text, p_quiz_id uuid)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_quiz quizzes%rowtype;
  v_result json;
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);
  select * into v_quiz from quizzes where id = p_quiz_id;

  select json_build_object(
    'id', v_quiz.id,
    'title', v_quiz.title,
    'description', v_quiz.description,
    'speed_bonus_enabled', v_quiz.speed_bonus_enabled,
    'speed_bonus_pct', v_quiz.speed_bonus_pct,
    'default_question_seconds', v_quiz.default_question_seconds,
    'visibility', v_quiz.visibility,
    'created_at', v_quiz.created_at,
    'questions', coalesce((
      select json_agg(
        json_build_object(
          'id', q.id,
          'ord', q.ord,
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
grant execute on function quiz_get_for_edit(text, uuid) to anon;

create or replace function quiz_update_settings(
  p_session_token text,
  p_quiz_id uuid,
  p_title text,
  p_description text,
  p_speed_bonus_enabled boolean,
  p_speed_bonus_pct int,
  p_default_question_seconds int
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);

  if char_length(trim(p_title)) = 0 then
    raise exception 'Dê um título para o quiz.';
  end if;
  if p_speed_bonus_pct < 0 or p_speed_bonus_pct > 100 then
    raise exception 'O bônus de velocidade precisa ser entre 0%% e 100%%.';
  end if;

  update quizzes
  set title = trim(p_title),
      description = nullif(trim(p_description), ''),
      speed_bonus_enabled = p_speed_bonus_enabled,
      speed_bonus_pct = p_speed_bonus_pct,
      default_question_seconds = p_default_question_seconds,
      updated_at = now()
  where id = p_quiz_id;
end;
$$;
grant execute on function quiz_update_settings(text, uuid, text, text, boolean, int, int) to anon;

create or replace function quiz_question_upsert(
  p_session_token text,
  p_quiz_id uuid,
  p_question_id uuid,
  p_ord int,
  p_text text,
  p_options jsonb,
  p_correct_key text,
  p_points int,
  p_media_url text default null,
  p_media_type text default null,
  p_question_seconds int default null,
  p_tags text[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_id uuid;
  v_tags text[] := coalesce((select array_agg(distinct nullif(trim(t), '')) from unnest(p_tags) as t where trim(t) <> ''), '{}');
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);

  if char_length(trim(p_text)) = 0 then
    raise exception 'A pergunta precisa ter um texto.';
  end if;
  if p_points <= 0 then
    raise exception 'A pontuação precisa ser maior que zero.';
  end if;
  if p_media_url is not null and p_media_type is null then
    raise exception 'Informe o tipo da mídia (imagem ou vídeo).';
  end if;
  perform validate_options(p_options, p_correct_key);

  if p_question_id is null then
    insert into quiz_questions (
      quiz_id, ord, text, options, correct_key, points, media_url, media_type, question_seconds, tags
    ) values (
      p_quiz_id, p_ord, trim(p_text), p_options, p_correct_key, p_points, p_media_url, p_media_type, p_question_seconds, v_tags
    )
    returning id into v_id;
  else
    update quiz_questions
    set ord = p_ord,
        text = trim(p_text),
        options = p_options,
        correct_key = p_correct_key,
        points = p_points,
        media_url = p_media_url,
        media_type = p_media_type,
        question_seconds = p_question_seconds,
        tags = v_tags
    where id = p_question_id and quiz_id = p_quiz_id
    returning id into v_id;

    if v_id is null then
      raise exception 'Pergunta não encontrada neste quiz.';
    end if;
  end if;

  update quizzes set updated_at = now() where id = p_quiz_id;

  return v_id;
end;
$$;
grant execute on function quiz_question_upsert(text, uuid, uuid, int, text, jsonb, text, int, text, text, int, text[]) to anon;

create or replace function quiz_question_delete(p_session_token text, p_quiz_id uuid, p_question_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);

  delete from quiz_questions where id = p_question_id and quiz_id = p_quiz_id;
  if not found then
    raise exception 'Pergunta não encontrada neste quiz.';
  end if;

  -- Renumera para fechar o "buraco" deixado no ord, senão uma pergunta nova
  -- adicionada depois poderia empatar com uma existente na ordenação.
  with renumeradas as (
    select id, row_number() over (order by ord) - 1 as novo_ord
    from quiz_questions
    where quiz_id = p_quiz_id
  )
  update quiz_questions q
  set ord = r.novo_ord
  from renumeradas r
  where q.id = r.id;

  update quizzes set updated_at = now() where id = p_quiz_id;
end;
$$;
grant execute on function quiz_question_delete(text, uuid, uuid) to anon;

create or replace function quiz_question_reorder(p_session_token text, p_quiz_id uuid, p_question_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_id uuid;
  v_ord int := 0;
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);

  foreach v_id in array p_question_ids loop
    update quiz_questions set ord = v_ord
    where id = v_id and quiz_id = p_quiz_id;
    v_ord := v_ord + 1;
  end loop;

  update quizzes set updated_at = now() where id = p_quiz_id;
end;
$$;
grant execute on function quiz_question_reorder(text, uuid, uuid[]) to anon;

create or replace function quiz_delete(p_session_token text, p_quiz_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);
  delete from quizzes where id = p_quiz_id;
end;
$$;
grant execute on function quiz_delete(text, uuid) to anon;

-- Pede para o quiz entrar no banco de perguntas público. Fica 'pending' até
-- um admin aprovar (ver 11_rpc_admin.sql) — nunca vira 'public' direto.
create or replace function quiz_request_public(p_session_token text, p_quiz_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_question_count int;
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);

  select count(*) into v_question_count from quiz_questions where quiz_id = p_quiz_id;
  if v_question_count = 0 then
    raise exception 'Adicione pelo menos uma pergunta antes de pedir publicação.';
  end if;

  update quizzes
  set visibility = 'pending', updated_at = now()
  where id = p_quiz_id and visibility = 'private';

  if not found then
    raise exception 'Esse quiz já está público ou aguardando revisão.';
  end if;
end;
$$;
grant execute on function quiz_request_public(text, uuid) to anon;

-- Volta para privado a qualquer momento (de 'pending' ou 'public'), sem
-- precisar de aprovação — só publicar de novo é que exige revisão.
create or replace function quiz_make_private(p_session_token text, p_quiz_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);

  update quizzes
  set visibility = 'private', updated_at = now()
  where id = p_quiz_id;
end;
$$;
grant execute on function quiz_make_private(text, uuid) to anon;
