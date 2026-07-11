// Avatares de perfil por emoji: uma grade curada (sem upload de imagem,
// sem custo de armazenamento). O mesmo seletor serve para participantes
// convidados (entrar.html) e contas de criador (login.html, painel.html).

export const EMOJIS = [
  // Ciência e física (a cara da marca)
  '🚀', '🧲', '⚛️', '🔭', '🧪', '⚡', '💡', '🪐',
  '🔬', '🌡️', '🛰️', '🌟', '☄️', '🧮', '📐', '🔋',
  // Rostos
  '😀', '😎', '🤓', '😜', '🤠', '🥸', '🤖', '👽',
  '🥳', '😺', '🤯', '😴', '🦸', '🧙', '👻', '💀',
  // Animais
  '🦊', '🐱', '🐼', '🦉', '🐙', '🦖', '🐢', '🦜',
  '🐬', '🦁', '🐸', '🦩', '🐝', '🦈', '🐨', '🐧',
  // Diversos
  '🎧', '🎸', '⚽', '🏀', '🎯', '🎲', '🧩', '🍕',
  '🔥', '🌈', '🎨', '📚', '🏆', '🎮', '🍀', '🌻',
];

export const AVATAR_PADRAO = '🙂';

export function emojiAleatorio() {
  return EMOJIS[Math.floor(Math.random() * EMOJIS.length)];
}

// Monta a grade de escolha dentro de `container`. Comporta-se como um
// radiogroup acessível; devolve { selecionado() } para ler o valor atual.
export function montarSeletorEmoji(container, { selecionado = null, aoEscolher = null } = {}) {
  let atual = selecionado ?? emojiAleatorio();

  container.innerHTML = '';
  container.classList.add('seletor-emoji');
  container.setAttribute('role', 'radiogroup');
  container.setAttribute('aria-label', 'Escolha seu avatar');

  for (const emoji of EMOJIS) {
    const botao = document.createElement('button');
    botao.type = 'button';
    botao.textContent = emoji;
    botao.setAttribute('role', 'radio');
    botao.setAttribute('aria-checked', String(emoji === atual));
    botao.setAttribute('aria-label', `Avatar ${emoji}`);
    botao.addEventListener('click', () => {
      atual = emoji;
      container.querySelectorAll('button').forEach((b) => {
        b.setAttribute('aria-checked', String(b === botao));
      });
      aoEscolher?.(emoji);
    });
    container.appendChild(botao);
  }

  return { selecionado: () => atual };
}
