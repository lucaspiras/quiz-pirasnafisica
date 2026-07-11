// Identidade do participante numa sala, guardada por sessão (sessionStorage):
// sobrevive a um F5 na mesma aba, mas não vaza para outras abas/jogos.

function chave(sessionId) {
  return `quizpf_participante_${sessionId}`;
}

export function salvarParticipante(sessionId, dados) {
  sessionStorage.setItem(chave(sessionId), JSON.stringify(dados));
}

export function lerParticipante(sessionId) {
  try {
    return JSON.parse(sessionStorage.getItem(chave(sessionId)));
  } catch {
    return null;
  }
}

export function esquecerParticipante(sessionId) {
  sessionStorage.removeItem(chave(sessionId));
}
