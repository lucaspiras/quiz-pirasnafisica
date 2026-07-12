-- Schema do sistema de quiz ao vivo (quiz.pirasnafisica.com.br)
-- Instalação nova: rode 01, 02, 03, 04, 05, 06, 07, 08, 10, 11 nessa ordem
-- (pule o 09, o 12, o 13 e o 14, que são migrações para bancos já existentes).
-- Banco já existente (rodou até o 08 antes desta versão): rode 04 de novo
-- (create or replace), depois 09, 10, 11.
-- Banco já existente sem avatares/prática com bônus: rode só o 12.
-- Banco já existente sem rastreio de origem das perguntas importadas:
-- rode o 13 e depois o 10 de novo.
-- Banco já existente sem perfil/histórico/login de participante: rode só o 14.

create extension if not exists pgcrypto with schema extensions;

-- Conta do criador: usuário/senha/pergunta secreta, sem e-mail. Senha e
-- resposta secreta usam bcrypt (extensions.crypt + gen_salt('bf')) — o
-- algoritmo certo para segredos escolhidos por humanos (baixa entropia,
-- precisa de custo computacional contra força bruta). Isso é diferente do
-- digest(...,'sha256') usado em tokens já aleatórios (sessão, PIN, etc.),
-- que não precisam desse custo extra.
create table creators (
  id                  uuid primary key default gen_random_uuid(),
  username            text not null unique check (username ~ '^[a-zA-Z0-9_]{3,24}$'),
  password_hash       text not null,
  secret_question     text not null check (secret_question in (
    'Nome do seu primeiro animal de estimação',
    'Cidade onde você nasceu',
    'Nome da sua escola no ensino fundamental',
    'Comida favorita da sua infância',
    'Apelido que você tinha quando criança'
  )),
  secret_answer_hash  text not null,
  -- Sem sistema de papéis: um único flag manual (defina via Table Editor do
  -- Supabase para a sua própria conta) controla quem pode moderar pedidos de
  -- publicação no banco de perguntas compartilhado.
  is_admin            boolean not null default false,
  -- Avatar de perfil: um emoji escolhido de uma grade curada no frontend.
  -- Limite de 16 chars comporta emojis compostos (ZWJ) sem aceitar texto livre.
  avatar_emoji        text check (char_length(avatar_emoji) <= 16),
  created_at          timestamptz not null default now(),
  last_login_at       timestamptz
);

create table creator_sessions (
  id              uuid primary key default gen_random_uuid(),
  creator_id      uuid not null references creators(id) on delete cascade,
  token_hash      bytea not null unique,
  created_at      timestamptz not null default now(),
  last_used_at    timestamptz not null default now()
);

create table quizzes (
  id                          uuid primary key default gen_random_uuid(),
  creator_id                  uuid not null references creators(id) on delete cascade,
  title                       text not null check (char_length(title) between 1 and 120),
  description                 text check (char_length(description) <= 500),
  speed_bonus_enabled         boolean not null default false,
  speed_bonus_pct             int not null default 50 check (speed_bonus_pct between 0 and 100),
  default_question_seconds    int not null default 20 check (default_question_seconds between 5 and 300),
  -- Banco de perguntas compartilhado: 'private' (padrão) só o criador vê;
  -- 'pending' foi pedido para publicar mas ainda não foi revisado; 'public'
  -- foi aprovado por um admin e entra no banco/na lista de prática pública.
  -- Virar 'private' de novo não precisa de aprovação; virar 'public' sempre precisa.
  visibility                  text not null default 'private' check (visibility in ('private', 'pending', 'public')),
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  last_used_at                timestamptz,
  is_archived                 boolean not null default false
);
create index quizzes_creator_idx on quizzes(creator_id);
create index quizzes_visibility_idx on quizzes(visibility);

create table quiz_questions (
  id                uuid primary key default gen_random_uuid(),
  quiz_id           uuid not null references quizzes(id) on delete cascade,
  ord               int not null default 0,
  text              text not null check (char_length(text) between 1 and 500),
  options           jsonb not null,
  correct_key       text not null,
  points            int not null default 100 check (points > 0),
  media_url         text,
  media_type        text check (media_type in ('image', 'youtube')),
  question_seconds  int check (question_seconds between 5 and 300),
  -- Tags de tema em texto livre (ex: "Cinemática", "Copa do Mundo"), usadas
  -- para filtrar o banco de perguntas público. GIN index para buscas por
  -- sobreposição (tags && array[...]).
  tags              text[] not null default '{}',
  -- Quando a pergunta foi importada do banco público, guarda a pergunta de
  -- origem. Serve para: (a) esconder do banco o que o quiz já importou e
  -- (b) não devolver cópias ao banco se este quiz virar público (duplicaria).
  -- Se a origem for apagada, a cópia vira "original" (set null) e segue viva.
  source_question_id uuid references quiz_questions(id) on delete set null,
  created_at        timestamptz not null default now(),
  constraint quiz_questions_options_shape check (
    jsonb_typeof(options) = 'array'
    and jsonb_array_length(options) between 2 and 4
  )
);
create index quiz_questions_quiz_idx on quiz_questions(quiz_id, ord);
create index quiz_questions_tags_gin_idx on quiz_questions using gin(tags);
create index quiz_questions_source_idx on quiz_questions(source_question_id) where source_question_id is not null;

