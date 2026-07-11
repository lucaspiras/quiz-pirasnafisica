-- RLS: participante fica sem conta (nickname + PIN); o criador tem conta
-- (usuário/senha), mas nunca acessa o banco diretamente — sempre via RPC.
-- Tabelas sensíveis ficam com RLS ativado e SEM NENHUMA policy — só são
-- acessíveis através das RPCs SECURITY DEFINER (arquivos 03-07).

alter table creators enable row level security;
alter table creator_sessions enable row level security;
alter table quizzes enable row level security;
alter table quiz_questions enable row level security;
alter table answers enable row level security;
alter table game_sessions enable row level security;
alter table participants enable row level security;
alter table session_state enable row level security;
alter table session_hosts enable row level security;
alter table participant_secrets enable row level security;

-- Estas três tabelas nunca guardam segredos nem o gabarito, então podem ser
-- lidas diretamente por qualquer um — necessário para o Realtime entregar
-- postgres_changes a clientes anônimos (que transmite a linha inteira, por
-- isso os hashes de segredo vivem em session_hosts/participant_secrets,
-- que ficam sem NENHUMA policy, só acessíveis via RPC SECURITY DEFINER).
create policy game_sessions_select_anon on game_sessions
  for select to anon using (true);

create policy participants_select_anon on participants
  for select to anon using (true);

create policy session_state_select_anon on session_state
  for select to anon using (true);

-- Helper de verificação de segredo (token/host_secret/join_secret).
create or replace function token_matches(p_hash bytea, p_raw text)
returns boolean
language sql
stable
as $$
  select p_hash = extensions.digest(p_raw, 'sha256')
$$;

-- Gerador de token aleatório de alta entropia (sessão de criador, host
-- secret, join secret) — usado a partir do arquivo 03 em diante.
create or replace function generate_url_safe_token(p_bytes int default 18)
returns text
language sql
volatile
as $$
  select translate(
    encode(extensions.gen_random_bytes(p_bytes), 'base64'),
    '+/=',
    '-_'
  )
$$;
