/**
 * Mascotinho — módulo do bichinho de vocês dois
 * ------------------------------------------------
 * Modo completo (com painel visual), usado em playground.html:
 *
 *   import { Mascotinho } from './mascotinho.js';
 *   Mascotinho.init({ supabase, pairId, container: '#mascotinho-widget' });
 *
 * Modo silencioso (só ganhar XP), usado em index.html / letters.html /
 * quotes.html / places.html:
 *
 *   import { Mascotinho } from './mascotinho.js';
 *   Mascotinho.init({ supabase, pairId }); // sem container
 *   await Mascotinho.ganharXP('momento');  // ou 'carta' / 'frase' / 'lugar' / 'memoria' / 'humor' / 'login'
 */

const XP_POR_ACAO = {
  momento: 15,
  carta: 15,
  frase: 10,
  lugar: 10,
  memoria: 12,
  humor: 6,
  login: 8,
};

// Ações que só rendem XP uma vez por dia (pra não virar spam de clique).
const TIPOS_DIARIOS = new Set(['login', 'humor']);

// Catálogo de roupinhas — desbloqueadas automaticamente pelo nível.
const ROUPAS = [
  { id: 'nenhuma', nivel: 1, nome: 'Sem roupinha', emoji: '' },
  { id: 'lenco', nivel: 2, nome: 'Lenço no pescoço', emoji: '🧣' },
  { id: 'chapeu', nivel: 4, nome: 'Chapéu de sol', emoji: '👒' },
  { id: 'jaqueta', nivel: 6, nome: 'Jaquetinha', emoji: '🧥' },
  { id: 'coroa', nivel: 9, nome: 'Coroa', emoji: '👑' },
  { id: 'terno', nivel: 12, nome: 'Terno de gala', emoji: '🎩' },
  { id: 'dino', nivel: 15, nome: 'Fantasia de dinossauro', emoji: '🦖' },
  { id: 'vestido', nivel: 18, nome: 'Vestido de festa', emoji: '👗' },
  { id: 'heroi', nivel: 21, nome: 'Capa de super-herói', emoji: '🦸' },
];

const ACESSORIOS = [
  { id: 'nenhum', nivel: 1, nome: 'Sem acessório', emoji: '' },
  { id: 'oculos', nivel: 3, nome: 'Óculos', emoji: '🕶️' },
  { id: 'mochila', nivel: 5, nome: 'Mochila', emoji: '🎒' },
  { id: 'flor', nivel: 7, nome: 'Florzinha', emoji: '🌸' },
  { id: 'estrela', nivel: 10, nome: 'Varinha de estrela', emoji: '✨' },
  { id: 'laco', nivel: 13, nome: 'Laço', emoji: '🎀' },
  { id: 'relogio', nivel: 16, nome: 'Relógio', emoji: '⌚' },
  { id: 'coroaflores', nivel: 19, nome: 'Coroa de flores', emoji: '💐' },
];

const QUARTOS = [
  { id: 'padrao', nivel: 1, nome: 'Quartinho simples' },
  { id: 'jardim', nivel: 3, nome: 'Cantinho de jardim' },
  { id: 'noturno', nivel: 6, nome: 'Céu estrelado' },
  { id: 'praia', nivel: 8, nome: 'Praiazinha' },
  { id: 'realeza', nivel: 11, nome: 'Salão real' },
  { id: 'floresta', nivel: 14, nome: 'Floresta encantada' },
  { id: 'espaco', nivel: 17, nome: 'Espaço sideral' },
  { id: 'castelo', nivel: 20, nome: 'Castelo de nuvens' },
];

// Catálogo de comidinhas — alimentar recupera fome (e um pouquinho de
// felicidade/energia + XP). Também desbloqueadas automaticamente pelo nível.
const COMIDAS = [
  { id: 'morango', nivel: 1, nome: 'Morango', emoji: '🍓' },
  { id: 'bolinho', nivel: 3, nome: 'Bolinho', emoji: '🧁' },
  { id: 'macarrao', nivel: 5, nome: 'Macarrão', emoji: '🍜' },
  { id: 'sorvete', nivel: 7, nome: 'Sorvete', emoji: '🍨' },
  { id: 'pizza', nivel: 9, nome: 'Pizza', emoji: '🍕' },
  { id: 'bolo', nivel: 11, nome: 'Bolo', emoji: '🎂' },
  { id: 'sushi', nivel: 14, nome: 'Sushi', emoji: '🍣' },
  { id: 'chocolate', nivel: 17, nome: 'Chocolate', emoji: '🍫' },
];

