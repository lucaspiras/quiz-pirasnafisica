// Confete de celebração sem bibliotecas: N peças em CSS puro, cada uma com
// posição, cor, tamanho, duração e rotação sorteados via custom properties.
// Duas divs aninhadas: a externa cai (translateY), a interna balança
// (translateX alternado) — juntas dão a trajetória em zigue-zague.

const CORES = ['#2f5bea', '#6a2fe8', '#e83e8c', '#fb923c', '#facc15', '#22c55e'];

export function dispararConfete({ quantidade = 120, duracaoMs = 5500 } = {}) {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  const container = document.createElement('div');
  container.className = 'confetti';
  container.setAttribute('aria-hidden', 'true');

  for (let i = 0; i < quantidade; i += 1) {
    const queda = document.createElement('div');
    queda.className = 'confetti-queda';
    queda.style.setProperty('--x', `${Math.random() * 100}%`);
    queda.style.setProperty('--dur', `${2.8 + Math.random() * 1.9}s`);
    queda.style.setProperty('--delay', `${Math.random() * 1.4}s`);
    queda.style.setProperty('--gira', `${540 + Math.random() * 540}deg`);

    const peca = document.createElement('span');
    peca.className = 'confetti-peca';
    peca.style.setProperty('--tam', `${6 + Math.random() * 6}px`);
    peca.style.setProperty('--cor', CORES[i % CORES.length]);
    peca.style.setProperty('--razao', String(0.6 + Math.random() * 1.2));
    peca.style.setProperty('--forma', Math.random() < 0.3 ? '50%' : '2px');

    queda.appendChild(peca);
    container.appendChild(queda);
  }

  document.body.appendChild(container);
  setTimeout(() => container.remove(), duracaoMs);
}
