# Quiz Piras na Física

Sistema de quiz ao vivo, estilo Kahoot, em português: quem cria uma conta
(usuário/senha/pergunta secreta, sem e-mail) pode criar e gerenciar vários
quizzes; qualquer pessoa entra durante a execução com um código de 6 dígitos,
sem precisar de conta. Também há um banco de perguntas público (com tags de
tema) e um modo de prática solo, sem PIN, para testar conhecimento sozinho
ou revisar antes de aplicar a uma turma. Front-end estático (GitHub Pages) +
Supabase como único backend.

## Estrutura

- `docs/` — o site em si (é o que o GitHub Pages publica). HTML + CSS + JS puro, sem build.
- `supabase/sql/` — schema, RLS e RPCs do banco, para rodar no SQL editor do Supabase.
- `gincana/` — projeto anterior (evento único), mantido como referência local, fora do Git.

## Configurar o backend (Supabase)

### Instalação nova (projeto Supabase vazio)

1. Crie um projeto em [supabase.com](https://supabase.com) (plano gratuito é suficiente para começar).
2. No **SQL Editor** do projeto, rode os arquivos de `supabase/sql/` **nesta ordem** (pule o `09`, o `12` e o `13`, que são só migrações para bancos já existentes):
   `01_schema.sql` → `02_rls.sql` → `03_rpc_creators.sql` → `04_rpc_quizzes.sql` → `05_rpc_sessions.sql` → `06_rpc_gameplay.sql` → `07_rpc_scoreboard.sql` → `08_realtime_publication.sql` → `10_rpc_bank.sql` → `11_rpc_admin.sql`.
3. Em **Configurações → API**, copie a **Project URL** e a chave **anon/public**.
4. Cole esses dois valores em [`docs/assets/js/config.js`](docs/assets/js/config.js).
5. Crie sua conta pelo site (`login.html`) e depois marque-a como administradora direto no **Table Editor** (tabela `creators`, coluna `is_admin` → `true`) — é quem aprova pedidos de publicação no banco de perguntas.

### Banco já rodando (já tinha 01-08 antes do banco de perguntas existir)

1. Rode de novo (são todos `create or replace`, seguro repetir): `03_rpc_creators.sql` → `04_rpc_quizzes.sql`.
   (o `03` mudou nesta versão — `creator_login`/`creator_register`/`creator_my_quizzes` passaram a devolver `is_admin`/`visibility`; pular esse passo faz o botão "Moderação" nunca aparecer, mesmo com a conta já marcada como admin no banco.)
2. Rode, nesta ordem: `09_migracao_banco_perguntas.sql` → `10_rpc_bank.sql` → `11_rpc_admin.sql`.
3. Marque sua conta como admin: `update creators set is_admin = true where username = 'seu_usuario';`
4. Saia e entre de novo no site com essa conta (o navegador só sabe se você é admin no momento do login).

### Banco já rodando, sem avatares/prática com bônus (versão anterior a jul/2026)

Rode **somente** `12_migracao_avatares_e_pratica.sql`, uma única vez, de
preferência fora de horário de jogo ao vivo. Ele adiciona os avatares emoji
(criadores e participantes), o RPC de troca de avatar e faz o modo praticar
devolver tempos e configuração de bônus de velocidade. Instalações novas não
precisam dele (os arquivos canônicos já incluem tudo).

### Banco já rodando, sem rastreio de origem das importações (versão anterior a jul/2026)

Rode `13_migracao_origem_importacao.sql` e, em seguida, rode o
`10_rpc_bank.sql` de novo (é `create or replace`, seguro repetir). Isso adiciona
a coluna `source_question_id` em `quiz_questions`, troca a importação do banco
público para o modo em massa (várias perguntas de uma vez) e faz o banco
esconder perguntas já importadas — e não devolver cópias importadas ao banco
quando o quiz que as recebeu vira público. Instalações novas não precisam dele.

### Semente inicial do banco de perguntas

`supabase/seed/perguntas_copa_importar.json` tem as 45 perguntas do quiz da
gincana (Copa do Mundo), já convertidas para o formato de importação. Para
usá-las: crie um quiz em `painel.html`, abra `editar.html`, use "Importar
arquivo" com esse JSON, e depois peça a publicação e aprove-a você mesmo
(você é admin) para que apareça no banco público.

## Rodar localmente

Qualquer servidor estático simples funciona (precisa ser HTTP, não `file://`, por causa dos ES modules):

```
npx serve docs
```

Depois acesse `http://localhost:3000` (ou a porta indicada).

## Publicar no GitHub Pages (quiz.pirasnafisica.com.br)

1. Suba este repositório para o GitHub.
2. Em **Settings → Pages**, defina a fonte como branch `main`, pasta `/docs`.
3. No provedor de DNS do domínio, crie um registro `CNAME` para `quiz` apontando para `SEU-USUARIO.github.io.`
4. Depois que o DNS propagar, defina `quiz.pirasnafisica.com.br` como domínio customizado em Settings → Pages (o arquivo `docs/CNAME` já contém esse valor) e habilite "Enforce HTTPS".

## Banco de perguntas público e prática solo

- Qualquer criador pode pedir para um quiz seu entrar no banco público (botão em `editar.html`); fica "aguardando revisão" até um admin aprovar em `moderacao.html`. Voltar para privado não precisa de aprovação.
- Perguntas de quizzes públicos ficam pesquisáveis por tag/texto (`editar.html`, seção "Banco de perguntas") e importáveis para qualquer outro quiz.
- Tags são texto livre, com sugestão das já usadas (sem lista fixa).
- Upload de perguntas em massa: arquivo `.json` com um array de objetos `{ text, options, correct_key, points, media_url, media_type, question_seconds, tags }` (só `text`/`options`/`correct_key` são obrigatórios).
- Modo prática (`praticar.html`) é solo, sem PIN nem sessão ao vivo: funciona em qualquer quiz público (sem login) ou nos seus próprios quizzes privados/pendentes (logado).

## Limitações aceitas (v1)

- Conta de criador é só usuário/senha/pergunta secreta, sem e-mail: esquecer o *usuário* não tem recuperação possível (só a senha, via pergunta secreta).
- Pergunta secreta é um mecanismo de recuperação mais fraco que e-mail — aceitável para um quiz escolar, sem dado sensível.
- Sem moderação de apelido de participante além do limite de tamanho e do botão de expulsar do host.
- Sem rate limiting além do padrão do Supabase — aceitável na escala inicial.
- `is_admin` é um flag manual (Table Editor), sem tela de gestão de admins.
