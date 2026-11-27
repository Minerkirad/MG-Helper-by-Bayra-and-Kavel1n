/* MG Helper UI - мост к хосту (WebView2). В браузере работает на мок-данных. */
(function () {
    'use strict';
    var _errHost = (window.chrome && window.chrome.webview) ? window.chrome.webview : null;
    window.addEventListener('error', function (ev) { try { if (_errHost) { _errHost.postMessage({ type: 'ui-error', message: String(ev.message), line: String(ev.lineno) }); } } catch (e) { } });

    var host = (window.chrome && window.chrome.webview) ? window.chrome.webview : null;
    var state = { health: null, state: null, events: [], version: '', ui: {} };

    function $(id) { return document.getElementById(id); }
    function text(id, value) { var el = $(id); if (el) { el.textContent = value; } }

    function send(cmd, payload) {
        var msg = { cmd: cmd };
        if (payload) { for (var k in payload) { if (Object.prototype.hasOwnProperty.call(payload, k)) { msg[k] = payload[k]; } } }
        if (host) { host.postMessage(msg); }
        else { console.log('cmd', msg); }
    }

    function fmtTime(iso) {
        if (!iso) { return ''; }
        try {
            var d = new Date(iso);
            return d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        } catch (e) { return iso; }
    }

    var EVENT_LABELS = {
        'watcher.start': 'watcher запущен',
        'watcher.ready': 'watcher готов',
        'watcher.stop': 'watcher остановлен',
        'golden.applied': 'эталон применён',
        'golden.mismatch': 'эталон от другой машины',
        'adopt.accepted': 'правки приняты как эталон',
        'apply.failed': 'не удалось применить эталон',
        'session.start': 'сессия началась',
        'session.end': 'сессия завершена',
        'session.unknown': 'SAFE MODE: защита выключена',
        'guard.rollback': 'откат чужой записи',
        'guard.window_expired': 'окно охраны истекло',
        'insurance.restored': 'страховка .bin',
        'insurance.risk': 'риск ошибки 1002',
        'bins.archived': 'архив .bin обновлён',
        'tray.restart': 'трей перезапущен',
        'config.reloaded': 'конфиг перечитан',
        'error': 'ошибка watcher'
    };

    function label(name) { return EVENT_LABELS[name] || name; }

    function render() {
        var h = state.health;
        var s = state.state || {};
        var hero = $('hero');
        var healthy = h && h.status === 'running' && h.ageSec !== null && h.ageSec <= 15;
        var safeMode = h && (h.phase === 'UnknownSession' || state.ui.mismatch);
        var stopped = !h || h.status === 'stopping' || (h.ageSec !== null && h.ageSec > 30);

        hero.className = 'hero';
        if (safeMode || stopped) { hero.className = 'hero is-bad'; }
        else if (!healthy) { hero.className = 'hero is-warn'; }

        if (safeMode) {
            text('heroTitle', 'SAFE MODE: защита выключена');
            text('heroSub', 'Эталон не применяется: сессия начата без watcher-а или сменилось железо. Меню [11] — новый эталон.');
            text('heroPill', 'внимание');
        } else if (stopped) {
            text('heroTitle', 'Watcher не работает');
            text('heroSub', h ? 'Последний heartbeat ' + fmtTime(h.lastHeartbeatUtc) : 'Файл состояния не найден.');
            text('heroPill', 'остановлен');
        } else if (healthy) {
            text('heroTitle', 'Защищено');
            text('heroSub', 'Эталон под охраной · фаза ' + (h.phase || '—') + (h.gamePid ? ' · игра PID ' + h.gamePid : ''));
            text('heroPill', 'жив');
        } else {
            text('heroTitle', 'Watcher не отвечает');
            text('heroSub', 'Heartbeat просрочен — проверьте журнал.');
            text('heroPill', 'проверить');
        }

        text('goldenState', s.applied ? 'применён' : 'ожидает');
        text('goldenHint', s.lastApplyUtc ? 'последняя запись ' + fmtTime(s.lastApplyUtc) : 'в этой сессии не применялся');
        text('sessionState', s.phase || '—');
        text('sessionHint', s.gamePid ? 'PID ' + s.gamePid : 'сессии нет');
        text('rollbacks', String(s.guardRollbacks || 0));
        text('watcherState', h ? (h.status || '—') : '—');
        text('watcherHint', h ? 'PID ' + h.pid + ' · heartbeat ' + (h.ageSec === null ? '—' : Math.round(h.ageSec) + ' c') : 'нет данных');
        text('brandVersion', state.version || '');
        text('updatedAt', 'обновлено ' + new Date().toLocaleTimeString('ru-RU'));

        renderEvents();
        renderSettings(s);
    }

    function renderEvents() {
        var box = $('events');
        var list = (state.events || []).slice(-8).reverse();
        if (!list.length) { box.innerHTML = '<li class="empty">Событий пока нет</li>'; return; }
        var html = '';
        for (var i = 0; i < list.length; i++) {
            var ev = list[i];
            html += '<li><span class="t">' + fmtTime(ev.ts) + '</span>' +
                '<span class="e">' + escapeHtml(label(ev.event)) + '</span>' +
                '<span class="d">' + escapeHtml(ev.data || '') + '</span></li>';
        }
        box.innerHTML = html;
        var log = $('logBox');
        if (log) {
            var all = (state.events || []).slice(-300);
            var lines = [];
            for (var j = 0; j < all.length; j++) {
                lines.push(fmtTime(all[j].ts) + '  [' + all[j].phase + ']  ' + all[j].event + '  ' + (all[j].data || ''));
            }
            log.textContent = lines.join('\n') || 'Событий пока нет';
        }
    }

    function renderSettings(s) {
        var c = state.ui.config;
        if (!c) { return; }
        setChecked('allowAdopt', !!c.allowAdopt);
        setChecked('sessionGuard', c.sessionGuard !== false);
        var gw = $('guardWindow'); if (gw && document.activeElement !== gw) { gw.value = c.guardWindowSec || 0; }
        setChecked('autoSend', !!state.ui.autoSend);
        setChecked('autostart', !!state.ui.autostart);
    }

    function setChecked(id, value) { var el = $(id); if (el) { el.checked = value; } }

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
    }

    /* ---------- навигация ---------- */
    document.querySelectorAll('.nav-item').forEach(function (btn) {
        btn.addEventListener('click', function () {
            var page = btn.getAttribute('data-page');
            document.querySelectorAll('.nav-item').forEach(function (b) { b.classList.toggle('is-active', b === btn); });
            document.querySelectorAll('.page').forEach(function (p) { p.classList.toggle('is-active', p.getAttribute('data-page') === page); });
        });
    });

    /* ---------- тема ---------- */
    var themeBtn = $('themeToggle');
    var saved = null;
    try { saved = localStorage.getItem('mg-theme'); } catch (e) { }
    if (saved === 'light') { document.body.classList.add('light'); }
    if (themeBtn) {
        themeBtn.addEventListener('click', function () {
            document.body.classList.toggle('light');
            try { localStorage.setItem('mg-theme', document.body.classList.contains('light') ? 'light' : 'dark'); } catch (e) { }
        });
    }

    /* ---------- команды ---------- */
    document.querySelectorAll('[data-cmd]').forEach(function (btn) {
        btn.addEventListener('click', function () {
            var cmd = btn.getAttribute('data-cmd');
            btn.disabled = true;
            setTimeout(function () { btn.disabled = false; }, 1200);
            send(cmd);
        });
    });

    var save = $('saveSettings');
    if (save) {
        save.addEventListener('click', function () {
            send('save-config', {
                allowAdopt: !!$('allowAdopt').checked,
                sessionGuard: !!$('sessionGuard').checked,
                guardWindowSec: parseInt($('guardWindow').value, 10) || 0,
                autoSend: !!$('autoSend').checked
            });
            text('settingsStatus', 'сохранено');
            setTimeout(function () { text('settingsStatus', ''); }, 2500);
        });
    }
    var auto = $('autoSend');
    if (auto) {
        auto.addEventListener('change', function () { send('set-autosend', { value: !!auto.checked }); });
    }

    /* ---------- приём состояния от хоста ---------- */
    window.mg = {
        update: function (payload) {
            if (!payload) { return; }
            state.health = payload.health || null;
            state.state = payload.state || null;
            state.events = payload.events || [];
            state.version = payload.version || '';
            state.ui = payload.ui || {};
            render();
        },
        status: function (message) {
            text('reportStatus', message);
            setTimeout(function () { text('reportStatus', ''); }, 4000);
        }
    };

    if (host) {
        // сообщаем хосту, что мост работает (используется smoke-тестом в CI)
        try { host.postMessage({ type: 'ui-ready', title: document.title, bridge: true }); } catch (e) { }
        host.addEventListener('message', function (e) {
            var data = e.data || {};
            if (data.type === 'status') { window.mg.status(data.text); }
        });
    }

    /* мок-режим для отладки в браузере */
    if (!host) {
        window.mg.update({
            version: '3.1.0-dev', health: { status: 'running', phase: 'Idle', pid: 1234, ageSec: 2 },
            state: { phase: 'Idle', applied: false, guardRollbacks: 0 }, events: [],
            ui: { config: { allowAdopt: false, sessionGuard: true, guardWindowSec: 0 } }
        });
    }
})();