function itensDesbloqueados(catalogo, nivel) {
  return catalogo.filter((i) => i.nivel <= nivel);
}

function proximoNivelDesbloqueio(nivelAtual) {
  const todos = [...ROUPAS, ...ACESSORIOS, ...QUARTOS, ...COMIDAS].map((i) => i.nivel);
  const proximos = todos.filter((n) => n > nivelAtual);
  return proximos.length ? Math.min(...proximos) : null;
}

export const Mascotinho = (() => {
  let supabase = null;
  let pairId = null;
  let container = null;
  let estadoAtual = null;

  function barraHtml(valor, cor, emoji, label) {
    const pct = Math.max(0, Math.min(100, Math.round(valor)));
    return `
      <div class="masc-stat">
        <span class="masc-stat-emoji" aria-hidden="true">${emoji}</span>
        <div class="masc-stat-track"><div class="masc-stat-fill" style="width:${pct}%; background:${cor}"></div></div>
        <span class="masc-stat-value">${pct}</span>
        <span class="masc-stat-label">${label}</span>
      </div>
    `;
  }

  function render() {
    if (!container || !estadoAtual) return;
    const m = estadoAtual;
    const xpPct = Math.round((m.xp / m.xp_para_proximo) * 100);
    const roupasDisponiveis = itensDesbloqueados(ROUPAS, m.nivel);
    const acessoriosDisponiveis = itensDesbloqueados(ACESSORIOS, m.nivel);
    const quartosDisponiveis = itensDesbloqueados(QUARTOS, m.nivel);
    const comidasDisponiveis = itensDesbloqueados(COMIDAS, m.nivel);
    const proximo = proximoNivelDesbloqueio(m.nivel);

    container.innerHTML = `
      <div class="masc-card">
        <div class="masc-header">
          <span class="masc-title">Disgramadinha Dengosa</span>
          <span class="masc-nivel">Nível ${m.nivel}</span>
        </div>

        <div class="masc-xp-row">
          <div class="masc-xp-track"><div class="masc-xp-fill" style="width:${xpPct}%"></div></div>
          <span class="masc-xp-label">${m.xp}/${m.xp_para_proximo} XP</span>
        </div>

        <div class="masc-stats">
          ${barraHtml(m.felicidade, '#E38FA0', '❤️', 'felicidade')}
          ${barraHtml(m.fome, '#E3A85C', '🍎', 'fome')}
          ${barraHtml(m.energia, '#7FB07A', '⚡', 'energia')}
        </div>

        <div class="masc-acoes">
          <button class="masc-btn-carinho" id="masc-btn-carinho">💗 Fazer carinho</button>
        </div>

        <details class="masc-guarda-roupa masc-cardapio">
          <summary>Comidinhas</summary>
          <div class="masc-secao">
            <p class="masc-secao-titulo">Toque para alimentar</p>
            <div class="masc-opcoes">
              ${comidasDisponiveis.map((c) => `<button class="masc-opcao masc-comida ${c.id === m.ultima_comida ? 'ativa' : ''}" data-id="${c.id}" data-nivel="${c.nivel}">${c.emoji} ${c.nome}</button>`).join('')}
            </div>
          </div>
        </details>

        <details class="masc-guarda-roupa">
          <summary>Roupinhas, acessórios e quarto</summary>
          <div class="masc-secao">
            <p class="masc-secao-titulo">Roupinha</p>
            <div class="masc-opcoes">
              ${roupasDisponiveis.map((r) => `<button class="masc-opcao ${r.id === m.roupa_atual ? 'ativa' : ''}" data-tipo="roupa" data-id="${r.id}" data-nivel="${r.nivel}">${r.emoji || '🚫'} ${r.nome}</button>`).join('')}
            </div>
            <p class="masc-secao-titulo">Acessório</p>
            <div class="masc-opcoes">
              ${acessoriosDisponiveis.map((a) => `<button class="masc-opcao ${a.id === m.acessorio_atual ? 'ativa' : ''}" data-tipo="acessorio" data-id="${a.id}" data-nivel="${a.nivel}">${a.emoji || '🚫'} ${a.nome}</button>`).join('')}
            </div>
            <p class="masc-secao-titulo">Quarto</p>
            <div class="masc-opcoes">
              ${quartosDisponiveis.map((q) => `<button class="masc-opcao ${q.id === m.quarto_atual ? 'ativa' : ''}" data-tipo="quarto" data-id="${q.id}" data-nivel="${q.nivel}">${q.nome}</button>`).join('')}
            </div>
            ${proximo ? `<p class="masc-proximo">Próximo desbloqueio no nível ${proximo}</p>` : `<p class="masc-proximo">Tudo desbloqueado! 🎉</p>`}
          </div>
        </details>
      </div>
    `;

    container.querySelector('#masc-btn-carinho').addEventListener('click', carinho);
    container.querySelectorAll('.masc-comida').forEach((btn) => {
      btn.addEventListener('click', () => alimentar(btn.dataset.id, Number(btn.dataset.nivel)));
    });
    container.querySelectorAll('.masc-opcao:not(.masc-comida)').forEach((btn) => {
      btn.addEventListener('click', () => equipar(btn.dataset.tipo, btn.dataset.id, Number(btn.dataset.nivel)));
    });

    aplicarOverlayNoFace();
    aplicarQuartoTema();
  }

  // Desenha a roupinha/acessório equipados sobre o rosto que já existe
  // em playground.html (procura o elemento #faceWanderer na página).
  function aplicarOverlayNoFace() {
    const wanderer = document.getElementById('faceWanderer');
    if (!wanderer || !estadoAtual) return;

    let layer = wanderer.querySelector('.masc-face-overlay');
    if (!layer) {
      layer = document.createElement('div');
      layer.className = 'masc-face-overlay';
      wanderer.appendChild(layer);
    }

    const roupa = ROUPAS.find((r) => r.id === estadoAtual.roupa_atual);
    const acessorio = ACESSORIOS.find((a) => a.id === estadoAtual.acessorio_atual);

    layer.innerHTML = `
      ${roupa && roupa.emoji ? `<span class="masc-face-item masc-face-roupa">${roupa.emoji}</span>` : ''}
      ${acessorio && acessorio.emoji ? `<span class="masc-face-item masc-face-acessorio">${acessorio.emoji}</span>` : ''}
    `;
  }

  // Aplica o tema de quarto como classe no <body> (a página já define
  // o gradiente de humor; o quarto soma uma textura de fundo por cima).
  function aplicarQuartoTema() {
    if (!estadoAtual) return;
    document.body.dataset.quarto = estadoAtual.quarto_atual;
  }

  async function equipar(tipo, id, nivelMinimo) {
    if (estadoAtual.nivel < nivelMinimo) return;
    const coluna = tipo === 'roupa' ? 'roupa_atual' : tipo === 'acessorio' ? 'acessorio_atual' : 'quarto_atual';
    const anterior = estadoAtual[coluna];
    estadoAtual[coluna] = id;
    render();
    const { data, error } = await supabase.rpc('equipar_item_mascote', {
      p_pair_id: pairId,
      p_tipo: tipo,
      p_id: id,
      p_nivel_minimo: nivelMinimo,
    });
    if (error) {
      console.error('Erro ao equipar item do mascotinho:', error);
      estadoAtual[coluna] = anterior;
      render();
      return;
    }
    estadoAtual = data;
    render();
  }

  async function carregarEstado() {
    const { data, error } = await supabase.rpc('get_or_create_mascote', { p_pair_id: pairId });
    if (error) {
      console.error('Erro ao carregar o mascotinho:', error);
      return;
    }
    estadoAtual = Array.isArray(data) ? data[0] : data;
    render();
  }

  function mostrarToast(texto) {
    const toast = document.createElement('div');
    toast.className = 'masc-toast';
    toast.textContent = texto;
    document.body.appendChild(toast);
    requestAnimationFrame(() => toast.classList.add('masc-toast-visivel'));
    setTimeout(() => {
      toast.classList.remove('masc-toast-visivel');
      setTimeout(() => toast.remove(), 400);
    }, 3200);
  }

  function jaGanhouHoje(tipo) {
    const chave = `mascotinho_${tipo}_${pairId}`;
    return localStorage.getItem(chave) === new Date().toDateString();
  }
  function marcarGanhoHoje(tipo) {
    localStorage.setItem(`mascotinho_${tipo}_${pairId}`, new Date().toDateString());
  }

  async function ganharXP(tipo) {
    if (!supabase || !pairId) return;
    if (TIPOS_DIARIOS.has(tipo) && jaGanhouHoje(tipo)) return;

    const quantidade = XP_POR_ACAO[tipo];
    if (!quantidade) {
      console.warn('Tipo de ação de XP desconhecido:', tipo);
      return;
    }

    const { data, error } = await supabase.rpc('adicionar_xp_mascote', {
      p_pair_id: pairId,
      p_quantidade: quantidade,
      p_tipo: tipo,
    });
    if (error) {
      console.error('Erro ao adicionar XP do mascotinho:', error);
      return;
    }

    const linha = Array.isArray(data) ? data[0] : data;
    estadoAtual = linha.mascote;
    render();

    if (linha.subiu_de_nivel) {
      mostrarToast(
        linha.niveis_ganhos > 1
          ? `🎉 O mascotinho subiu ${linha.niveis_ganhos} níveis! Novo item desbloqueado.`
          : '🎉 O mascotinho subiu de nível! Novo item desbloqueado.'
      );
    }

    if (TIPOS_DIARIOS.has(tipo)) marcarGanhoHoje(tipo);
  }

  async function carinho() {
    if (!supabase || !pairId) return;
    const { data, error } = await supabase.rpc('fazer_carinho_mascote', { p_pair_id: pairId });
    if (error) {
      console.error('Erro ao fazer carinho no mascotinho:', error);
      return;
    }
    const linha = Array.isArray(data) ? data[0] : data;
    estadoAtual = linha.mascote;
    render();

    if (!linha.podia_fazer_carinho) {
      const btn = container && container.querySelector('#masc-btn-carinho');
      if (btn) {
        const original = btn.textContent;
        btn.textContent = 'Ele já recebeu carinho recentemente 💤';
        setTimeout(() => { btn.textContent = original; }, 2200);
      }
    }
  }

  async function alimentar(id, nivelMinimo) {
    if (!supabase || !pairId || !estadoAtual) return;
    if (estadoAtual.nivel < nivelMinimo) return;

    const { data, error } = await supabase.rpc('alimentar_mascote', {
      p_pair_id: pairId,
      p_comida_id: id,
    });
    if (error) {
      console.error('Erro ao alimentar o mascotinho:', error);
      return;
    }
    const linha = Array.isArray(data) ? data[0] : data;
    estadoAtual = linha.mascote;
    render();

    if (linha.podia_alimentar) {
      const comida = COMIDAS.find((c) => c.id === id);
      mostrarToast(`${comida ? comida.emoji : '🍽️'} Ela adorou a comidinha!`);
    } else {
      mostrarToast('Ela ainda está satisfeita, tenta de novo daqui a pouco 🍽️');
    }
  }

  async function init(opts) {
    supabase = opts.supabase;
    pairId = opts.pairId;
    container = opts.container ? (typeof opts.container === 'string' ? document.querySelector(opts.container) : opts.container) : null;

    if (!supabase || !pairId) {
      console.error('Mascotinho.init: supabase e pairId são obrigatórios.');
      return;
    }

    if (container) {
      await carregarEstado();
      await ganharXP('login');
    }
  }

  return { init, ganharXP, carinho };
})();
