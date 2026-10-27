// =====================================================================
// PONTO AVP — leitor de planilha de colaboradores
// Aceita planilhas "do jeito que estiverem": acha a aba, a linha de
// títulos e as colunas de nome, CPF, função, posto e empresa sozinho,
// confere os CPFs e liga cada posto da planilha a um posto já cadastrado.
// =====================================================================
(function (raiz) {
  const semAcento = s => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '');
  const norm = s => semAcento(s).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const soDig = s => String(s ?? '').replace(/\D/g, '');

  const CAMPOS = ['nome', 'cpf', 'funcao', 'posto', 'empresa'];
  const ROTULOS = { nome: 'Nome', cpf: 'CPF', funcao: 'Função', posto: 'Posto', empresa: 'Empresa' };
  const SINONIMOS = {
    nome: ['nome completo', 'nome do funcionario', 'nome do colaborador', 'nome funcionario', 'nome colaborador', 'funcionario', 'colaborador', 'empregado', 'nome'],
    cpf: ['cpf', 'c p f', 'n cpf', 'numero cpf', 'cpf do funcionario'],
    funcao: ['funcao', 'cargo', 'ocupacao', 'atividade', 'funcao cargo'],
    posto: ['posto de servico', 'posto de trabalho', 'posto', 'local de trabalho', 'local', 'condominio', 'cliente', 'lotacao', 'unidade', 'obra', 'contrato'],
    empresa: ['empresa', 'razao social', 'empregador']
  };
  const EXCLUIR = {
    nome: /\b(pai|mae|responsavel|empresa|posto|social|fantasia|cliente|condominio|conjuge|filho)\b/,
    posto: /\b(endereco|cep|bairro)\b/,
    funcao: /\b(data|admissao)\b/
  };

  // pontuação de um título de coluna para um campo
  function pontuar(titulo, campo) {
    const n = norm(titulo);
    if (!n || n.length > 40) return 0;
    if (EXCLUIR[campo] && EXCLUIR[campo].test(n)) return 0;
    let melhor = 0;
    for (const s of SINONIMOS[campo]) {
      if (n === s) melhor = Math.max(melhor, 3);
      else if (n.startsWith(s + ' ') || n.endsWith(' ' + s)) melhor = Math.max(melhor, 2);
      else if ((' ' + n + ' ').includes(' ' + s + ' ')) melhor = Math.max(melhor, 1);
    }
    return melhor;
  }

  function cpfValido(c) {
    if (!/^\d{11}$/.test(c) || /^(\d)\1{10}$/.test(c)) return false;
    for (const n of [9, 10]) {
      let s = 0;
      for (let i = 0; i < n; i++) s += +c[i] * (n + 1 - i);
      if ((s * 10) % 11 % 10 !== +c[n]) return false;
    }
    return true;
  }
  function limparCpf(v) {
    let d = soDig(v);
    if (d.length >= 9 && d.length < 11) d = d.padStart(11, '0'); // Excel come os zeros da frente
    return d;
  }
  const pareceCpf = v => limparCpf(v).length === 11;

  // acha a melhor linha de títulos de uma aba e o mapeamento das colunas
  function analisarAba(linhas) {
    let melhor = null;
    const limite = Math.min(linhas.length, 25);
    for (let r = 0; r < limite; r++) {
      const row = linhas[r] || [];
      const mapa = {}, usadas = new Set();
      let pontos = 0;
      for (const campo of CAMPOS) {
        let col = -1, pt = 0;
        row.forEach((cel, i) => { const p = pontuar(cel, campo); if (p > pt && !usadas.has(i)) { pt = p; col = i; } });
        if (col >= 0) { mapa[campo] = col; usadas.add(col); pontos += pt; }
      }
      if (mapa.nome === undefined) continue;
      // CPF sem título: procura a coluna onde a maioria parece CPF
      if (mapa.cpf === undefined) {
        const cols = Math.max(...linhas.slice(r + 1, r + 40).map(x => (x || []).length), 0);
        for (let i = 0; i < cols; i++) {
          if (usadas.has(i)) continue;
          const vals = linhas.slice(r + 1, r + 40).map(x => (x || [])[i]).filter(v => String(v ?? '').trim());
          if (vals.length >= 3 && vals.filter(pareceCpf).length / vals.length >= 0.6) { mapa.cpf = i; usadas.add(i); pontos += 1; break; }
        }
      }
      const dados = linhas.slice(r + 1).filter(x => String((x || [])[mapa.nome] ?? '').trim()).length;
      const nota = pontos * 100 + (mapa.cpf !== undefined ? 500 : 0) + Math.min(dados, 99);
      if (!melhor || nota > melhor.nota) melhor = { linhaTitulo: r, mapa, nota, dados };
    }
    return melhor;
  }

  // escolhe a aba com mais cara de lista de funcionários
  function analisarArquivo(abas) { // abas: [{nome, linhas: [[...]]}]
    const res = abas.map(a => ({ aba: a.nome, linhas: a.linhas, ...(analisarAba(a.linhas) || { nota: -1, dados: 0 }) }));
    const ordenadas = res.slice().sort((x, y) => y.nota - x.nota);
    return { abas: res, escolhida: ordenadas[0] && ordenadas[0].nota >= 0 ? ordenadas[0].aba : null };
  }

  // ----- postos -----
  const PALAVRAS_FORA = new Set(['condominio', 'cond', 'residencial', 'res', 'edificio', 'ed', 'predio', 'conjunto', 'posto', 'do', 'da', 'de', 'dos', 'das', 'e', 'o', 'a']);
  function chavePosto(s) {
    return norm(s).split(' ').filter(w => w && !PALAVRAS_FORA.has(w)).join(' ').replace(/(.)\1+/g, '$1');
  }
  function distancia(a, b) {
    const m = a.length, n = b.length, d = Array.from({ length: m + 1 }, (_, i) => [i]);
    for (let j = 1; j <= n; j++) d[0][j] = j;
    for (let i = 1; i <= m; i++) for (let j = 1; j <= n; j++)
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    return d[m][n];
  }
  function acharPosto(nome, postos) {
    const k = chavePosto(nome);
    if (!k) return null;
    let p = postos.find(x => chavePosto(x.nome) === k);
    if (p) return p;
    const contem = postos.filter(x => { const kx = chavePosto(x.nome); return kx.length >= 4 && k.length >= 4 && (kx.includes(k) || k.includes(kx)); });
    if (contem.length === 1) return contem[0];
    let melhor = null, nota = 0;
    for (const x of postos) {
      const kx = chavePosto(x.nome), sim = 1 - distancia(k, kx) / Math.max(k.length, kx.length);
      if (sim > nota) { nota = sim; melhor = x; }
    }
    return nota >= 0.85 ? melhor : null;
  }
  function nomeBonito(s) {
    const pequenas = new Set(['de', 'da', 'do', 'dos', 'das', 'e']);
    return String(s ?? '').trim().replace(/\s+/g, ' ').toLowerCase()
      .split(' ').map((w, i) => (i && pequenas.has(w)) ? w : w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
  }

  // monta a lista final a partir da aba e do mapeamento escolhidos
  function montar(linhas, linhaTitulo, mapa, postos) {
    const pegar = (row, campo) => mapa[campo] === undefined || mapa[campo] === null || mapa[campo] === '' ? '' : String((row || [])[mapa[campo]] ?? '').trim();
    const itens = [];
    linhas.slice(linhaTitulo + 1).forEach((row, i) => {
      const nome = pegar(row, 'nome').replace(/\s+/g, ' ').toUpperCase();
      if (!nome || /^(total|subtotal|soma)\b/i.test(nome)) return;
      const cpfBruto = pegar(row, 'cpf'), cpf = limparCpf(cpfBruto);
      let status = 'ok';
      if (!cpf) status = 'sem_cpf';
      else if (!cpfValido(cpf)) status = 'cpf_invalido';
      itens.push({
        linha: linhaTitulo + i + 2, nome, cpf, cpfBruto, status,
        funcao: pegar(row, 'funcao').replace(/\s+/g, ' ').toUpperCase() || null,
        empresa: pegar(row, 'empresa').replace(/\s+/g, ' ').toUpperCase() || null,
        postoPlanilha: pegar(row, 'posto').replace(/\s+/g, ' ')
      });
    });
    // CPF repetido: vale a última linha, as anteriores ficam marcadas
    const ultima = {};
    itens.forEach((it, i) => { if (it.status === 'ok') ultima[it.cpf] = i; });
    itens.forEach((it, i) => { if (it.status === 'ok' && ultima[it.cpf] !== i) { it.status = 'repetido'; it.repetidoCom = itens[ultima[it.cpf]]; } });
    // postos
    const novos = new Map();
    itens.forEach(it => {
      if (!it.postoPlanilha) { it.posto = null; return; }
      const p = acharPosto(it.postoPlanilha, postos);
      if (p) { it.posto = { id: p.id, nome: p.nome, novo: false }; return; }
      const k = chavePosto(it.postoPlanilha);
      if (!novos.has(k)) novos.set(k, { nome: nomeBonito(it.postoPlanilha), qtd: 0 });
      if (it.status === 'ok') novos.get(k).qtd++;
      it.posto = { id: null, chave: k, nome: novos.get(k).nome, novo: true };
    });
    const conta = s => itens.filter(x => x.status === s).length;
    return {
      itens, postosNovos: [...novos.entries()].map(([chave, v]) => ({ chave, ...v })),
      resumo: { ok: conta('ok'), sem_cpf: conta('sem_cpf'), cpf_invalido: conta('cpf_invalido'), repetido: conta('repetido') }
    };
  }

  const api = { analisarArquivo, analisarAba, montar, cpfValido, limparCpf, acharPosto, chavePosto, nomeBonito, CAMPOS, ROTULOS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else raiz.Importador = api;
})(typeof window !== 'undefined' ? window : this);
