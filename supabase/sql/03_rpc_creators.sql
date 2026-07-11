-- RPCs de conta do criador: cadastro, login, logout, recuperação de senha
-- e listagem de quizzes. Sem e-mail — recuperação é por pergunta secreta.

create or replace function normalize_secret_answer(p_answer text)
returns text
language sql
immutable
as $$
  select lower(trim(p_answer))
$$;

-- Mudar as colunas de retorno de uma função exige apagar antes: CREATE OR
-- REPLACE só aceita mudar o corpo ou acrescentar parâmetros de ENTRADA com
-- valor padrão, nunca a lista de colunas de saída (RETURNS TABLE).
drop function if exists creator_register(text, text, text, text);
drop function if exists creator_register(text, text, text, text, text);
create or replace function creator_register(
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
create or replace function creator_login(p_username text, p_password text)
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

create or replace function creator_logout(p_session_token text)
returns void
language sql
security definer
set search_path = public, extensions
as $$
  delete from creator_sessions where token_hash = extensions.digest(p_session_token, 'sha256')
$$;
grant execute on function creator_logout(text) to anon;

create or replace function creator_id_from_session(p_session_token text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid;
begin
  update creator_sessions
  set last_used_at = now()
  where token_hash = extensions.digest(p_session_token, 'sha256')
  returning creator_id into v_creator_id;

  if v_creator_id is null then
    raise exception 'Sessão expirada, faça login novamente.';
  end if;

  return v_creator_id;
end;
$$;

create or replace function creator_recover_get_question(p_username text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_question text;
begin
  select secret_question into v_question from creators where username = trim(p_username);
  if not found then
    raise exception 'Usuário não encontrado.';
  end if;
  return v_question;
end;
$$;
grant execute on function creator_recover_get_question(text) to anon;

create or replace function creator_recover_reset(
  p_username text,
  p_secret_answer text,
  p_new_password text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator creators%rowtype;
begin
  if char_length(coalesce(p_new_password, '')) < 8 then
    raise exception 'A nova senha precisa ter pelo menos 8 caracteres.';
  end if;

  select * into v_creator from creators where username = trim(p_username);

  if not found then
    raise exception 'Resposta secreta incorreta.';
  end if;
  if v_creator.secret_answer_hash <> extensions.crypt(normalize_secret_answer(p_secret_answer), v_creator.secret_answer_hash) then
    raise exception 'Resposta secreta incorreta.';
  end if;

  update creators
  set password_hash = extensions.crypt(p_new_password, extensions.gen_salt('bf'))
  where id = v_creator.id;

  -- Troca de senha invalida sessões existentes, por segurança.
  delete from creator_sessions where creator_id = v_creator.id;
end;
$$;
grant execute on function creator_recover_reset(text, text, text) to anon;

drop function if exists creator_my_quizzes(text);
create or replace function creator_my_quizzes(p_session_token text)
returns table (
  quiz_id uuid,
  title text,
  description text,
  visibility text,
  created_at timestamptz,
  updated_at timestamptz,
  last_used_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
begin
  return query
    select q.id, q.title, q.description, q.visibility, q.created_at, q.updated_at, q.last_used_at
    from quizzes q
    where q.creator_id = v_creator_id
    order by q.updated_at desc;
end;
$$;
grant execute on function creator_my_quizzes(text) to anon;
