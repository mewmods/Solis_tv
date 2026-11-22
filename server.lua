local Tunnel = module("vrp", "lib/Tunnel")
local Proxy = module("vrp", "lib/Proxy")
vRP = Proxy.getInterface("vRP")

local TvServer = {}
Tunnel.bindInterface(GetCurrentResourceName(), TvServer)

local serverTVs = {}
local savedCustomTvs = {}

-- ===================================================
-- CHECAGEM DE PERMISSÃO ADMIN (vRP)
-- ===================================================
local function hasPermission(source)
    local user_id = nil
    if vRP.Passport then
        user_id = vRP.Passport(source)
    elseif vRP.getUserId then
        user_id = vRP.getUserId(source)
    end
    if not user_id then return false end

    local requiredPermission = Config.AdminPermission or "Admin"
    if vRP.HasGroup then
        return vRP.HasGroup(user_id, requiredPermission)
    elseif vRP.hasGroup then
        return vRP.hasGroup(user_id, requiredPermission)
    elseif vRP.hasPermission then
        return vRP.hasPermission(user_id, requiredPermission) or vRP.hasPermission(user_id, "admin.permissao")
    end
    return false
end

-- ===================================================
-- BANCO DE DADOS (PLAYLISTS, RECENTES E TVS SALVAS)
-- ===================================================
CreateThread(function()
    Wait(1000)
    local sqlTvPlaylists = [[
        CREATE TABLE IF NOT EXISTS `player_tv_playlists` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `passport` INT NOT NULL,
            `name` VARCHAR(100) NOT NULL,
            `songs` LONGTEXT NOT NULL DEFAULT '[]',
            `collaborators` LONGTEXT NOT NULL DEFAULT '[]',
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]]
    local sqlTvRecent = [[
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
    ]]
    local sqlCustomTvs = [[
        CREATE TABLE IF NOT EXISTS `saved_custom_tvs` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `model` VARCHAR(100) NOT NULL,
            `x` FLOAT NOT NULL,
            `y` FLOAT NOT NULL,
            `z` FLOAT NOT NULL,
            `rx` FLOAT NOT NULL,
            `ry` FLOAT NOT NULL,
            `rz` FLOAT NOT NULL,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]]

    exports.oxmysql:query(sqlTvPlaylists, {})
    exports.oxmysql:query(sqlTvRecent, {})
    exports.oxmysql:query(sqlCustomTvs, {}, function()
        -- Carrega todas as TVs salvas no MySQL
        exports.oxmysql:query('SELECT * FROM `saved_custom_tvs`', {}, function(rows)
            if rows and #rows > 0 then
                savedCustomTvs = rows
                print(string.format("^2[SolisTV] %d TVs personalizadas carregadas do banco de dados MySQL!^7", #savedCustomTvs))
            end
        end)
    end)
end)

local function GetCurrentTimestamp(tv)
    if not tv then return 0 end
    if tv.playing then
        return math.max(0, os.time() - tv.startedAt)
    else
        return math.max(0, tv.pausedAt or 0)
    end
end

-- ===================================================
-- SINCRONIZAÇÃO GERAL E SPAWN DE TVS SALVAS
-- ===================================================

RegisterNetEvent('solisTV:server:requestSync', function()
    local src = source
    local payload = {}
    for id, tv in pairs(serverTVs) do
        payload[id] = {
            tvId = tv.tvId,
            videoId = tv.videoId,
            url = tv.url,
            title = tv.title,
            thumb = tv.thumb,
            duration = tv.duration or 0,
            coords = tv.coords,
            model = tv.model,
            scale = tv.scale,
            offset = tv.offset,
            distance = tv.distance,
            volume = tv.volume,
            playing = tv.playing,
            speed = tv.speed or 1.0,
            cc = tv.cc == true,
            controller = tv.controller,
            currentTime = GetCurrentTimestamp(tv)
        }
    end

    -- Sincroniza o conteúdo tocando e spawna as TVs do MySQL para o jogador
    TriggerClientEvent('solisTV:client:syncAll', src, payload)
    if #savedCustomTvs > 0 then
        TriggerClientEvent('solisTV:client:spawnSavedTvs', src, savedCustomTvs)
    end
end)

-- ===================================================
-- BUSCA NO YOUTUBE (fallback sem cota da Data API)
-- ===================================================
-- A Data API tem limite baixo de search_list por dia. Quando a chave estoura
-- a cota, a busca continua funcionando pelos dados publicos da pagina de
-- resultados do proprio YouTube, direto no servidor do recurso.
local searchCache = {}
local SEARCH_CACHE_TTL = 300

local function urlEncode(value)
    if not value then return '' end
    return (tostring(value):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function textOf(value)
    if type(value) == 'string' then return value end
    if type(value) ~= 'table' then return '' end

    if type(value.simpleText) == 'string' then return value.simpleText end
    if type(value.runs) == 'table' then
        local out = ''
        for _, run in ipairs(value.runs) do
            out = out .. tostring(run.text or '')
        end
        return out
    end
    return ''
end

local function parseDurationText(value)
    local total = 0
    for part in tostring(value or ''):gmatch("%d+") do
        total = (total * 60) + tonumber(part)
    end
    return total
end

local function extractYtInitialData(html)
    if type(html) ~= 'string' then return nil end

    local marker = 'var ytInitialData = '
    local startAt = string.find(html, marker, 1, true)
    if startAt then
        startAt = startAt + #marker
    else
        local _, after = string.find(html, 'ytInitialData"%s*=%s*')
        if not after then return nil end
        startAt = after + 1
    end

    local endAt = string.find(html, ';</script>', startAt, true) or #html
    if endAt <= startAt then return nil end
    return html:sub(startAt, endAt - 1)
end

local function parseSearchPage(html)
    local jsonText = extractYtInitialData(html)
    if not jsonText then return {} end

    local ok, decoded = pcall(json.decode, jsonText)
    if not ok or type(decoded) ~= 'table' then return {} end

    local results = {}

    local function addVideo(renderer)
        local id = renderer.videoId
        if type(id) ~= 'string' or #id ~= 11 then return end

        local thumb = ''
        local thumbs = renderer.thumbnail and renderer.thumbnail.thumbnails
        if type(thumbs) == 'table' and #thumbs > 0 then
            thumb = tostring(thumbs[#thumbs].url or thumbs[1].url or '')
        end

        results[#results + 1] = {
            videoId = id,
            url = 'https://www.youtube.com/watch?v=' .. id,
            title = textOf(renderer.title),
            thumb = thumb,
            duration = parseDurationText(textOf(renderer.lengthText))
        }
    end

    local function walk(node)
        if type(node) ~= 'table' or #results >= 16 then return end

        if type(node.videoRenderer) == 'table' then
            addVideo(node.videoRenderer)
            return
        end

        if #node > 0 then
            for i = 1, #node do
                walk(node[i])
                if #results >= 16 then return end
            end
        else
            for _, child in pairs(node) do
                walk(child)
                if #results >= 16 then return end
            end
        end
    end

    walk(decoded)
    return results
end

RegisterNetEvent('solisTV:server:searchYouTube', function(query)
    local src = source
    query = tostring(query or '')
    if query == '' then
        TriggerClientEvent('solisTV:client:searchResults', src, {}, 'Consulta vazia')
        return
    end

    local cacheKey = string.lower(query)
    local cached = searchCache[cacheKey]
    if cached and (os.time() - cached.at) < SEARCH_CACHE_TTL then
        TriggerClientEvent('solisTV:client:searchResults', src, cached.results)
        return
    end

    local url = 'https://www.youtube.com/results?search_query=' .. urlEncode(query)
    PerformHttpRequest(url, function(status, body)
        local results = (status == 200) and parseSearchPage(body) or {}

        if #results > 0 then
            searchCache[cacheKey] = { at = os.time(), results = results }
            TriggerClientEvent('solisTV:client:searchResults', src, results)
        else
            TriggerClientEvent('solisTV:client:searchResults', src, {}, 'Nenhum vídeo encontrado')
        end
    end, 'GET', '', {
        ['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36',
        ['Accept-Language'] = 'pt-BR,pt;q=0.9,en;q=0.8'
    })
end)

-- Iniciar novo vídeo
RegisterNetEvent('solisTV:server:play', function(tvId, data)
    local src = source
    local now = os.time()
    local coords = type(data.coords) == 'vector3' and data.coords or vec3(data.coords.x, data.coords.y, data.coords.z)

    local targetId = tvId
    for id, tv in pairs(serverTVs) do
        if #(tv.coords - coords) <= 2.5 then
            targetId = id
            break
        end
    end

    if serverTVs[targetId] then
        TriggerClientEvent('solisTV:client:destroy', -1, targetId)
    end

    serverTVs[targetId] = {
        tvId = targetId,
        videoId = data.videoId,
        url = data.url,
        title = data.title or "Vídeo",
        thumb = data.thumb or "",
        duration = tonumber(data.duration) or 0,
        coords = coords,
        model = data.model,
        scale = data.scale,
        offset = data.offset,
        distance = data.distance or 22.0,
        volume = data.volume or 50,
        playing = true,
        speed = tonumber(data.speed) or 1.0,
        cc = data.cc == true,
        controller = src,
        startedAt = now,
        pausedAt = 0,
        currentTime = 0
    }

    TriggerClientEvent('solisTV:client:play', -1, targetId, serverTVs[targetId])
end)

-- Controles remotos
RegisterNetEvent('solisTV:server:control', function(tvId, action, value)
    local tv = serverTVs[tvId]
    if not tv then return end

    local now = os.time()

    if action == 'pause' then
        if tv.playing then
            tv.playing = false
            tv.pausedAt = now - tv.startedAt
            tv.currentTime = tv.pausedAt
        end
    elseif action == 'resume' then
        if not tv.playing then
            tv.playing = true
            tv.startedAt = now - (tv.pausedAt or 0)
            tv.currentTime = now - tv.startedAt
        end
    elseif action == 'seek' then
        local targetSec = tonumber(value) or 0
        tv.startedAt = now - targetSec
        tv.pausedAt = targetSec
        tv.currentTime = targetSec
    elseif action == 'volume' then
        tv.volume = math.floor((tonumber(value) or 0) * 100)
    elseif action == 'speed' then
        tv.speed = tonumber(value) or 1.0
    elseif action == 'cc' then
        tv.cc = (value == 'on')
    end

    local currentSec = GetCurrentTimestamp(tv)
    TriggerClientEvent('solisTV:client:control', -1, tvId, action, value, currentSec)
end)

-- Fim de vídeo reportado pela DUI. Só o controlador pode avançar a fila;
-- os outros jogadores apenas recebem o estado pausado até o próximo play.
RegisterNetEvent('solisTV:server:ended', function(tvId)
    local src = source
    local tv = serverTVs[tvId]
    if not tv then return end
    if tv.controller and tv.controller ~= src then return end

    local elapsed = os.time() - (tv.startedAt or os.time())
    tv.playing = false
    tv.pausedAt = (tv.duration and tv.duration > 0) and tv.duration or math.max(0, elapsed)
    tv.currentTime = tv.pausedAt

    TriggerClientEvent('solisTV:client:control', -1, tvId, 'pause', 0, GetCurrentTimestamp(tv))
end)

-- Desligar TV
RegisterNetEvent('solisTV:server:destroy', function(tvId)
    if serverTVs[tvId] then
        serverTVs[tvId] = nil
        TriggerClientEvent('solisTV:client:destroy', -1, tvId)
    end
end)

-- ===================================================
-- SALVAMENTO E GESTÃO DAS TVS NO BANCO DE DADOS
-- ===================================================

RegisterNetEvent('solisTV:server:saveCustomTvs', function(tvData)
    local src = source
    if not hasPermission(src) then
        TriggerClientEvent("solisTV:client:notify", src, "error", "Você não tem permissão!", "Admin")
        return
    end

    if type(tvData) ~= "table" then return end

    -- Limpa a tabela antiga e insere a nova lista de TVs no MySQL
    exports.oxmysql:query('TRUNCATE TABLE `saved_custom_tvs`', {}, function()
        if #tvData > 0 then
            local insertQuery = 'INSERT INTO `saved_custom_tvs` (`model`, `x`, `y`, `z`, `rx`, `ry`, `rz`) VALUES '
            local params = {}
            local valuesList = {}

            for i, tv in ipairs(tvData) do
                table.insert(valuesList, '(?, ?, ?, ?, ?, ?, ?)')
                table.insert(params, tv.model)
                table.insert(params, tv.x)
                table.insert(params, tv.y)
                table.insert(params, tv.z)
                table.insert(params, tv.rx)
                table.insert(params, tv.ry)
                table.insert(params, tv.rz)
            end

            insertQuery = insertQuery .. table.concat(valuesList, ', ')
            exports.oxmysql:query(insertQuery, params, function()
                savedCustomTvs = tvData
                TriggerClientEvent('solisTV:client:spawnSavedTvs', -1, savedCustomTvs)
                TriggerClientEvent("solisTV:client:notify", src, "success", #tvData .. " TVs salvas no Banco de Dados!", "Admin")
            end)
        else
            savedCustomTvs = {}
            TriggerClientEvent('solisTV:client:spawnSavedTvs', -1, {})
            TriggerClientEvent("solisTV:client:notify", src, "warning", "Todas as TVs foram removidas do banco.", "Admin")
        end
    end)
end)

-- Comandos Administrativos
RegisterCommand("spawntv", function(source, args) 
    if hasPermission(source) then 
        TriggerClientEvent("solisTV:client:executeAdminCommand", source, "spawntv", args[1]) 
    end 
end)

RegisterCommand("deletetv", function(source) 
    if hasPermission(source) then 
        TriggerClientEvent("solisTV:client:executeAdminCommand", source, "deletetv") 
    end 
end)

RegisterCommand("tvedit", function(source) 
    if hasPermission(source) then 
        TriggerClientEvent("solisTV:client:executeAdminCommand", source, "tvedit") 
    end 
end)

RegisterCommand("savetv", function(source) 
    if hasPermission(source) then 
        TriggerClientEvent("solisTV:client:executeAdminCommand", source, "savetv") 
    end 
end)

RegisterCommand("wipetv", function(source) 
    if hasPermission(source) then 
        TriggerClientEvent("solisTV:client:executeAdminCommand", source, "wipetv") 
    end 
end)

-- Playlists e Recentes
function TvServer.getPlaylists()
    local src = source
    local passport = vRP.Passport(src)
    if not passport then return {} end
    local rows = exports.oxmysql:query_async('SELECT * FROM player_tv_playlists WHERE passport = ? OR collaborators LIKE ?', { passport, '%"' .. passport .. '"%' }) or {}
    for _, r in ipairs(rows) do
        r.isOwner = (tonumber(r.passport) == tonumber(passport))
    end
    return rows
end

function TvServer.getRecentSongs()
    local passport = vRP.Passport(source)
    if not passport then return {} end
    return exports.oxmysql:query_async('SELECT * FROM player_tv_recent WHERE passport = ? ORDER BY timestamp DESC LIMIT 6', { passport }) or {}
end

RegisterNetEvent('solisTV:server:createPlaylist', function(name, songsJson)
    local src = source
    local passport = vRP.Passport(src)
    if not passport then return end
    exports.oxmysql:insert('INSERT INTO player_tv_playlists (passport, name, songs) VALUES (?, ?, ?)', { passport, name, songsJson or '[]' }, function()
        TriggerClientEvent("solisTV:client:notify", src, "success", "Playlist criada!", "Solis TV")
        TriggerClientEvent("solisTV:client:refreshPlaylists", src)
    end)
end)

RegisterNetEvent('solisTV:server:deletePlaylist', function(id)
    local src = source
    local passport = vRP.Passport(src)
    if not passport then return end
    exports.oxmysql:query('DELETE FROM player_tv_playlists WHERE id = ? AND passport = ?', { id, passport }, function()
        TriggerClientEvent("solisTV:client:notify", src, "warning", "Playlist excluída.", "Solis TV")
        TriggerClientEvent("solisTV:client:refreshPlaylists", src)
    end)
end)

RegisterNetEvent('solisTV:server:addSongToPlaylist', function(playlistId, songData)
    local src = source
    local passport = vRP.Passport(src)
    if not passport then return end
    exports.oxmysql:query('SELECT songs FROM player_tv_playlists WHERE id = ?', { playlistId }, function(result)
        if result and result[1] then
            local currentSongs = json.decode(result[1].songs) or {}
            table.insert(currentSongs, songData)
            exports.oxmysql:update('UPDATE player_tv_playlists SET songs = ? WHERE id = ?', { json.encode(currentSongs), playlistId })
            TriggerClientEvent("solisTV:client:notify", src, "success", "Vídeo adicionado!", "Solis TV")
            TriggerClientEvent("solisTV:client:refreshPlaylists", src)
        end
    end)
end)

RegisterNetEvent('solisTV:server:updatePlaylistSongs', function(playlistId, newSongList)
    exports.oxmysql:update('UPDATE player_tv_playlists SET songs = ? WHERE id = ?', { json.encode(newSongList), playlistId })
end)

RegisterNetEvent('solisTV:server:addRecentSong', function(songData)
    local src = source
    local passport = vRP.Passport(src)
    if not passport or not songData.url then return end
    local query = [[
        INSERT INTO player_tv_recent (passport, url, title, thumb, timestamp) 
        VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP) 
        ON DUPLICATE KEY UPDATE timestamp = CURRENT_TIMESTAMP, title = ?, thumb = ?
    ]]
    exports.oxmysql:update(query, { passport, songData.url, songData.title or "Vídeo", songData.thumb or "", songData.title or "Vídeo", songData.thumb or "" })
end)