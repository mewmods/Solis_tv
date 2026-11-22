# Solis TV — Documentação técnica

Referência interna do recurso: arquivos, fluxo de rede, eventos, protocolo da
DUI, geometria da tela 3D, banco de dados e pontos de atenção.

- [Visão geral](#visão-geral)
- [Estrutura de arquivos](#estrutura-de-arquivos)
- [Fluxo de dados](#fluxo-de-dados)
- [Eventos de rede](#eventos-de-rede)
- [Callbacks NUI](#callbacks-nui)
- [Mensagens Lua → NUI](#mensagens-lua--nui)
- [Interface Tunnel (vRP)](#interface-tunnel-vrp)
- [Protocolo da DUI](#protocolo-da-dui)
- [Geometria da tela 3D](#geometria-da-tela-3d)
- [Permissões](#permissões)
- [Banco de dados](#banco-de-dados)
- [Desempenho](#desempenho)
- [Segurança e privacidade](#segurança-e-privacidade)
- [Como estender](#como-estender)

---

## Visão geral

O `solis_tv` transforma props de TV do GTA V em telas de vídeo sincronizadas.
Cada TV tem uma **DUI** própria (navegador offscreen do CEF) apontando para
`html/tv_screen.html`, que embute o player do YouTube. A textura da DUI é
desenhada a cada frame sobre a caixa do modelo, então a imagem acompanha
posição, rotação, escala e inclinação do prop.

Três peças mantêm o estado coerente:

| Camada | Responsabilidade |
| --- | --- |
| `server.lua` | Estado autoritativo das TVs (`serverTVs`), tempo por `os.time()`, permissões, MySQL, busca no YouTube, playlists |
| `client.lua` | Ciclo de vida das DUIs no raio, desenho 3D, editor, controle remoto, volume individual |
| `html/*` | Controle remoto (NUI), player da TV (DUI) e estilos |

O servidor **não** guarda texturas nem DUIs: ele só replica estado. Se um
jogador entra depois, recebe `syncAll` e monta a DUI já no segundo correto.

---

## Estrutura de arquivos

```
solis_tv/
├── fxmanifest.lua          manifesto (lua54, ui_page, shared/client/server)
├── config.lua              todas as opções, incluindo Config.TVObjects
├── client.lua              DUIs, render 3D, editor, comandos do jogador
├── server.lua              estado, permissões, MySQL, busca, playlists
├── html/
│   ├── index.html          controle remoto (NUI)
│   ├── script.js           lógica do controle (JS puro, sem build)
│   ├── style.css           tema claro/escuro
│   └── tv_screen.html      player da TV (DUI), YouTube IFrame API
├── README.md
├── DOCUMENTACAO.md
└── LICENSE
```

O `fxmanifest.lua` declara:

```lua
shared_scripts { '@vrp/lib/utils.lua', 'config.lua' }
client_scripts { 'client.lua' }
server_scripts { 'server.lua' }
ui_page 'html/index.html'
files { 'html/index.html', 'html/tv_screen.html', 'html/style.css', 'html/script.js' }
dependencies { 'oxmysql' }
```

> `tv_screen.html` **precisa** estar em `files`: é ela que a DUI carrega.

---

## Fluxo de dados

### Tocar um vídeo

```
NUI (index.html)
  └─ postNUI('playMusic', { url, title, thumb, duration })
       └─ client.lua: GetClosestTV() → TriggerServerEvent('solisTV:server:play', tvId, data)
            └─ server.lua: grava serverTVs[tvId] (startedAt, controller = src)
                 ├─ TriggerClientEvent('solisTV:client:destroy', -1, tvId)   -- fecha DUI antiga
                 └─ TriggerClientEvent('solisTV:client:play', -1, tvId, data)
                      └─ client.lua: limpa memória, cria DUI quando o ped entra no raio
                           └─ html/tv_screen.html: player.cueVideoById + sync
```

### Controle (pause, seek, volume, velocidade, legendas)

```
NUI → 'controlMusic' → 'solisTV:server:control' (tvId, action, value)
      → server recalcula currentTime → 'solisTV:client:control' (-1, ...)
      → cada cliente: atualiza estado local + PushDuiState() (sync)
```

### Entrada de um jogador no servidor

```
server: requestSync → payload com todas as TVs (currentTime calculado)
                     + savedCustomTvs, se existirem
client: monta activeTVs, a thread de ciclo de vida cria DUI ao entrar no raio
```

### Fim de vídeo

```
DUI → POST /tvDuiEvent { ev:'ended', id }
   → client: se tv.controller == meu server id → 'solisTV:server:ended'
   → server: pausa no fim e replica 'solisTV:client:control' ('pause')
   → client controlador: SendNUIMessage({ type:'songEnded' }) avança a fila do NUI
```

---

## Eventos de rede

### Cliente → servidor

| Evento | Parâmetros | Descrição |
| --- | --- | --- |
| `solisTV:server:requestSync` | — | Pede o estado atual e as TVs salvas |
| `solisTV:server:play` | `tvId, data` | Inicia um vídeo na TV |
| `solisTV:server:control` | `tvId, action, value` | `pause`, `resume`, `seek`, `volume`, `speed`, `cc` |
| `solisTV:server:ended` | `tvId` | Fim de vídeo reportado pelo controlador |
| `solisTV:server:destroy` | `tvId` | Desliga a TV |
| `solisTV:server:saveCustomTvs` | `tvData` | Regrava a lista de TVs (admin) |
| `solisTV:server:searchYouTube` | `query` | Busca no YouTube (cache de 5 min) |
| `solisTV:server:createPlaylist` | `name, songsJson` | Cria playlist do personagem |
| `solisTV:server:deletePlaylist` | `id` | Exclui playlist do próprio dono |
| `solisTV:server:addSongToPlaylist` | `playlistId, song` | Adiciona vídeo |
| `solisTV:server:updatePlaylistSongs` | `playlistId, songs` | Reordena/atualiza a lista |
| `solisTV:server:addRecentSong` | `song` | Upsert em `player_tv_recent` |

### Servidor → cliente

| Evento | Parâmetros | Descrição |
| --- | --- | --- |
| `solisTV:client:syncAll` | `tvs` | Snapshot completo das TVs ativas |
| `solisTV:client:spawnSavedTvs` | `lista` | Spawna as TVs do banco |
| `solisTV:client:play` | `tvId, data` | Novo vídeo |
| `solisTV:client:control` | `tvId, action, value, currentSec` | Mudança de estado |
| `solisTV:client:destroy` | `tvId` | Remove a TV/DUI |
| `solisTV:client:notify` | `type, text, title` | Toast na NUI |
| `solisTV:client:refreshPlaylists` | — | Pede à NUI para recarregar playlists |
| `solisTV:client:searchResults` | `results, err` | Resultado da busca pública |
| `solisTV:client:executeAdminCommand` | `cmd, argModel` | Executa `spawntv`, `deletetv`, `tvedit`, `savetv`, `wipetv` |

### Estrutura de `data` em `solisTV:server:play`

```lua
{
    videoId  = "dQw4w9WgXcQ",   -- 11 caracteres
    url      = "https://www.youtube.com/watch?v=...",
    title    = "Título",
    thumb    = "https://img.youtube.com/vi/.../mqdefault.jpg",
    duration = 213,             -- segundos (0 = desconhecida)
    coords   = vector3(...),    -- posição da TV
    model    = "prop_tv_flat_01",
    distance = 22.0,
    volume   = 50               -- 0-100
}
```

---

## Callbacks NUI

Registrados em `client.lua` com `RegisterNUICallback`:

| Callback | Payload | Retorno |
| --- | --- | --- |
| `close` | — | `'ok'` — fecha o controle e libera o foco |
| `playMusic` | `{ url, title, thumb, duration }` | `'ok'` ou `'error'` |
| `controlMusic` | `{ action, value, time }` | `'ok'` ou `'error'` |
| `destroyCurrentTV` | — | `'ok'` ou `'error'` |
| `searchYouTube` | `{ query }` | `'ok'` (resultado vem por evento) |
| `getPlaylists` | — | array via Tunnel |
| `getRecentSongs` | — | array via Tunnel |
| `createPlaylist` | `{ name, songs }` | `'ok'` |
| `deletePlaylist` | `{ id }` | `'ok'` |
| `addSongToPlaylist` | `{ playlistId, song }` | `'ok'` |
| `updatePlaylistSongs` | `{ id, songs }` | `'ok'` |
| `tvDuiEvent` | `{ ev, id, ... }` | `'ok'` — eventos vindos da DUI |

O controle só abre com uma TV a até `Config.InteractDistance + 1.0` metros, e
`playMusic` revalida a distância (+2 m) antes de enviar ao servidor.

---

## Mensagens Lua → NUI

Enviadas com `SendNUIMessage` e tratadas em `html/script.js`:

| `type` | Conteúdo | Efeito |
| --- | --- | --- |
| `ui` | `status`, `apiKey`, `state` | Abre/fecha o controle e hidrata o estado |
| `updateProgress` | `current`, `max` | Atualiza a barra de progresso |
| `toast` | `toastType`, `text`, `title` | Mostra notificação |
| `searchResults` | `results`, `error` | Renderiza resultados da busca pública |
| `fetchPlaylists` | — | Recarrega playlists via `getPlaylists` |
| `songEnded` | — | Avança a fila local (só no controlador) |

`apiKey` é apenas a chave pública do `config.lua` repassada à NUI para a busca
direta na YouTube Data API. **Nunca** coloque credenciais privadas ali: tudo que
vai para a NUI é visível ao jogador.

---

## Interface Tunnel (vRP)

O servidor expõe duas funções para o cliente via `Tunnel.bindInterface`:

```lua
TvServer.getPlaylists()    -- playlists do personagem (dono ou colaborador)
TvServer.getRecentSongs()  -- últimas 6 músicas do personagem
```

Toda playlist é escopada por `vRP.Passport(source)`; o cliente nunca informa o
próprio ID. `deletePlaylist` só apaga quando `passport` bate com o dono.

---

## Protocolo da DUI

### URL inicial

```
https://cfx-nui-solis_tv/html/tv_screen.html
    ?r=solis_tv
    &id=<tvId>
    &v=<videoId>
    &t=<segundos>
    &vol=<0-100>
    &autoplay=1|0
    &speed=<0.5-2.0>
    &cc=1|0
```

Com `Config.TVPlayerFallback`, a segunda tentativa usa
`nui://solis_tv/html/tv_screen.html` com os mesmos parâmetros.

### DUI → cliente

`POST /tvDuiEvent` (JSON), tentando `https://<host>/`, `https://<recurso>/` e
`https://cfx-nui-<recurso>/` até um responder:

| `ev` | Campos extras | Significado |
| --- | --- | --- |
| `ready` | `duration` | Player pronto; dispara o `sync` completo |
| `state` | `state` (1 tocando, 2 pausado, 3 buffer, 0 encerrado) | Mudança de estado |
| `duration` | `duration` | Duração descoberta |
| `time` | `time`, `duration` | Progresso periódico |
| `ended` | — | Vídeo terminou |
| `error` | `code` | Erro do player (153 = embed recusado → recria a DUI) |

### Cliente → DUI

`SendDuiMessage(handle, json.encode({ action = 'sync', ... }))`:

```json
{
  "action": "sync",
  "v": "videoId",
  "t": 42,
  "vol": 50,
  "playing": true,
  "speed": 1.0,
  "cc": false
}
```

Enviado no `ready` e a cada controle, para que volume/velocidade/legendas
sobrevivam a recargas da página.

---

## Geometria da tela 3D

O quadro é calculado em **metros**, a partir da *bounding box* do modelo:

```lua
local minDim, maxDim = GetModelDimensions(hash)
local boxWidth  = maxDim.x - minDim.x
local boxHeight = maxDim.z - minDim.z

local h = math.min(boxHeight * inset, boxWidth * inset * (9 / 16))
local w = h * (16 / 9)
```

- `inset` vem de `screen.inset` (padrão `0.94`), ou seja, o vidro ocupa até 94%
  da caixa do modelo.
- O quadro é centralizado em `cx`/`cz`, com `vBias` deslocando a altura.
- O desenho acontece nas duas faces Y (`yMin - 0.004` e `yMax + 0.004`), então
  não é preciso configurar de que lado está a tela.
- Cada face é composta por 4 triângulos (duas ordens de vértices por triângulo),
  porque o jogo descarta faces viradas para o outro lado.
- A textura vem de um par `txd`/`txn` **novo a cada DUI** (`solistv_txd_<n>`),
  já que `CreateRuntimeTxd`/`CreateRuntimeTextureFromDuiHandle` não aceitam
  reutilizar nomes — com nome fixo a TV voltava preta ao sair e voltar ao raio.
- Modelos fora do `Config.TVObjects` funcionam: a caixa é medida em runtime e o
  resultado fica em `screenSpecCache`. Se o modelo ainda não estiver carregado
  (dimensões zeradas), a medição é refeita na próxima chamada.

Ajustes por modelo, quando o vidro não é quase toda a caixa:

```lua
{
    model = 'xm_prop_x17_tv_flat_02',
    distance = 20.0,
    screen = { inset = 0.96, vBias = 0.5 } -- x, z e mirror também são aceitos
}
```

---

## Permissões

```lua
Config.AdminPermission = "Admin"
```

`hasPermission(source)` resolve o ID do personagem e testa, nesta ordem:

1. `vRP.HasGroup(user_id, grupo)`
2. `vRP.hasGroup(user_id, grupo)`
3. `vRP.hasPermission(user_id, grupo)` ou `vRP.hasPermission(user_id, "admin.permissao")`

Os comandos `spawntv`, `deletetv`, `tvedit`, `savetv` e `wipetv` checam a
permissão **no servidor** antes de disparar o evento para o cliente, e
`solisTV:server:saveCustomTvs` revalida por conta própria (é um evento de rede).

O controle remoto (`/tv`, play, pause, volume) **não** exige permissão: qualquer
jogador perto da TV pode operá-la. Se o servidor precisar de controle por TV,
adicione a checagem em `solisTV:server:play` e `solisTV:server:control`.

---

## Banco de dados

Criado automaticamente em `server.lua` no start (após 1 s):

```sql
CREATE TABLE IF NOT EXISTS `player_tv_playlists` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `passport` INT NOT NULL,
    `name` VARCHAR(100) NOT NULL,
    `songs` LONGTEXT NOT NULL DEFAULT '[]',
    `collaborators` LONGTEXT NOT NULL DEFAULT '[]',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `player_tv_recent` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `passport` INT NOT NULL,
    `url` VARCHAR(255) NOT NULL,
    `title` VARCHAR(255) NOT NULL,
    `thumb` VARCHAR(255) NOT NULL,
    `timestamp` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `unique_tv_song` (`passport`, `url`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `saved_custom_tvs` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `model` VARCHAR(100) NOT NULL,
    `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL,
    `rx` FLOAT NOT NULL, `ry` FLOAT NOT NULL, `rz` FLOAT NOT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Observações:

- `saved_custom_tvs` é `TRUNCATE` + `INSERT` em lote a cada `/savetv`.
- `collaborators` é um JSON de passaportes; `getPlaylists` usa
  `collaborators LIKE '%"<passport>"%'`. A UI ainda não escreve nessa coluna.
- A busca de playlists usa `query_async`; as escritas usam os callbacks do
  `oxmysql`.

---

## Desempenho

- A thread de ciclo de vida roda a cada **400 ms** e só cria/recria DUI quando o
  jogador entra ou sai do raio da TV.
- A thread de renderização roda a `Wait(0)` apenas com TV carregada na sessão;
  sem TVs por perto, espera **300 ms** por iteração.
- A barra de progresso do NUI atualiza a cada **1 s** (não a cada frame).
- A busca no YouTube tem cache em memória de **5 minutos** por consulta e limita
  o resultado a **16 vídeos**.
- Cada TV carregada custa uma DUI (CEF) + uma textura. Raios grandes
  (`distance`) fazem mais jogadores carregarem DUI ao mesmo tempo — dimensione
  `Config.TVObjects` pensando nisso.
- A DUI é destruída por `DestroyDui` ao sair do raio, ao deletar o prop, ao
  trocar de vídeo e no `onResourceStop`.

---

## Segurança e privacidade

- Nenhuma credencial privada deve ficar no `config.lua`. A única chave prevista
  é `Config.YoutubeAPIKey`, que é **pública por natureza** (vai para o cliente e
  é usada em requisições do navegador). Restrinja a chave por referrer/API no
  Google Cloud para reduzir abuso.
- Toda query usa parâmetros (`?`) via `oxmysql`; não há concatenação de valores
  vindos do jogador.
- Eventos de rede que alteram dados (`saveCustomTvs`, playlists) revalidam
  permissão/passaporte no servidor.
- URLs e títulos exibidos na NUI passam por `escapeHtml` no `script.js`.
- O servidor faz requisição HTTP para `youtube.com` quando a busca pública é
  usada; nenhum dado de jogador é enviado nessa requisição.
- O recurso não grava logs de vídeos assistidos além da tabela de recentes por
  personagem.

---

## Como estender

**Adicionar um modelo de TV**: inclua uma entrada em `Config.TVObjects` com
`model` e `distance`; se a imagem ficar torta ou pequena, use `screen`.

**Trocar o comando do controle**: `Config.OpenCommand = "controle"`.

**Usar outro domínio de player**: `Config.TVPlayerURL = "https://meu-cdn/tv.html"`,
mantendo os parâmetros de query (`r`, `id`, `v`, `t`, `vol`, `autoplay`, `speed`,
`cc`) e o `POST /tvDuiEvent`.

**Permissão por TV**: adicione `owner`/`group` em `serverTVs` e valide em
`solisTV:server:play` e `solisTV:server:control` antes de replicar.

**Colaboradores de playlist**: grave o JSON em `collaborators` e a consulta de
`getPlaylists` já passa a retornar a playlist para os convidados.
