// MG Helper report relay (Cloudflare Worker)
//
// Принимает отчёт от приложения (multipart/form-data, поле document) и пересылает его
// в Telegram через бота. В пакет MG Helper попадает только URL воркера — токен бота
// живёт здесь, в переменных окружения воркера, и никогда не уходит пользователям.
//
// Переменные (Settings → Variables and Secrets):
//   TG_TOKEN  — токен бота (secret)
//   TG_CHAT   — chat_id получателя (secret)
//   MG_KEY    — необязательный общий ключ; если задан, клиент обязан прислать заголовок X-MG-Key
//
// Деплой: npx wrangler deploy relay/worker.js --name mg-helper-reports
// Клиент: в config.json приложения "reportUrl": "https://mg-helper-reports.<account>.workers.dev"

export default {
    async fetch(request, env) {
        const cors = {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, X-MG-Key',
        };
        if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
        if (request.method !== 'POST') return json({ ok: false, error: 'method' }, 405, cors);

        const url = new URL(request.url);
        if (url.pathname !== '/' && url.pathname !== '/report') return json({ ok: false, error: 'path' }, 404, cors);
        if (env.MG_KEY && request.headers.get('X-MG-Key') !== env.MG_KEY) {
            return json({ ok: false, error: 'key' }, 401, cors);
        }

        let form;
        try {
            form = await request.formData();
        } catch (e) {
            return json({ ok: false, error: 'form' }, 400, cors);
        }
        const file = form.get('document');
        if (!file || typeof file === 'string') return json({ ok: false, error: 'document' }, 400, cors);

        // защита от мусора: только текстовые отчёты разумного размера
        if (file.size > 2 * 1024 * 1024) return json({ ok: false, error: 'size' }, 413, cors);
        const name = (file.name || 'report.txt').replace(/[^\w.\-]/g, '_');

        const caption = [
            'MG Helper report',
            (form.get('version') || '').toString().slice(0, 40),
            (form.get('caption') || '').toString().slice(0, 120),
        ].filter(Boolean).join(' · ');

        const tg = new FormData();
        tg.append('chat_id', env.TG_CHAT);
        tg.append('caption', caption);
        tg.append('document', new File([await file.arrayBuffer()], name, { type: 'text/plain' }));

        const resp = await fetch(`https://api.telegram.org/bot${env.TG_TOKEN}/sendDocument`, {
            method: 'POST',
            body: tg,
        });
        if (!resp.ok) {
            return json({ ok: false, error: 'telegram', status: resp.status }, 502, cors);
        }
        return json({ ok: true }, 200, cors);
    },
};

function json(body, status, headers) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { ...headers, 'Content-Type': 'application/json; charset=utf-8' },
    });
}