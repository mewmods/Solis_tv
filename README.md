# Solis TV

Controle remoto e tela 3D para TVs do GTA V no FiveM, com reprodução de vídeos
do YouTube em DUI, fila, playlists por jogador e editor de telões dentro do jogo.

O vídeo e o áudio saem da própria DUI criada em cima do prop: cada TV do mapa
tem sua textura, seu volume e sua posição na fila, e todos os jogadores no raio
de renderização veem o mesmo vídeo no mesmo segundo.

> Recurso escrito para servidores **vRP** (solis, zirix e derivados).
> Base original de *Ac Loaf / Mew Team*, mantida e reescrita pela **Solis**.

---

## Índice

- [Recursos](#recursos)
- [Requisitos](#requisitos)
- [Instalação](#instalação)
- [Comandos](#comandos)
- [Configuração](#configuração)
- [Modelos de TV](#modelos-de-tv)
- [Banco de dados](#banco-de-dados)
- [Como funciona](#como-funciona)
- [Solução de problemas](#solução-de-problemas)
- [Limitações conhecidas](#limitações-conhecidas)
- [Licença](#licença)

---

## Recursos

### Reprodução

- Vídeo do YouTube direto na geometria do prop, sem scaleform compartilhado.
- **Uma DUI por TV**: duas TVs próximas tocam vídeos diferentes ao mesmo tempo.
- Player local (`html/tv_screen.html`) servido pelo próprio recurso em `https`,
  o que dá ao embed do YouTube uma origem válida e mantém vídeo + áudio juntos.
- Fallback automático para `nui://` quando o cliente não carrega a página `https`,
  com troca de URL depois de `Config.DuiLoadTimeout` e nova tentativa nos erros
  `153` do player.
- Sincronização de estado (vídeo, tempo, pausa, volume, velocidade, legendas)
  feita pelo servidor: quem entra no meio do vídeo cai no segundo certo.
- Fim de vídeo detectado pela DUI e reportado só pelo controlador, evitando que
  todo mundo avance a fila de uma vez.

### Controle

- `/tv` abre o controle remoto quando você está perto de uma TV.
- Play, pause, seek, volume, velocidade (0.5x a 2x) e legendas.
- Volume **individual** por jogador: `/tv 30` reduz só o seu áudio e `/tv off`
  muta a TV apenas para você, sem mexer na TV dos outros.
- Barra de progresso atualizada em tempo real no controle.
- Fila de reprodução, repetir, aleatório e playlists por personagem.

### Busca

- Cole um link do YouTube ou um ID de 11 caracteres para tocar na hora.
- Busca por texto com a **YouTube Data API v3** (opcional, usa sua chave).
- Sem chave — ou com a cota diária estourada — a busca continua funcionando
  pelos dados públicos da página de resultados do YouTube, processados no
  servidor do recurso (cache de 5 minutos por consulta).

### Editor de TVs

- `/spawntv [modelo]` cria uma TV à sua frente.
- `/tvedit` abre o modo construtor: mover, subir, descer, girar e inclinar.
- `/savetv` grava todas as TVs no MySQL; `/deletetv` remove a TV mais próxima
  (e encerra o áudio dela); `/wipetv` limpa tudo do mapa e do banco.
- TVs salvas são recriadas automaticamente para cada jogador que entra.
- Se o mapa já tem um prop no mesmo ponto, o recurso reaproveita o existente em
  vez de duplicar o modelo.

### Interface

- NUI própria em HTML/CSS/JS puro (sem framework, sem build).
- Tema claro/escuro salvo no `localStorage`.
- Abas de início, busca, playlist e recentes, com toasts de retorno.

---

## Requisitos

| Item | Versão / observação |
| --- | --- |
| FiveM | build com suporte a `lua54` (fx_version `cerulean` ou superior) |
| vRP | base `vrp` presente na raiz dos resources (usa `@vrp/lib/utils.lua`) |
| oxmysql | iniciado **antes** do `solis_tv` |
| YouTube Data API v3 | opcional — só para busca por texto com cota própria |

O recurso usa `module("vrp", "lib/Tunnel")` e `module("vrp", "lib/Proxy")`, então
a pasta da base **precisa** se chamar `vrp` (é o padrão das bases solis/zirix).
As permissões administrativas seguem os grupos do vRP.

---

## Instalação

1. Copie a pasta para `resources/[solis]/solis_tv` (o nome da pasta precisa ser
   `solis_tv`, porque os eventos e a página da DUI usam o nome do recurso).
2. Garanta que `vrp` e `oxmysql` sobem antes, no `server.cfg`:

   ```cfg
   ensure oxmysql
   ensure vrp
   ensure solis_tv
   ```

3. Ajuste o grupo administrativo em `config.lua`:

   ```lua
   Config.AdminPermission = "Admin" -- grupo do vRP que pode usar /spawntv, /tvedit, ...
   ```

4. (Opcional) Informe sua chave da YouTube Data API v3:

   ```lua
   Config.YoutubeAPIKey = "SUA_CHAVE_AQUI"
   ```

   Sem chave o recurso funciona normalmente usando a busca pública do YouTube.

5. Inicie o servidor. As tabelas do banco são criadas automaticamente na
   primeira execução (veja [Banco de dados](#banco-de-dados)).

> **Nunca comite uma chave real.** O `config.lua` deste repositório sai com
> `Config.YoutubeAPIKey` vazio de propósito.

---

## Comandos

| Comando | Quem usa | O que faz |
| --- | --- | --- |
| `/tv` | qualquer jogador | Abre/fecha o controle remoto da TV mais próxima (`Config.OpenCommand`) |
| `/tv 0-100` | qualquer jogador | Ajusta o volume **só para você** (0 muta) |
| `/tv off` | qualquer jogador | Muta a TV apenas para você |
| `/spawntv [modelo]` | admin | Cria uma TV à frente do ped (padrão `Config.DefaultSpawnModel`) |
| `/tvedit` | admin | Liga/desliga o modo construtor |
| `/savetv` | admin | Grava as TVs atuais no banco e sincroniza para todos |
| `/deletetv` | admin | Remove a TV mais próxima (até 15 m) e encerra o áudio dela |
| `/wipetv` | admin | Remove todas as TVs do mapa e do banco |

Também é possível abrir o controle com **E** (`INPUT_CONTEXT`) quando o prompt
aparece perto de uma TV.

No modo construtor: `E` seleciona, `ENTER` trava/destrava a edição,
`W/A/S/D` movem no plano, setas ↑/↓ mudam a altura, setas ←/→ giram e `Q/E`
inclinam.

---

## Configuração

Tudo fica em `config.lua`.

### Player DUI

| Chave | Padrão | Descrição |
| --- | --- | --- |
| `TVPlayerURL` | `""` | Página usada pela DUI. Vazio = `https://cfx-nui-<recurso>/html/tv_screen.html`. Preencha só se for hospedar em outro domínio `https`. |
| `TVPlayerFallback` | `true` | Tenta `nui://` quando a página `https` não responde. |
| `DuiLoadTimeout` | `9000` | Milissegundos sem `ready` da DUI antes de trocar de URL. |
| `DuiWidth` / `DuiHeight` | `1280` / `720` | Resolução da textura 3D (16:9). |

### Comportamento

| Chave | Padrão | Descrição |
| --- | --- | --- |
| `YoutubeAPIKey` | `""` | Chave da YouTube Data API v3. Vazio = busca pública no servidor. |
| `AdminPermission` | `"Admin"` | Grupo/permissão do vRP exigida pelos comandos de admin. |
| `DefaultSpawnModel` | `"prop_tv_flat_01"` | Modelo usado por `/spawntv` sem argumento. |
| `OpenCommand` | `"tv"` | Nome do comando que abre o controle. |
| `InteractDistance` | `3.5` | Distância (m) para o prompt de interação e o `/tv`. |

### Modelos de TV (`Config.TVObjects`)

Cada entrada registra um modelo e o raio de renderização/áudio:

```lua
{
    model = 'prop_tv_flat_01',
    distance = 22.0
}
```

| Campo | Descrição |
| --- | --- |
| `model` | Nome do modelo do prop. |
| `distance` | Raio em metros em que a DUI é criada, renderizada e audível. |
| `screen` | Opcional. Ajuste fino do vidro, quando ele não ocupa ~94% da caixa do modelo. |
| `screen.inset` | Fração da caixa ocupada pelo vidro (padrão `0.94`). |
| `screen.vBias` | Altura relativa do centro do vidro dentro da caixa (padrão `0.5`). |
| `screen.x` | Centro horizontal do vidro (padrão: centro da caixa). |
| `screen.z` | Centro vertical absoluto do vidro. |
| `screen.mirror` | Gira a imagem 180° se o texto aparecer espelhado. |

Modelos fora da lista continuam funcionando: o recurso mede a *bounding box* do
prop em tempo de execução e encaixa um quadro 16:9 dentro dela.

---

## Banco de dados

As tabelas são criadas por `CREATE TABLE IF NOT EXISTS` no start do recurso.
Nada precisa ser importado à mão.

```sql
player_tv_playlists (id, passport, name, songs LONGTEXT, collaborators LONGTEXT)
player_tv_recent    (id, passport, url, title, thumb, timestamp)
                    -- UNIQUE (passport, url)
saved_custom_tvs    (id, model, x, y, z, rx, ry, rz)
```

- `passport` é o ID do personagem no vRP (`vRP.Passport`), não o `source`.
- `songs` guarda um JSON com os vídeos da playlist.
- `collaborators` guarda um JSON com passaportes convidados; a leitura já
  considera playlists compartilhadas, mas a interface ainda não tem tela para
  adicionar colaboradores.
- `saved_custom_tvs` é reescrita por inteiro a cada `/savetv`.

---

## Como funciona

```
[ NUI: controle remoto ] --NUI callback--> [ client.lua ] --evento--> [ server.lua ]
                                                                          |
                                        estado autoritativo (vídeo, tempo, volume)
                                                                          |
        [ client.lua de todos ] <--------------- evento ----------------+
                 |
                 +--> DUI (html/tv_screen.html) --> textura --> DrawSpritePoly no prop
```

1. O jogador escolhe um vídeo no controle; o cliente envia o pedido ao servidor.
2. O servidor guarda o estado daquela TV (vídeo, tempo inicial, volume, quem
   controla) e transmite para todos.
3. Cada cliente dentro do raio cria uma **DUI própria** apontando para
   `html/tv_screen.html?v=<id>&t=<segundos>&autoplay=1...`.
4. A página avisa `ready`; o cliente reenvia o estado completo (`sync`) para que
   nada se perca quando a DUI recarrega.
5. A cada frame, o cliente desenha a textura em dois triângulos por face do
   modelo, medidos na *bounding box* do prop — sem constante de escala.
6. A DUI reporta `ended`, e só o cliente controlador pede ao servidor para
   avançar a fila.

Detalhes de eventos, callbacks e matemática da tela estão em
[`DOCUMENTACAO.md`](DOCUMENTACAO.md).

---

## Solução de problemas

| Sintoma | Causa provável | O que fazer |
| --- | --- | --- |
| TV preta | DUI não carregou no cliente | Confira `Config.DuiLoadTimeout`; o recurso alterna `https` ↔ `nui://` sozinho |
| Vídeo sem áudio | Volume da TV em 0 ou mutado localmente | `/tv 100` e confira `/tv off` |
| Som em dobro | Duas DUIs no mesmo ponto | Apague props duplicados no mesmo local e use `/savetv` |
| Imagem espelhada | Modelo com o vidro do lado oposto | Adicione `screen = { mirror = true }` no modelo |
| Imagem pequena/deslocada | Vidro menor que a caixa do modelo | Ajuste `screen.inset`, `screen.vBias`, `screen.x` e `screen.z` |
| Busca não retorna nada | Sem chave e página do YouTube bloqueada | Informe `Config.YoutubeAPIKey` ou teste a rede do servidor |
| "Cota da API esgotada" | Limite diário da Data API | A busca cai automaticamente no modo público |
| Comandos de admin não funcionam | Grupo diferente | Ajuste `Config.AdminPermission` |
| TVs sumiram | Banco limpo ou modelo inválido | Rode `/savetv` novamente; confira os modelos no `config.lua` |

Para depurar, ative o console do cliente (`F8`) e observe as mensagens de
`[SolisTV]` no console do servidor.

---

## Limitações conhecidas

- **Controle compartilhado**: qualquer jogador perto da TV pode pausar, pular ou
  desligar o vídeo pelo controle remoto. Não há permissão por TV (o controle
  administrativo é só para spawn/edição/salvamento).
- **Colaboradores de playlist**: o banco e a consulta suportam, a interface
  ainda não expõe o convite.
- **YouTube**: o recurso depende dos termos e da disponibilidade do embed do
  YouTube; vídeos com embed bloqueado aparecem como erro no player.
- **DUI**: alguns clientes podem não carregar a página `https`; nesse caso o
  fallback `nui://` é usado e o comportamento varia por build.
- **Uma TV por posição**: a identificação da TV usa as coordenadas arredondadas
  (`x_y_z`), então dois props no mesmo metro podem ser tratados como um só.
- **Sem servidor de mídia próprio**: não há streaming de arquivos locais, apenas
  YouTube.

---

## Licença

Distribuído sob a **Apache License 2.0**. O texto completo está em
[`LICENSE`](LICENSE).

Base original do player e da ideia de TV 3D: *Ac Loaf / Mew Team*. Alterações,
reescrita da DUI, sincronização, playlists e editor: **Solis**.
