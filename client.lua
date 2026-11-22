local RES = GetCurrentResourceName()

local Tunnel = module("vrp", "lib/Tunnel")
local Proxy = module("vrp", "lib/Proxy")
vRP = Proxy.getInterface("vRP")

local TvServer = Tunnel.getInterface(RES)

local display = false
local currentActiveTvId = nil
local activeTVs = {}

-- TVs Spawnadas Dinamicamente
local spawnedCustomTvs = {}
local isEditing = false
local selectedTv = nil
local editModeLocked = false

-- Volume Local Individual
local localUserVolume = 1.0
local isLocalMuted = false

-- ===================================================
-- NOTIFICAÇÕES E EVENTOS
-- ===================================================

local function Notify(type, text, title)
    SendNUIMessage({
        type = "toast",
        toastType = type or "info",
        text = text,
        title = title or "Solis TV"
    })
end

RegisterNetEvent("solisTV:client:notify", function(type, text, title)
    Notify(type, text, title)
end)

RegisterNetEvent("solisTV:client:refreshPlaylists", function()
    SendNUIMessage({ type = "fetchPlaylists" })
end)

RegisterNetEvent("solisTV:client:searchResults", function(results, err)
    SendNUIMessage({ type = "searchResults", results = results or {}, error = err })
end)

local function CalculateLocalVolume(serverVolume)
    if isLocalMuted then return 0 end
    local base = serverVolume or 50
    local effective = math.floor(base * localUserVolume)
    return math.max(0, math.min(100, effective))
end

local function GetTVTimestamp(tv)
    if not tv then return 0 end
    local base = tv.currentTime or 0
    if tv.playing and tv.clientReceivedAt then
        local delta = math.floor((GetGameTimer() - tv.clientReceivedAt) / 1000)
        return math.max(0, base + delta)
    end
    return base
end

local function GetTVId(coords)
    return string.format("%.1f_%.1f_%.1f", coords.x, coords.y, coords.z)
end

-- Coordenadas chegam pela rede; normaliza para vector3 para nunca comparar
-- nil/table com um vetor (era uma das causas de TV "sumir" para um jogador).
local function ToVec3(value)
    if type(value) == 'vector3' then return value end
    if type(value) == 'table' then
        return vector3(tonumber(value.x) or 0.0, tonumber(value.y) or 0.0, tonumber(value.z) or 0.0)
    end
    return nil
end

-- Resolve o prop exato da TV. Todos os jogadores usam o mesmo raio e o mesmo
-- modelo, então o objeto escolhido é sempre o mesmo em todas as máquinas.
local function FindTvEntity(coords, model, radius)
    if not coords or not model then return 0 end
    local obj = GetClosestObjectOfType(coords.x, coords.y, coords.z, radius or 2.5, GetHashKey(model), false, false, false)
    return obj or 0
end

-- Busca a TV que está ESTRITAMENTE mais perto do jogador (elimina o bug de aplicar escala da TV errada)
local function GetClosestTV(maxDist)
    local ped = PlayerPedId()
    local pedCoords = GetEntityCoords(ped)
    maxDist = maxDist or (Config and Config.InteractDistance or 3.5)

    if not Config or not Config.TVObjects then return nil, nil, nil, nil end

    local closestObj = nil
    local closestDist = maxDist + 1.0
    local closestCfg = nil

    for _, cfg in ipairs(Config.TVObjects) do
        local obj = GetClosestObjectOfType(pedCoords.x, pedCoords.y, pedCoords.z, maxDist, GetHashKey(cfg.model), false, false, false)
        if DoesEntityExist(obj) then
            local dist = #(pedCoords - GetEntityCoords(obj))
            if dist < closestDist then
                closestDist = dist
                closestObj = obj
                closestCfg = cfg
            end
        end
    end

    if closestObj then
        local objCoords = GetEntityCoords(closestObj)
        return closestObj, objCoords, closestCfg, GetTVId(objCoords)
    end

    return nil, nil, nil, nil
end

local function ExtractYoutubeId(url)
    if not url then return nil end
    local match = string.match(url, "youtu%.be/([%w_%-]+)") or
                  string.match(url, "youtube%.com/watch%?v=([%w_%-]+)") or
                  string.match(url, "youtube%.com/embed/([%w_%-]+)") or
                  string.match(url, "youtube%.com/v/([%w_%-]+)")
    if match and #match == 11 then
        return match
    elseif #url == 11 then
        return url
    end
    return match
end

local function CleanTVMemory(tv)
    if not tv then return end

    if tv.DUI and tv.DUI.Long then
        DestroyDui(tv.DUI.Long)
        tv.DUI = nil
    end

    tv.Texture = nil
    tv.IsLoaded = false
    tv.Entity = nil
    tv.duiReady = false
    tv.duiRetries = 0
    tv.duiCreatedAt = 0
    tv.urlIndex = 0
