-- Migração: rastreio de origem das perguntas importadas do banco público.
-- Rode SÓ em bancos que já existiam antes desta versão (instalação nova já
-- ganha tudo pelo 01 e pelo 10). Depois deste arquivo, rode o 10 de novo
-- (create or replace) para recriar as funções do banco de perguntas.
--
-- O que muda:
--  * quiz_questions.source_question_id guarda de qual pergunta pública a
--    cópia foi importada — assim o banco esconde o que o quiz já importou e
--    não devolve cópias ao banco quando o quiz de destino vira público.
--  * A importação passa a ser em massa (quiz_questions_import_from_bank com
--    array de ids); as versões antigas das funções são removidas aqui porque
--    a assinatura mudou (create or replace não cobre mudança de parâmetros).
--
-- Cópias importadas ANTES desta migração não têm como ser reconhecidas e
-- ficam como perguntas "originais" — comportamento igual ao de antes.

alter table quiz_questions
  add column if not exists source_question_id uuid references quiz_questions(id) on delete set null;

create index if not exists quiz_questions_source_idx
  on quiz_questions(source_question_id) where source_question_id is not null;

drop function if exists question_bank_search(text[], text);
drop function if exists quiz_question_import_from_bank(text, uuid, uuid, int);

-- Agora rode o 10_rpc_bank.sql de novo.
