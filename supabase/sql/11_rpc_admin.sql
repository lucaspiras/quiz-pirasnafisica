-- RPCs de moderação: aprovar/rejeitar pedidos de publicação no banco
-- público. Restrito a contas com creators.is_admin = true (definido
-- manualmente pelo Table Editor do Supabase — ver 09_migracao_banco_perguntas.sql).

create or replace function assert_is_admin(p_creator_id uuid)
returns void
language plpgsql
stable
as $$
begin
  if not exists (select 1 from creators where id = p_creator_id and is_admin) then
    raise exception 'Apenas administradores podem fazer isso.';
  end if;
end;
$$;

create or replace function admin_pending_quizzes(p_session_token text)
returns table (
  quiz_id uuid,
  title text,
  description text,
  creator_username text,
  question_count bigint,
  requested_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
begin
  perform assert_is_admin(v_creator_id);

  return query
    select z.id, z.title, z.description, c.username, count(q.id), z.updated_at
    from quizzes z
    join creators c on c.id = z.creator_id
    left join quiz_questions q on q.quiz_id = z.id
    where z.visibility = 'pending'
    group by z.id, z.title, z.description, c.username, z.updated_at
    order by z.updated_at asc;
end;
$$;
grant execute on function admin_pending_quizzes(text) to anon;

create or replace function admin_review_quiz(p_session_token text, p_quiz_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_creator_id uuid := creator_id_from_session(p_session_token);
begin
  perform assert_is_admin(v_creator_id);

  update quizzes
  set visibility = case when p_approve then 'public' else 'private' end,
      updated_at = now()
  where id = p_quiz_id and visibility = 'pending';

  if not found then
    raise exception 'Esse quiz não está mais aguardando revisão.';
  end if;
end;
$$;
grant execute on function admin_review_quiz(text, uuid, boolean) to anon;
