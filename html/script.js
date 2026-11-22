/* script.js — NUI do solis_tv (JavaScript puro, arquivos locais). */

let YOUTUBE_KEY = "";
let playlists = [];
let playQueue = [];
let queueIndex = 0;
let repeatMode = 0;
let isPlaying = false;
let currentView = 'home';
let activePlaylistId = null;
let isSeeking = false;
let currentMaxDuration = 0;
let currentTimeSeconds = 0;

let currentSpeedIndex = 1;
const speeds = [0.5, 1.0, 1.25, 1.5, 2.0];
let ccActive = false;

const THEME_KEY = 'solistv-theme';
let modalCallback = null;
let contextSong = null;
let lastVolume = 50;

/* ===================================================
   HELPERS
   =================================================== */
function $(selector, root) {
    return (root || document).querySelector(selector);
}

function $$(selector, root) {
    return Array.from((root || document).querySelectorAll(selector));
}

function svgIcon(id, extraClass) {
    return `<svg class="ico ${extraClass || ''}"><use href="#${id}"></use></svg>`;
}

function escapeHtml(value) {
    return String(value === null || value === undefined ? '' : value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function resourceName() {
    return typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'solis_tv';
}

function postNUI(name, data) {
    return fetch(`https://${resourceName()}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data || {})
    }).then(function (response) {
        return response.text();
    });
}

function nuiJson(name, data) {
    return postNUI(name, data).then(function (text) {
        try { return JSON.parse(text); } catch (e) { return text; }
    }).catch(function () { return null; });
}

function showToast(type, text, title) {
    const icons = { success: 'i-check', error: 'i-close', warning: 'i-alert', info: 'i-info' };
    const titles = { success: 'Pronto', error: 'Aviso', warning: 'Atenção', info: 'Solis TV' };
    const tone = icons[type] ? type : 'info';

    const toast = document.createElement('div');
    toast.className = 'ios-toast';
    toast.innerHTML = `
        <div class="toast-icon" data-tone="${tone}">${svgIcon(icons[tone])}</div>
        <div class="toast-content">
            <span class="toast-title">${escapeHtml(title || titles[tone])}</span>
            <span class="toast-desc">${escapeHtml(text || '')}</span>
        </div>
    `;

    $('#toast-container').appendChild(toast);
    setTimeout(function () {
        toast.classList.add('hide');
        setTimeout(function () { toast.remove(); }, 300);
    }, 4500);
}

/* ===================================================
   TEMA (claro / escuro)
   =================================================== */
function currentTheme() {
    return document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
}

function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    try { localStorage.setItem(THEME_KEY, theme); } catch (e) { }
}

applyTheme(currentTheme());

$('#theme-toggle').addEventListener('click', function (event) {
    const option = event.target.closest('[data-theme-opt]');
    applyTheme(option ? option.dataset.themeOpt : (currentTheme() === 'dark' ? 'light' : 'dark'));
});

/* ===================================================
   ABRIR / FECHAR
   =================================================== */
function openApp() {
    document.body.classList.add('app-open');
}

function closeUI() {
    document.body.classList.remove('app-open');
    $('#context-menu').style.display = 'none';
    $('#custom-modal').style.display = 'none';
    postNUI('close').catch(function () { });
}

window.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') closeUI();
});

$('#close-btn').addEventListener('click', closeUI);

/* ===================================================
   MENSAGENS DO JOGO
   =================================================== */
window.addEventListener('message', function (event) {
    const data = event.data;
    if (!data || typeof data !== 'object') return;

    if (data.type === 'ui') {
        if (data.status) {
            openApp();
            YOUTUBE_KEY = data.apiKey || "";
            $('#sidebar-tv-status').textContent = 'Conectado';

            if (data.state) {
                const volume = typeof data.state.volume === 'number' ? data.state.volume : 0.5;
                setVolumeUI(volume * 100);

                isPlaying = data.state.playing === true;
                setPlayIcon(isPlaying);

                $('#current-song-title').textContent = data.state.title || 'Nenhum vídeo em reprodução';
                $('#current-device-tag').innerHTML = `${svgIcon('i-tv')} ${escapeHtml(data.state.deviceName || 'Solis TV')}`;

                currentMaxDuration = data.state.duration || 0;
                if (currentMaxDuration > 0) {
                    $('#total-time').textContent = formatTime(currentMaxDuration);
                }

                const speed = Number(data.state.speed) || 1;
                const speedIndex = speeds.indexOf(speed);
                currentSpeedIndex = speedIndex >= 0 ? speedIndex : 1;
                $('#btn-speed').textContent = speed.toFixed(1) + 'x';

                ccActive = data.state.cc === true;
                $('#btn-toggle-cc').classList.toggle('active', ccActive);
            }

            fetchPlaylists();
            fetchRecentSongs();

            if (currentView === 'home') {
                $('#results-area').style.display = 'none';
                $('#default-home-content').style.display = '';
                $('#search-input').value = "";
            }
        } else {
            $('#sidebar-tv-status').textContent = 'Desligado';
            closeUI();
        }
    } else if (data.type === 'toast') {
        showToast(data.toastType, data.text, data.title);
    } else if (data.type === 'fetchPlaylists') {
        fetchPlaylists();
    } else if (data.type === 'songEnded') {
        playNext();
    } else if (data.type === 'updateProgress') {
        if (!isSeeking) updateProgressBar(data.current || 0, data.max || 0);
    } else if (data.type === 'searchResults') {
        renderSearchResults(data.results || [], data.error);
    }
});

/* ===================================================
   VÍDEO / URLs
   =================================================== */
function extractVideoId(url) {
    if (!url) return '';
    const match = String(url).match(/^.*(youtu\.be\/|v\/|u\/\w\/|embed\/|shorts\/|watch\?v=|\&v=)([^#\&\?]*).*/);
    return (match && match[2] && match[2].length === 11) ? match[2] : String(url);
}

function getYoutubeThumb(url) {
    const videoId = extractVideoId(url);
    if (videoId && videoId.length === 11) {
        return `https://img.youtube.com/vi/${videoId}/mqdefault.jpg`;
    }
    return "";
}

function parseISO8601(duration) {
    const match = duration ? String(duration).match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/) : null;
    if (!match) return 0;
    const h = parseInt(match[1] || 0, 10);
    const m = parseInt(match[2] || 0, 10);
    const s = parseInt(match[3] || 0, 10);
    return (h * 3600) + (m * 60) + s;
}

function fetchVideoDuration(videoId, callback) {
    if (!YOUTUBE_KEY || !videoId || String(videoId).length !== 11) {
        callback(0);
        return;
    }

    const url = `https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=${encodeURIComponent(videoId)}&key=${encodeURIComponent(YOUTUBE_KEY)}`;
    fetch(url)
        .then(function (response) { return response.json(); })
        .then(function (data) {
            if (data && data.items && data.items.length > 0 && data.items[0].contentDetails) {
                callback(parseISO8601(data.items[0].contentDetails.duration));
            } else {
                callback(0);
            }
        })
        .catch(function () { callback(0); });
}

/* ===================================================
   CONTROLE REMOTO
   =================================================== */
$('#btn-power-tv').addEventListener('click', function () {
    postNUI('destroyCurrentTV').then(function (result) {
        if (result === 'ok') {
            showToast("warning", "A TV foi desligada.", "Solis TV");
            $('#current-song-title').textContent = "TV desligada";
            setPlayIcon(false);
            isPlaying = false;
            updateProgressBar(0, 0);
        } else {
            showToast("error", "Nenhuma TV ligada próxima a você.");
        }
    }).catch(function () {
        showToast("error", "Nenhuma TV ligada próxima a você.");
    });
});

function setSeekBarFill(percent) {
    percent = Math.max(0, Math.min(100, percent));
    $('#seek-bar').style.setProperty('--fill', percent + '%');
}

function setVolumeUI(value) {
    value = Math.max(0, Math.min(100, Number(value) || 0));
    const slider = $('#volume-slider');
    slider.value = value;
    slider.style.setProperty('--fill', value + '%');
    setVolumeIcon(value <= 0);
}

function setVolumeIcon(muted) {
    const button = $('#vol-icon');
    button.classList.toggle('is-muted', muted);
    const use = button.querySelector('use');
    if (use) use.setAttribute('href', muted ? '#i-mute' : '#i-volume');
}

function updateProgressBar(current, max) {
    currentTimeSeconds = Number(current) || 0;

    if (max > 0) {
        currentMaxDuration = Number(max) || 0;
        const percent = (currentTimeSeconds / currentMaxDuration) * 100;
        $('#seek-bar').value = percent;
        setSeekBarFill(percent);
        $('#curr-time').textContent = formatTime(currentTimeSeconds);
        $('#total-time').textContent = formatTime(currentMaxDuration);
    } else {
        $('#curr-time').textContent = formatTime(currentTimeSeconds);
    }
}

function formatTime(seconds) {
    seconds = Math.max(0, Math.floor(Number(seconds) || 0));
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return m + ":" + (s < 10 ? "0" + s : s);
}

function currentPlaybackTime() {
    return currentTimeSeconds;
}

const seekBar = $('#seek-bar');

function beginSeek() {
    isSeeking = true;
    const percent = parseFloat(seekBar.value) || 0;
    setSeekBarFill(percent);
    if (currentMaxDuration > 0) {
        currentTimeSeconds = (percent / 100) * currentMaxDuration;
        $('#curr-time').textContent = formatTime(currentTimeSeconds);
    }
}

function endSeek() {
    if (!isSeeking) return;
    isSeeking = false;
    const percent = parseFloat(seekBar.value) || 0;
    setSeekBarFill(percent);
    if (currentMaxDuration > 0) {
        const targetTime = Math.floor((percent / 100) * currentMaxDuration);
        postNUI('controlMusic', { action: 'seek', time: targetTime }).catch(function () { });
    }
}

seekBar.addEventListener('input', beginSeek);
seekBar.addEventListener('mousedown', beginSeek);
seekBar.addEventListener('touchstart', beginSeek);
seekBar.addEventListener('change', endSeek);
seekBar.addEventListener('mouseup', endSeek);
seekBar.addEventListener('touchend', endSeek);

/* ===================================================
   FILA / REPRODUÇÃO
   =================================================== */
function resetProgressUI() {
    isSeeking = false;
    currentMaxDuration = 0;
    currentTimeSeconds = 0;
    seekBar.value = 0;
    setSeekBarFill(0);
    $('#curr-time').textContent = "0:00";
    $('#total-time').textContent = "--:--";
}

function playSingleSong(url, title, thumb, options) {
    options = options || {};
    const videoId = extractVideoId(url);
    if (!thumb && url) thumb = getYoutubeThumb(url);

    resetProgressUI();

    function start(duration) {
        currentMaxDuration = duration || 0;
        if (currentMaxDuration > 0) {
            $('#total-time').textContent = formatTime(currentMaxDuration);
        }

        if (!options.keepQueue) {
            playQueue = [{ url: url, title: title, thumb: thumb || "", duration: currentMaxDuration }];
            queueIndex = 0;
        } else if (playQueue[queueIndex]) {
            playQueue[queueIndex].duration = currentMaxDuration;
        }

        $('#current-song-title').textContent = title;
        setPlayIcon(true);
        isPlaying = true;

        postNUI('playMusic', {
            url: url,
            title: title,
            thumb: thumb || getYoutubeThumb(url),
            duration: currentMaxDuration
        }).catch(function () { });
    }

    if (typeof options.duration === 'number' && options.duration > 0) {
        start(options.duration);
    } else {
        fetchVideoDuration(videoId, start);
    }
}

function safeParseSongs(value) {
    if (Array.isArray(value)) return value;
    if (!value) return [];
    try {
        const parsed = JSON.parse(value);
        return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
        return [];
    }
}

function playEntirePlaylist(id) {
    const playlist = playlists.find(function (p) { return p.id == id; });
    if (!playlist) return;

    const songs = safeParseSongs(playlist.songs);
    if (songs.length === 0) return;

    playQueue = songs.slice();
    queueIndex = 0;
    playSingleSong(songs[0].url, songs[0].title, songs[0].thumb, {
        keepQueue: true,
        duration: Number(songs[0].duration) || 0
    });
}

function playNext() {
    if (playQueue.length === 0) return;

    if (repeatMode === 2) {
        const song = playQueue[queueIndex];
        playSingleSong(song.url, song.title, song.thumb, { keepQueue: true, duration: song.duration || 0 });
        return;
    }

    queueIndex++;
    if (queueIndex >= playQueue.length) {
        if (repeatMode === 1) {
            queueIndex = 0;
            const song = playQueue[queueIndex];
            playSingleSong(song.url, song.title, song.thumb, { keepQueue: true, duration: song.duration || 0 });
        } else {
            queueIndex = playQueue.length - 1;
            isPlaying = false;
            setPlayIcon(false);
        }
    } else {
        const song = playQueue[queueIndex];
        playSingleSong(song.url, song.title, song.thumb, { keepQueue: true, duration: song.duration || 0 });
    }
}

function playPrev() {
    if (playQueue.length === 0) return;
    queueIndex--;
    if (queueIndex < 0) queueIndex = playQueue.length - 1;
    const song = playQueue[queueIndex];
    playSingleSong(song.url, song.title, song.thumb, { keepQueue: true, duration: song.duration || 0 });
}

$('#next-btn').addEventListener('click', playNext);
$('#prev-btn').addEventListener('click', playPrev);

$('#play-pause-btn').addEventListener('click', function () {
    isPlaying = !isPlaying;
    setPlayIcon(isPlaying);
    postNUI('controlMusic', {
        action: isPlaying ? 'resume' : 'pause',
        value: 0
    }).catch(function () { });
});

$('#btn-backward-10').addEventListener('click', function () {
    const target = Math.max(0, currentPlaybackTime() - 10);
    postNUI('controlMusic', { action: 'seek', time: target }).catch(function () { });
});

$('#btn-forward-10').addEventListener('click', function () {
    let target = currentPlaybackTime() + 10;
    if (currentMaxDuration > 0) target = Math.min(currentMaxDuration, target);
    postNUI('controlMusic', { action: 'seek', time: target }).catch(function () { });
});

$('#btn-toggle-cc').addEventListener('click', function () {
    ccActive = !ccActive;
    this.classList.toggle('active', ccActive);
    postNUI('controlMusic', { action: 'cc', value: ccActive ? 'on' : 'off' }).catch(function () { });
    showToast(ccActive ? "success" : "info", ccActive ? "Legendas ativadas" : "Legendas desativadas");
});

$('#btn-speed').addEventListener('click', function () {
    currentSpeedIndex = (currentSpeedIndex + 1) % speeds.length;
    const speed = speeds[currentSpeedIndex];
    this.textContent = speed.toFixed(1) + "x";
    postNUI('controlMusic', { action: 'speed', value: speed }).catch(function () { });
    showToast("info", "Velocidade: " + speed + "x");
});

$('#volume-slider').addEventListener('input', function () {
    let value = parseInt(this.value, 10) || 0;
    value = Math.max(0, Math.min(100, value));
    this.style.setProperty('--fill', value + '%');
    setVolumeIcon(value <= 0);
    if (value > 0) lastVolume = value;
    postNUI('controlMusic', { action: 'volume', value: value / 100.0 }).catch(function () { });
});

$('#vol-icon').addEventListener('click', function () {
    const slider = $('#volume-slider');
    const value = parseInt(slider.value, 10) || 0;

    if (value > 0) {
        lastVolume = value;
        slider.value = 0;
    } else {
        slider.value = lastVolume || 50;
    }
    slider.dispatchEvent(new Event('input', { bubbles: true }));
});

function setPlayIcon(playing) {
    const button = $('#play-pause-btn');
    button.classList.toggle('is-playing', !!playing);
    const use = button.querySelector('use');
    if (use) use.setAttribute('href', playing ? '#i-pause' : '#i-play');
}

/* ===================================================
   NAVEGAÇÃO
   =================================================== */
function showHome() {
    $('#playlist-view').classList.remove('is-active');
    $('#home-view').classList.add('is-active');
    $('#results-area').style.display = 'none';
    $('#default-home-content').style.display = '';
    $('#search-input').value = "";
    currentView = 'home';

    $$('.menu-item').forEach(function (item) { item.classList.remove('active'); });
    $('#btn-home').classList.add('active');

    fetchPlaylists();
    fetchRecentSongs();
}

$('#btn-home').addEventListener('click', showHome);
$('#back-to-home').addEventListener('click', showHome);

$('#search-input').addEventListener('keyup', function (event) {
    if (event.key === 'Enter') performSearch();
});
$('#search-btn').addEventListener('click', performSearch);

function renderSearchResults(items, error) {
    const area = $('#results-area');
    $('#default-home-content').style.display = 'none';
    area.innerHTML = '';
    area.style.display = 'grid';

    if (!items || items.length === 0) {
        area.innerHTML = `<p class="empty">${escapeHtml(error || 'Nenhum vídeo encontrado.')}</p>`;
        return;
    }

    items.forEach(function (item) {
        const duration = Number(item.duration) || 0;
        const card = document.createElement('div');
        card.className = 'card';
        card.dataset.url = item.url;
        card.dataset.title = item.title;
        card.dataset.thumb = item.thumb || '';
        card.dataset.duration = duration;
        card.innerHTML = `
            <div class="card-thumb">
                <img src="${escapeHtml(item.thumb || '')}" alt="">
                ${duration > 0 ? `<span class="card-duration">${formatTime(duration)}</span>` : ''}
            </div>
            <div class="card-title">${escapeHtml(item.title || 'Vídeo')}</div>
        `;
        area.appendChild(card);
    });
}

function fallbackSearch(query) {
    const area = $('#results-area');
    $('#default-home-content').style.display = 'none';
    area.innerHTML = '<p class="empty">Buscando no YouTube...</p>';
    area.style.display = 'grid';

    postNUI('searchYouTube', { query: query }).catch(function () {
        renderSearchResults([], 'Não foi possível consultar o YouTube.');
    });
}

function performSearch() {
    const query = $('#search-input').value.trim();
    if (!query) {
        $('#results-area').style.display = 'none';
        $('#default-home-content').style.display = '';
        return;
    }

    if (/youtube\.com|youtu\.be/i.test(query)) {
        playSingleSong(query, "Vídeo do YouTube", getYoutubeThumb(query));
        return;
    }

    if (!YOUTUBE_KEY) {
        fallbackSearch(query);
        return;
    }

    const url = `https://www.googleapis.com/youtube/v3/search?part=snippet&maxResults=16&q=${encodeURIComponent(query)}&type=video&key=${encodeURIComponent(YOUTUBE_KEY)}`;

    fetch(url)
        .then(function (response) { return response.json(); })
        .then(function (data) {
            if (data && data.error) {
                const message = data.error.message || '';
                fallbackSearch(query);
                if (/quota|exceeded/i.test(message)) {
                    showToast("info", "Cota da API esgotada. Usando a busca do YouTube.", "Solis TV");
                }
                return;
            }

            const items = (data && data.items || []).map(function (item) {
                const thumb = item.snippet && item.snippet.thumbnails && item.snippet.thumbnails.medium
                    ? item.snippet.thumbnails.medium.url
                    : '';
                return {
                    videoId: item.id && item.id.videoId || '',
                    url: `https://www.youtube.com/watch?v=${item.id && item.id.videoId || ''}`,
                    title: item.snippet && item.snippet.title || 'Vídeo',
                    thumb: thumb,
                    duration: 0
                };
            }).filter(function (item) { return item.videoId; });

            if (items.length === 0) {
                fallbackSearch(query);
                return;
            }

            renderSearchResults(items);
        })
        .catch(function () {
            fallbackSearch(query);
        });
}

document.addEventListener('click', function (event) {
    const card = event.target.closest('.card');
    if (card) {
        playSingleSong(card.dataset.url, card.dataset.title, card.dataset.thumb, {
            duration: Number(card.dataset.duration) || 0
        });
        return;
    }

    if (!event.target.closest('.context-menu')) {
        $('#context-menu').style.display = 'none';
    }
});

document.addEventListener('contextmenu', function (event) {
    const card = event.target.closest('.card');
    if (!card) return;

    event.preventDefault();
    openContextMenu(event, {
        url: card.dataset.url,
        title: card.dataset.title,
        thumb: card.dataset.thumb,
        duration: Number(card.dataset.duration) || 0
    });
});

/* ===================================================
   RECENTES
   =================================================== */
function fetchRecentSongs() {
    nuiJson('getRecentSongs').then(function (data) {
        const container = $('#recent-grid');
        container.innerHTML = '';

        const songs = Array.isArray(data) ? data : [];
        if (songs.length === 0) {
            container.innerHTML = '<p class="empty">Nada por aqui ainda — toque um vídeo para começar.</p>';
            return;
        }

        songs.forEach(function (song) {
            const card = document.createElement('div');
            card.className = 'recent-card';
            card.innerHTML = `
                <img src="${escapeHtml(song.thumb || '')}" class="recent-card-img" alt="">
                <span class="recent-card-title">${escapeHtml(song.title || '')}</span>
                <div class="recent-card-play-btn">${svgIcon('i-play')}</div>
            `;
            card.addEventListener('click', function () {
                playSingleSong(song.url, song.title, song.thumb);
            });
            container.appendChild(card);
        });
    });
}

/* ===================================================
   PLAYLISTS
   =================================================== */
function fetchPlaylists() {
    nuiJson('getPlaylists').then(function (data) {
        playlists = Array.isArray(data) ? data : [];
        renderSidebarPlaylists();
        renderHomePlaylists();

        if (currentView === 'playlist' && activePlaylistId) {
            const playlist = playlists.find(function (p) { return p.id == activePlaylistId; });
            if (playlist) renderPlaylistSongs(playlist);
        }
    });
}

function renderHomePlaylists() {
    const container = $('#playlists-grid');
    container.innerHTML = '';

    if (playlists.length === 0) {
        container.innerHTML = '<p class="empty">Crie uma playlist para guardar seus vídeos.</p>';
        return;
    }

    playlists.forEach(function (playlist) {
        const songs = safeParseSongs(playlist.songs);
        const description = songs.length === 1 ? "1 vídeo" : songs.length + " vídeos";
        const thumbSrc = songs.length > 0 ? songs[0].thumb : '';
        const image = thumbSrc
            ? `<img src="${escapeHtml(thumbSrc)}" alt="">`
            : `<div class="playlist-card-img-placeholder">${svgIcon('i-tv')}</div>`;

        const card = document.createElement('div');
        card.className = 'playlist-card';
        card.innerHTML = `
            ${image}
            <div class="playlist-card-title">${escapeHtml(playlist.name || '')}</div>
            <div class="playlist-card-desc">${description}</div>
        `;
        card.addEventListener('click', function () { openPlaylistView(playlist.id); });
        container.appendChild(card);
    });
}

function renderSidebarPlaylists() {
    const container = $('#playlist-list');
    container.innerHTML = '';

    playlists.forEach(function (playlist) {
        const item = document.createElement('div');
        item.className = 'playlist-item';
        item.dataset.id = playlist.id;
        item.innerHTML = `
            <span class="pl-sidebar-play" title="Tocar na TV">${svgIcon('i-play')}</span>
            <span class="pl-name-span">${escapeHtml(playlist.name || '')}</span>
            <span class="delete-pl" title="Excluir playlist">${svgIcon('i-trash')}</span>
        `;

        item.addEventListener('click', function () { openPlaylistView(playlist.id); });
        item.querySelector('.pl-sidebar-play').addEventListener('click', function (event) {
            event.stopPropagation();
            playEntirePlaylist(playlist.id);
        });
        item.querySelector('.delete-pl').addEventListener('click', function (event) {
            event.stopPropagation();
            deletePlaylist(playlist.id);
        });

        container.appendChild(item);
    });
}

function openPlaylistView(id) {
    const playlist = playlists.find(function (p) { return p.id == id; });
    if (!playlist) return;

    activePlaylistId = id;
    currentView = 'playlist';
    $('#home-view').classList.remove('is-active');
    $('#playlist-view').classList.add('is-active');
    $('#pl-view-name').textContent = playlist.name || 'Playlist';
    $('#pl-play-all').onclick = function () { playEntirePlaylist(playlist.id); };

    renderPlaylistSongs(playlist);
}

function renderPlaylistSongs(playlist) {
    const songs = safeParseSongs(playlist.songs);
    const container = $('#pl-songs-container');
    container.innerHTML = '';

    if (songs.length === 0) {
        container.innerHTML = '<li class="empty">Playlist vazia. Clique com o botão direito em um vídeo para adicionar.</li>';
        return;
    }

    let draggedIndex = null;

    songs.forEach(function (song, index) {
        const row = document.createElement('li');
        row.className = 'pl-song-row';
        row.draggable = true;
        row.innerHTML = `
            ${svgIcon('i-grip', 'pl-drag-handle')}
            <img src="${escapeHtml(song.thumb || '')}" class="pl-song-img" alt="">
            <div class="pl-song-name">${escapeHtml(song.title || '')}</div>
            <span class="pl-song-remove">${svgIcon('i-close')}</span>
        `;

        row.addEventListener('dragstart', function (event) {
            draggedIndex = index;
            row.style.opacity = '0.45';
            if (event.dataTransfer) {
                event.dataTransfer.effectAllowed = 'move';
                event.dataTransfer.setData('text/plain', String(index));
            }
        });

        row.addEventListener('dragend', function () {
            draggedIndex = null;
            row.style.opacity = '';
        });

        row.addEventListener('dragover', function (event) {
            event.preventDefault();
            if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
        });

        row.addEventListener('drop', function (event) {
            event.preventDefault();

            let from = draggedIndex;
            if (from === null && event.dataTransfer) {
                from = parseInt(event.dataTransfer.getData('text/plain'), 10);
            }
            if (!isNaN(from) && from !== index && from >= 0 && from < songs.length) {
                const moved = songs.splice(from, 1)[0];
                songs.splice(index, 0, moved);
                savePlaylistSongs(playlist.id, songs);
                renderPlaylistSongs(playlist);
            }
        });

        row.querySelector('.pl-song-remove').addEventListener('click', function (event) {
            event.stopPropagation();
            songs.splice(index, 1);
            savePlaylistSongs(playlist.id, songs);
            renderPlaylistSongs(playlist);
        });

        row.addEventListener('click', function () {
            playSingleSong(song.url, song.title, song.thumb, { duration: song.duration || 0 });
        });

        container.appendChild(row);
    });
}

function savePlaylistSongs(id, newSongs) {
    postNUI('updatePlaylistSongs', { id: id, songs: newSongs }).catch(function () { });
}

function deletePlaylist(id) {
    postNUI('deletePlaylist', { id: id }).then(function () {
        fetchPlaylists();
        if (activePlaylistId == id) showHome();
    }).catch(function () { });
}

/* ===================================================
   MODAL
   =================================================== */
function showModal(title, callback, defaultValue) {
    $('#modal-title').textContent = title;
    $('#modal-input').value = defaultValue || '';
    $('#custom-modal').style.display = 'flex';
    $('#modal-input').focus();
    modalCallback = callback;
}

function closeModal() {
    $('#custom-modal').style.display = 'none';
    modalCallback = null;
}

$('#modal-cancel').addEventListener('click', closeModal);

$('#modal-confirm').addEventListener('click', function () {
    const callback = modalCallback;
    const value = $('#modal-input').value;
    closeModal();
    if (callback) callback(value);
});

$('#modal-input').addEventListener('keyup', function (event) {
    if (event.key === 'Enter') $('#modal-confirm').click();
});

$('#create-playlist-btn').addEventListener('click', function () {
    showModal("Nova playlist", function (value) {
        if (value) {
            postNUI('createPlaylist', { name: value }).then(function () {
                setTimeout(fetchPlaylists, 200);
            }).catch(function () { });
        }
    });
});

/* ===================================================
   MENU DE CONTEXTO
   =================================================== */
function openContextMenu(event, songData) {
    contextSong = songData || {};

    let html = `<li id="ctx-new">${svgIcon('i-plus')} Nova playlist</li>`;
    playlists.forEach(function (playlist) {
        html += `<li class="ctx-add-existing" data-id="${escapeHtml(playlist.id)}">${svgIcon('i-tv')} ${escapeHtml(playlist.name || '')}</li>`;
    });

    const list = $('#context-playlist-list');
    list.innerHTML = html;
    list.querySelector('#ctx-new').addEventListener('click', function () {
        $('#context-menu').style.display = 'none';
        showModal("Nova playlist", function (value) {
            if (value) {
                postNUI('createPlaylist', { name: value }).then(function () {
                    setTimeout(fetchPlaylists, 200);
                }).catch(function () { });
            }
        });
    });

    $$('.ctx-add-existing', list).forEach(function (item) {
        item.addEventListener('click', function () {
            $('#context-menu').style.display = 'none';
            postNUI('addSongToPlaylist', {
                playlistId: item.dataset.id,
                song: contextSong
            }).then(function () {
                setTimeout(fetchPlaylists, 200);
            }).catch(function () { });
        });
    });

    const menu = $('#context-menu');
    const appRect = $('#app').getBoundingClientRect();
    menu.style.top = (event.pageY - appRect.top) + 'px';
    menu.style.left = (event.pageX - appRect.left) + 'px';
    menu.style.display = 'block';
}
