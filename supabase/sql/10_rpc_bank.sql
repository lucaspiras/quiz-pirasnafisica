-- RPCs do banco de perguntas público e do modo prática solo.
-- Só enxergam conteúdo de quizzes com visibility = 'public' (aprovados por
-- um admin) ou, no modo prática, o próprio dono vendo seu quiz privado.
-- Aqui é seguro devolver correct_key: são perguntas já públicas por natureza
-- (banco de consulta / autoestudo), não uma partida ao vivo com gabarito
-- escondido.

-- Perguntas com source_question_id ficam fora do banco: são cópias importadas
-- e devolvê-las duplicaria a original quando o quiz de destino vira público.
-- Com p_exclude_quiz_id, também some o que aquele quiz já importou (ou as
-- perguntas dele próprio), para o dono não importar duas vezes.
create or replace function question_bank_search(
  p_tags text[] default null,
  p_search text default null,
  p_exclude_quiz_id uuid default null
)
returns table (
  question_id uuid,
  quiz_id uuid,
  quiz_title text,
  text text,
  options jsonb,
  correct_key text,
  points int,
  media_url text,
  media_type text,
  tags text[]
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select q.id, q.quiz_id, z.title, q.text, q.options, q.correct_key, q.points, q.media_url, q.media_type, q.tags
  from quiz_questions q
  join quizzes z on z.id = q.quiz_id
  where z.visibility = 'public'
    and q.source_question_id is null
    and (p_tags is null or array_length(p_tags, 1) is null or q.tags && p_tags)
    and (p_search is null or trim(p_search) = '' or q.text ilike '%' || trim(p_search) || '%')
    and (
      p_exclude_quiz_id is null
      or (
        q.quiz_id <> p_exclude_quiz_id
        and not exists (
          select 1 from quiz_questions m
          where m.quiz_id = p_exclude_quiz_id and m.source_question_id = q.id
        )
      )
    )
  order by q.quiz_id, q.ord
  limit 200
$$;
grant execute on function question_bank_search(text[], text, uuid) to anon;

create or replace function question_bank_tags()
returns table (tag text)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select distinct unnest(q.tags) as tag
  from quiz_questions q
  join quizzes z on z.id = q.quiz_id
  where z.visibility = 'public'
    and q.source_question_id is null
  order by tag
$$;
grant execute on function question_bank_tags() to anon;

-- Importa várias perguntas do banco de uma vez, na ordem em que foram
-- selecionadas. Perguntas que o quiz já importou antes são puladas em silêncio
-- (proteção contra duplo clique / abas concorrentes).
create or replace function quiz_questions_import_from_bank(
  p_session_token text,
  p_quiz_id uuid,
  p_source_question_ids uuid[]
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_source quiz_questions%rowtype;
  v_next_ord int;
  v_count int := 0;
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);

  if p_source_question_ids is null or array_length(p_source_question_ids, 1) is null then
    raise exception 'Selecione pelo menos uma pergunta para importar.';
  end if;

  select coalesce(max(ord) + 1, 0) into v_next_ord from quiz_questions where quiz_id = p_quiz_id;

  for v_source in
    select q.*
    from quiz_questions q
    join quizzes z on z.id = q.quiz_id
    where q.id = any(p_source_question_ids)
      and z.visibility = 'public'
      and q.quiz_id <> p_quiz_id
    order by array_position(p_source_question_ids, q.id)
  loop
    if exists (
      select 1 from quiz_questions m
      where m.quiz_id = p_quiz_id and m.source_question_id = v_source.id
    ) then
      continue;
    end if;

    insert into quiz_questions (
      quiz_id, ord, text, options, correct_key, points, media_url, media_type,
      question_seconds, tags, source_question_id
    ) values (
      p_quiz_id, v_next_ord, v_source.text, v_source.options, v_source.correct_key, v_source.points,
      v_source.media_url, v_source.media_type, v_source.question_seconds, v_source.tags,
      -- Se a fonte já for uma cópia, aponta para a origem raiz da cadeia.
      coalesce(v_source.source_question_id, v_source.id)
    );

    v_next_ord := v_next_ord + 1;
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Nenhuma pergunta nova para importar — as selecionadas já estão neste quiz.';
  end if;

  update quizzes set updated_at = now() where id = p_quiz_id;

  return v_count;
end;
$$;
grant execute on function quiz_questions_import_from_bank(text, uuid, uuid[]) to anon;

-- Importação em massa a partir de um arquivo JSON (ver formato documentado
-- em editar.html / README.md). Reaproveita as mesmas validações do upsert
-- de pergunta individual.
create or replace function quiz_questions_bulk_import(p_session_token text, p_quiz_id uuid, p_questions jsonb)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
  v_next_ord int;
  v_item jsonb;
  v_count int := 0;
  v_options jsonb;
  v_correct_key text;
  v_text text;
  v_points int;
  v_media_url text;
  v_media_type text;
  v_seconds int;
  v_tags text[];
begin
  perform assert_owns_quiz(v_creator_id, p_quiz_id);

  if jsonb_typeof(p_questions) <> 'array' then
    raise exception 'O arquivo precisa conter uma lista (array) de perguntas.';
  end if;
  if jsonb_array_length(p_questions) = 0 then
    raise exception 'O arquivo não tem nenhuma pergunta.';
  end if;

  select coalesce(max(ord) + 1, 0) into v_next_ord from quiz_questions where quiz_id = p_quiz_id;

  for v_item in select * from jsonb_array_elements(p_questions) loop
    v_text := trim(coalesce(v_item ->> 'text', ''));
    v_options := coalesce(v_item -> 'options', '[]'::jsonb);
    v_correct_key := v_item ->> 'correct_key';
    v_points := coalesce((v_item ->> 'points')::int, 100);
    v_media_url := nullif(v_item ->> 'media_url', '');
    v_media_type := nullif(v_item ->> 'media_type', '');
    v_seconds := nullif(v_item ->> 'question_seconds', '')::int;

    select coalesce(array_agg(distinct nullif(trim(t), '')) filter (where trim(t) <> ''), '{}')
      into v_tags
      from jsonb_array_elements_text(coalesce(v_item -> 'tags', '[]'::jsonb)) as t;

    if v_text = '' then
      raise exception 'Uma das perguntas do arquivo está sem texto.';
    end if;
    if v_points <= 0 then
      raise exception 'Uma das perguntas do arquivo tem pontuação inválida.';
    end if;
    if v_media_url is not null and v_media_type is null then
      raise exception 'Uma das perguntas tem mídia sem informar o tipo (image/youtube).';
    end if;
    perform validate_options(v_options, v_correct_key);

    insert into quiz_questions (
      quiz_id, ord, text, options, correct_key, points, media_url, media_type, question_seconds, tags
    ) values (
      p_quiz_id, v_next_ord, v_text, v_options, v_correct_key, v_points, v_media_url, v_media_type, v_seconds, v_tags
    );

    v_next_ord := v_next_ord + 1;
    v_count := v_count + 1;
  end loop;

  update quizzes set updated_at = now() where id = p_quiz_id;

  return v_count;
end;
$$;
grant execute on function quiz_questions_bulk_import(text, uuid, jsonb) to anon;

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
    count(q.id),
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

-- Modo prática solo: sem PIN, sem sessão ao vivo. Acessível a qualquer um
-- para quizzes 'public'; para quizzes 'private'/'pending', só o dono (via
-- p_session_token) pode praticar o próprio quiz antes de publicá-lo.
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
