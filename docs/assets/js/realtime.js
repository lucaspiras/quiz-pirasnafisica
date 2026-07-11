// Sincronização ao vivo: Supabase Realtime (postgres_changes) + um fallback
// de polling a cada poucos segundos. Em eventos ao vivo o Wi-Fi cai e derruba
// o socket silenciosamente — o polling garante que a tela se recupera sozinha.

import { supabase } from './supabase.js';

export function criarSincronizacaoAoVivo({ nomeCanal, tabelas, buscar, atualizar, intervaloPollMs = 2500 }) {
  let ultimaAssinatura = null;
  let pollTimer = null;
  let canalRt = null;
  let ativo = false;

  function assinaturaDe(dados) {
    try {
      return JSON.stringify(dados);
    } catch {
      return String(Date.now());
    }
  }

  async function buscarEDisparar(forcar = false) {
    if (!ativo) return;
    let dados;
    try {
      dados = await buscar();
    } catch {
      return; // falha de rede pontual: o próximo ciclo de polling tenta de novo
    }
    const assinatura = assinaturaDe(dados);
    if (forcar || assinatura !== ultimaAssinatura) {
      ultimaAssinatura = assinatura;
      atualizar(dados);
    }
  }

  function iniciar() {
    ativo = true;
    canalRt = supabase.channel(nomeCanal);
    for (const { nome, coluna, valor } of tabelas) {
      canalRt.on(
        'postgres_changes',
        { event: '*', schema: 'public', table: nome, filter: `${coluna}=eq.${valor}` },
        () => buscarEDisparar()
      );
    }
    canalRt.subscribe();

    pollTimer = setInterval(() => buscarEDisparar(), intervaloPollMs);
    buscarEDisparar(true);
  }

  function parar() {
    ativo = false;
    if (canalRt) supabase.removeChannel(canalRt);
    if (pollTimer) clearInterval(pollTimer);
  }

  return { iniciar, parar, forcarAtualizacao: () => buscarEDisparar(true) };
}
