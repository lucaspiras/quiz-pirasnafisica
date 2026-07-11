-- RPCs de leitura pública (placar e respostas da rodada atual).
-- Não recebem segredo: não vazam o gabarito nem dados sensíveis.

-- RETURNS TABLE com coluna nova exige drop antes (CREATE OR REPLACE não
-- aceita mudar a lista de colunas de saída — erro 42P13).
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

-- Contagem de quem já respondeu a pergunta atual, mesmo enquanto o tempo
-- ainda está aberto. Não vaza qual alternativa foi escolhida nem se está
-- certa, só a contagem — por isso pode ser pública, sem segredo de host.
create or replace function session_current_answer_count(p_session_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public, extensions
as $$
  select count(*)::bigint
  from session_state s
  join answers a on a.session_id = s.session_id and a.question_id = s.current_question_id
  where s.session_id = p_session_id
$$;
grant execute on function session_current_answer_count(uuid) to anon;