end

-- ===================================================
-- PLAYER DUI LOCAL
-- ===================================================
-- A pagina tv_screen.html e servida pelo proprio recurso em https. O CEF do
-- FiveM nao manda Referer para nui://, mas a URL cfx-nui-... tem origem https
-- valida — exatamente o que o embed do YouTube exige. Video e audio saem da
-- mesma DUI.
local function PlayerURLs()
    local urls = {}
    local custom = Config and Config.TVPlayerURL

    if type(custom) == 'string' and custom ~= '' then
        urls[1] = custom
    else
        urls[1] = ('https://cfx-nui-%s/html/tv_screen.html'):format(RES)
    end

    if Config and Config.TVPlayerFallback ~= false then
        local fallback = ('nui://%s/html/tv_screen.html'):format(RES)
        if fallback ~= urls[1] then urls[2] = fallback end
    end

    return urls
end

local function BuildPlayerUrl(tv, index)
    local urls = PlayerURLs()
    local base = urls[index] or urls[1]
    local params = {
        'r=' .. RES,
        'id=' .. tostring(tv.id or tv.tvId or ''),
        'v=' .. tostring(tv.videoId or ''),
        't=' .. tostring(math.floor(GetTVTimestamp(tv))),
        'vol=' .. tostring(CalculateLocalVolume(tv.volume)),
        'autoplay=' .. ((tv.playing == true) and '1' or '0'),
        'speed=' .. tostring(tonumber(tv.speed) or 1.0),
        'cc=' .. ((tv.cc == true) and '1' or '0')
    }
    local separator = base:find('?', 1, true) and '&' or '?'
    return base .. separator .. table.concat(params, '&')
end

-- Reenvia o estado cheio para a DUI. Chamado no "ready" e a cada controle,
-- entao volume/velocidade/legendas nao se perdem quando a pagina recarrega.
local function PushDuiState(tv)
    if not (tv and tv.IsLoaded and tv.DUI and tv.DUI.Long and tv.duiReady) then return end

    SendDuiMessage(tv.DUI.Long, json.encode({
        action = 'sync',
        v = tostring(tv.videoId or ''),
        t = math.floor(GetTVTimestamp(tv)),
        vol = CalculateLocalVolume(tv.volume),
        playing = (tv.playing == true),
        speed = tonumber(tv.speed) or 1.0,
        cc = (tv.cc == true)
    }))
end

-- ===================================================
-- GEOMETRIA 3D DA TELA
-- ===================================================
-- O quadro é medido na bounding box do próprio modelo, então sempre cai
-- sobre o vidro da TV — inclusive modelos que não estão no config, como os
-- usados por casas e mapas customizados.
local screenSpecCache = {}
local modelScreenConfig = {}

for _, entry in ipairs((Config and Config.TVObjects) or {}) do
    modelScreenConfig[entry.model] = entry
end

-- Cada DUI recebe um par txd/txn novo. CreateRuntimeTxd e
-- CreateRuntimeTextureFromDuiHandle não aceitam reaproveitar um nome já
-- usado: com nome fixo a TV voltava preta ao sair e voltar ao raio dela.
local textureCounter = 0
local function NextTextureId()
    textureCounter = textureCounter + 1
    return tostring(textureCounter)
end

