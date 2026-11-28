// MG Helper report relay (Cloudflare Worker)
//
// Принимает отчёт от приложения (multipart/form-data, поле document) и пересылает его
// в Telegram через бота. В пакет MG Helper попадает только URL воркера — токен бота
// живёт здесь, в секретах воркера, и никогда не уходит пользователям.
//
// Переменные окружения воркера:
//   TG_TOKEN   — токен бота (secret)
//   TG_CHAT    — chat_id получателя (secret)
//   MG_KEY     — общий ключ только для служебного /discover (secret)
//   REQUIRE_KEY — "1" включает обязательный заголовок X-MG-Key для /report
//
// Маршруты:
//   POST /report   — отчёт -> Telegram
//   GET  /discover — служебный: отдаёт chat_id'ы, которые писали боту (нужен X-MG-Key)
//   GET  /health   — проверка, что воркер жив и настроен

export default {
    async fetch(request, env) {
        const cors = {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, X-MG-Key',
        };
        if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });

        const url = new URL(request.url);
        const path = url.pathname.replace(/\/+$/, '') || '/';

        if (path === '/health') {
            return json({
                ok: true,
                configured: Boolean(env.TG_TOKEN),
                chatSet: Boolean(env.TG_CHAT),
            }, 200, cors);
        }

        // Служебный маршрут: нужен при первой настройке, чтобы узнать chat_id.
        if (path === '/discover') {
            if (!env.MG_KEY || request.headers.get('X-MG-Key') !== env.MG_KEY) {
                return json({ ok: false, error: 'key' }, 401, cors);
            }
            if (!env.TG_TOKEN) return json({ ok: false, error: 'no-token' }, 500, cors);
            const resp = await fetch(`https://api.telegram.org/bot${env.TG_TOKEN}/getUpdates?limit=20`);
            const data = await resp.json();
            if (!data.ok) return json({ ok: false, error: 'telegram', detail: data }, 502, cors);
            const chats = [];
            for (const update of data.result || []) {
                const msg = update.message || update.edited_message || update.channel_post;
                if (msg && msg.chat) {
                    chats.push({ id: msg.chat.id, type: msg.chat.type, name: msg.chat.username || msg.chat.title || msg.chat.first_name || '' });
                }
            }
            return json({ ok: true, chats: chats }, 200, cors);
        }

        if (request.method !== 'POST') return json({ ok: false, error: 'method' }, 405, cors);
        if (path !== '/' && path !== '/report') return json({ ok: false, error: 'path' }, 404, cors);
        if (env.REQUIRE_KEY === '1' && env.MG_KEY && request.headers.get('X-MG-Key') !== env.MG_KEY) {
            return json({ ok: false, error: 'key' }, 401, cors);
        }
        if (!env.TG_TOKEN || !env.TG_CHAT) return json({ ok: false, error: 'not-configured' }, 500, cors);

        let form;
        try {
            form = await request.formData();
        } catch (e) {
            return json({ ok: false, error: 'form' }, 400, cors);
        }
        const file = form.get('document');
        if (!file || typeof file === 'string') return json({ ok: false, error: 'document' }, 400, cors);
        if (file.size > 2 * 1024 * 1024) return json({ ok: false, error: 'size' }, 413, cors);

        const name = (file.name || 'report.txt').replace(/[^\w.\-]/g, '_');
        const parts = [
            'MG Helper report',
            (form.get('version') || '').toString().slice(0, 40),
            (form.get('caption') || '').toString().slice(0, 120),
        ].filter(function (p) { return p && String(p).trim().length > 0; });

        const tg = new FormData();
        tg.append('chat_id', env.TG_CHAT);
        tg.append('caption', parts.join(' · '));
        tg.append('document', new File([await file.arrayBuffer()], name, { type: 'text/plain' }));

        const resp = await fetch(`https://api.telegram.org/bot${env.TG_TOKEN}/sendDocument`, {
            method: 'POST',
            body: tg,
        });
        if (!resp.ok) {
            let detail = '';
            try { detail = (await resp.text()).slice(0, 300); } catch (e) { }
            return json({ ok: false, error: 'telegram', status: resp.status, detail: detail }, 502, cors);
        }
        return json({ ok: true }, 200, cors);
    },
};

function json(body, status, headers) {
    return new Response(JSON.stringify(body), {
        status: status,
        headers: Object.assign({}, headers, { 'Content-Type': 'application/json; charset=utf-8' }),
    });
}