create table game_sessions (
  id                    uuid primary key default gen_random_uuid(),
  quiz_id               uuid not null references quizzes(id) on delete cascade,
  pin                   text not null,
  status                text not null default 'lobby' check (status in ('lobby', 'running', 'finished')),
  speed_bonus_enabled   boolean not null,
  speed_bonus_pct       int not null,
  created_at            timestamptz not null default now(),
  ended_at              timestamptz
);
-- PIN só precisa ser único entre sessões ainda não finalizadas.
create unique index game_sessions_pin_active_uidx on game_sessions(pin) where status <> 'finished';

-- Segredo do host separado de game_sessions: game_sessions precisa de uma
-- policy de leitura pública (para Realtime), e o Realtime transmite a linha
-- inteira — então nenhum hash de segredo pode viver numa tabela lida por anon.
create table session_hosts (
  session_id        uuid primary key references game_sessions(id) on delete cascade,
  host_secret_hash  bytea not null
);

create table session_state (
  session_id            uuid primary key references game_sessions(id) on delete cascade,
  question_status       text not null default 'idle' check (
    question_status in ('idle', 'shown', 'open', 'closed', 'revealed')
  ),
  current_question_id   uuid references quiz_questions(id),
  q_index               int,
  q_total               int,
  q_text                text,
  q_options             jsonb,
  q_points              int,
  q_media_url           text,
  q_media_type          text,
  q_seconds             int,
  question_started_at   timestamptz,
  reveal_correct_key    text,
  updated_at            timestamptz not null default now()
);

create table participants (
  id                uuid primary key default gen_random_uuid(),
  session_id        uuid not null references game_sessions(id) on delete cascade,
  nickname          text not null check (char_length(nickname) between 1 and 24),
  -- Avatar emoji do convidado (mesma regra de creators.avatar_emoji). Esta
  -- tabela é lida por anon via Realtime, então só dados públicos aqui.
  avatar_emoji      text check (char_length(avatar_emoji) <= 16),
  is_kicked         boolean not null default false,
  joined_at         timestamptz not null default now()
);
-- Uniqueness sobre lower(nickname) é uma expressão, não uma coluna simples
-- — por isso precisa ser um índice único, não um UNIQUE(...) de tabela.
create unique index participants_session_nickname_uidx on participants(session_id, lower(nickname));

-- Segredo do participante separado pelo mesmo motivo que session_hosts acima.
create table participant_secrets (
  participant_id    uuid primary key references participants(id) on delete cascade,
  join_secret_hash  bytea not null
);

-- Vínculo participante ↔ conta (quando o jogador entra logado). Fica FORA de
-- participants pelo mesmo motivo dos segredos: participants é lida por anon
-- via Realtime (linha inteira), e creator_id ali viraria um mapa público de
-- qual conta usa qual apelido em cada sala. Sem policies — só via RPC.
create table participant_accounts (
  participant_id  uuid primary key references participants(id) on delete cascade,
  creator_id      uuid not null references creators(id) on delete cascade,
  linked_at       timestamptz not null default now()
);
create index participant_accounts_creator_idx on participant_accounts(creator_id);

create table answers (
  id              uuid primary key default gen_random_uuid(),
  session_id      uuid not null references game_sessions(id) on delete cascade,
  question_id     uuid not null references quiz_questions(id) on delete cascade,
  participant_id  uuid not null references participants(id) on delete cascade,
  choice_key      text not null,
  is_correct      boolean not null,
  response_ms     int not null,
  points_awarded  int not null default 0,
  counted         boolean not null default false,
  answered_at     timestamptz not null default now(),
  unique (session_id, question_id, participant_id)
);

-- Histórico pessoal do modo praticar. A pontuação é calculada no navegador e
-- o gabarito chega ao cliente, então este número é fraudável — por isso NUNCA
-- vira ranking público: só o próprio dono vê (via RPC). O servidor guarda no
-- máximo as 20 tentativas mais recentes por (conta, quiz).
create table practice_plays (
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
create index practice_plays_creator_idx on practice_plays(creator_id, played_at desc);
create index practice_plays_creator_quiz_idx on practice_plays(creator_id, quiz_id, played_at desc);
