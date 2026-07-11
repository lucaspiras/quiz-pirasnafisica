export function escaparHtml(valor) {
  return String(valor ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

let temporizadorToast = null;

export function mostrarToast(mensagem, tipo = 'info') {
  let el = document.getElementById('toast-global');
  if (!el) {
    el = document.createElement('div');
    el.id = 'toast-global';
    el.className = 'toast';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    el.style.display = 'none';
    document.body.appendChild(el);
  }
  el.textContent = mensagem;
  el.classList.toggle('is-error', tipo === 'error');
  el.style.display = 'block';
  clearTimeout(temporizadorToast);
  temporizadorToast = setTimeout(() => { el.style.display = 'none'; }, 3200);
}

export async function copiarTexto(texto) {
  try {
    await navigator.clipboard.writeText(texto);
    mostrarToast('Copiado para a área de transferência.');
  } catch {
    mostrarToast('Não foi possível copiar. Copie manualmente.', 'error');
  }
}

export function urlQrCode(conteudo, tamanho = 220) {
  return `https://api.qrserver.com/v1/create-qr-code/?size=${tamanho}x${tamanho}&data=${encodeURIComponent(conteudo)}`;
}

export function parametrosDaUrl() {
  return new URLSearchParams(window.location.search);
}

// Modal de confirmação que substitui window.confirm: deixa explícito o que
// se perde e permite rotular o botão de acordo com a ação.
export function confirmarAcao({ titulo, mensagem, rotuloConfirmar = 'Confirmar', perigoso = false }) {
  return new Promise((resolver) => {
    const backdrop = document.createElement('div');
    backdrop.className = 'modal-backdrop';
    backdrop.innerHTML = `
      <div class="modal" role="dialog" aria-modal="true" aria-labelledby="modal-titulo">
        <h3 id="modal-titulo">${escaparHtml(titulo)}</h3>
        <p>${escaparHtml(mensagem)}</p>
        <div class="modal-acoes">
          <button class="btn btn-ghost" data-modal="cancelar">Cancelar</button>
          <button class="btn ${perigoso ? 'btn-danger' : 'btn-primary'}" data-modal="confirmar">${escaparHtml(rotuloConfirmar)}</button>
        </div>
      </div>
    `;

    function fechar(resposta) {
      backdrop.remove();
      document.removeEventListener('keydown', aoTeclar);
      resolver(resposta);
    }
    function aoTeclar(evento) {
      if (evento.key === 'Escape') fechar(false);
    }

    backdrop.addEventListener('click', (evento) => {
      if (evento.target === backdrop) fechar(false);
    });
    backdrop.querySelector('[data-modal="cancelar"]').addEventListener('click', () => fechar(false));
    backdrop.querySelector('[data-modal="confirmar"]').addEventListener('click', () => fechar(true));
    document.addEventListener('keydown', aoTeclar);

    document.body.appendChild(backdrop);
    backdrop.querySelector('[data-modal="confirmar"]').focus();
  });
}
