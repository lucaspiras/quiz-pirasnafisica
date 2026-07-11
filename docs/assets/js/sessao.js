// Sessão do criador (conta usuário/senha): um único par { creatorId,
// username, sessionToken } guardado no localStorage, válido em qualquer
// aparelho em que o criador fizer login.

const CHAVE = 'quizpf_sessao';

export const PERGUNTAS_SECRETAS = [
  'Nome do seu primeiro animal de estimação',
  'Cidade onde você nasceu',
  'Nome da sua escola no ensino fundamental',
  'Comida favorita da sua infância',
  'Apelido que você tinha quando criança',
];

export function salvarSessao({ creatorId, username, sessionToken, isAdmin, avatarEmoji }) {
  localStorage.setItem(CHAVE, JSON.stringify({
    creatorId, username, sessionToken, isAdmin: !!isAdmin, avatarEmoji: avatarEmoji || null,
  }));
}

// Atualiza um campo da sessão salva (ex.: troca de avatar no painel).
export function atualizarSessao(campos) {
  const sessao = lerSessao();
  if (!sessao) return;
  localStorage.setItem(CHAVE, JSON.stringify({ ...sessao, ...campos }));
}

export function lerSessao() {
  try {
    return JSON.parse(localStorage.getItem(CHAVE));
  } catch {
    return null;
  }
}

export function limparSessao() {
  localStorage.removeItem(CHAVE);
}

export function exigirSessaoOuRedirecionar() {
  const sessao = lerSessao();
  if (!sessao?.sessionToken) {
    window.location.href = 'login.html';
    return null;
  }
  return sessao;
}
