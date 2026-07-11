-- Migração para bancos que já rodaram 01-08 antes do banco de perguntas
-- público existir. Instalação nova: NÃO rode este arquivo — 01_schema.sql
-- já cria essas colunas direto.

alter table creators
  add column if not exists is_admin boolean not null default false;

alter table quizzes
  add column if not exists visibility text not null default 'private'
    check (visibility in ('private', 'pending', 'public'));
create index if not exists quizzes_visibility_idx on quizzes(visibility);

alter table quiz_questions
  add column if not exists tags text[] not null default '{}';
create index if not exists quiz_questions_tags_gin_idx on quiz_questions using gin(tags);

-- Depois de rodar isto, marque a SUA conta como admin (troque 'seu_usuario'):
-- update creators set is_admin = true where username = 'seu_usuario';
