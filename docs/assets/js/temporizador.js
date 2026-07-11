// Timer sincronizado: o servidor é consultado uma única vez por pergunta
// (quiz_elapsed_ms) para saber quanto tempo já passou; a contagem regressiva
// local então usa performance.now() (relógio monotônico), imune a um
// relógio de parede errado no celular de alguém.

import { chamarRpc } from './supabase.js';

export function criarTemporizador({ segundosTotais, aoAtualizar, aoTerminar }) {
  let referenciaPerf = null;
  let elapsedMsNaCalibragem = 0;
  let intervalo = null;

  async function calibrar(sessionId) {
    const elapsedMs = await chamarRpc('quiz_elapsed_ms', { p_session_id: sessionId });
    if (elapsedMs === null || elapsedMs === undefined) return false;
    elapsedMsNaCalibragem = elapsedMs;
    referenciaPerf = performance.now();
    return true;
  }

  // Modo local (praticar): não há sessão ao vivo no servidor — o tempo
  // começa a contar agora, no aparelho de quem pratica.
  function calibrarLocal() {
    elapsedMsNaCalibragem = 0;
    referenciaPerf = performance.now();
  }

  function decorridoMs() {
    if (referenciaPerf === null) return 0;
    return elapsedMsNaCalibragem + (performance.now() - referenciaPerf);
  }

  function restanteMs() {
    if (referenciaPerf === null) return segundosTotais * 1000;
    const decorridoDesdeCalibragem = performance.now() - referenciaPerf;
    const decorridoTotal = elapsedMsNaCalibragem + decorridoDesdeCalibragem;
    return Math.max(0, segundosTotais * 1000 - decorridoTotal);
  }

  function iniciar() {
    parar();
    intervalo = setInterval(() => {
      const restante = restanteMs();
      aoAtualizar?.(restante, segundosTotais * 1000);
      if (restante <= 0) {
        parar();
        aoTerminar?.();
      }
    }, 100);
  }

  function parar() {
    if (intervalo) {
      clearInterval(intervalo);
      intervalo = null;
    }
  }

  return { calibrar, calibrarLocal, iniciar, parar, restanteMs, decorridoMs };
}
