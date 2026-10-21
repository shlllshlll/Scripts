// ==UserScript==
// @name         飞牛影视 · 弹幕增强
// @name:en      fnOS Video Danmaku
// @namespace    https://github.com/shlllshlll/Scripts
// @homepageURL  https://github.com/shlllshlll/Scripts
// @supportURL   https://github.com/shlllshlll/Scripts/issues
// @version      1.0.21
// @description  为飞牛影视网页播放器挂载 danmu-api 弹幕：自动匹配、手动搜索、完整的 GM 设置面板；无需反向代理。
// @description:en  Add danmu-api bullet comments to the fnOS Video web player, with auto-match, manual search, an in-player settings submenu, and GM-based configuration.
// @author       shlllshlll
// @license      MIT
// @match        *://*/v
// @match        *://*/v/*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_registerMenuCommand
// @grant        GM_xmlhttpRequest
// @connect      *
// @run-at       document-start
// @noframes
// ==/UserScript==

(() => {
    'use strict';

    /* ══════════════════════════════════════════════════════════════════
     *  飞牛影视弹幕增强（油猴 / ScriptCat 版）
     *
     *  与 fn-danmu 反向代理方案的区别：
     *    - 脚本直接运行在飞牛影视原始页面中，不修改页面、不代理视频流；
     *    - 弹幕数据通过 GM_xmlhttpRequest 直连 danmu-api，绕过浏览器 CORS；
     *    - API 地址 / Token 与显示参数通过 GM_getValue / GM_setValue 保存；
     *    - 菜单命令「飞牛弹幕设置」打开独立设置窗口。
     * ══════════════════════════════════════════════════════════════════ */

    const VERSION = '1.0.21';
    const STORE_KEY = 'fnos_danmaku_cfg_v1';
    const FONT = '"PingFang SC","Microsoft YaHei","Helvetica Neue",Arial,sans-serif';
    const PSEL = 'div.xgplayer, .xgplayer, [class*="xgplayer"]';

    const DEFAULTS = Object.freeze({
        apiBase: '',
        apiToken: '',
        autoMatch: true,
        enabled: true,
        opacity: 0.85,
        area: 35,
        fontSize: 22,
        lineHeight: 1.8,
        speed: 1,
        outline: true,
        density: 100,
        maxActive: 40,
        offset: 0,
        debug: false
    });

    /* ══════════════════════════════════════════════════════════════════
     *  基础工具
     * ══════════════════════════════════════════════════════════════════ */

    function h(tag, attrs, ...children) {
        const node = document.createElement(tag);
        if (attrs) {
            for (const [key, value] of Object.entries(attrs)) {
                if (value == null || value === false) continue;
                if (key === 'class') node.className = value;
                else if (key === 'text') node.textContent = value;
                else if (key === 'style') node.style.cssText = value;
                else if (key === 'html') node.innerHTML = value;
                else if (key.startsWith('on') && typeof value === 'function') {
                    node.addEventListener(key.slice(2).toLowerCase(), value);
                } else if (key in node) {
                    try { node[key] = value; } catch { node.setAttribute(key, value); }
                } else {
                    node.setAttribute(key, value);
                }
            }
        }
        for (const child of children.flat(Infinity)) {
            if (child == null || child === false) continue;
            node.append(child.nodeType ? child : document.createTextNode(String(child)));
        }
        return node;
    }

    function styleNode(css) {
        const s = document.createElement('style');
        s.textContent = css;
        return s;
    }

    function clamp(n, min, max) {
        return Math.min(max, Math.max(min, n));
    }

    function pad2(n) {
        const num = Number(n);
        return Number.isFinite(num) && num > 0 ? String(num).padStart(2, '0') : '?';
    }

    function formatTime(sec) {
        const s = Math.max(0, Number(sec) || 0);
        return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
    }

    function stripSlash(s) {
        return String(s || '').trim().replace(/^\/+|\/+$/g, '');
    }

    /* ── 飞牛 Web 端请求签名 ───────────────────────────────────────────
     * 飞牛的 /v/api/v1/* 接口不只看 Cookie，还校验 authx 签名。
     * 签名算法来自当前 fnOS Web 客户端：
     *   sign = md5([固定密钥, pathname, nonce, timestamp, md5(body), apiKey].join('_'))
     * 这样油猴脚本不用依赖页面内 fetch 拦截器，也能读取 play/info。
     * 如果飞牛后续修改签名算法，需要同步更新这里的常量。
     */
    const TRIM_AUTH_SECRET = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh';
    const TRIM_API_KEY = '16CCEB3D-AB42-077D-36A1-F355324E4237';
    const TRIM_CLIENT_VERSION = '631';

    function md5(str) {
        function safeAdd(x, y) {
            const lsw = (x & 0xffff) + (y & 0xffff);
            return (((x >> 16) + (y >> 16) + (lsw >> 16)) << 16) | (lsw & 0xffff);
        }
        function rol(num, cnt) { return (num << cnt) | (num >>> (32 - cnt)); }
        function cmn(q, a, b, x, s, t) {
            return safeAdd(rol(safeAdd(safeAdd(a, q), safeAdd(x, t)), s), b);
        }
        function ff(a, b, c, d, x, s, t) { return cmn((b & c) | (~b & d), a, b, x, s, t); }
        function gg(a, b, c, d, x, s, t) { return cmn((b & d) | (c & ~d), a, b, x, s, t); }
        function hh(a, b, c, d, x, s, t) { return cmn(b ^ c ^ d, a, b, x, s, t); }
        function ii(a, b, c, d, x, s, t) { return cmn(c ^ (b | ~d), a, b, x, s, t); }

        function str2binl(s) {
            const bin = [];
            const mask = (1 << 8) - 1;
            for (let i = 0; i < s.length * 8; i += 8) {
                bin[i >> 5] |= (s.charCodeAt(i / 8) & mask) << (i % 32);
            }
            return bin;
        }

        function binl2hex(bin) {
            const hexTab = '0123456789abcdef';
            let out = '';
            for (let i = 0; i < bin.length * 4; i++) {
                out += hexTab.charAt((bin[i >> 2] >> ((i % 4) * 8 + 4)) & 0xf) +
                    hexTab.charAt((bin[i >> 2] >> ((i % 4) * 8)) & 0xf);
            }
            return out;
        }

        function core(x, len) {
            x[len >> 5] |= 0x80 << (len % 32);
            x[(((len + 64) >>> 9) << 4) + 14] = len;
            let a = 1732584193;
            let b = -271733879;
            let c = -1732584194;
            let d = 271733878;

            for (let i = 0; i < x.length; i += 16) {
                const olda = a;
                const oldb = b;
                const oldc = c;
                const oldd = d;

                a = ff(a, b, c, d, x[i], 7, -680876936);
                d = ff(d, a, b, c, x[i + 1], 12, -389564586);
                c = ff(c, d, a, b, x[i + 2], 17, 606105819);
                b = ff(b, c, d, a, x[i + 3], 22, -1044525330);
                a = ff(a, b, c, d, x[i + 4], 7, -176418897);
                d = ff(d, a, b, c, x[i + 5], 12, 1200080426);
                c = ff(c, d, a, b, x[i + 6], 17, -1473231341);
                b = ff(b, c, d, a, x[i + 7], 22, -45705983);
                a = ff(a, b, c, d, x[i + 8], 7, 1770035416);
                d = ff(d, a, b, c, x[i + 9], 12, -1958414417);
                c = ff(c, d, a, b, x[i + 10], 17, -42063);
                b = ff(b, c, d, a, x[i + 11], 22, -1990404162);
                a = ff(a, b, c, d, x[i + 12], 7, 1804603682);
                d = ff(d, a, b, c, x[i + 13], 12, -40341101);
                c = ff(c, d, a, b, x[i + 14], 17, -1502002290);
                b = ff(b, c, d, a, x[i + 15], 22, 1236535329);

                a = gg(a, b, c, d, x[i + 1], 5, -165796510);
                d = gg(d, a, b, c, x[i + 6], 9, -1069501632);
                c = gg(c, d, a, b, x[i + 11], 14, 643717713);
                b = gg(b, c, d, a, x[i], 20, -373897302);
                a = gg(a, b, c, d, x[i + 5], 5, -701558691);
                d = gg(d, a, b, c, x[i + 10], 9, 38016083);
                c = gg(c, d, a, b, x[i + 15], 14, -660478335);
                b = gg(b, c, d, a, x[i + 4], 20, -405537848);
                a = gg(a, b, c, d, x[i + 9], 5, 568446438);
                d = gg(d, a, b, c, x[i + 14], 9, -1019803690);
                c = gg(c, d, a, b, x[i + 3], 14, -187363961);
                b = gg(b, c, d, a, x[i + 8], 20, 1163531501);
                a = gg(a, b, c, d, x[i + 13], 5, -1444681467);
                d = gg(d, a, b, c, x[i + 2], 9, -51403784);
                c = gg(c, d, a, b, x[i + 7], 14, 1735328473);
                b = gg(b, c, d, a, x[i + 12], 20, -1926607734);

                a = hh(a, b, c, d, x[i + 5], 4, -378558);
                d = hh(d, a, b, c, x[i + 8], 11, -2022574463);
                c = hh(c, d, a, b, x[i + 11], 16, 1839030562);
                b = hh(b, c, d, a, x[i + 14], 23, -35309556);
                a = hh(a, b, c, d, x[i + 1], 4, -1530992060);
                d = hh(d, a, b, c, x[i + 4], 11, 1272893353);
                c = hh(c, d, a, b, x[i + 7], 16, -155497632);
                b = hh(b, c, d, a, x[i + 10], 23, -1094730640);
                a = hh(a, b, c, d, x[i + 13], 4, 681279174);
                d = hh(d, a, b, c, x[i], 11, -358537222);
                c = hh(c, d, a, b, x[i + 3], 16, -722521979);
                b = hh(b, c, d, a, x[i + 6], 23, 76029189);
                a = hh(a, b, c, d, x[i + 9], 4, -640364487);
                d = hh(d, a, b, c, x[i + 12], 11, -421815835);
                c = hh(c, d, a, b, x[i + 15], 16, 530742520);
                b = hh(b, c, d, a, x[i + 2], 23, -995338651);

                a = ii(a, b, c, d, x[i], 6, -198630844);
                d = ii(d, a, b, c, x[i + 7], 10, 1126891415);
                c = ii(c, d, a, b, x[i + 14], 15, -1416354905);
                b = ii(b, c, d, a, x[i + 5], 21, -57434055);
                a = ii(a, b, c, d, x[i + 12], 6, 1700485571);
                d = ii(d, a, b, c, x[i + 3], 10, -1894986606);
                c = ii(c, d, a, b, x[i + 10], 15, -1051523);
                b = ii(b, c, d, a, x[i + 1], 21, -2054922799);
                a = ii(a, b, c, d, x[i + 8], 6, 1873313359);
                d = ii(d, a, b, c, x[i + 15], 10, -30611744);
                c = ii(c, d, a, b, x[i + 6], 15, -1560198380);
                b = ii(b, c, d, a, x[i + 13], 21, 1309151649);
                a = ii(a, b, c, d, x[i + 4], 6, -145523070);
                d = ii(d, a, b, c, x[i + 11], 10, -1120210379);
                c = ii(c, d, a, b, x[i + 2], 15, 718787259);
                b = ii(b, c, d, a, x[i + 9], 21, -343485551);

                a = safeAdd(a, olda);
                b = safeAdd(b, oldb);
                c = safeAdd(c, oldc);
                d = safeAdd(d, oldd);
            }
            return [a, b, c, d];
        }

        const bytes = new TextEncoder().encode(str);
        let s = '';
        for (const b of bytes) s += String.fromCharCode(b);
        return binl2hex(core(str2binl(s), s.length * 8));
    }

    function getCookie(name) {
        try {
            const parts = document.cookie.split(';');
            for (const part of parts) {
                const trimmed = part.trim();
                const index = trimmed.indexOf('=');
                if (index < 0) continue;
                if (trimmed.slice(0, index) === name) {
                    return decodeURIComponent(trimmed.slice(index + 1));
                }
            }
        } catch { /* ignore */ }
        return '';
    }

    function trimAuthHeaders(url, method, bodyString) {
        const u = new URL(url, location.origin);
        const isGet = String(method || 'GET').toUpperCase() === 'GET';
        let dataHash;

        if (isGet) {
            const params = {};
            u.searchParams.forEach((value, key) => {
                if (value !== 'undefined' && value !== 'null') params[key] = value;
            });
            const search = new URLSearchParams();
            for (const key of Object.keys(params).sort()) {
                search.append(key, String(params[key]));
            }
            const query = search.toString().replace(/\+/g, '%20');
            let decoded = query;
            try {
                decoded = decodeURIComponent(query.replace(/%(?![0-9A-Fa-f]{2})/g, '%25'));
            } catch { /* keep query */ }
            dataHash = md5(decoded);
        } else {
            dataHash = md5(bodyString || '');
        }

        const nonce = String(Math.floor(Math.random() * 900000) + 100000);
        const timestamp = String(Date.now());
        const sign = md5([
            TRIM_AUTH_SECRET,
            u.pathname,
            nonce,
            timestamp,
            dataHash,
            TRIM_API_KEY
        ].join('_'));

        return {
            Authorization: getCookie('Trim-MC-token'),
            authx: `nonce=${nonce}&timestamp=${timestamp}&sign=${sign}`,
            'X-Trim-Client': 'web',
            'X-Trim-Client-Version': TRIM_CLIENT_VERSION
        };
    }

    let saveTimer = null;
    let cfg = { ...DEFAULTS };

    // 尽早注册焦点守卫，赶在播放器自己的 focusout 关闭逻辑之前。
    ensureFocusGuard();

    function log(...args) {
        if (cfg.debug) console.log('%c[飞牛弹幕]', 'color:#4f8cff;font-weight:bold', ...args);
    }

    function warn(...args) {
        if (cfg.debug) console.warn('[飞牛弹幕]', ...args);
    }

    function error(...args) {
        console.error('[飞牛弹幕]', ...args);
    }

    /* ══════════════════════════════════════════════════════════════════
     *  设置存储（油猴设置 API）
     * ══════════════════════════════════════════════════════════════════ */

    function gmGet(key, fallback) {
        try {
            if (typeof GM_getValue === 'function') {
                const value = GM_getValue(key);
                return value === undefined ? fallback : value;
            }
        } catch (e) {
            warn('GM_getValue 失败，回退 localStorage', e);
        }
        try {
            const value = localStorage.getItem(`fn_dm_${key}`);
            return value == null ? fallback : value;
        } catch {
            return fallback;
        }
    }

    function gmSet(key, value) {
        try {
            if (typeof GM_setValue === 'function') {
                GM_setValue(key, value);
                return;
            }
        } catch (e) {
            warn('GM_setValue 失败，回退 localStorage', e);
        }
        try { localStorage.setItem(`fn_dm_${key}`, value); } catch { /* ignore */ }
    }

    function loadCfg() {
        const out = { ...DEFAULTS };
        let saved = null;
        try {
            const raw = gmGet(STORE_KEY, '');
            if (raw && typeof raw === 'object') saved = raw;
            else if (typeof raw === 'string' && raw.trim()) saved = JSON.parse(raw);
        } catch (e) {
            warn('读取设置失败，使用默认值', e);
        }
        if (!saved || typeof saved !== 'object') return out;

        if (typeof saved.apiBase === 'string') out.apiBase = saved.apiBase;
        if (typeof saved.apiToken === 'string') out.apiToken = saved.apiToken;
        if (typeof saved.autoMatch === 'boolean') out.autoMatch = saved.autoMatch;
        if (typeof saved.enabled === 'boolean') out.enabled = saved.enabled;
        if (typeof saved.outline === 'boolean') out.outline = saved.outline;
        if (typeof saved.debug === 'boolean') out.debug = saved.debug;

        const numbers = {
            opacity: [0, 1],
            area: [10, 80],
            fontSize: [10, 40],
            lineHeight: [1.2, 3],
            speed: [0.5, 2.5],
            density: [10, 100],
            maxActive: [10, 80],
            offset: [-30, 30]
        };
        for (const [key, [min, max]] of Object.entries(numbers)) {
            if (typeof saved[key] === 'number' && Number.isFinite(saved[key])) {
                out[key] = clamp(saved[key], min, max);
            }
        }
        return out;
    }

    cfg = loadCfg();

    function saveNow() {
        clearTimeout(saveTimer);
        try {
            gmSet(STORE_KEY, JSON.stringify(cfg));
            log('设置已保存', cfg);
        } catch (e) {
            error('保存设置失败', e);
        }
    }

    function saveSoon() {
        clearTimeout(saveTimer);
        saveTimer = setTimeout(saveNow, 250);
    }

    /* ══════════════════════════════════════════════════════════════════
     *  API 地址与请求
     * ══════════════════════════════════════════════════════════════════ */

    function defaultApiBase() {
        const host = location.hostname;
        if (!host) return '';
        const hh = host.includes(':') && !host.startsWith('[') ? `[${host}]` : host;
        return `http://${hh}:9321`;
    }

    function normalizeBase(input) {
        let value = String(input == null ? '' : input).trim();
        if (!value) return '';
        if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) value = `http://${value}`;
        let url;
        try {
            url = new URL(value);
        } catch {
            throw new Error('地址格式不正确，请填写 http://NAS-IP:9321');
        }
        if (url.protocol !== 'http:' && url.protocol !== 'https:') {
            throw new Error('只支持 http / https 地址');
        }
        return `${url.origin}${url.pathname}`.replace(/\/+$/g, '');
    }

    function apiRoot(override) {
        const source = override || {};
        const base = normalizeBase(source.base != null ? source.base : cfg.apiBase) ||
            normalizeBase(defaultApiBase());
        if (!base) throw new Error('未配置 danmu-api 地址');
        const token = stripSlash(source.token != null ? source.token : cfg.apiToken);
        return token ? `${base}/${encodeURIComponent(token)}` : base;
    }

    class ApiError extends Error {
        constructor(status, message) {
            super(message || `HTTP ${status}`);
            this.name = 'ApiError';
            this.status = status || 0;
        }
    }

    function apiErrorMessage(data, text) {
        if (data && typeof data === 'object') {
            return data.errorMessage || data.message || data.msg || data.error || '';
        }
        return String(text || '').trim().slice(0, 180);
    }

    function fallbackFetchJson(url, opts) {
        return fetch(url, {
            method: opts.method || 'GET',
            headers: opts.headers || {},
            body: opts.body,
            credentials: opts.withCredentials ? 'include' : 'omit'
        }).then(async res => {
            const text = await res.text();
            let data = null;
            try { data = text ? JSON.parse(text) : null; } catch { /* keep null */ }
            if (!res.ok) throw new ApiError(res.status, apiErrorMessage(data, text));
            if (text && data == null) throw new ApiError(res.status, '接口返回的不是 JSON');
            return data;
        });
    }

    function requestJson(url, opts = {}) {
        const method = (opts.method || 'GET').toUpperCase();
        const headers = Object.assign({ Accept: 'application/json' }, opts.headers || {});
        const timeout = opts.timeout || 30000;

        if (typeof GM_xmlhttpRequest !== 'function') {
            log('GM_xmlhttpRequest 不可用，使用 fetch', url);
            return fallbackFetchJson(url, { ...opts, method, headers });
        }

        return new Promise((resolve, reject) => {
            let finished = false;
            const finish = (fn, value) => {
                if (finished) return;
                finished = true;
                fn(value);
            };
            try {
                GM_xmlhttpRequest({
                    method,
                    url,
                    headers,
                    data: opts.body,
                    timeout,
                    withCredentials: !!opts.withCredentials,
                    onload(res) {
                        const text = res.responseText || '';
                        let data = null;
                        try { data = text ? JSON.parse(text) : null; } catch { /* keep null */ }
                        if (res.status >= 200 && res.status < 300) {
                            finish(resolve, data);
                        } else {
                            finish(reject, new ApiError(res.status, apiErrorMessage(data, text)));
                        }
                    },
                    onerror() { finish(reject, new Error('网络请求失败')); },
                    ontimeout() { finish(reject, new Error(`请求超时（${Math.round(timeout / 1000)} 秒）`)); },
                    onabort() { finish(reject, new Error('请求已取消')); }
                });
            } catch (e) {
                finish(reject, e);
            }
        });
    }

    function apiUrl(path, override) {
        return `${apiRoot(override)}${path}`;
    }

    const api = {
        search(keyword, override) {
            return requestJson(apiUrl(`/api/v2/search/anime?keyword=${encodeURIComponent(keyword)}`, override), {
                timeout: 25000
            });
        },
        match(fileName, override) {
            return requestJson(apiUrl('/api/v2/match', override), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ fileName }),
                timeout: 35000
            });
        },
        bangumi(id, override) {
            return requestJson(apiUrl(`/api/v2/bangumi/${encodeURIComponent(id)}`, override), {
                timeout: 25000
            });
        },
        async comment(id, override) {
            const r = await requestJson(
                apiUrl(`/api/v2/comment/${encodeURIComponent(id)}?format=json&duration=true`, override),
                { timeout: 35000 }
            );
            const comments = r?.comments || r?.data?.comments || (Array.isArray(r) ? r : []);
            const videoDuration = r?.videoDuration || r?.data?.videoDuration || 0;
            return { comments: Array.isArray(comments) ? comments : [], videoDuration };
        }
    };

    async function testApi(override) {
        const started = Date.now();
        const keyword = S?.info?.title || '测试';
        const r = await api.search(keyword, override);
        const list = r?.animes || r?.data?.animes || (Array.isArray(r) ? r : []);
        return { ms: Date.now() - started, count: Array.isArray(list) ? list.length : 0 };
    }

    /* ══════════════════════════════════════════════════════════════════
     *  飞牛影视页面信息
     * ══════════════════════════════════════════════════════════════════ */

    function getGuid() {
        const patterns = [
            /\/v\/video\/([a-f0-9]+)/i,
            /[?&](?:item_)?guid=([a-f0-9]+)/i
        ];
        for (const source of [location.pathname, location.hash, location.search]) {
            for (const re of patterns) {
                const m = String(source || '').match(re);
                if (m) return m[1];
            }
        }
        return null;
    }

    async function fetchPlayInfo(guid) {
        const prefix = (location.pathname.match(/^(.*?)\/v(?:\/|$)/) || [])[1] || '';
        const url = `${location.origin}${prefix}/v/api/v1/play/info`;
        const body = JSON.stringify({ item_guid: guid });
        const headers = {
            'Content-Type': 'application/json',
            ...trimAuthHeaders(url, 'POST', body)
        };
        try {
            const res = await fetch(url, {
                method: 'POST',
                headers,
                body,
                credentials: 'include'
            });
            if (!res.ok) throw new ApiError(res.status, `读取视频信息失败（HTTP ${res.status}）`);
            return await res.json();
        } catch (e) {
            if (e instanceof ApiError) throw e;
            log('fetch 读取 play/info 失败，尝试 GM_xmlhttpRequest', e);
            return requestJson(url, {
                method: 'POST',
                headers,
                body,
                withCredentials: true,
                timeout: 15000
            });
        }
    }

    function mapPlayInfo(raw, guid) {
        const item = raw?.data?.item;
        if (!item) {
            if (raw?.code === 5000 && /invalid sign/i.test(String(raw.msg || ''))) {
                throw new Error('飞牛登录签名校验失败，请刷新页面或重新登录');
            }
            throw new Error(raw?.msg || '无法读取当前视频信息');
        }
        const title = item.tv_title || item.title || item.name || item.item_name || '未知视频';
        const season = Number(item.season_number) || 1;
        const episode = Number(item.episode_number) || 1;
        const isSeries = !!item.tv_title;
        const year = item.year || item.release_year ||
            (item.release_date ? String(item.release_date).slice(0, 4) : '');
        return {
            guid: item.guid || guid,
            title: String(title),
            season,
            episode,
            isSeries,
            year: String(year || '')
        };
    }

    async function getInfo() {
        const guid = getGuid();
        if (!guid) return null;
        const raw = await fetchPlayInfo(guid);
        return mapPlayInfo(raw, guid);
    }

    function buildMatchNames(info) {
        const title = String(info?.title || '').replace(/\s+/g, ' ').trim();
        if (!title) return [];
        const out = [];
        if (info.isSeries) {
            out.push(`${title} S${pad2(info.season)}E${pad2(info.episode)}`);
            out.push(`${title} 第${info.episode}集`);
            if (info.season > 1) out.push(`${title} 第${info.season}季 第${info.episode}集`);
        } else {
            out.push(title);
            if (info.year) out.push(`${title} ${info.year}`);
        }
        return [...new Set(out)];
    }

    /* ══════════════════════════════════════════════════════════════════
     *  弹幕渲染引擎
     * ══════════════════════════════════════════════════════════════════ */

    class DanmakuEngine {
        constructor({ host, canvas, video, signal, onCount, onHit }) {
            this.host = host;
            this.canvas = canvas;
            this.video = video;
            this.signal = signal;
            this.onCount = onCount;
            this.onHit = onHit;

            this.ctx = canvas.getContext('2d');
            this.W = 1;
            this.H = 1;
            this.lastDpr = 0;
            this.texCache = new Map();

            this.all = [];
            this.active = [];
            this.rows = [];
            this.fixedTop = [];
            this.fixedBot = [];
            this.idx = 0;
            this.raw = null;
            this.dmDuration = 0;
            this.playTime = 0;
            this.lastFrame = 0;
            this.raf = null;
            this.showGuide = false;
            this.destroyed = false;

            this._tick = this.tick.bind(this);
            this._fit = this.fit.bind(this);
            this._init();
        }

        _init() {
            this.fit();
            if (typeof ResizeObserver === 'function') {
                this.ro = new ResizeObserver(() => this.fit());
                this.ro.observe(this.host);
            }
            window.addEventListener('resize', this._fit, { signal: this.signal });

            const v = this.video;
            v.addEventListener('play', () => { this.lastFrame = 0; this.ensureLoop(); }, { signal: this.signal });
            v.addEventListener('pause', () => this.ensureLoop(), { signal: this.signal });
            v.addEventListener('seeked', () => this.onSeek(), { signal: this.signal });
            v.addEventListener('ratechange', () => { this.lastFrame = 0; }, { signal: this.signal });
            v.addEventListener('loadedmetadata', () => {
                if (this.raw && this.dmDuration > 0) this.applyLoad();
                this.ensureLoop();
            }, { signal: this.signal });

            this.playTime = v.currentTime || 0;
            this.ensureLoop();
        }

        fit() {
            if (this.destroyed || !this.ctx) return;
            const rect = this.host.getBoundingClientRect();
            const dpr = window.devicePixelRatio || 1;
            this.W = Math.max(1, Math.round(rect.width));
            this.H = Math.max(1, Math.round(rect.height));
            this.canvas.width = Math.round(this.W * dpr);
            this.canvas.height = Math.round(this.H * dpr);
            this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
            this.ctx.imageSmoothingEnabled = true;
            if (dpr !== this.lastDpr) {
                this.lastDpr = dpr;
                this.texCache.clear();
            }
            this.measureAll();
            this.ensureLoop();
        }

        destroy() {
            this.destroyed = true;
            if (this.raf) cancelAnimationFrame(this.raf);
            this.raf = null;
            if (this.ro) this.ro.disconnect();
            this.ro = null;
            this.texCache.clear();
            this.all = [];
            this.active = [];
            this.rows = [];
            this.fixedTop = [];
            this.fixedBot = [];
            this.raw = null;
            this.ctx = null;
        }

        clearTextCache() {
            this.texCache.clear();
        }

        measureAll() {
            if (!this.ctx) return;
            const fs = cfg.fontSize;
            this.ctx.save();
            this.ctx.font = `bold ${fs}px ${FONT}`;
            for (const d of this.all) d.w = this.ctx.measureText(d.text).width;
            for (const d of this.active) d.w = this.ctx.measureText(d.text).width;
            this.ctx.restore();
        }

        parse(raw) {
            const list = Array.isArray(raw) ? raw : [];
            const out = [];
            for (const item of list) {
                if (!item) continue;
                try {
                    let time;
                    let mode;
                    let color;
                    let text;

                    if (typeof item === 'string') {
                        const split = item.indexOf(':');
                        if (split < 0) continue;
                        time = parseFloat(item.slice(0, split));
                        text = item.slice(split + 1);
                        mode = 1;
                        color = 16777215;
                    } else if (item.p != null) {
                        const p = String(item.p).split(',');
                        time = parseFloat(p[0]);
                        mode = parseInt(p[1] || '1', 10);
                        color = p[2];
                        text = item.m != null ? item.m : item.text;
                    } else {
                        time = Number(item.time != null ? item.time : item.t);
                        if (item.progress != null && !Number.isFinite(time)) time = Number(item.progress) / 1000;
                        mode = Number(item.mode != null ? item.mode : item.type != null ? item.type : 1);
                        color = item.color != null ? item.color : item.colorDecimal;
                        text = item.m != null ? item.m : item.text != null ? item.text : item.content;
                    }

                    if (!Number.isFinite(time)) continue;
                    const value = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
                    if (!value) continue;

                    let colorCss = '#ffffff';
                    if (typeof color === 'string' && /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(color.trim())) {
                        colorCss = color.trim();
                    } else if (color != null && color !== '') {
                        const n = typeof color === 'number' ? color : parseInt(String(color), 10);
                        if (Number.isFinite(n)) colorCss = `#${(n & 0xffffff).toString(16).padStart(6, '0')}`;
                    }

                    const type = mode === 4 ? 1 : mode === 5 ? 2 : 0;
                    out.push({ text: value, color: colorCss, type, time, w: 0 });
                } catch (e) {
                    warn('解析单条弹幕失败', item, e);
                }
            }
            out.sort((a, b) => a.time - b.time);
            return out.slice(0, 20000);
        }

        load(raw, duration) {
            this.raw = Array.isArray(raw) ? raw : [];
            this.dmDuration = Number(duration) || 0;
            this.applyLoad();
        }

        applyLoad() {
            this.all = this.parse(this.raw);
            const vd = Number(this.video?.duration);
            if (this.dmDuration > 0 && Number.isFinite(vd) && vd > 0 && Math.abs(vd - this.dmDuration) > 5) {
                const ratio = vd / this.dmDuration;
                if (ratio > 0.5 && ratio < 2) {
                    for (const d of this.all) d.time *= ratio;
                    this.all.sort((a, b) => a.time - b.time);
                    log('弹幕时长校准', this.dmDuration, '→', vd, 'ratio', ratio.toFixed(3));
                }
            }
            this.active = [];
            this.rows = [];
            this.fixedTop = [];
            this.fixedBot = [];
            this.idx = 0;
            this.stats = { scroll: 0, top: 0, bottom: 0 };
            for (const d of this.all) {
                if (d.type === 1) this.stats.bottom++;
                else if (d.type === 2) this.stats.top++;
                else this.stats.scroll++;
            }
            log('弹幕类型统计', this.stats);
            if (this.onCount) this.onCount(this.all.length);
            this.measureAll();
            this.onSeek();
            this.ensureLoop();
        }

        clear() {
            this.all = [];
            this.active = [];
            this.rows = [];
            this.fixedTop = [];
            this.fixedBot = [];
            this.idx = 0;
            this.raw = null;
            this.dmDuration = 0;
            this.texCache.clear();
            if (this.onCount) this.onCount(0);
            this.draw();
        }

        onSeek() {
            if (!this.video) return;
            this.active = [];
            this.rows = [];
            this.fixedTop = [];
            this.fixedBot = [];
            this.lastFrame = 0;
            this.playTime = this.video.currentTime || 0;
            const t = this.playTime - cfg.offset;
            let lo = 0;
            let hi = this.all.length;
            while (lo < hi) {
                const m = (lo + hi) >> 1;
                if (this.all[m].time <= t) lo = m + 1;
                else hi = m;
            }
            this.idx = lo;
            this.ensureLoop();
        }

        ensureLoop() {
            if (this.destroyed || this.raf) return;
            this.lastFrame = 0;
            this.raf = requestAnimationFrame(this._tick);
        }

        tick(ts) {
            this.raf = null;
            if (this.destroyed) return;

            const dt = this.lastFrame ? Math.min((ts - this.lastFrame) / 1000, 0.05) : 0;
            this.lastFrame = ts;
            const v = this.video;
            const playing = !!v && !v.paused && !v.ended && !v.seeking;

            if (playing) {
                this.playTime += dt * (v.playbackRate || 1);
                const drift = v.currentTime - this.playTime;
                if (Math.abs(drift) > 1.5) {
                    const delta = v.currentTime - this.playTime;
                    this.playTime = v.currentTime;
                    for (const d of this.active) d.born += delta;
                    for (const r of this.rows) if (r) r.born += delta;
                    for (const r of this.fixedTop) if (r) r.born += delta;
                    for (const r of this.fixedBot) if (r) r.born += delta;
                } else if (Math.abs(drift) > 0.02) {
                    this.playTime += drift * 0.05;
                }

                if (cfg.enabled && this.all.length && v.currentTime > 0) this.emitNew();
            }

            this.pruneActive();
            this.draw();

            if (playing || this.showGuide) this.raf = requestAnimationFrame(this._tick);
        }

        countVisible() {
            let count = 0;
            for (const d of this.active) {
                if (d.paused) { count++; continue; }
                if (d.fixed) {
                    if (this.playTime - d.born < d.life) count++;
                } else {
                    const x = d.startX - (this.playTime - d.born) * d.spd;
                    if (x + d.w > 0) count++;
                }
            }
            return count;
        }

        emitNew() {
            if (!this.video) return;
            const ct = this.video.currentTime - cfg.offset;
            while (this.idx < this.all.length && this.all[this.idx].time <= ct + 0.2) {
                const dm = this.all[this.idx++];
                // 固定弹幕（顶部/底部）数量少，不参与滚动弹幕的密度/同屏上限淘汰。
                if (dm.type === 0) {
                    if (Math.random() * 100 >= cfg.density) continue;
                    if (this.countVisible() >= cfg.maxActive) continue;
                }
                this.fire(dm);
            }
        }

        fire(dm) {
            const fs = cfg.fontSize;
            const lh = fs * cfg.lineHeight;
            const maxR = Math.floor((this.H * cfg.area) / 100 / lh);
            if (maxR <= 0) return;

            if (dm.type === 0) {
                const row = this.findRow(dm.w, maxR);
                if (row < 0) return;
                const spd = (120 + Math.random() * 50) * cfg.speed;
                this.rows[row] = { born: this.playTime, spd, w: dm.w };
                this.active.push({
                    text: dm.text,
                    color: dm.color,
                    w: dm.w,
                    startX: this.W + 5,
                    y: row * lh + fs,
                    spd,
                    fixed: false,
                    born: this.playTime,
                    time: dm.time,
                    paused: false,
                    highlight: false
                });
                return;
            }

            const bound = (this.H * cfg.area) / 100;
            const life = 4;
            const maxRows = 4;
            const rows = dm.type === 2 ? this.fixedTop : this.fixedBot;
            let row = -1;
            for (let i = 0; i < maxRows; i++) {
                if (!rows[i] || this.playTime - rows[i].born >= rows[i].life) {
                    row = i;
                    break;
                }
            }
            if (row < 0) return;
            rows[row] = { born: this.playTime, life };

            const y = dm.type === 2
                ? fs * 1.5 + row * lh
                : Math.max(fs * 2, bound - fs * 2 - row * lh);

            this.active.push({
                text: dm.text,
                color: dm.color,
                w: dm.w,
                x: (this.W - dm.w) / 2,
                y,
                fixed: true,
                born: this.playTime,
                life,
                time: dm.time,
                paused: false,
                highlight: false
            });
        }

        findRow(width, maxR) {
            let best = -1;
            let bestClear = -1;
            for (let r = 0; r < maxR; r++) {
                const rd = this.rows[r];
                if (!rd) return r;
                const elapsed = this.playTime - rd.born;
                if (elapsed < 0) continue;
                const rightEdge = this.W + 5 - elapsed * rd.spd + rd.w;
                if (rightEdge < 0) {
                    this.rows[r] = null;
                    return r;
                }
                const clear = this.W - rightEdge;
                if (clear > width + 40 && clear > bestClear) {
                    bestClear = clear;
                    best = r;
                }
            }
            return best;
        }

        pruneActive() {
            this.active = this.active.filter(d => {
                if (d.paused) return true;
                if (d.fixed) return this.playTime - d.born < d.life;
                const x = d.startX - (this.playTime - d.born) * d.spd;
                return x > -(this.W * 2);
            });
        }

        draw() {
            if (!this.ctx) return;
            this.ctx.clearRect(0, 0, this.W, this.H);

            if (cfg.enabled && this.active.length) {
                this.ctx.save();
                this.ctx.globalAlpha = cfg.opacity;
                for (const d of this.active) {
                    let x;
                    if (d.paused) {
                        x = d.pauseX;
                    } else if (d.fixed) {
                        if (this.playTime - d.born > d.life) continue;
                        x = d.x;
                    } else {
                        x = d.startX - (this.playTime - d.born) * d.spd;
                        if (x > this.W + 10) continue;
                    }
                    const tex = this.getTex(d.text, d.color);
                    const dx = x - tex.pad;
                    const dy = d.y - tex.pad;

                    if (d.highlight) {
                        const p = 4;
                        this.ctx.fillStyle = 'rgba(79,140,255,0.28)';
                        this.ctx.beginPath();
                        if (this.ctx.roundRect) {
                            this.ctx.roundRect(dx - p, dy - p, tex.w + p * 2, tex.h + p * 2, 6);
                        } else {
                            this.ctx.rect(dx - p, dy - p, tex.w + p * 2, tex.h + p * 2);
                        }
                        this.ctx.fill();
                    }
                    this.ctx.drawImage(tex.c, dx, dy);
                }
                this.ctx.restore();
            }

            if (this.showGuide) {
                const gy = (this.H * cfg.area) / 100;
                this.ctx.save();
                this.ctx.fillStyle = 'rgba(79,140,255,0.06)';
                this.ctx.fillRect(0, 0, this.W, gy);
                this.ctx.globalAlpha = 0.55;
                this.ctx.strokeStyle = '#4f8cff';
                this.ctx.lineWidth = 1.5;
                this.ctx.setLineDash([8, 5]);
                this.ctx.beginPath();
                this.ctx.moveTo(0, gy);
                this.ctx.lineTo(this.W, gy);
                this.ctx.stroke();
                this.ctx.setLineDash([]);
                this.ctx.fillStyle = '#4f8cff';
                this.ctx.globalAlpha = 0.85;
                this.ctx.font = `12px ${FONT}`;
                this.ctx.textBaseline = 'top';
                this.ctx.fillText(`弹幕区域 ${cfg.area}%`, 10, gy + 6);
                this.ctx.restore();
            }
        }

        getTex(text, color) {
            const dpr = window.devicePixelRatio || 1;
            if (dpr !== this.lastDpr) {
                this.lastDpr = dpr;
                this.texCache.clear();
            }
            const key = `${text}\u0000${color}\u0000${cfg.fontSize}\u0000${cfg.outline}`;
            const cached = this.texCache.get(key);
            if (cached) return cached;

            const fs = cfg.fontSize;
            const sw = cfg.outline ? Math.max(1, fs / 10) : 0;
            const pad = Math.ceil(sw / 2) + 1;

            const tc = document.createElement('canvas');
            const t = tc.getContext('2d');
            t.font = `bold ${fs}px ${FONT}`;
            const tw = t.measureText(text).width;
            const cW = Math.ceil(tw) + pad * 2;
            const cH = Math.ceil(fs * 1.35) + pad * 2;

            tc.width = Math.round(cW * dpr);
            tc.height = Math.round(cH * dpr);
            t.scale(dpr, dpr);
            t.font = `bold ${fs}px ${FONT}`;
            t.textBaseline = 'top';

            if (cfg.outline) {
                t.strokeStyle = 'rgba(0,0,0,0.72)';
                t.lineWidth = sw;
                t.lineJoin = 'round';
                t.strokeText(text, pad, pad);
            }
            t.fillStyle = color;
            t.fillText(text, pad, pad);

            const entry = { c: tc, w: cW, h: cH, pad };
            this.texCache.set(key, entry);
            if (this.texCache.size > 600) {
                this.texCache.delete(this.texCache.keys().next().value);
            }
            return entry;
        }

        setGuide(value) {
            this.showGuide = !!value;
            this.ensureLoop();
        }

        hitTest(cx, cy) {
            const fs = cfg.fontSize;
            for (let i = this.active.length - 1; i >= 0; i--) {
                const d = this.active[i];
                if (d.paused) continue;
                let x;
                if (d.fixed) {
                    if (this.playTime - d.born > d.life) continue;
                    x = d.x;
                } else {
                    x = d.startX - (this.playTime - d.born) * d.spd;
                }
                if (cx >= x - 4 && cx <= x + d.w + 4 &&
                    cy >= d.y - 4 && cy <= d.y + fs * 1.35 + 4) {
                    return d;
                }
            }
            return null;
        }

        pause(d) {
            let x;
            if (d.fixed) x = d.x;
            else x = d.startX - (this.playTime - d.born) * d.spd;
            d.paused = true;
            d.pauseX = x;
            d.pauseAt = this.playTime;
            d.highlight = true;
            return x;
        }

        resume(d) {
            if (!d || !d.paused || this.destroyed) return;
            d.paused = false;
            d.highlight = false;
            d.born += this.playTime - (d.pauseAt || this.playTime);
        }
    }

    /* ══════════════════════════════════════════════════════════════════
     *  播放器 UI
     * ══════════════════════════════════════════════════════════════════ */

    const PLAYER_CSS = `
        :host {
            all: initial;
            display: block;
            font-family: ${FONT};
            color: #fff;
        }
        *, *::before, *::after { box-sizing: border-box; }
        .dm-canvas {
            position: absolute;
            top: 0; left: 0; right: 0; bottom: 0;
            width: 100%; height: 100%;
            z-index: 1;
            pointer-events: none;
        }
        .dm-panel {
            position: absolute;
            bottom: 54px; right: 74px;
            z-index: 40;
            width: 380px;
            max-width: calc(100% - 24px);
            max-height: min(560px, calc(100% - 72px));
            display: none;
            flex-direction: column;
            overflow: hidden;
            background: rgba(18,19,22,.985);
            border: 1px solid rgba(255,255,255,.12);
            border-radius: 14px;
            box-shadow: 0 16px 48px rgba(0,0,0,.55);
            isolation: isolate;
            pointer-events: auto;
            color: #f3f4f6;
            font-size: 13px;
        }
        .dm-panel.open { display: flex; }
        .dm-head {
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 10px;
            padding: 13px 14px 10px;
            border-bottom: 1px solid rgba(255,255,255,.08);
        }
        .dm-head-title { font-size: 15px; font-weight: 700; }
        .dm-current {
            max-width: 270px;
            margin-top: 3px;
            overflow: hidden;
            color: #9aa0aa;
            font-size: 11px;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .dm-head-actions { display: flex; gap: 4px; }
        .dm-icon-btn {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 28px; height: 28px;
            padding: 0;
            border: 0;
            border-radius: 7px;
            background: transparent;
            color: #aab0ba;
            font: 16px/1 ${FONT};
            cursor: pointer;
        }
        .dm-icon-btn:hover { background: rgba(255,255,255,.08); color: #fff; }
        .dm-search {
            display: flex;
            gap: 8px;
            padding: 12px 14px 8px;
        }
        .dm-input {
            flex: 1;
            min-width: 0;
            height: 36px;
            padding: 0 11px;
            border: 1px solid #30343d;
            border-radius: 9px;
            outline: none;
            background: #101115;
            color: #f3f4f6;
            font: 13px ${FONT};
        }
        .dm-input:focus { border-color: #4f8cff; box-shadow: 0 0 0 3px rgba(79,140,255,.16); }
        .dm-btn-primary {
            height: 36px;
            padding: 0 14px;
            border: 0;
            border-radius: 9px;
            background: #4f8cff;
            color: #fff;
            font: 600 13px ${FONT};
            cursor: pointer;
            white-space: nowrap;
        }
        .dm-btn-primary:hover { background: #669dff; }
        .dm-btn-ghost {
            height: 34px;
            padding: 0 12px;
            border: 1px solid #30343d;
            border-radius: 8px;
            background: #22252c;
            color: #d7dae0;
            font: 500 12px ${FONT};
            cursor: pointer;
        }
        .dm-btn-ghost:hover { background: #2b2f38; }
        .dm-quick { padding: 0 14px 8px; }
        .dm-quick .dm-btn-ghost { width: 100%; }
        .dm-list {
            flex: 1;
            min-height: 80px;
            overflow-y: auto;
            overscroll-behavior: contain;
            scrollbar-gutter: stable;
            padding: 2px 10px 12px;
        }
        .dm-msg {
            padding: 20px 12px;
            color: #8b909a;
            font-size: 12px;
            line-height: 1.6;
            text-align: center;
        }
        .dm-msg.error { color: #ff7b7b; }
        .dm-item {
            display: block;
            width: 100%;
            margin-bottom: 7px;
            padding: 10px 12px;
            border: 1px solid #292d35;
            border-radius: 10px;
            background: #202329;
            color: #f3f4f6;
            font-family: ${FONT};
            text-align: left;
            cursor: pointer;
        }
        .dm-item:hover { background: #292d35; border-color: #3a3f4a; }
        .dm-item .t {
            overflow: hidden;
            font-size: 13px;
            font-weight: 600;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .dm-item .m { margin-top: 3px; color: #8b909a; font-size: 11px; }
        .dm-ep {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 10px;
            width: 100%;
            margin-bottom: 6px;
            padding: 9px 11px;
            border: 1px solid #292d35;
            border-radius: 9px;
            background: #202329;
            color: #f3f4f6;
            font-family: ${FONT};
            text-align: left;
            cursor: pointer;
        }
        .dm-ep:hover { background: #292d35; }
        .dm-ep-label { color: #9fb8ff; font-size: 12px; font-weight: 700; }
        .dm-ep-title {
            flex: 1;
            overflow: hidden;
            color: #c4c8d0;
            font-size: 11px;
            text-align: right;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .dm-foot {
            padding: 8px 14px 11px;
            border-top: 1px solid rgba(255,255,255,.08);
            color: #6f747e;
            font-size: 10px;
            line-height: 1.5;
        }
        .dm-status {
            position: absolute;
            left: 16px; bottom: 58px;
            z-index: 35;
            display: flex;
            flex-direction: column;
            gap: 3px;
            max-width: min(540px, 78%);
            padding: 9px 13px;
            border: 1px solid rgba(255,255,255,.1);
            border-radius: 9px;
            background: rgba(0,0,0,.78);
            opacity: 0;
            transform: translateY(4px);
            transition: opacity .25s, transform .25s;
            pointer-events: none;
        }
        .dm-status.show { opacity: 1; transform: none; }
        .dm-status-main { font-size: 13px; font-weight: 600; }
        .dm-status-sub { color: #a1a1aa; font-size: 11px; }
        .dm-status.error .dm-status-main { color: #ff7b7b; }
        .dm-tip {
            position: absolute;
            z-index: 50;
            padding: 4px 9px;
            border-radius: 6px;
            background: rgba(0,0,0,.86);
            color: #fff;
            font-size: 12px;
            font-weight: 700;
            white-space: nowrap;
            opacity: 0;
            transition: opacity .2s;
            pointer-events: none;
        }
        .dm-tip.show { opacity: 1; }
        @media (max-width: 600px) {
            .dm-panel { bottom: 46px; left: 8px; right: 8px; width: auto; max-height: calc(100% - 58px); }
        }
    `;

    let S = null;
    let settingsHost = null;
    let settingsRoot = null;
    let settingsEscHandler = null;
    let globalToastHost = null;
    let globalToastTimer = null;
    let settingsUid = 0;
    let settingsRowTimer = null;
    let settingsObserver = null;
    let danmakuSubmenu = null;

    function getPlayerToastFn() {
        if (!S) return null;
        if (S.playerToastFn && typeof S.playerToastFn.success === 'function') return S.playerToastFn;
        const rootEl = document.querySelector('.trim-mc__video-player--root') || S.container;
        if (!rootEl) return null;
        const key = Object.keys(rootEl).find(k => k.startsWith('__reactFiber$'));
        if (!key) return null;
        let fiber = rootEl[key];
        while (fiber && fiber.return) fiber = fiber.return;
        if (!fiber) return null;

        let found = null;
        const seen = new Set();
        const walk = f => {
            if (!f || found || seen.has(f)) return;
            seen.add(f);
            const props = f.memoizedProps;
            if (props && props.toastFn && typeof props.toastFn.success === 'function') {
                found = props.toastFn;
                return;
            }
            if (props && props.playerToast && typeof props.playerToast.success === 'function') {
                found = props.playerToast;
                return;
            }
            walk(f.child);
            walk(f.sibling);
        };
        walk(fiber);
        if (found) S.playerToastFn = found;
        return found;
    }

    function flash(message, isError = false, sub = '') {
        // 优先复用播放器自己的 toast（semi-toast），不再额外显示脚本左下角提示。
        const toast = getPlayerToastFn();
        if (toast) {
            const text = isError && sub ? `${message} · ${String(sub).slice(0, 80)}` : message;
            try {
                if (isError && typeof toast.error === 'function') toast.error(text);
                else if (/^(正在|匹配中|搜索中|加载中)/.test(message) && typeof toast.info === 'function') toast.info(text);
                else if (typeof toast.success === 'function') toast.success(text);
                else throw new Error('no toast method');
                if (S && S.statusEl) S.statusEl.classList.remove('show');
                return;
            } catch (e) {
                warn('调用播放器提示失败，回退到脚本提示', e);
            }
        }

        if (!S || !S.statusEl) {
            showGlobalToast(message, isError, sub);
            return;
        }
        S.statusMain.textContent = message;
        S.statusSub.textContent = sub || '';
        S.statusEl.classList.toggle('error', !!isError);
        S.statusEl.classList.add('show');
        clearTimeout(S.statusTimer);
        S.statusTimer = setTimeout(() => S?.statusEl.classList.remove('show'), 8000);
    }

    function setCount(count) {
        if (!S) return;
        S.count = Number(count) || 0;
        updateSettingRow();
    }

    function modalParent() {
        const fs = document.fullscreenElement;
        if (!fs) return document.body;
        if (fs.tagName === 'VIDEO') return fs.parentElement || document.body;
        return fs;
    }

    function showGlobalToast(message, isError = false, sub = '') {
        const parent = modalParent();
        if (!globalToastHost || !globalToastHost.isConnected) {
            globalToastHost = h('div');
            globalToastHost.style.cssText =
                'position:fixed;left:50%;bottom:28px;transform:translateX(-50%);' +
                'z-index:2147483647;pointer-events:none;display:block;';
            const root = globalToastHost.attachShadow({ mode: 'open' });
            root.append(styleNode(`
                :host { all: initial; display: block; }
                .toast {
                    max-width: min(560px, 86vw);
                    padding: 10px 14px;
                    border: 1px solid rgba(255,255,255,.12);
                    border-radius: 10px;
                    background: rgba(15,16,20,.94);
                    box-shadow: 0 10px 30px rgba(0,0,0,.45);
                    color: #fff;
                    font: 13px/1.5 ${FONT};
                    opacity: 0;
                    transform: translateY(6px);
                    transition: opacity .2s, transform .2s;
                    backdrop-filter: blur(12px);
                }
                .toast.show { opacity: 1; transform: none; }
                .toast.error .main { color: #ff7b7b; }
                .main { font-weight: 600; }
                .sub { margin-top: 2px; color: #9aa0aa; font-size: 11px; }
            `));
            const toast = h('div', { class: 'toast' },
                h('div', { class: 'main' }),
                h('div', { class: 'sub' })
            );
            root.append(toast);
            parent.append(globalToastHost);
            globalToastHost._toast = toast;
            globalToastHost._main = toast.querySelector('.main');
            globalToastHost._sub = toast.querySelector('.sub');
        }
        const toast = globalToastHost._toast;
        globalToastHost._main.textContent = message;
        globalToastHost._sub.textContent = sub || '';
        toast.classList.toggle('error', !!isError);
        toast.classList.add('show');
        clearTimeout(globalToastTimer);
        globalToastTimer = setTimeout(() => {
            toast.classList.remove('show');
            setTimeout(() => {
                if (globalToastHost && !toast.classList.contains('show')) {
                    globalToastHost.remove();
                    globalToastHost = null;
                }
            }, 250);
        }, 4500);
    }

    function showTip(text, x, y) {
        if (!S || !S.tipEl) return;
        S.tipEl.textContent = text;
        const maxX = Math.max(8, S.engine ? S.engine.W - 90 : 300);
        const maxY = Math.max(8, S.engine ? S.engine.H - 30 : 200);
        S.tipEl.style.left = `${clamp(x, 4, maxX)}px`;
        S.tipEl.style.top = `${clamp(y, 4, maxY)}px`;
        S.tipEl.classList.add('show');
        clearTimeout(S.tipTimer);
        S.tipTimer = setTimeout(() => S?.tipEl.classList.remove('show'), 2600);
    }

    function trapUIKeys(root, onEscape) {
        const stop = e => {
            if (e.key === 'Escape' && onEscape) {
                e.preventDefault();
                e.stopPropagation();
                onEscape();
                return;
            }
            // 输入框/按钮的默认行为保留，只阻止事件冒泡到飞牛播放器的全局快捷键。
            e.stopPropagation();
        };
        for (const type of ['keydown', 'keyup', 'keypress']) {
            root.addEventListener(type, stop, false);
        }
    }

    function findPlayerSettingsList() {
        const pops = document.querySelectorAll('.trim-ui__player--popover');
        for (const pop of pops) {
            const rect = pop.getBoundingClientRect();
            if (!rect.width || !rect.height) continue;
            if (getComputedStyle(pop).visibility === 'hidden') continue;
            const text = pop.textContent || '';
            if (!text.includes('设置') || !/自动连播/.test(text)) continue;
            const lists = pop.querySelectorAll('.flex.flex-col.gap-2');
            for (const list of lists) {
                if (/自动连播/.test(list.textContent || '')) return list;
            }
        }
        return null;
    }

    function svgChevron(rotate) {
        const ns = 'http://www.w3.org/2000/svg';
        const svg = document.createElementNS(ns, 'svg');
        svg.setAttribute('xmlns', ns);
        svg.setAttribute('width', '1em');
        svg.setAttribute('height', '1em');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('fill', 'currentColor');
        svg.setAttribute('class', 'mr-0.5 text-[20px] leading-5 text-white');
        if (rotate) svg.style.transform = 'rotate(180deg)';
        const path = document.createElementNS(ns, 'path');
        path.setAttribute('fill-rule', 'evenodd');
        path.setAttribute('clip-rule', 'evenodd');
        path.setAttribute('d', 'M15.457 11.543a1 1 0 010 1.414l-5.5 5.5a1 1 0 01-1.414-1.414l4.793-4.793-4.793-4.793a1 1 0 011.414-1.414l5.5 5.5z');
        svg.append(path);
        return svg;
    }

    function svgSettings() {
        const ns = 'http://www.w3.org/2000/svg';
        const svg = document.createElementNS(ns, 'svg');
        svg.setAttribute('xmlns', ns);
        svg.setAttribute('width', '1em');
        svg.setAttribute('height', '1em');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('fill', 'currentColor');
        svg.setAttribute('class', 'block text-[20px] leading-5');
        const path = document.createElementNS(ns, 'path');
        path.setAttribute('d', 'M19.14 12.94c.04-.3.06-.61.06-.94s-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.49.49 0 0 0-.59-.22l-2.39.96a7.03 7.03 0 0 0-1.62-.94l-.36-2.54a.48.48 0 0 0-.48-.41h-3.84a.48.48 0 0 0-.48.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96a.48.48 0 0 0-.59.22L2.74 8.87a.48.48 0 0 0 .12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.48-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32a.49.49 0 0 0-.12-.61l-2.01-1.58zM12 15.6A3.6 3.6 0 1 1 12 8.4a3.6 3.6 0 0 1 0 7.2z');
        svg.append(path);
        return svg;
    }

    function menuRow(label, value, opts = {}) {
        const row = document.createElement('div');
        row.className = 'group flex items-center justify-between rounded-[6px] py-1.5 pl-3 pr-2' +
            (opts.onClick ? ' hover:bg-[var(--semi-color-fill-1)] cursor-pointer' : '');
        if (opts.title) row.title = opts.title;

        const left = document.createElement('div');
        left.className = 'flex-1';
        const line = document.createElement('div');
        line.className = 'flex items-center justify-between text-base leading-base ' +
            'text-[var(--semi-color-text-1)] group-hover:text-[var(--semi-color-text-0)]';
        const labelEl = document.createElement('div');
        labelEl.className = 'flex flex-1 cursor-default items-center overflow-hidden ' +
            '!text-[var(--semi-color-text-0)]' +
            (opts.truncate ? ' truncate' : '') +
            (opts.leadingChevron ? ' gap-1' : '');
        if (opts.leadingChevron) {
            labelEl.append(svgChevron(true), document.createTextNode(label));
        } else {
            labelEl.textContent = label;
        }
        line.append(labelEl);

        if (value != null) {
            const valueEl = document.createElement('div');
            valueEl.className = 'text-xs leading-xs';
            valueEl.textContent = value;
            line.append(valueEl);
        }
        left.append(line);
        row.append(left);

        if (opts.chevron) row.append(svgChevron(false));
        if (opts.onClick) row.addEventListener('click', opts.onClick);
        return row;
    }

    function createSemiSwitch(checked, onChange) {
        const sw = document.createElement('div');
        sw.className = 'semi-switch' + (checked ? ' semi-switch-checked' : '');
        sw.tabIndex = 0;
        sw.setAttribute('role', 'switch');
        sw.setAttribute('aria-checked', String(!!checked));

        const knob = document.createElement('div');
        knob.className = 'semi-switch-knob';
        knob.setAttribute('aria-hidden', 'true');
        const input = document.createElement('input');
        input.type = 'checkbox';
        input.className = 'semi-switch-native-control';
        input.tabIndex = -1;
        input.setAttribute('role', 'switch');
        input.setAttribute('aria-checked', String(!!checked));
        input.checked = !!checked;
        sw.append(knob, input);

        const set = value => {
            const on = !!value;
            sw.classList.toggle('semi-switch-checked', on);
            sw.setAttribute('aria-checked', String(on));
            input.checked = on;
            input.setAttribute('aria-checked', String(on));
        };
        sw.addEventListener('click', e => {
            e.preventDefault();
            e.stopPropagation();
            const next = !sw.classList.contains('semi-switch-checked');
            set(next);
            onChange(next);
        });
        sw.addEventListener('keydown', e => {
            e.stopPropagation();
            if (e.key === ' ' || e.key === 'Enter') {
                e.preventDefault();
                sw.click();
            }
        });
        sw._set = set;
        return sw;
    }

    function createSwitchRow(label, checked, onChange) {
        const row = document.createElement('div');
        row.className = 'group flex items-center justify-between rounded-[6px] py-1.5 pl-3 pr-2';
        const left = document.createElement('div');
        left.className = 'flex-1';
        const line = document.createElement('div');
        line.className = 'flex items-center justify-between text-base leading-base ' +
            'text-[var(--semi-color-text-1)] group-hover:text-[var(--semi-color-text-0)]';
        const labelEl = document.createElement('div');
        labelEl.className = 'flex flex-1 cursor-default items-center overflow-hidden ' +
            '!text-[var(--semi-color-text-0)]';
        labelEl.textContent = label;
        const wrap = document.createElement('div');
        const sw = createSemiSwitch(checked, onChange);
        wrap.append(sw);
        line.append(labelEl, wrap);
        left.append(line);
        row.append(left);
        row._switch = sw;
        return row;
    }

    function buildPlayerSettingRow(state) {
        const row = menuRow('弹幕', '', { chevron: true, title: '弹幕' });
        row.classList.add('fn-dm-menu-row');
        row.dataset.fnDmOwner = String(state.uid);
        row.tabIndex = 0;

        const valueEl = row.querySelector('.text-xs');
        const open = () => {
            const pop = row.closest('.trim-ui__player--popover');
            if (pop) openDanmakuSubmenu(pop);
        };
        // 飞牛设置弹层在 document 上监听 pointerdown/click 关闭“外部点击”。
        // 注入的行不在它的 React 树里，必须截停这些事件，否则点一下就被判为外部点击。
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
            row.addEventListener(type, e => e.stopPropagation());
        }
        row.addEventListener('click', open);
        row.addEventListener('keydown', e => {
            e.stopPropagation();
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                open();
            }
        });

        state.settingValueEl = valueEl;
        state.settingRow = row;
        return row;
    }

    function invokePlayerSettingRow() {
        if (!S) return;
        const list = findPlayerSettingsList();
        const rows = document.querySelectorAll('.fn-dm-menu-row');

        if (!list) {
            // 进入飞牛原生二级菜单（画面比例/音频等）或弹层关闭时，移除弹幕行。
            rows.forEach(row => row.remove());
            S.settingRow = null;
            cleanupDanmakuSubmenuIfOrphaned();
            return;
        }

        rows.forEach(row => {
            if (row.parentElement !== list) row.remove();
        });

        let row = list.querySelector('.fn-dm-menu-row');
        if (row && row.dataset.fnDmOwner !== String(S.uid)) {
            row.remove();
            row = null;
        }
        if (!row) {
            row = buildPlayerSettingRow(S);
            list.append(row);
        }
        S.settingRow = row;
        updateSettingRow();
    }

    function updateSettingRow() {
        if (!S) return;
        const row = S.settingRow;
        if (row && row.isConnected && S.settingValueEl) {
            if (S.count > 0) S.settingValueEl.textContent = `${S.count} 条`;
            else S.settingValueEl.textContent = cfg.enabled ? '未加载' : '已关闭';
        } else if (row && !row.isConnected) {
            S.settingRow = null;
        }
        if (danmakuSubmenu && danmakuSubmenu.update) danmakuSubmenu.update();
    }

    function isDanmakuUiNode(node) {
        if (!node || node.nodeType !== 1) return false;
        return !!node.closest('.fn-dm-menu-row, .fn-dm-submenu, .fn-dm-settings, .fn-dm-overlay');
    }

    function ensureFocusGuard() {
        if (window.__fnDmFocusGuard) return;
        window.__fnDmFocusGuard = true;
        const stop = e => {
            if (isDanmakuUiNode(e.target) || isDanmakuUiNode(e.relatedTarget)) {
                e.stopPropagation();
            }
        };
        for (const type of ['focus', 'focusin', 'blur', 'focusout']) {
            window.addEventListener(type, stop, true);
        }

        // 飞牛在 window/document 捕获阶段把注入行当作“外部点击”并关闭设置弹层。
        // 在 document-start 就注册捕获守卫，直接接管弹幕行的指针事件。
        const rowGuard = e => {
            const row = e.target && e.target.closest ? e.target.closest('.fn-dm-menu-row') : null;
            if (!row) return;
            e.stopImmediatePropagation();
            e.preventDefault();
            if (e.type === 'pointerdown') {
                const pop = row.closest('.trim-ui__player--popover');
                if (pop) openDanmakuSubmenu(pop);
            }
        };
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
            window.addEventListener(type, rowGuard, true);
        }

        // 二级菜单打开期间，禁止飞牛因 hover 离开而关闭设置弹层。
        const leaveGuard = e => {
            const st = danmakuSubmenu;
            if (!st || !st.popover) return;
            if (st.popover.contains(e.target) || st.popover.contains(e.relatedTarget)) {
                e.stopPropagation();
            }
        };
        for (const type of ['mouseout', 'mouseleave', 'pointerout', 'pointerleave']) {
            window.addEventListener(type, leaveGuard, true);
        }
    }

    function ensureSettingsObserver() {
        if (settingsObserver || typeof MutationObserver !== 'function') return;
        ensureFocusGuard();
        settingsObserver = new MutationObserver(() => {
            clearTimeout(settingsRowTimer);
            settingsRowTimer = setTimeout(invokePlayerSettingRow, 80);
        });
        settingsObserver.observe(document.body, { childList: true, subtree: true });
        document.addEventListener('click', () => {
            clearTimeout(settingsRowTimer);
            settingsRowTimer = setTimeout(invokePlayerSettingRow, 120);
        }, true);
    }

    function closeDanmakuSubmenu() {
        const st = danmakuSubmenu;
        if (!st) return;
        danmakuSubmenu = null;
        try { st.cancel?.(); } catch { /* ignore */ }
        try { st.host?.remove(); } catch { /* ignore */ }
        if (st.content && st.content.isConnected) {
            st.content.style.position = st.contentPosition || '';
            st.content.style.height = st.contentHeight || '';
            st.content.style.minHeight = st.contentMinHeight || '';
        }
        if (st.original && st.original.isConnected) {
            st.original.style.position = st.originalPosition || '';
            st.original.style.height = st.originalHeight || '';
            st.original.style.minHeight = st.originalMinHeight || '';
            st.original.style.visibility = st.originalVisibility || '';
            st.original.style.pointerEvents = st.originalPointerEvents || '';
        }
        if (st.hiddenChildren) {
            for (const item of st.hiddenChildren) {
                if (!item.el) continue;
                item.el.style.visibility = item.visibility || '';
                item.el.style.pointerEvents = item.pointerEvents || '';
            }
        }
    }

    function cleanupDanmakuSubmenuIfOrphaned() {
        if (!danmakuSubmenu) return;
        if (!danmakuSubmenu.host?.isConnected || !danmakuSubmenu.popover?.isConnected) {
            closeDanmakuSubmenu();
        }
    }

    function openDanmakuSubmenu(popover) {
        if (!S) return;
        closeDanmakuSubmenu();

        const content = popover.querySelector('.semi-popover-content');
        if (!content) return;
        const original = content.querySelector('[data-player-popper-content]') || content.firstElementChild;
        if (!original) return;

        const st = {
            popover,
            content,
            original,
            contentPosition: content.style.position,
            contentHeight: content.style.height,
            contentMinHeight: content.style.minHeight,
            originalPosition: original.style.position,
            originalHeight: original.style.height,
            originalMinHeight: original.style.minHeight,
            originalVisibility: original.style.visibility,
            originalPointerEvents: original.style.pointerEvents,
            hiddenChildren: [],
            host: null,
            update: null,
            cancel: null
        };
        danmakuSubmenu = st;

        content.style.position = 'relative';
        content.style.height = '420px';
        content.style.minHeight = '420px';
        // 保持 original 容器本身可见并继续被飞牛的 hover 逻辑追踪，
        // 只隐藏里面的旧设置内容，把二级界面挂到 original 内部。
        original.style.position = 'relative';
        original.style.height = '420px';
        original.style.minHeight = '420px';
        for (const child of [...original.children]) {
            st.hiddenChildren.push({
                el: child,
                visibility: child.style.visibility,
                pointerEvents: child.style.pointerEvents
            });
            child.style.visibility = 'hidden';
            child.style.pointerEvents = 'none';
        }

        const host = document.createElement('div');
        host.className = 'fn-dm-submenu';
        host.style.cssText =
            'position:absolute;inset:0;z-index:5;display:flex;flex-direction:column;' +
            'overflow:hidden;color:#fff;font-size:14px;line-height:20px;';
        st.host = host;
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
            host.addEventListener(type, e => e.stopPropagation());
        }
        original.append(host);

        const header = document.createElement('div');
        header.className = 'border-0 border-b border-solid border-[var(--semi-color-border-modal)] ' +
            'pb-3.5 pl-1.5 pr-2 pt-1.5 !cursor-default';
        const headerLine = document.createElement('div');
        headerLine.className = 'flex items-center gap-1';
        const back = document.createElement('button');
        back.type = 'button';
        back.title = '返回设置';
        back.setAttribute('aria-label', '返回设置');
        back.style.cssText =
            'display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;' +
            'padding:0;border:0;background:transparent;color:#fff;cursor:pointer;';
        back.append(svgChevron(true));
        back.addEventListener('click', e => {
            e.stopPropagation();
            closeDanmakuSubmenu();
        });
        const title = document.createElement('div');
        title.textContent = '弹幕';
        const countEl = document.createElement('div');
        countEl.className = 'ml-auto text-xs leading-xs';
        const settingsBtn = document.createElement('button');
        settingsBtn.type = 'button';
        settingsBtn.title = '弹幕设置';
        settingsBtn.setAttribute('aria-label', '弹幕设置');
        settingsBtn.className = 'ml-2 inline-flex items-center justify-center ' +
            'text-[var(--semi-color-text-1)] hover:text-[var(--semi-color-text-0)] cursor-pointer';
        settingsBtn.style.cssText =
            'width:20px;height:20px;border:0;background:transparent;padding:0;';
        settingsBtn.append(svgSettings());
        settingsBtn.addEventListener('click', e => {
            e.stopPropagation();
            openSettings();
        });
        headerLine.append(back, title, countEl, settingsBtn);
        header.append(headerLine);
        host.append(header);

        const body = document.createElement('div');
        body.style.cssText =
            'flex:1;overflow-y:auto;overscroll-behavior:contain;padding:8px;' +
            'display:flex;flex-direction:column;gap:8px;';
        host.append(body);

        const switchRow = createSwitchRow('显示弹幕', cfg.enabled, value => {
            cfg.enabled = value;
            saveSoon();
            if (S && S.engine) S.engine.ensureLoop();
            updateSettingRow();
        });
        body.append(switchRow);

        const searchRow = document.createElement('div');
        searchRow.style.cssText = 'display:flex;align-items:center;gap:8px;';
        const searchInput = document.createElement('input');
        searchInput.type = 'search';
        searchInput.placeholder = '搜索番剧 / 电影名称';
        searchInput.value = S.info ? S.info.title : '';
        searchInput.style.cssText =
            'flex:1;min-width:0;height:32px;padding:0 10px;border:1px solid ' +
            'var(--semi-color-border,rgba(255,255,255,.18));border-radius:6px;' +
            'background:var(--semi-color-fill-0,rgba(255,255,255,.08));' +
            'color:var(--semi-color-text-0,#fff);font:inherit;font-size:14px;outline:none;' +
            'box-sizing:border-box;';
        const searchButton = document.createElement('button');
        searchButton.type = 'button';
        searchButton.textContent = '搜索';
        searchButton.style.cssText =
            'flex:none;height:32px;padding:0 12px;border:0;border-radius:6px;' +
            'background:var(--semi-color-primary,#0066ff);color:#fff;font:inherit;' +
            'font-size:14px;cursor:pointer;';
        searchRow.append(searchInput, searchButton);
        body.append(searchRow);

        const quickRow = menuRow('自动匹配当前视频', null, {
            onClick: () => {
                closeDanmakuSubmenu();
                refreshCurrent(true);
            }
        });
        body.append(quickRow);

        const results = document.createElement('div');
        results.style.cssText = 'display:flex;flex-direction:column;gap:8px;';
        body.append(results);

        const status = document.createElement('div');
        status.className = 'text-xs leading-xs px-1';
        status.style.cssText = 'color:var(--semi-color-text-1,#a1a1aa);min-height:16px;';
        body.append(status);

        let seq = 0;
        let cachedAnimes = [];
        st.cancel = () => { seq++; };

        const setStatus = (text, isError = false) => {
            status.textContent = text;
            status.style.color = isError ? '#ff7b7b' : 'var(--semi-color-text-1,#a1a1aa)';
        };

        const renderAnimes = animes => {
            results.replaceChildren();
            if (!Array.isArray(animes) || !animes.length) {
                setStatus('没有找到结果，试试更短的名称');
                return;
            }
            for (const anime of animes.slice(0, 30)) {
                const name = anime.animeTitle || anime.title || anime.name || '未命名';
                const meta = [
                    anime.typeDescription || anime.type,
                    anime.year,
                    anime.episodeCount ? `${anime.episodeCount} 集` : ''
                ].filter(Boolean).join(' · ');
                results.append(menuRow(name, meta, {
                    truncate: true,
                    onClick: () => loadEpisodes(anime)
                }));
            }
        };

        const renderEpisodes = (anime, episodes) => {
            results.replaceChildren();
            results.append(menuRow('返回搜索结果', null, {
                leadingChevron: true,
                onClick: () => {
                    if (cachedAnimes.length) renderAnimes(cachedAnimes);
                    else doSearch();
                }
            }));
            for (const ep of episodes) {
                const seasonNum = Number(ep.seasonNumber ?? ep.season);
                const season = Number.isFinite(seasonNum) && seasonNum > 0 ? seasonNum : null;
                const epNum = Number(ep.episodeNumber ?? ep.episode ?? ep.number);
                const label = `${season ? `S${pad2(season)} ` : ''}E${pad2(epNum)}` +
                    (ep.episodeTitle || ep.title ? ` · ${ep.episodeTitle || ep.title}` : '');
                results.append(menuRow(label, null, {
                    truncate: true,
                    onClick: () => loadEpisode(ep, `${anime.animeTitle || anime.title || ''} ${label}`)
                }));
            }
        };

        async function doSearch() {
            const keyword = searchInput.value.trim();
            if (!keyword) {
                setStatus('请输入要搜索的名称', true);
                return;
            }
            const my = ++seq;
            setStatus('搜索中…');
            try {
                const r = await api.search(keyword);
                if (my !== seq || danmakuSubmenu !== st) return;
                cachedAnimes = r?.animes || r?.data?.animes || (Array.isArray(r) ? r : []);
                renderAnimes(cachedAnimes);
                setStatus(`找到 ${cachedAnimes.length} 个结果`);
            } catch (e) {
                if (my !== seq) return;
                setStatus(`搜索失败：${e.message}`, true);
                warn('搜索弹幕失败', e);
            }
        }

        async function loadEpisodes(anime) {
            const my = ++seq;
            setStatus('加载剧集…');
            try {
                const bg = await api.bangumi(anime.animeId || anime.id);
                if (my !== seq || danmakuSubmenu !== st) return;
                const detail = bg?.bangumi || bg?.data?.bangumi || bg?.data || bg || {};
                const episodes = detail.episodes || bg?.episodes || bg?.data?.episodes || [];
                if (!Array.isArray(episodes) || !episodes.length) {
                    setStatus('该条目暂无剧集数据', true);
                    return;
                }
                episodes.sort((a, b) => (Number(a.episodeNumber) || 0) - (Number(b.episodeNumber) || 0));
                renderEpisodes(anime, episodes);
                setStatus(`共 ${episodes.length} 集`);
            } catch (e) {
                if (my !== seq) return;
                setStatus(`加载剧集失败：${e.message}`, true);
                warn('加载剧集失败', e);
            }
        }

        async function loadEpisode(ep, desc) {
            const cid = ep.episodeId ?? ep.id;
            if (cid == null) {
                setStatus('该剧集没有可用的弹幕 ID', true);
                return;
            }
            const my = ++seq;
            setStatus('加载弹幕…');
            try {
                const result = await api.comment(cid);
                if (my !== seq || danmakuSubmenu !== st || !S) return;
                if (!result.comments.length) {
                    setStatus('该集暂无弹幕', true);
                    return;
                }
                S.engine.load(result.comments, result.videoDuration);
                updateSettingRow();
                flash(`已加载 ${result.comments.length} 条弹幕`, false, desc);
                setStatus(`已加载 ${result.comments.length} 条弹幕`, false);
                setTimeout(() => {
                    if (danmakuSubmenu === st) closeDanmakuSubmenu();
                }, 700);
            } catch (e) {
                if (my !== seq) return;
                setStatus(`加载失败：${e.message}`, true);
                warn('加载弹幕失败', e);
            }
        }

        st.update = () => {
            countEl.textContent = S && S.count > 0
                ? `${S.count} 条`
                : cfg.enabled ? '未加载' : '已关闭';
            const sw = switchRow._switch;
            if (sw && sw._set) sw._set(cfg.enabled);
        };
        st.update();

        searchButton.addEventListener('click', doSearch);
        searchInput.addEventListener('keydown', e => {
            if (e.key === 'Enter') doSearch();
        });
        searchInput.addEventListener('input', () => setStatus(''));

        const blockKeys = e => {
            e.stopPropagation();
            if (e.key === 'Escape') {
                e.preventDefault();
                closeDanmakuSubmenu();
            }
        };
        for (const type of ['keydown', 'keyup', 'keypress']) {
            host.addEventListener(type, blockKeys, false);
        }
    }

    function findPlayer() {
        const videos = Array.from(document.querySelectorAll('video')).filter(v => {
            const r = v.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
        });
        videos.sort((a, b) => {
            const ra = a.getBoundingClientRect();
            const rb = b.getBoundingClientRect();
            return rb.width * rb.height - ra.width * ra.height;
        });
        for (const v of videos) {
            const p = v.closest(PSEL);
            if (p) return p;
            if (v.parentElement) return v.parentElement;
        }
        return null;
    }

    function buildPanel(state) {
        const panel = h('div', { class: 'dm-panel' });
        const current = h('div', { class: 'dm-current', text: '尚未读取到视频信息' });
        const list = h('div', { class: 'dm-list' });
        let reqSeq = 0;

        const input = h('input', {
            class: 'dm-input',
            type: 'search',
            placeholder: '搜索番剧 / 电影名称',
            autocomplete: 'off',
            spellcheck: 'false'
        });
        const searchBtn = h('button', { class: 'dm-btn-primary', type: 'button', text: '搜索' });
        const quickBtn = h('button', { class: 'dm-btn-ghost', type: 'button', text: '自动匹配当前视频' });
        const gearBtn = h('button', { class: 'dm-icon-btn', type: 'button', title: '弹幕设置', 'aria-label': '弹幕设置', text: '⚙' });
        const closeBtn = h('button', { class: 'dm-icon-btn', type: 'button', title: '关闭', 'aria-label': '关闭', text: '×' });

        panel.append(
            h('div', { class: 'dm-head' },
                h('div', null,
                    h('div', { class: 'dm-head-title', text: '弹幕' }),
                    current
                ),
                h('div', { class: 'dm-head-actions' }, gearBtn, closeBtn)
            ),
            h('div', { class: 'dm-search' }, input, searchBtn),
            h('div', { class: 'dm-quick' }, quickBtn),
            list,
            h('div', { class: 'dm-foot', text: '自动匹配失败时，可搜索番剧并手动选择集数。' })
        );

        function setInfo(info) {
            if (!info) {
                current.textContent = '尚未读取到视频信息';
                return;
            }
            current.textContent = info.isSeries
                ? `当前：${info.title} S${pad2(info.season)}E${pad2(info.episode)}`
                : `当前：${info.title}`;
            if (!input.value.trim()) input.value = info.title;
        }

        function message(text, isError = false) {
            list.replaceChildren(h('div', { class: `dm-msg${isError ? ' error' : ''}`, text }));
        }

        function open() {
            panel.classList.add('open');
        }

        function close() {
            panel.classList.remove('open');
        }

        function toggle() {
            if (panel.classList.contains('open')) close();
            else open();
        }

        async function doSearch() {
            const keyword = input.value.trim();
            if (!keyword) {
                message('请输入要搜索的名称');
                return;
            }
            const seq = ++reqSeq;
            message('搜索中…');
            try {
                const r = await api.search(keyword);
                if (seq !== reqSeq) return;
                const animes = r?.animes || r?.data?.animes || (Array.isArray(r) ? r : []);
                if (!Array.isArray(animes) || !animes.length) {
                    message('没有找到结果，试试更短的名称');
                    return;
                }
                list.replaceChildren();
                for (const anime of animes.slice(0, 30)) {
                    const title = anime.animeTitle || anime.title || anime.name || '未命名';
                    const meta = [
                        anime.typeDescription || anime.type,
                        anime.year,
                        anime.episodeCount ? `${anime.episodeCount} 集` : ''
                    ].filter(Boolean).join(' · ');
                    const item = h('button', { class: 'dm-item', type: 'button' },
                        h('div', { class: 't', text: title }),
                        meta ? h('div', { class: 'm', text: meta }) : null
                    );
                    item.addEventListener('click', () => showEpisodes(anime, seq));
                    list.append(item);
                }
            } catch (e) {
                if (seq !== reqSeq) return;
                message(`搜索失败：${e.message}`, true);
                warn('搜索弹幕失败', e);
            }
        }

        async function showEpisodes(anime, parentSeq) {
            const seq = ++reqSeq;
            const title = anime.animeTitle || anime.title || anime.name || '未命名';
            message('正在加载剧集…');
            try {
                const bg = await api.bangumi(anime.animeId || anime.id);
                if (seq !== reqSeq) return;
                const detail = bg?.bangumi || bg?.data?.bangumi || bg?.data || bg || {};
                const episodes = detail.episodes || bg?.episodes || bg?.data?.episodes || [];
                if (!Array.isArray(episodes) || !episodes.length) {
                    message('该条目暂无剧集数据');
                    return;
                }
                episodes.sort((a, b) => (Number(a.episodeNumber) || 0) - (Number(b.episodeNumber) || 0));
                list.replaceChildren();
                const back = h('button', { class: 'dm-btn-ghost', type: 'button', text: '← 返回搜索结果' });
                back.style.width = '100%';
                back.style.marginBottom = '8px';
                back.addEventListener('click', () => {
                    doSearch();
                });
                list.append(back);
                for (const ep of episodes) {
                    const seasonNum = Number(ep.seasonNumber ?? ep.season);
                    const season = Number.isFinite(seasonNum) && seasonNum > 0 ? seasonNum : null;
                    const epNum = Number(ep.episodeNumber ?? ep.episode ?? ep.number);
                    const label = `${season ? `S${pad2(season)} ` : ''}E${pad2(epNum)}`;
                    const epTitle = ep.episodeTitle || ep.title || '';
                    const btn = h('button', { class: 'dm-ep', type: 'button' },
                        h('span', { class: 'dm-ep-label', text: label }),
                        h('span', { class: 'dm-ep-title', text: epTitle || title })
                    );
                    btn.addEventListener('click', () => loadEpisode(ep, `${title} ${label}`));
                    list.append(btn);
                }
            } catch (e) {
                if (seq !== reqSeq) return;
                message(`加载剧集失败：${e.message}`, true);
                warn('加载剧集失败', e);
            }
        }

        async function loadEpisode(ep, desc) {
            const cid = ep.episodeId ?? ep.id;
            if (cid == null) {
                flash('该剧集没有可用的弹幕 ID', true, desc);
                return;
            }
            const seq = ++reqSeq;
            message('正在加载弹幕…');
            try {
                const result = await api.comment(cid);
                if (seq !== reqSeq) return;
                if (!result.comments.length) {
                    message('该集暂无弹幕');
                    flash('该集暂无弹幕', true, desc);
                    return;
                }
                state.engine.load(result.comments, result.videoDuration);
                flash(`已加载 ${result.comments.length} 条弹幕`, false, desc);
                close();
            } catch (e) {
                if (seq !== reqSeq) return;
                message(`加载失败：${e.message}`, true);
                flash('加载弹幕失败', true, e.message);
                warn('加载弹幕失败', e);
            }
        }

        async function quickMatch() {
            if (!state.info) {
                flash('还没有读取到当前视频，请稍后再试', true);
                return;
            }
            quickBtn.disabled = true;
            quickBtn.textContent = '匹配中…';
            try {
                await autoMatch(state.info, ++state.matchSeq);
            } catch (e) {
                flash('匹配失败', true, e.message);
                warn('手动自动匹配失败', e);
            } finally {
                quickBtn.disabled = false;
                quickBtn.textContent = '自动匹配当前视频';
            }
        }

        searchBtn.addEventListener('click', doSearch);
        input.addEventListener('keydown', e => {
            if (e.key === 'Enter') doSearch();
        });
        quickBtn.addEventListener('click', quickMatch);
        gearBtn.addEventListener('click', () => {
            close();
            openSettings();
        });
        closeBtn.addEventListener('click', close);

        trapUIKeys(panel, close);
        return { root: panel, open, close, toggle, setInfo, message, input };
    }

    function setupPlayerInteractions(state) {
        const { container, engine } = state;
        const signal = state.abort.signal;

        container.addEventListener('click', e => {
            if (!S || !S.engine || !cfg.enabled) return;
            const path = e.composedPath ? e.composedPath() : [];
            if (path.some(n => n instanceof Element &&
                (n.classList?.contains('fn-dm-settings') ||
                    n.classList?.contains('fn-dm-menu-row') ||
                    n.closest?.('.dm-panel') ||
                    n.closest?.('.fn-dialog') ||
                    n.closest?.('.fn-backdrop') ||
                    n.closest?.('.trim-ui__player--popover')))) return;

            const rect = container.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const y = e.clientY - rect.top;
            const dm = engine.hitTest(x, y);
            if (!dm) return;

            e.preventDefault();
            e.stopPropagation();
            const px = engine.pause(dm);
            showTip(formatTime(dm.time), px, Math.max(0, dm.y - 30));
            setTimeout(() => {
                if (S && S.engine === engine) engine.resume(dm);
            }, 3000);
        }, { capture: true, signal });

        state.video.addEventListener('loadedmetadata', () => {
            if (!S) return;
            const src = state.video.currentSrc || state.video.src;
            if (src && src !== state.lastSrc) {
                state.lastSrc = src;
                refreshCurrent(false);
            }
        }, { signal });
    }

    async function injectPlayer(container, video) {
        if (S) return;
        log('注入播放器', container, video);

        const originalPosition = container.style.position;
        let positionChanged = false;
        if (getComputedStyle(container).position === 'static') {
            container.style.position = 'relative';
            positionChanged = true;
        }

        const host = h('div', { class: 'fn-dm-overlay' });
        host.style.cssText =
            'position:absolute;top:0;left:0;right:0;bottom:0;display:block;' +
            'z-index:2147483000;pointer-events:none;';
        container.append(host);

        const root = host.attachShadow({ mode: 'open' });
        root.append(styleNode(PLAYER_CSS));

        const canvas = h('canvas', { class: 'dm-canvas' });
        const statusEl = h('div', { class: 'dm-status' },
            h('div', { class: 'dm-status-main' }),
            h('div', { class: 'dm-status-sub' })
        );
        const tipEl = h('div', { class: 'dm-tip' });

        const abort = new AbortController();
        const state = {
            container,
            video,
            host,
            root,
            canvas,
            statusEl,
            statusMain: statusEl.querySelector('.dm-status-main'),
            statusSub: statusEl.querySelector('.dm-status-sub'),
            statusTimer: null,
            tipEl,
            tipTimer: null,
            uid: ++settingsUid,
            count: 0,
            settingRow: null,
            settingValueEl: null,
            playerToastFn: null,
            abort,
            originalPosition,
            positionChanged,
            info: null,
            lastSrc: video.currentSrc || video.src || '',
            matchSeq: 0,
            engine: null,
            panel: null
        };
        S = state;

        const panel = buildPanel(state);
        state.panel = panel;
        root.append(canvas, statusEl, tipEl, panel.root);
        trapUIKeys(root);

        const engine = new DanmakuEngine({
            host,
            canvas,
            video,
            signal: abort.signal,
            onCount: setCount,
            onHit: () => {}
        });
        state.engine = engine;

        setupPlayerInteractions(state);
        ensureSettingsObserver();
        initInfo(state);
        setTimeout(invokePlayerSettingRow, 50);
    }

    async function initInfo(state) {
        try {
            const info = await getInfo();
            if (!S || S !== state) return;
            state.info = info;
            state.panel.setInfo(info);
            updateSettingRow();
            if (cfg.autoMatch) {
                autoMatch(info, ++state.matchSeq);
            } else {
                flash('已就绪，在播放器设置中选择「弹幕」', false, info?.title || '');
            }
        } catch (e) {
            if (!S || S !== state) return;
            if (e instanceof ApiError && (e.status === 401 || e.status === 403)) {
                flash('飞牛影视登录状态失效，请刷新页面', true, e.message);
            } else {
                flash('无法读取当前视频信息', true, e.message);
            }
            warn('读取视频信息失败', e);
        }
    }

    function teardownPlayer(closeSettingsToo = true) {
        if (!S) {
            closeDanmakuSubmenu();
            if (closeSettingsToo) closeSettings();
            return;
        }
        log('清理播放器');
        closeDanmakuSubmenu();
        const state = S;
        S = null;
        state.matchSeq++;
        clearTimeout(state.statusTimer);
        clearTimeout(state.tipTimer);
        try { state.abort.abort(); } catch { /* ignore */ }
        try { state.engine?.destroy(); } catch { /* ignore */ }
        try { state.settingRow?.remove(); } catch { /* ignore */ }
        try { state.host.remove(); } catch { /* ignore */ }
        if (state.positionChanged && state.container.isConnected) {
            try { state.container.style.position = state.originalPosition; } catch { /* ignore */ }
        }
        if (closeSettingsToo) closeSettings();
    }

    /* ══════════════════════════════════════════════════════════════════
     *  自动匹配
     * ══════════════════════════════════════════════════════════════════ */

    async function autoMatch(info, seq) {
        if (!S || seq !== S.matchSeq) return;
        if (!info) return;
        const names = buildMatchNames(info);
        if (!names.length) {
            flash('无法生成匹配关键词', true);
            return;
        }

        flash('正在匹配弹幕…', false, names[0]);
        let lastError = null;

        for (const name of names) {
            if (!S || seq !== S.matchSeq) return;
            let match;
            try {
                match = await api.match(name);
            } catch (e) {
                if (seq !== S.matchSeq) return;
                lastError = e;
                if (e.status === 401 || e.status === 403) {
                    flash('弹幕 API 鉴权失败，请检查 Token', true, name);
                    return;
                }
                if (e.status) {
                    warn('匹配请求失败，尝试下一个关键词', name, e);
                    continue;
                }
                flash('无法连接弹幕 API，请检查设置中的地址', true, e.message);
                return;
            }

            if (seq !== S.matchSeq) return;
            const matches = Array.isArray(match)
                ? match
                : (match?.matches || match?.data?.matches || []);
            const found = (Array.isArray(matches) ? matches : []).find(x => x && x.episodeId != null) ||
                (Array.isArray(matches) ? matches[0] : null);
            if (!found || found.episodeId == null) continue;

            let result;
            try {
                result = await api.comment(found.episodeId);
            } catch (e) {
                if (seq !== S.matchSeq) return;
                lastError = e;
                warn('获取弹幕失败', e);
                continue;
            }

            if (seq !== S.matchSeq || !S) return;
            if (result.comments.length) {
                S.engine.load(result.comments, result.videoDuration);
                const desc = [found.animeTitle, found.episodeTitle].filter(Boolean).join(' · ') || name;
                flash(`已加载 ${result.comments.length} 条弹幕`, false, desc);
                return;
            }
        }

        if (seq !== S.matchSeq) return;
        const message = lastError?.status === 404
            ? '未找到匹配的弹幕'
            : '未匹配到弹幕，可点击「弹幕」手动搜索';
        flash(message, true, lastError?.message || names[0]);
    }

    async function refreshCurrent(manual = false) {
        if (!S) {
            if (manual) flash('当前页面没有播放器');
            return;
        }
        const state = S;
        const seq = ++state.matchSeq;
        let info;
        try {
            info = await getInfo();
        } catch (e) {
            if (S !== state || seq !== state.matchSeq) return;
            flash('读取视频信息失败', true, e.message);
            return;
        }
        if (S !== state || seq !== state.matchSeq) return;
        if (!info) {
            if (manual) flash('未识别到当前视频', true);
            return;
        }
        state.info = info;
        state.panel.setInfo(info);
        if (!cfg.autoMatch && !manual) return;
        await autoMatch(info, seq);
    }

    /* ══════════════════════════════════════════════════════════════════
     *  设置窗口
     * ══════════════════════════════════════════════════════════════════ */

    const SETTINGS_CSS = `
        :host {
            all: initial;
            display: block;
            font-family: ${FONT};
            color: #e8eaed;
        }
        *, *::before, *::after { box-sizing: border-box; }
        .fn-backdrop {
            position: absolute;
            top: 0; left: 0; right: 0; bottom: 0;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
            background: rgba(3,4,7,.78);
            isolation: isolate;
            pointer-events: auto;
        }
        .fn-dialog {
            width: min(620px, 100%);
            max-height: min(86vh, 780px);
            display: flex;
            flex-direction: column;
            overflow: hidden;
            border: 1px solid #2a2d35;
            border-radius: 18px;
            background: #141519;
            box-shadow: 0 30px 90px rgba(0,0,0,.65);
            isolation: isolate;
            outline: none;
        }
        .fn-head {
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 12px;
            padding: 18px 20px 14px;
            border-bottom: 1px solid #24272f;
            background: linear-gradient(180deg, rgba(79,140,255,.08), transparent);
        }
        .fn-title-row { display: flex; align-items: center; gap: 10px; }
        .fn-logo {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            width: 34px; height: 34px;
            border-radius: 10px;
            background: linear-gradient(135deg, #4f8cff, #7c5cff);
            color: #fff;
            font-size: 16px;
            font-weight: 800;
            box-shadow: 0 4px 14px rgba(79,140,255,.35);
        }
        .fn-title { font-size: 17px; font-weight: 700; letter-spacing: .2px; }
        .fn-subtitle { margin-top: 3px; color: #8b909a; font-size: 11px; }
        .fn-close {
            width: 30px; height: 30px;
            padding: 0;
            border: 1px solid #30343d;
            border-radius: 8px;
            background: #1c1f25;
            color: #aab0ba;
            font: 18px/1 ${FONT};
            cursor: pointer;
        }
        .fn-close:hover { background: #292d35; color: #fff; }
        .fn-body {
            overflow-y: auto;
            overscroll-behavior: contain;
            scrollbar-gutter: stable;
            padding: 16px 20px 6px;
        }
        .fn-body::-webkit-scrollbar { width: 8px; }
        .fn-body::-webkit-scrollbar-thumb { background: #30343d; border-radius: 8px; }
        .fn-section {
            margin-bottom: 16px;
            overflow: hidden;
            border: 1px solid #24272f;
            border-radius: 14px;
            background: #191b20;
        }
        .fn-section-head { padding: 12px 15px 0; }
        .fn-section-title { color: #f3f4f6; font-size: 13px; font-weight: 700; }
        .fn-section-desc { margin-top: 3px; color: #7f848e; font-size: 11px; line-height: 1.5; }
        .fn-section-body { padding: 12px 15px 15px; }
        .fn-field { margin-bottom: 13px; }
        .fn-field:last-child { margin-bottom: 0; }
        .fn-label { display: block; margin-bottom: 6px; color: #c4c8d0; font-size: 12px; font-weight: 600; }
        .fn-input {
            width: 100%;
            height: 38px;
            padding: 0 11px;
            border: 1px solid #30343d;
            border-radius: 9px;
            outline: none;
            background: #101115;
            color: #f3f4f6;
            font: 13px ${FONT};
        }
        .fn-input:focus { border-color: #4f8cff; box-shadow: 0 0 0 3px rgba(79,140,255,.16); }
        .fn-hint { margin-top: 5px; color: #7f848e; font-size: 11px; line-height: 1.55; }
        .fn-row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 9px; }
        .fn-btn {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            height: 34px;
            padding: 0 13px;
            border: 1px solid #30343d;
            border-radius: 8px;
            background: #22252c;
            color: #d7dae0;
            font: 500 12px ${FONT};
            cursor: pointer;
            white-space: nowrap;
        }
        .fn-btn:hover { background: #2b2f38; }
        .fn-btn:disabled { opacity: .5; cursor: default; }
        .fn-btn.primary { border-color: #4f8cff; background: #4f8cff; color: #fff; font-weight: 600; }
        .fn-btn.primary:hover { background: #669dff; }
        .fn-btn.danger { border-color: #4a2a2e; background: #2a1a1d; color: #ff9a9a; }
        .fn-btn.danger:hover { background: #3a2226; }
        .fn-status { min-height: 18px; margin-top: 8px; color: #9aa0aa; font-size: 12px; line-height: 1.5; }
        .fn-status.ok { color: #63d68b; }
        .fn-status.err { color: #ff7b7b; }
        .fn-toggle-row {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 14px;
            padding: 8px 0;
        }
        .fn-toggle-row + .fn-toggle-row { border-top: 1px solid #20232a; }
        .fn-toggle-copy { min-width: 0; }
        .fn-toggle-copy .fn-label { margin: 0; }
        .fn-toggle {
            position: relative;
            flex: none;
            width: 44px; height: 24px;
            padding: 0;
            border: 1px solid #3a3e48;
            border-radius: 999px;
            background: #2a2d35;
            cursor: pointer;
            transition: background .2s, border-color .2s;
        }
        .fn-toggle::after {
            content: "";
            position: absolute;
            top: 3px; left: 3px;
            width: 16px; height: 16px;
            border-radius: 50%;
            background: #fff;
            transition: left .2s;
        }
        .fn-toggle.on { border-color: #4f8cff; background: #4f8cff; }
        .fn-toggle.on::after { left: 23px; }
        .fn-range-row {
            display: grid;
            grid-template-columns: 76px 1fr 58px;
            gap: 10px;
            align-items: center;
            margin: 12px 0;
        }
        .fn-range-row label { color: #c4c8d0; font-size: 12px; }
        .fn-range-row input[type="range"] { width: 100%; height: 6px; accent-color: #4f8cff; }
        .fn-range-row output {
            color: #f3f4f6;
            font-size: 12px;
            font-variant-numeric: tabular-nums;
            text-align: right;
        }
        .fn-about { display: flex; justify-content: space-between; gap: 10px; color: #6f747e; font-size: 11px; }
        .fn-about a { color: #8fb2ff; text-decoration: none; }
        .fn-about a:hover { text-decoration: underline; }
        .fn-foot {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
            padding: 12px 20px;
            border-top: 1px solid #24272f;
            background: #101115;
        }
        .fn-foot-note { color: #6f747e; font-size: 11px; line-height: 1.4; }
        .fn-foot-actions { display: flex; gap: 8px; }
        @media (max-width: 560px) {
            .fn-backdrop { padding: 10px; }
            .fn-dialog { max-height: 92vh; }
            .fn-range-row { grid-template-columns: 64px 1fr 52px; }
            .fn-foot { flex-direction: column; align-items: stretch; }
            .fn-foot-actions { justify-content: flex-end; }
        }
    `;

    function makeToggle(value, onChange) {
        const btn = h('button', {
            class: 'fn-toggle',
            type: 'button',
            role: 'switch',
            'aria-checked': String(!!value)
        });
        const update = v => {
            btn.classList.toggle('on', !!v);
            btn.setAttribute('aria-checked', String(!!v));
        };
        update(value);
        btn.addEventListener('click', () => {
            const next = !btn.classList.contains('on');
            update(next);
            onChange(next);
        });
        return btn;
    }

    function toggleRow(label, hint, value, onChange) {
        return h('div', { class: 'fn-toggle-row' },
            h('div', { class: 'fn-toggle-copy' },
                h('div', { class: 'fn-label', text: label }),
                hint ? h('div', { class: 'fn-hint', text: hint }) : null
            ),
            makeToggle(value, onChange)
        );
    }

    function settingSection(title, desc, body) {
        return h('section', { class: 'fn-section' },
            h('div', { class: 'fn-section-head' },
                h('div', { class: 'fn-section-title', text: title }),
                desc ? h('div', { class: 'fn-section-desc', text: desc }) : null
            ),
            h('div', { class: 'fn-section-body' }, body)
        );
    }

    function field(label, control, hint) {
        return h('div', { class: 'fn-field' },
            h('label', { class: 'fn-label', text: label }),
            control,
            hint ? h('div', { class: 'fn-hint', text: hint }) : null
        );
    }

    function addRange(parent, label, key, min, max, step, format) {
        const output = h('output', { text: format(cfg[key]) });
        const input = h('input', {
            type: 'range',
            min,
            max,
            step,
            value: cfg[key],
            'aria-label': label
        });
        input.addEventListener('input', () => {
            const value = Number(input.value);
            cfg[key] = value;
            output.textContent = format(value);
            saveSoon();
            applyConfig(key);
        });
        parent.append(h('div', { class: 'fn-range-row' },
            h('label', { text: label }),
            input,
            output
        ));
    }

    function applyConfig(key) {
        if (!S || !S.engine) return;
        if (key === 'fontSize' || key === 'outline') S.engine.clearTextCache();
        if (key === 'fontSize') S.engine.measureAll();
        S.engine.setGuide(!!settingsHost);
        S.engine.ensureLoop();
    }

    function reparentSettings() {
        if (!settingsHost) return;
        const parent = modalParent();
        if (settingsHost.parentElement !== parent) parent.append(settingsHost);
    }

    function closeSettings() {
        if (!settingsHost) return;
        const host = settingsHost;
        settingsHost = null;
        settingsRoot = null;
        if (settingsEscHandler) {
            document.removeEventListener('keydown', settingsEscHandler, true);
            settingsEscHandler = null;
        }
        document.removeEventListener('fullscreenchange', reparentSettings);
        try { host.remove(); } catch { /* ignore */ }
        if (S && S.engine) S.engine.setGuide(false);
    }

    function openSettings() {
        if (settingsHost) return;
        const parent = modalParent();
        const host = h('div', { class: 'fn-dm-settings' });
        host.style.cssText =
            'position:fixed;top:0;left:0;right:0;bottom:0;display:block;' +
            'z-index:2147483647;';
        parent.append(host);
        const root = host.attachShadow({ mode: 'open' });
        root.append(styleNode(SETTINGS_CSS));

        const baseInput = h('input', {
            class: 'fn-input',
            type: 'text',
            value: cfg.apiBase,
            placeholder: defaultApiBase() || 'http://192.168.1.2:9321',
            autocomplete: 'off',
            spellcheck: 'false'
        });
        const tokenInput = h('input', {
            class: 'fn-input',
            type: 'password',
            value: cfg.apiToken,
            placeholder: '可留空（默认 87654321 可省略）',
            autocomplete: 'off',
            spellcheck: 'false'
        });
        const apiStatus = h('div', { class: 'fn-status', text: '' });
        const settingsInfo = h('div', { class: 'fn-hint', text: '' });

        const fillBtn = h('button', { class: 'fn-btn', type: 'button', text: '填入当前 NAS 地址' });
        fillBtn.addEventListener('click', () => {
            baseInput.value = defaultApiBase();
            apiStatus.textContent = '已填入当前 NAS 地址，请确认端口是否为 9321。';
            apiStatus.className = 'fn-status';
        });

        const testBtn = h('button', { class: 'fn-btn', type: 'button', text: '测试连接' });
        testBtn.addEventListener('click', async () => {
            testBtn.disabled = true;
            testBtn.textContent = '测试中…';
            apiStatus.textContent = '正在连接 danmu-api…';
            apiStatus.className = 'fn-status';
            try {
                const result = await testApi({ base: baseInput.value, token: tokenInput.value });
                apiStatus.textContent = `连接成功 · ${result.ms} ms · 搜索到 ${result.count} 个结果`;
                apiStatus.className = 'fn-status ok';
            } catch (e) {
                apiStatus.textContent = `连接失败：${e.message}`;
                apiStatus.className = 'fn-status err';
            } finally {
                testBtn.disabled = false;
                testBtn.textContent = '测试连接';
            }
        });

        const autoMatchToggle = toggleRow(
            '自动匹配',
            '打开视频后按标题 / 季 / 集自动匹配弹幕',
            cfg.autoMatch,
            v => {
                cfg.autoMatch = v;
                saveSoon();
            }
        );

        const debugToggle = toggleRow(
            '调试日志',
            '在浏览器控制台输出匹配与 API 请求细节',
            cfg.debug,
            v => {
                cfg.debug = v;
                saveSoon();
                log('调试日志已开启');
            }
        );

        const displayBody = h('div');
        addRange(displayBody, '透明度', 'opacity', 0, 1, 0.05, v => Number(v).toFixed(2));
        addRange(displayBody, '显示区域', 'area', 10, 80, 5, v => `${v}%`);
        displayBody.append(h('div', {
            class: 'fn-hint',
            text: '弹幕只在画面顶部「显示区域」内滚动；打开本窗口时会显示参考线。'
        }));
        addRange(displayBody, '字号', 'fontSize', 10, 40, 1, v => `${v}px`);
        addRange(displayBody, '行间距', 'lineHeight', 1.2, 3, 0.1, v => `${Number(v).toFixed(1)}x`);
        addRange(displayBody, '滚动速度', 'speed', 0.5, 2.5, 0.1, v => `${Number(v).toFixed(1)}x`);
        addRange(displayBody, '弹幕密度', 'density', 10, 100, 5, v => `${v}%`);
        addRange(displayBody, '同屏上限', 'maxActive', 10, 80, 5, v => `${v} 条`);
        addRange(displayBody, '时间偏移', 'offset', -30, 30, 0.5, v => `${v > 0 ? '+' : ''}${Number(v).toFixed(1)}s`);
        displayBody.append(h('div', {
            class: 'fn-hint',
            text: '时间偏移：正数 = 弹幕延后，负数 = 弹幕提前。'
        }));
        const engineStats = S && S.engine ? S.engine.stats : null;
        if (engineStats) {
            displayBody.append(h('div', {
                class: 'fn-hint',
                text: `当前弹幕类型：滚动 ${engineStats.scroll} · 顶部 ${engineStats.top} · 底部 ${engineStats.bottom}`
            }));
        }
        displayBody.append(toggleRow('显示弹幕', '关闭后保留已加载的数据，随时可以再次打开', cfg.enabled, v => {
            cfg.enabled = v;
            saveSoon();
            if (S && S.engine) S.engine.ensureLoop();
            updateSettingRow();
        }));
        displayBody.append(toggleRow('文字描边', '在浅色画面中提升弹幕可读性', cfg.outline, v => {
            cfg.outline = v;
            saveSoon();
            if (S && S.engine) {
                S.engine.clearTextCache();
                S.engine.ensureLoop();
            }
        }));

        const rematchBtn = h('button', { class: 'fn-btn primary', type: 'button', text: '重新匹配当前视频' });
        rematchBtn.addEventListener('click', async () => {
            if (!S) {
                apiStatus.textContent = '当前页面没有播放器，请先打开一个视频。';
                apiStatus.className = 'fn-status err';
                return;
            }
            apiStatus.textContent = '正在重新匹配…';
            apiStatus.className = 'fn-status';
            await refreshCurrent(true);
            apiStatus.textContent = '已发起匹配，请留意播放器左下角的提示。';
            apiStatus.className = 'fn-status ok';
        });

        const clearBtn = h('button', { class: 'fn-btn danger', type: 'button', text: '清除当前弹幕' });
        clearBtn.addEventListener('click', () => {
            if (S && S.engine) {
                S.engine.clear();
                apiStatus.textContent = '已清除当前弹幕。';
                apiStatus.className = 'fn-status ok';
            } else {
                apiStatus.textContent = '当前页面没有播放器。';
                apiStatus.className = 'fn-status err';
            }
        });

        const resetBtn = h('button', { class: 'fn-btn danger', type: 'button', text: '恢复默认设置' });
        resetBtn.addEventListener('click', () => {
            if (!confirm('恢复所有默认设置？包括 API 地址与显示参数。')) return;
            cfg = { ...DEFAULTS };
            saveNow();
            if (S && S.engine) {
                S.engine.clearTextCache();
                S.engine.measureAll();
                S.engine.ensureLoop();
            }
            updateSettingRow();
            closeSettings();
            openSettings();
            flash('已恢复默认设置');
        });

        function saveApiAndApply() {
            try {
                const base = normalizeBase(baseInput.value) || normalizeBase(defaultApiBase());
                if (!base) throw new Error('请填写 danmu-api 地址');
                cfg.apiBase = base;
                cfg.apiToken = stripSlash(tokenInput.value);
                saveNow();
                closeSettings();
                if (S) {
                    flash('设置已保存，正在重新匹配…');
                    refreshCurrent(true);
                } else {
                    flash('设置已保存');
                }
            } catch (e) {
                apiStatus.textContent = e.message;
                apiStatus.className = 'fn-status err';
            }
        }

        baseInput.addEventListener('keydown', e => {
            if (e.key === 'Enter') saveApiAndApply();
        });
        tokenInput.addEventListener('keydown', e => {
            if (e.key === 'Enter') saveApiAndApply();
        });

        const dataSection = settingSection(
            '弹幕数据源',
            '直连 danmu-api，不经过反向代理。地址和 Token 通过油猴存储保存。',
            h('div', null,
                field('danmu-api 地址', baseInput, '例如 http://192.168.1.252:9321；留空时自动使用当前 NAS 地址 + 9321 端口。'),
                field('API Token（可选）', tokenInput, '对应 danmu-api 的 TOKEN。默认 87654321 可留空；也可以直接把 Token 写进上面的地址。'),
                h('div', { class: 'fn-row' }, testBtn, fillBtn),
                apiStatus
            )
        );

        const matchSection = settingSection(
            '匹配与播放',
            '自动匹配基于飞牛返回的标题、季、集信息。',
            h('div', null,
                autoMatchToggle,
                settingsInfo,
                h('div', { class: 'fn-row' }, rematchBtn, clearBtn)
            )
        );

        const displaySection = settingSection(
            '显示效果',
            '所有显示参数会立即生效，并自动保存。',
            displayBody
        );

        const miscSection = settingSection(
            '排查与维护',
            '遇到问题时可以打开调试日志，或在控制台查看 [飞牛弹幕] 前缀的输出。',
            h('div', null,
                debugToggle,
                h('div', { class: 'fn-row' }, resetBtn)
            )
        );

        const about = h('div', { class: 'fn-about' },
            h('span', { text: `飞牛影视弹幕增强 v${VERSION}` }),
            h('span', null,
                h('a', {
                    href: 'https://github.com/huangxd-/danmu_api',
                    target: '_blank',
                    rel: 'noopener noreferrer',
                    text: 'danmu-api'
                }),
                document.createTextNode(' · 参考 fn-danmu')
            )
        );

        const closeBtn = h('button', { class: 'fn-btn', type: 'button', text: '关闭' });
        closeBtn.addEventListener('click', closeSettings);

        const saveBtn = h('button', { class: 'fn-btn primary', type: 'button', text: '保存并应用' });
        saveBtn.addEventListener('click', saveApiAndApply);

        const dialog = h('div', { class: 'fn-dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': '飞牛影视弹幕设置', tabindex: '-1' },
            h('div', { class: 'fn-head' },
                h('div', { class: 'fn-title-row' },
                    h('div', { class: 'fn-logo', text: '弹' }),
                    h('div', null,
                        h('div', { class: 'fn-title', text: '飞牛影视弹幕设置' }),
                        h('div', { class: 'fn-subtitle', text: 'GM 存储 · 直连 danmu-api · 无需代理' })
                    )
                ),
                h('button', { class: 'fn-close', type: 'button', title: '关闭', 'aria-label': '关闭', text: '×', onclick: closeSettings })
            ),
            h('div', { class: 'fn-body' }, dataSection, matchSection, displaySection, miscSection, about),
            h('div', { class: 'fn-foot' },
                h('div', { class: 'fn-foot-note', text: '显示设置会自动保存；API 地址点击「保存并应用」后生效。' }),
                h('div', { class: 'fn-foot-actions' }, closeBtn, saveBtn)
            )
        );

        const backdrop = h('div', { class: 'fn-backdrop' }, dialog);
        backdrop.addEventListener('click', e => {
            if (e.target === backdrop) closeSettings();
        });
        root.append(backdrop);
        trapUIKeys(root, closeSettings);

        settingsHost = host;
        settingsRoot = root;
        if (S && S.engine) S.engine.setGuide(true);

        settingsEscHandler = e => {
            if (e.key === 'Escape') {
                e.preventDefault();
                closeSettings();
            }
        };
        document.addEventListener('keydown', settingsEscHandler, true);
        document.addEventListener('fullscreenchange', reparentSettings);

        setTimeout(() => {
            try { dialog.focus(); } catch { /* ignore */ }
        }, 30);

        if (S && S.info) {
            settingsInfo.textContent = S.info.isSeries
                ? `当前视频：${S.info.title} S${pad2(S.info.season)}E${pad2(S.info.episode)}`
                : `当前视频：${S.info.title}`;
        } else {
            settingsInfo.textContent = '当前页面没有播放器；仍可先配置 API 地址和显示参数。';
        }
    }

    /* ══════════════════════════════════════════════════════════════════
     *  SPA 路由监听
     * ══════════════════════════════════════════════════════════════════ */

    const watch = {
        href: location.href,
        guid: getGuid(),
        injecting: false,
        timer: null,
        observer: null
    };

    function scheduleEnsure(delay = 120) {
        clearTimeout(watch.timer);
        watch.timer = setTimeout(ensurePlayer, delay);
    }

    async function ensurePlayer() {
        if (watch.injecting) return;
        const guid = getGuid();

        if (!guid) {
            if (S) teardownPlayer(true);
            watch.guid = null;
            return;
        }

        if (S) {
            const alive = S.video && S.video.isConnected &&
                S.container && S.container.isConnected &&
                S.container.contains(S.video);
            if (!alive || watch.guid !== guid) {
                teardownPlayer(true);
            } else {
                return;
            }
        }

        const container = findPlayer();
        if (!container) return;
        const video = container.querySelector('video');
        if (!video) return;

        watch.injecting = true;
        try {
            await injectPlayer(container, video);
            watch.guid = guid;
        } catch (e) {
            error('注入失败', e);
            teardownPlayer(false);
        } finally {
            watch.injecting = false;
        }
    }

    function onRouteMaybeChanged() {
        const href = location.href;
        if (href !== watch.href) {
            watch.href = href;
            scheduleEnsure(120);
        } else {
            scheduleEnsure(250);
        }
    }

    function startWatch() {
        const target = document.body || document.documentElement;
        if (target && typeof MutationObserver === 'function') {
            watch.observer = new MutationObserver(() => {
                if (watch.injecting) return;
                if (!S || !S.video || !S.video.isConnected) scheduleEnsure(180);
            });
            watch.observer.observe(target, { childList: true, subtree: true });
        }

        window.addEventListener('popstate', onRouteMaybeChanged);
        window.addEventListener('hashchange', onRouteMaybeChanged);

        setInterval(() => {
            if (location.href !== watch.href) {
                watch.href = location.href;
                scheduleEnsure(100);
            } else if (!S) {
                scheduleEnsure(300);
            } else if (S.video && !S.video.isConnected) {
                scheduleEnsure(200);
            }
        }, 1000);

        scheduleEnsure(80);
    }

    /* ══════════════════════════════════════════════════════════════════
     *  菜单 & 启动
     * ══════════════════════════════════════════════════════════════════ */

    function sleep(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    function findSettingsTrigger() {
        const triggers = [...document.querySelectorAll('.xg-right-grid [aria-haspopup="dialog"]')];
        triggers.sort((a, b) => b.getBoundingClientRect().x - a.getBoundingClientRect().x);
        return triggers[0] || null;
    }

    function pressElement(el) {
        if (!el) return;
        const rect = el.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        const events = [
            [PointerEvent, 'pointerover', true],
            [MouseEvent, 'mouseover', true],
            [PointerEvent, 'pointerenter', false],
            [MouseEvent, 'mouseenter', false],
            [PointerEvent, 'pointerdown', true],
            [MouseEvent, 'mousedown', true],
            [PointerEvent, 'pointerup', true],
            [MouseEvent, 'mouseup', true],
            [MouseEvent, 'click', true]
        ];
        for (const [Ctor, type, bubbles] of events) {
            try {
                el.dispatchEvent(new Ctor(type, {
                    bubbles,
                    composed: true,
                    cancelable: true,
                    clientX: x,
                    clientY: y,
                    button: 0,
                    buttons: type.includes('down') ? 1 : 0,
                    pointerId: 1,
                    pointerType: 'mouse',
                    isPrimary: true
                }));
            } catch { /* ignore */ }
        }
    }

    async function openDanmakuMenuFromScript() {
        if (!S) {
            flash('当前页面没有播放器', true);
            return;
        }
        if (danmakuSubmenu) return;

        const getTopPopover = () => [...document.querySelectorAll('.trim-ui__player--popover')]
            .find(pop => pop.getBoundingClientRect().width > 0 && /自动连播/.test(pop.textContent || ''));

        const openFromPopover = pop => {
            invokePlayerSettingRow();
            const row = pop.querySelector('.fn-dm-menu-row');
            if (!row) return false;
            row.click();
            return true;
        };

        let pop = getTopPopover();
        if (pop && openFromPopover(pop)) return;

        const trigger = findSettingsTrigger();
        if (!trigger) {
            flash('未找到播放器设置入口', true);
            return;
        }

        const anyOpen = document.querySelector('.trim-ui__player--popover');
        pressElement(trigger);
        await sleep(anyOpen && !pop ? 220 : 260);
        if (anyOpen && !pop) {
            // 原生二级菜单打开时，先点一次关闭，再点一次打开顶层设置。
            pressElement(trigger);
            await sleep(260);
        }

        for (let i = 0; i < 6; i++) {
            pop = getTopPopover();
            if (pop) {
                if (openFromPopover(pop)) return;
            }
            await sleep(80);
        }
        flash('未能自动打开播放器设置，请手动点击播放器设置', true);
    }

    function registerMenus() {
        if (typeof GM_registerMenuCommand !== 'function') return;
        try {
            GM_registerMenuCommand('⚙ 飞牛弹幕设置', () => openSettings());
            GM_registerMenuCommand('💬 打开弹幕搜索', () => {
                openDanmakuMenuFromScript();
            });
            GM_registerMenuCommand('🔄 重新匹配当前视频', () => refreshCurrent(true));
            GM_registerMenuCommand('🧹 清除当前弹幕', () => {
                if (S && S.engine) {
                    S.engine.clear();
                    flash('弹幕已清除');
                } else {
                    flash('当前页面没有播放器');
                }
            });
        } catch (e) {
            warn('注册菜单命令失败', e);
        }
    }

    function boot() {
        if (document.documentElement.dataset.fnosDanmaku === '1') {
            log('脚本已运行，跳过重复初始化');
            return;
        }
        document.documentElement.dataset.fnosDanmaku = '1';

        log(`启动 v${VERSION}`, location.href);
        registerMenus();
        startWatch();
        window.addEventListener('pagehide', saveNow, { capture: true });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot, { once: true });
    } else {
        boot();
    }
})();
