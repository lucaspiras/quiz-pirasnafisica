/* Tema claro/escuro. Carregado de forma síncrona no <head> para aplicar
   o tema antes da primeira pintura (sem "flash" de tema errado).
   Prioridade: escolha salva do usuário > tema do sistema operacional.
   O botão #botao-tema (quando existe na página) alterna e salva. */
(function () {
  var CHAVE = 'tema';

  function temaSalvo() {
    try { return localStorage.getItem(CHAVE); } catch (e) { return null; }
  }

  function temaPreferido() {
    var salvo = temaSalvo();
    if (salvo === 'dark' || salvo === 'light') return salvo;
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  function aplicar(tema) {
    document.documentElement.dataset.theme = tema;
    var botao = document.getElementById('botao-tema');
    if (botao) {
      botao.textContent = tema === 'dark' ? '☀️' : '🌙';
      var rotulo = tema === 'dark' ? 'Mudar para tema claro' : 'Mudar para tema escuro';
      botao.title = rotulo;
      botao.setAttribute('aria-label', rotulo);
    }
  }

  aplicar(temaPreferido());

  document.addEventListener('DOMContentLoaded', function () {
    aplicar(temaPreferido());
    var botao = document.getElementById('botao-tema');
    if (botao) {
      botao.addEventListener('click', function () {
        var novo = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
        try { localStorage.setItem(CHAVE, novo); } catch (e) { /* navegação privada */ }
        aplicar(novo);
      });
    }
  });

  // Sem escolha salva, acompanha mudanças de tema do sistema em tempo real.
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function () {
    if (!temaSalvo()) aplicar(temaPreferido());
  });
})();