local function CreateTvDui(tv)
    local urls = PlayerURLs()
    tv.urlIndex = ((tv.urlIndex or 0) % #urls) + 1
    tv.duiRetries = (tv.duiRetries or 0) + 1

    local url = BuildPlayerUrl(tv, tv.urlIndex)
    local dui = CreateDui(url, Config.DuiWidth or 1280, Config.DuiHeight or 720)
    local handle = GetDuiHandle(dui)

    if not handle or handle == 0 then
        if dui then DestroyDui(dui) end
        return false
    end

    local uid = NextTextureId()
    local txd = 'solistv_txd_' .. uid
    local txn = 'solistv_txn_' .. uid
    CreateRuntimeTextureFromDuiHandle(CreateRuntimeTxd(txd), txn, handle)

    tv.Texture = { Dict = txd, Name = txn }
    tv.DUI = { Long = dui, Obj = handle }
    tv.IsLoaded = true
    tv.duiReady = false
    tv.duiCreatedAt = GetGameTimer()
    return true
end

-- Tentativa seguinte sem perder a referencia do prop (a DUI pode demorar a
-- subir no CEF; recriar com a URL alternativa resolve na maioria dos clients).
local function RetryDui(tv)
    if tv.DUI and tv.DUI.Long then DestroyDui(tv.DUI.Long) end
    tv.DUI = nil
    tv.Texture = nil
    tv.IsLoaded = false
    tv.duiReady = false
    tv.duiCreatedAt = 0
end

local function GetScreenSpec(model)
    if not model then return nil end

    local cached = screenSpecCache[model]
    if cached ~= nil then return cached or nil end

    local hash = GetHashKey(model)
    if IsModelValid and not IsModelValid(hash) then return nil end

    local minDim, maxDim = GetModelDimensions(hash)
    local boxWidth  = maxDim.x - minDim.x
    local boxHeight = maxDim.z - minDim.z
    -- Sem medidas ainda (modelo não carregado): tenta de novo na próxima
    -- chamada em vez de guardar a falha no cache.
    if boxWidth <= 0.01 or boxHeight <= 0.01 then return nil end

    local entry = modelScreenConfig[model]
    local cfg = (entry and entry.screen) or {}
    local fit = cfg.inset or 0.94

    -- Quadro 16:9 (mesma proporção do DUI) encaixado DENTRO da caixa do
    -- modelo. Tudo em metros: o desenho é em coordenadas de mundo, então não
    -- existe constante de escala para calibrar.
    local h = math.min(boxHeight * fit, boxWidth * fit * (9.0 / 16.0))
    local w = h * (16.0 / 9.0)

    local spec = {
        w = w,
        h = h,
        cx = cfg.x or ((minDim.x + maxDim.x) * 0.5),
        cz = cfg.z or (minDim.z + boxHeight * (cfg.vBias or 0.5)),
        yMin = minDim.y,
        yMax = maxDim.y,
        mirror = cfg.mirror and true or false
    }

    screenSpecCache[model] = spec
    return spec
end

-- Um triângulo texturizado em coordenadas de mundo. O jogo descarta a face
-- virada para o outro lado, por isso cada triângulo sai nas duas ordens de
-- vértices: sem isso a imagem some dependendo do ângulo da câmera.
local function DrawScreenTriangle(txd, txn, a, au, av, b, bu, bv, c, cu, cv)
    DrawSpritePoly(
        a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z,
        255, 255, 255, 255, txd, txn,
        au, av, 0.0, bu, bv, 0.0, cu, cv, 0.0
    )
end

local function DrawScreenFace(tl, tr, bl, br, spec, txd, txn)
    local u0, u1 = 0.0, 1.0
    if spec.mirror then u0, u1 = 1.0, 0.0 end

    -- superior esquerdo / inferior direito / superior direito
    DrawScreenTriangle(txd, txn, tl, u0, 0.0, br, u1, 1.0, tr, u1, 0.0)
    DrawScreenTriangle(txd, txn, tr, u1, 0.0, br, u1, 1.0, tl, u0, 0.0)
    -- superior esquerdo / inferior esquerdo / inferior direito
    DrawScreenTriangle(txd, txn, tl, u0, 0.0, bl, u0, 1.0, br, u1, 1.0)
    DrawScreenTriangle(txd, txn, br, u1, 1.0, bl, u0, 1.0, tl, u0, 0.0)
end

-- Desenha o quadro nas duas faces Y do modelo. O vidro fica em uma delas e a
-- outra fica escondida dentro do corpo da TV — assim nenhum modelo precisa
-- ser configurado para "descobrir" de que lado está a tela.
local function DrawScreen(entity, spec, txd, txn)
    local hw, hh = spec.w * 0.5, spec.h * 0.5
    local nudge = 0.004

    for _, y in ipairs({ spec.yMin - nudge, spec.yMax + nudge }) do
        local tl = GetOffsetFromEntityInWorldCoords(entity, spec.cx - hw, y, spec.cz + hh)
        local tr = GetOffsetFromEntityInWorldCoords(entity, spec.cx + hw, y, spec.cz + hh)
        local bl = GetOffsetFromEntityInWorldCoords(entity, spec.cx - hw, y, spec.cz - hh)
        local br = GetOffsetFromEntityInWorldCoords(entity, spec.cx + hw, y, spec.cz - hh)
        DrawScreenFace(tl, tr, bl, br, spec, txd, txn)
    end
end

local function ApplyIndividualVolume()
    for _, tv in pairs(activeTVs) do
        PushDuiState(tv)
    end
end

-- ===================================================
-- SINCRONIZAÇÃO EM REDE E SPAWN DE TVS DO BANCO
-- ===================================================

RegisterNetEvent('solisTV:client:syncAll', function(allTvs)
    for id, tv in pairs(activeTVs) do
        if not allTvs[id] then
            CleanTVMemory(tv)
            activeTVs[id] = nil
        end
    end

    for id, data in pairs(allTvs) do
        local coords = ToVec3(data.coords)

        if coords then
            local tv = activeTVs[id]
            if not tv then
                tv = {}
                activeTVs[id] = tv
                tv.IsLoaded = false
            end

            tv.id = id
            tv.tvId = id

            if tv.videoId ~= data.videoId then CleanTVMemory(tv) end

            tv.coords = coords
            tv.model = data.model or tv.model
            tv.videoId = data.videoId
            tv.url = data.url
            tv.volume = data.volume
            tv.playing = data.playing
            tv.title = data.title
            tv.thumb = data.thumb
            tv.duration = data.duration or 0
            tv.distance = data.distance or tv.distance or 20.0
            tv.currentTime = data.currentTime or 0
            tv.speed = tonumber(data.speed) or tv.speed or 1.0
            tv.cc = data.cc == true
            tv.controller = data.controller
            tv.clientReceivedAt = GetGameTimer()
        elseif activeTVs[id] then
            CleanTVMemory(activeTVs[id])
            activeTVs[id] = nil
        end
    end
end)

RegisterNetEvent('solisTV:client:spawnSavedTvs', function(tvList)
    CreateThread(function()
        for _, tv in ipairs(spawnedCustomTvs) do
            if DoesEntityExist(tv.entity) then
                DeleteEntity(tv.entity)
            end
        end
        spawnedCustomTvs = {}

        if not tvList or #tvList == 0 then return end

        for _, data in ipairs(tvList) do
            local model = data.model
            local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
            local rx, ry, rz = tonumber(data.rx) or 0.0, tonumber(data.ry) or 0.0, tonumber(data.rz) or 0.0

            if model and x and y and z then
                local modelHash = GetHashKey(model)
                RequestModel(modelHash)
                local timeout = GetGameTimer() + 5000
                while not HasModelLoaded(modelHash) and GetGameTimer() < timeout do Wait(10) end

                if HasModelLoaded(modelHash) then
                    -- Se o mapa já tem esta TV neste ponto, reaproveita o prop
                    -- existente. Duas TVs no mesmo lugar faziam cada jogador
                    -- encontrar uma diferente e a tela aparecia quebrada.
                    local tvObj = FindTvEntity(vector3(x, y, z), model, 0.75)

                    if not DoesEntityExist(tvObj) then
                        tvObj = CreateObjectNoOffset(modelHash, x, y, z, false, false, false)
                        SetEntityRotation(tvObj, rx, ry, rz, 2, true)
                        FreezeEntityPosition(tvObj, true)
                        SetEntityInvincible(tvObj, true)
                    end

                    table.insert(spawnedCustomTvs, { entity = tvObj, model = model })
                end
            end
        end
    end)
end)

RegisterNetEvent('solisTV:client:play', function(tvId, data)
    if activeTVs[tvId] then
        CleanTVMemory(activeTVs[tvId])
    end

    local coords = ToVec3(data.coords)
    if not coords then return end

    data.coords = coords
    activeTVs[tvId] = data
    activeTVs[tvId].id = tvId
    activeTVs[tvId].tvId = tvId
    activeTVs[tvId].distance = data.distance or 20.0
    activeTVs[tvId].currentTime = data.currentTime or 0
    activeTVs[tvId].duration = data.duration or 0
    activeTVs[tvId].speed = tonumber(data.speed) or 1.0
    activeTVs[tvId].cc = data.cc == true
    activeTVs[tvId].clientReceivedAt = GetGameTimer()
    activeTVs[tvId].IsLoaded = false
    activeTVs[tvId].duiReady = false
    activeTVs[tvId].urlIndex = 0
    activeTVs[tvId].duiRetries = 0
end)

RegisterNetEvent('solisTV:client:control', function(tvId, action, value, currentSec)
    local tv = activeTVs[tvId]
    if not tv then return end

    tv.currentTime = currentSec or tv.currentTime or 0
    tv.clientReceivedAt = GetGameTimer()

    if action == 'pause' then
        tv.playing = false
    elseif action == 'resume' then
        tv.playing = true
    elseif action == 'volume' then
        tv.volume = math.floor((tonumber(value) or 0) * 100)
    elseif action == 'seek' then
        tv.currentTime = tonumber(value) or tv.currentTime
    elseif action == 'speed' then
        tv.speed = tonumber(value) or 1.0
    elseif action == 'cc' then
        tv.cc = (value == 'on' or value == true)
    end

    PushDuiState(tv)

    if display and currentActiveTvId == tvId then
        SendNUIMessage({ type = 'updateProgress', current = GetTVTimestamp(tv), max = tv.duration or 0 })
    end
end)

RegisterNetEvent('solisTV:client:destroy', function(tvId)
    if activeTVs[tvId] then
        CleanTVMemory(activeTVs[tvId])
        activeTVs[tvId] = nil
    end
end)

-- ===================================================
-- EVENTOS DA DUI (player.html local -> cliente)
-- ===================================================
-- A pagina local posta aqui quando o player fica pronto, muda de estado,
-- descobre a duracao de um video ou termina a reproducao.
RegisterNUICallback('tvDuiEvent', function(data, cb)
    local tv = data and data.id and activeTVs[data.id]
    if tv then
        local ev = data.ev

        if ev == 'ready' then
            tv.duiReady = true
            tv.duiRetries = 0
            if tonumber(data.duration) and tonumber(data.duration) > 0 then
                tv.duration = math.floor(tonumber(data.duration))
            end
            PushDuiState(tv)

        elseif ev == 'duration' then
            local duration = tonumber(data.duration) or 0
            if duration > 0 then tv.duration = math.floor(duration) end

        elseif ev == 'state' then
            local state = tonumber(data.state) or -1
            -- 1 = tocando, 2 = pausado, 3 = buffering, 0 = encerrado
            if state == 1 then
                tv.playing = true
            elseif state == 2 then
                tv.playing = false
            end

        elseif ev == 'ended' then
            tv.playing = false
            -- So o controlador avanca a fila, para todo mundo nao pular de uma vez.
            if tv.controller == GetPlayerServerId(PlayerId()) then
                TriggerServerEvent('solisTV:server:ended', data.id)
                SendNUIMessage({ type = 'songEnded' })
            end

        elseif ev == 'error' then
            if tonumber(data.code) == 153 and tv.duiRetries and tv.duiRetries < 6 then
                RetryDui(tv)
            end

        elseif ev == 'time' then
            local duration = tonumber(data.duration) or 0
            if duration > 0 then tv.duration = math.floor(duration) end
        end

        if display and currentActiveTvId == data.id then
            SendNUIMessage({ type = 'updateProgress', current = GetTVTimestamp(tv), max = tv.duration or 0 })
        end
    end

    if cb then cb('ok') end
end)

-- ===================================================
-- THREAD 1: CICLO DE VIDA DO DUI (ENTRAR E SAIR DO RAIO)
-- ===================================================
CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(100) end
    TriggerServerEvent('solisTV:server:requestSync')

    while true do
        Wait(400)
        local pedCoords = GetEntityCoords(PlayerPedId())

        for tvId, tv in pairs(activeTVs) do
            local coords = tv.coords
            local maxDist = tv.distance or 20.0

            if coords and #(pedCoords - coords) <= maxDist then
                if not tv.IsLoaded then
                    local obj = tv.Entity
                    if not obj or not DoesEntityExist(obj) then
                        obj = FindTvEntity(coords, tv.model, 2.5)
                    end

                    if DoesEntityExist(obj) then
                        tv.Entity = obj
                        CreateTvDui(tv)
                    end
                elseif not DoesEntityExist(tv.Entity) then
                    -- Prop deletado do mundo (ex: /deletetv): encerra video e audio.
                    CleanTVMemory(tv)
                elseif not tv.duiReady then
                    -- Pagina local nao respondeu: tenta a URL seguinte (https -> nui://).
                    local timeout = Config.DuiLoadTimeout or 9000
                    local maxTries = #PlayerURLs() * 3
                    if (tv.duiRetries or 0) < maxTries
                        and (GetGameTimer() - (tv.duiCreatedAt or 0)) > timeout then
                        RetryDui(tv)
                    end
                end
            elseif tv.IsLoaded then
                CleanTVMemory(tv)
            end
        end
    end
end)

-- ===================================================
-- THREAD 2: RENDERIZAÇÃO 3D
-- ===================================================
-- Cada TV desenha a própria textura DUI direto na geometria do prop. Não
-- existe scaleform compartilhado: antes, a textura de uma TV sobrepunha a das
-- outras e só a primeira ficava com o vídeo.
CreateThread(function()
    while true do
        local busy = false

        for _, tv in pairs(activeTVs) do
            if tv.IsLoaded then
                busy = true

                if not DoesEntityExist(tv.Entity) then
                    -- Prop deletado: encerra o DUI para não sobrar áudio fantasma
                    CleanTVMemory(tv)
                else
                    local spec = GetScreenSpec(tv.model)
                    local tex = tv.Texture

                    if tex and spec and IsEntityOnScreen(tv.Entity) then
                        DrawScreen(tv.Entity, spec, tex.Dict, tex.Name)
                    end
                end
            end
        end

        Wait(busy and 0 or 300)
    end
end)

-- ===================================================
-- MODO CONSTRUTOR / EDITOR 3D DE TELÕES
-- ===================================================
local function DrawText3D(x, y, z, text)
    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    if onScreen then
        SetTextScale(0.35, 0.35)
        SetTextFont(4)
        SetTextProportional(1)
        SetTextColour(255, 255, 255, 255)
        SetTextOutline()
        SetTextEntry("STRING")
        SetTextCentre(1)
        AddTextComponentString(text)
        DrawText(_x, _y)
    end
end

local function DrawUI(text)
    SetTextFont(4)
    SetTextScale(0.45, 0.45)
    SetTextColour(255, 255, 255, 255)
    SetTextOutline()
    SetTextEntry("STRING")
    AddTextComponentString(text)
    DrawText(0.35, 0.04)
end

CreateThread(function()
    while true do
        local sleep = 500
        if isEditing then
            sleep = 0
            local pCoords = GetEntityCoords(PlayerPedId())

            if not editModeLocked then
                DrawUI("~b~MODO DE SELEÇÃO\n~w~Olhe para uma TV.\n~g~[E]~w~ Selecionar\n~r~[ENTER]~w~ Editar Posição\n~y~[/tvedit]~w~ Sair")

                local closestTv, minDist = nil, 100.0
                for _, tvData in ipairs(spawnedCustomTvs) do
                    if DoesEntityExist(tvData.entity) then
                        local tCoords = GetEntityCoords(tvData.entity)
                        local dist = #(pCoords - tCoords)

                        local color = (selectedTv == tvData.entity) and {0, 255, 0, 255} or {255, 255, 255, 100}
                        DrawLine(pCoords.x, pCoords.y, pCoords.z, tCoords.x, tCoords.y, tCoords.z, color[1], color[2], color[3], color[4])
                        DrawText3D(tCoords.x, tCoords.y, tCoords.z + 1.2, tvData.model)

                        if dist < minDist then minDist, closestTv = dist, tvData.entity end
                    end
                end

                if IsControlJustPressed(0, 38) then -- E
                    selectedTv = closestTv
                    PlaySoundFrontend(-1, "SELECT", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)
                end

                if selectedTv and IsControlJustPressed(0, 191) then -- ENTER
                    editModeLocked = true
                    PlaySoundFrontend(-1, "YES", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)
                end
            else
                DrawUI("~g~MODO CONSTRUTOR~w~\n[W/A/S/D] Mover Horizontal\n[Setas Cima/Baixo] Mover Altura\n[Setas Esq/Dir] Girar\n[Q/E] Inclinar\n~y~[ENTER] Travar Posição")

                DisableControlAction(0, 30, true)
                DisableControlAction(0, 31, true)

                if DoesEntityExist(selectedTv) then
                    local coords = GetEntityCoords(selectedTv)
                    local rot = GetEntityRotation(selectedTv)
                    local moveSpeed, rotSpeed = 0.04, 0.5

                    if IsDisabledControlPressed(0, 32) then coords = coords + vector3(0, moveSpeed, 0) end
                    if IsDisabledControlPressed(0, 33) then coords = coords + vector3(0, -moveSpeed, 0) end
                    if IsDisabledControlPressed(0, 34) then coords = coords + vector3(-moveSpeed, 0, 0) end
                    if IsDisabledControlPressed(0, 35) then coords = coords + vector3(moveSpeed, 0, 0) end

                    if IsControlPressed(0, 172) then coords = coords + vector3(0, 0, moveSpeed) end
                    if IsControlPressed(0, 173) then coords = coords + vector3(0, 0, -moveSpeed) end

                    if IsControlPressed(0, 174) then rot = rot + vector3(0, 0, rotSpeed) end
                    if IsControlPressed(0, 175) then rot = rot + vector3(0, 0, -rotSpeed) end

                    if IsControlPressed(0, 44) then rot = rot + vector3(rotSpeed, 0, 0) end
                    if IsControlPressed(0, 38) then rot = rot + vector3(-rotSpeed, 0, 0) end

                    SetEntityCoordsNoOffset(selectedTv, coords.x, coords.y, coords.z, false, false, false)
                    SetEntityRotation(selectedTv, rot.x, rot.y, rot.z, 2, true)

                    if IsControlJustPressed(0, 191) then -- ENTER
                        editModeLocked = false
                        PlaySoundFrontend(-1, "YES", "HUD_FRONTEND_DEFAULT_SOUNDSET", true)
                    end
                else
                    editModeLocked = false
                end
            end
        end
        Wait(sleep)
    end
end)

-- Comandos Admin Executados do Servidor
RegisterNetEvent("solisTV:client:executeAdminCommand", function(cmd, argModel)
    CreateThread(function()
        if cmd == "spawntv" then
            local ped = PlayerPedId()
            local spawnCoords = GetEntityCoords(ped) + (GetEntityForwardVector(ped) * 3.0)
            local chosenModel = argModel or Config.DefaultSpawnModel or "prop_tv_flat_01"
            local modelHash = GetHashKey(chosenModel)

            RequestModel(modelHash)
            while not HasModelLoaded(modelHash) do Wait(10) end

            local tvObj = CreateObjectNoOffset(modelHash, spawnCoords.x, spawnCoords.y, spawnCoords.z, false, false, false)
            SetEntityHeading(tvObj, GetEntityHeading(ped))
            FreezeEntityPosition(tvObj, true)
            SetEntityInvincible(tvObj, true)

            table.insert(spawnedCustomTvs, { entity = tvObj, model = chosenModel })
            Notify("success", "TV (" .. chosenModel .. ") spawnada! Use /tvedit para mover e /savetv para gravar.", "Editor")

        elseif cmd == "deletetv" then
            local pedCoords = GetEntityCoords(PlayerPedId())
            local closestTv, closestDist, closestIndex = nil, 999.0, -1

            for i, tvData in ipairs(spawnedCustomTvs) do
                if DoesEntityExist(tvData.entity) then
                    local dist = #(pedCoords - GetEntityCoords(tvData.entity))
                    if dist < closestDist then
                        closestDist = dist
                        closestTv = tvData.entity
                        closestIndex = i
                    end
                end
            end

            if closestTv and closestDist < 15.0 then
                local tvCoords = GetEntityCoords(closestTv)

                -- 1. Encerra qualquer reprodução ativa dessa TV (desliga o áudio imediatamente)
                for id, tv in pairs(activeTVs) do
                    if tv.coords and #(tv.coords - tvCoords) <= 3.0 then
                        TriggerServerEvent('solisTV:server:destroy', id)
                        CleanTVMemory(tv)
                        activeTVs[id] = nil
                    end
                end

                -- 2. Deleta o prop físico do mapa
                DeleteEntity(closestTv)
                table.remove(spawnedCustomTvs, closestIndex)
                Notify("warning", "TV deletada e áudio encerrado! Digite /savetv para confirmar no banco.", "Editor")
            else
                Notify("error", "Nenhuma TV spawnada próxima de você.", "Editor")
            end

        elseif cmd == "tvedit" then
            isEditing = not isEditing
            selectedTv = nil
            editModeLocked = false
            Notify("info", isEditing and "Editor de TVs ATIVADO." or "Editor de TVs DESATIVADO.", "Editor")

        elseif cmd == "savetv" then
            local dataToSave = {}
            for _, tvData in ipairs(spawnedCustomTvs) do
                if DoesEntityExist(tvData.entity) then
                    local coords = GetEntityCoords(tvData.entity)
                    local rot = GetEntityRotation(tvData.entity)
                    table.insert(dataToSave, {
                        model = tvData.model,
                        x = coords.x, y = coords.y, z = coords.z,
                        rx = rot.x, ry = rot.y, rz = rot.z
                    })
                end
            end

            TriggerServerEvent("solisTV:server:saveCustomTvs", dataToSave)

        elseif cmd == "wipetv" then
            -- Encerra todas as reproduções de som ativas
            for id, tv in pairs(activeTVs) do
                TriggerServerEvent('solisTV:server:destroy', id)
                CleanTVMemory(tv)
                activeTVs[id] = nil
            end

            for _, tvData in ipairs(spawnedCustomTvs) do
                if DoesEntityExist(tvData.entity) then
                    DeleteEntity(tvData.entity)
                end
            end
            spawnedCustomTvs = {}
            TriggerServerEvent("solisTV:server:saveCustomTvs", {})
            Notify("warning", "Todas as TVs foram limpas do mapa e do banco de dados.", "Editor")
        end
    end)
end)

-- ===================================================
-- COMANDO /TV & CONTROLE NUI
-- ===================================================
local function OpenTVRemote()
    local interactDist = Config and Config.InteractDistance or 3.5
    local obj, coords, cfg, tvId = GetClosestTV(interactDist + 1.0)

    if not DoesEntityExist(obj) then
        Notify("error", "Nenhuma TV próxima encontrada!", "Solis TV")
        return
    end

    currentActiveTvId = tvId
    display = not display

    if display then
        SetNuiFocus(true, true)
        local curTv = activeTVs[tvId]
        SendNUIMessage({
            type = "ui",
            status = true,
            apiKey = Config and Config.YoutubeAPIKey or "",
            state = {
                mode = "tv",
                deviceName = "Solis TV (" .. cfg.model .. ")",
                title = curTv and curTv.title or "Nenhum vídeo em reprodução",
                playing = curTv and curTv.playing or false,
                volume = curTv and (curTv.volume / 100) or 0.5,
                duration = curTv and curTv.duration or 0,
                speed = curTv and tonumber(curTv.speed) or 1.0,
                cc = curTv and curTv.cc == true
            }
        })
    else
        SetNuiFocus(false, false)
        SendNUIMessage({ type = "ui", status = false })
    end
end

RegisterCommand((Config and Config.OpenCommand) or 'tv', function(source, args)
    if args[1] and string.lower(args[1]) == "off" then
        isLocalMuted = true
        ApplyIndividualVolume()
        Notify("warning", "TV mutada localmente para você.", "Volume Individual")
        return
    end

    local num = tonumber(args[1])
    if num ~= nil then
        num = math.min(100, math.max(0, math.floor(num)))
        localUserVolume = num / 100.0
        isLocalMuted = (num == 0)
        ApplyIndividualVolume()
        Notify("success", string.format("Volume individual ajustado para %d%%.", num), "Volume Individual")
        return
    end

    OpenTVRemote()
end, false)

CreateThread(function()
    while true do
        local sleep = 750
        local interactDist = Config and Config.InteractDistance or 3.0
        local obj = GetClosestTV(interactDist)

        if DoesEntityExist(obj) and not display and not isEditing then
            sleep = 5
            AddTextEntry('TV_REMOTE_PROMPT', 'Pressione ~INPUT_CONTEXT~ para abrir o ~b~Controle da TV~s~')
            DisplayHelpTextThisFrame('TV_REMOTE_PROMPT', false)

            if IsControlJustReleased(0, 51) then
                OpenTVRemote()
            end
        end

        Wait(sleep)
    end
end)

RegisterNUICallback('close', function(_, cb)
    display = false
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('playMusic', function(data, cb)
    local interactDist = Config and Config.InteractDistance or 3.5
    local obj, coords, cfg, tvId = GetClosestTV(interactDist + 2.0)

    if not DoesEntityExist(obj) then
        Notify("error", "Você se afastou da TV!", "Solis TV")
        cb('error')
        return
    end

    local videoId = ExtractYoutubeId(data.url)
    if not videoId then
        Notify("error", "URL ou ID do YouTube inválido!", "Solis TV")
        cb('error')
        return
    end

    TriggerServerEvent('solisTV:server:play', tvId, {
        videoId = videoId,
        url = data.url,
        title = data.title or "Vídeo",
        thumb = data.thumb or "",
        duration = tonumber(data.duration) or 0,
        coords = coords,
        model = cfg.model,
        distance = cfg.distance or 22.0,
        volume = 50
    })

    TriggerServerEvent('solisTV:server:addRecentSong', {
        url = data.url,
        title = data.title,
        thumb = data.thumb
    })

    cb('ok')
end)

RegisterNUICallback('controlMusic', function(data, cb)
    if not currentActiveTvId or not activeTVs[currentActiveTvId] then
        cb('error')
        return
    end

    local action = data.action
    if action == 'pause' or action == 'resume' then
        TriggerServerEvent('solisTV:server:control', currentActiveTvId, action)
    elseif action == 'volume' then
        TriggerServerEvent('solisTV:server:control', currentActiveTvId, 'volume', data.value)
    elseif action == 'seek' then
        TriggerServerEvent('solisTV:server:control', currentActiveTvId, 'seek', tonumber(data.time) or 0)
    elseif action == 'speed' or action == 'cc' then
        TriggerServerEvent('solisTV:server:control', currentActiveTvId, action, data.value)
    end

    cb('ok')
end)

RegisterNUICallback('destroyCurrentTV', function(_, cb)
    local interactDist = Config and Config.InteractDistance or 3.5
    local obj, coords, cfg, tvId = GetClosestTV(interactDist + 2.0)
    local targetId = tvId or currentActiveTvId

    if targetId and activeTVs[targetId] then
        TriggerServerEvent('solisTV:server:destroy', targetId)
        cb('ok')
    else
        cb('error')
    end
end)

RegisterNUICallback('searchYouTube', function(data, cb)
    TriggerServerEvent('solisTV:server:searchYouTube', data and data.query or '')
    cb('ok')
end)

RegisterNUICallback('getPlaylists', function(_, cb)
    if TvServer and TvServer.getPlaylists then
        cb(TvServer.getPlaylists() or {})
    else
        cb({})
    end
end)

RegisterNUICallback('getRecentSongs', function(_, cb)
    if TvServer and TvServer.getRecentSongs then
        cb(TvServer.getRecentSongs() or {})
    else
        cb({})
    end
end)

RegisterNUICallback('createPlaylist', function(d, cb)
    TriggerServerEvent('solisTV:server:createPlaylist', d.name, d.songs and json.encode(d.songs) or '[]')
    cb('ok')
end)

RegisterNUICallback('deletePlaylist', function(d, cb)
    TriggerServerEvent('solisTV:server:deletePlaylist', d.id)
    cb('ok')
end)

RegisterNUICallback('addSongToPlaylist', function(d, cb)
    TriggerServerEvent('solisTV:server:addSongToPlaylist', d.playlistId, d.song)
    cb('ok')
end)

RegisterNUICallback('updatePlaylistSongs', function(d, cb)
    TriggerServerEvent('solisTV:server:updatePlaylistSongs', d.id, d.songs)
    cb('ok')
end)

-- Barra de progresso contínua no NUI
CreateThread(function()
    while true do
        Wait(1000)
        if display and currentActiveTvId and activeTVs[currentActiveTvId] then
            local tv = activeTVs[currentActiveTvId]
            local current = GetTVTimestamp(tv)
            SendNUIMessage({
                type = "updateProgress",
                current = current,
                max = tv.duration or 0
            })
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if GetCurrentResourceName() ~= res then return end
    for _, tv in pairs(activeTVs) do
        CleanTVMemory(tv)
    end
    for _, tvData in ipairs(spawnedCustomTvs) do
        if DoesEntityExist(tvData.entity) then
            DeleteEntity(tvData.entity)
        end
    end
end)
