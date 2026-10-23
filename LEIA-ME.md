# Ponto AVP — como colocar no ar

App de ponto da AVP Terceirização. O colaborador bate o ponto pelo celular com **selfie + GPS**. O ponto é **bloqueado se ele estiver fora do raio do posto**. O empregador acompanha tudo pelo painel.

- `index.html`: app do colaborador (celular)
- `admin.html`: painel do empregador (computador ou celular)
- `config.js`: onde vão os dados do Supabase
- `supabase/schema.sql`: banco de dados (rodar uma vez)
- `modelo_colaboradores.xlsx`: modelo para importar os funcionários

---

## 1. Criar o banco (Supabase), uns 10 minutos

1. Entre em supabase.com e crie um **projeto novo** chamado `ponto-avp`. Use um projeto separado do app da Van Service.
2. Vá em **Authentication > Sign In / Providers > Email** e **desligue "Confirm email"**. Sem isso, o colaborador não consegue criar a senha.
3. Vá em **SQL Editor > New query**, cole todo o conteúdo de `supabase/schema.sql` e clique em **Run**.
4. Crie o seu acesso de administrador:
   - **Authentication > Users > Add user > Create new user**: coloque seu e-mail e uma senha e marque **Auto Confirm User**.
   - Volte no **SQL Editor** e rode (trocando o e-mail se precisar):
     ```sql
     insert into public.admins (user_id, nome)
     select id, 'Anderson' from auth.users where email = 'lcs@lcsterceirizacao.com.br';
     ```
   - Repita para cada pessoa do RH que for usar o painel.
5. Vá em **Project Settings > API**, copie a **Project URL** e a chave **anon public** e cole no `config.js`.

## 2. Publicar (GitHub Pages)

1. No GitHub, crie um repositório chamado `ponto-avp` (público).
2. Envie todos os arquivos desta pasta (Add file > Upload files).
3. Vá em **Settings > Pages > Branch: main / (root) > Save**.
4. Em 1 ou 2 minutos fica no ar:
   - Colaborador: `https://andersonveloso0503-cmyk.github.io/ponto-avp/`
   - Painel: `https://andersonveloso0503-cmyk.github.io/ponto-avp/admin.html`

> Precisa ser **https**. Sem isso, o celular não libera câmera nem GPS. O GitHub Pages já é https.

## 3. Primeiro uso

1. Abra o **painel > Postos e raio GPS** e cadastre cada posto:
   - Coordenadas: no Google Maps, segure o dedo em cima do prédio e copie os números. Ou vá até o posto e toque em "Usar minha localização".
   - Raio: **150 m** é um bom começo. Em prédio alto ou área com sinal ruim, use 200 a 300 m.
2. Abra **Colaboradores > Importar planilha** e use o `modelo_colaboradores.xlsx`. O nome do posto na planilha precisa ser igual ao nome cadastrado.
3. Mande o link para os colaboradores. No celular, cada um:
   - toca em **"Criar senha com CPF e nome"** (o nome completo precisa ser igual ao cadastro, mas acento e maiúscula não importam);
   - permite **localização** e **câmera**;
   - toca em **"Instale o app no seu celular"**, na tela de entrada. O app mostra o passo a passo certo para o celular dele (Android, iPhone ou Samsung). No Android com Chrome aparece um botão **Instalar agora**.

## Funcionários por posto

Cada colaborador fica ligado a um posto (ex.: Sidnei → Condomínio Vila Carrara). Ele só consegue bater ponto e fazer ronda dentro do raio do **seu** posto. No painel, a aba **Colaboradores** mostra a lista separada por posto e tem um filtro de posto. Para trocar alguém de posto, é só editar.

## Rondas com QR Code

1. No painel, vá em **Postos e raio GPS** e clique em **QR da ronda** no posto.
2. Cadastre os pontos (Garagem, Portão B, Salão de festas…) na ordem da ronda.
3. Clique em **Imprimir QR Codes**. Sai uma folha A4 com 4 QR por página. Recorte e cole cada um no local, de preferência plastificado e na altura dos olhos.
4. Na ronda, o colaborador toca em **"Ler QR Code da ronda"** no app, ou aponta a câmera normal do celular, que abre o app sozinha.

Regras da ronda: precisa ter batido a entrada (e não estar em intervalo), estar dentro do raio do posto e o QR precisa ser do posto dele. A mesma pessoa não registra o mesmo ponto duas vezes em menos de 2 minutos. Na tela inicial, o colaborador vê quais pontos já passou na jornada.

No painel, a aba **Rondas** mostra, por período, quantas passagens teve cada ponto (os pontos sem nenhuma passagem aparecem marcados), quem passou e a que horas, com exportação para Excel. As tentativas recusadas aparecem em **Tentativas bloqueadas**.

> Se um QR Code for perdido ou copiado, clique em **Desativar** nele e cadastre o ponto de novo. O código antigo para de funcionar.

## Como funciona o bloqueio

Quem decide é o servidor, não o celular:

- O servidor calcula a distância entre o GPS do celular e o posto do colaborador. Fora do raio, o ponto **não é gravado**.
- Também bloqueia: GPS com precisão pior que 200 m, falta de selfie, duas batidas em menos de 1 minuto e registro fora de ordem.
- Toda tentativa bloqueada fica em **Tentativas bloqueadas**, com selfie e local. Assim dá para ver quem tentou bater de casa.
- A hora gravada é a do **servidor**. Mudar o relógio do celular não adianta.
- Registros **não podem ser alterados nem apagados**, nem pelo administrador. Cada um tem número sequencial (NSR) e um código de verificação encadeado.

**Limite honesto:** um celular "adulterado" com app de GPS falso pode enganar a localização. A selfie e o relatório de tentativas ajudam a pegar esses casos. Se aparecer alguém suspeito, vale conferir a foto e o mapa no painel.

## Dia a dia

- **Esqueceu a senha:** no painel, clique em "Esqueceu a senha" no colaborador e siga as instruções. Você apaga o usuário no Supabase e ele cria a senha de novo. Os registros dele continuam guardados.
- **Saiu da empresa:** edite e coloque **Inativo**. Ele fica bloqueado na hora.
- **Mudou de posto:** edite e troque o posto.
- **Folha / vale:** em **Espelho de ponto**, escolha o período e clique em **Exportar Excel**. O arquivo traz uma aba de resumo (dias e horas por pessoa) e uma aba com todas as jornadas.
- **Turno da noite (12x36):** a jornada fica ligada à entrada, mesmo virando o dia. O porteiro pode bater "Saída" direto, sem intervalo.

## Sobre a lei (Portaria 671 / AFD)

O app gera comprovante a cada batida e tem o botão **Exportar AFD**, no leiaute da Portaria 671 para ponto por programa (REP-P). Para usar este app **no lugar do cartão de ponto oficial**, mostre ao seu contador ou advogado trabalhista antes, e valide o AFD no validador do Ministério do Trabalho. A portaria também pede itens como registro do programa no INPI e atestado técnico. Como **controle interno**, ele já pode ser usado direto.
