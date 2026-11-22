Config = {}

-- ===================================================
-- PLAYER DUI LOCAL
-- ===================================================
-- Deixe vazio para usar a pagina local do proprio recurso:
--   https://cfx-nui-<nome_do_recurso>/html/tv_screen.html
-- A pagina sobe em https e a DUI toca video E audio diretamente.
-- So preencha se quiser hospedar a pagina em outro dominio https.
Config.TVPlayerURL = ""

-- Alguns clients so carregam DUI pelo esquema nui://. Se a pagina https nao
-- responder, o cliente tenta esse fallback automaticamente.
Config.TVPlayerFallback = true

-- Tempo (ms) sem "ready" da DUI antes de tentar a proxima URL.
Config.DuiLoadTimeout = 9000

-- Resolucao da DUI usada na textura 3D.
Config.DuiWidth = 1280
Config.DuiHeight = 720

-- Chave da Google YouTube Data API v3 (opcional, para pesquisa por texto
-- com duracao dos videos). Crie a sua em https://console.cloud.google.com/apis
-- e cole aqui; nunca comite uma chave real.
-- Deixe vazio para usar somente a busca publica do YouTube, feita pelo
-- servidor do recurso (sem cota e sem chave).
Config.YoutubeAPIKey = ""

-- Permissao necessaria para usar os comandos de spawn/edicao de TVs
Config.AdminPermission = "Admin"

-- Modelo padrao ao digitar /spawntv sem argumentos
Config.DefaultSpawnModel = "prop_tv_flat_01"

Config.OpenCommand = "tv" -- nome do comando que abre o controle
Config.InteractDistance = 3.5

-- ===================================================
-- GEOMETRIA DA TELA 3D
-- ===================================================
-- O quadro do video e desenhado direto na geometria do prop, em metros e em
-- 16:9 (mesma proporcao do DUI), sempre encaixado dentro da caixa de cada
-- modelo. Nao existe constante de escala para calibrar aqui.

-- ===================================================
-- MODELOS DE TV
-- ===================================================
-- distance = raio de renderizacao e de audio, em metros.
--
-- 'screen' e opcional: use so quando o vidro nao ocupar ~94% da caixa do
-- modelo. Campos (todos em metros, relativos a origem do prop):
--   inset  = fracao do modelo ocupada pelo vidro (padrao 0.94)
--   vBias  = altura relativa do centro do vidro na caixa (padrao 0.5)
--   x      = centro horizontal do vidro (padrao: centro da caixa)
--   z      = centro vertical do vidro   (padrao: minDim.z + vBias * altura)
--   mirror = gira a imagem 180 graus, se o texto aparecer espelhado
Config.TVObjects = {
    {
        model = 'prop_tv_flat_01',
        distance = 22.0
    },
    {
        model = 'prop_tv_flat_michael',
        distance = 20.0
    },
    {
        model = 'prop_trev_tv_01',
        distance = 15.0
    },
    {
        model = 'prop_tv_flat_03b',
        distance = 18.0
    },
    {
        model = 'prop_tv_flat_03',
        distance = 18.0
    },
    {
        model = 'prop_tv_flat_02b',
        distance = 20.0
    },
    {
        model = 'prop_tv_flat_02',
        distance = 20.0
    },
    -- Usada pelas casas do mapa customizado (rc_maps2 / ZonaMods).
    -- TV de parede fina: o vidro ocupa quase toda a caixa do modelo.
    {
        model = 'xm_prop_x17_tv_flat_02',
        distance = 20.0,
        screen = { inset = 0.96, vBias = 0.5 }
    },
    -- Telao gigante para eventos
    {
        model = 'prop_huge_display_01',
        distance = 120.0
    }
}
