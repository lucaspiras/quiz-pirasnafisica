-- Habilita o Realtime (postgres_changes) para as tabelas que os clientes
-- precisam observar ao vivo. session_state já tem uma policy de SELECT
-- pública (02_rls.sql); game_sessions e participants também precisam estar
-- na publicação para o board/lobby verem status e lista de participantes
-- em tempo real (a leitura em si passa pelas views *_public / RPCs).

alter publication supabase_realtime add table session_state;
alter publication supabase_realtime add table game_sessions;
alter publication supabase_realtime add table participants;
