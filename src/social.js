'use strict';
// Automatic posting of shoot results to the social platforms an account holder
// has connected. Credentials are stored encrypted. Posting never blocks or fails
// an upload: each account records the outcome of its last attempt.
const crypto = require('crypto');
const dns = require('dns').promises;
const net = require('net');
const express = require('express');

const MAX_ACCOUNTS = 10;
// Test hook only: lets the posters talk to a local mock server.
const allowLocal = () => process.env.SOCIAL_ALLOW_LOCAL === '1';

function isPrivateIp(ip) {
  if (net.isIPv6(ip)) {
    const v = ip.toLowerCase();
    if (v === '::1' || v === '::' || v.startsWith('fc') || v.startsWith('fd') || /^fe[89ab]/.test(v)) return true;
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(v);
    return mapped ? isPrivateIp(mapped[1]) : false;
  }
  const [a, b] = ip.split('.').map(Number);
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
}

async function assertPublicHttps(urlText) {
  const u = new URL(urlText);
  if (allowLocal()) return u;
  if (u.protocol !== 'https:' || u.username || u.password) throw new Error('must be an https address');
  const addrs = net.isIP(u.hostname) ? [{ address: u.hostname }] : await dns.lookup(u.hostname, { all: true });
  if (!addrs.length || addrs.some((a) => isPrivateIp(a.address))) throw new Error('address is not allowed');
  return u;
}

async function send(method, url, { headers = {}, json, form } = {}) {
  const init = { method, headers: { Accept: 'application/json', ...headers }, redirect: 'error', signal: AbortSignal.timeout(15000) };
  if (json !== undefined) { init.body = JSON.stringify(json); init.headers['Content-Type'] = 'application/json'; }
  if (form) init.body = new URLSearchParams(form);
  let res;
  try { res = await fetch(url, init); } catch { throw new Error('could not connect'); }
  const text = await res.text();
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  try { return text ? JSON.parse(text) : {}; } catch { return {}; }
}

const clip = (text, max) => (text.length <= max ? text : text.slice(0, max - 1).trimEnd() + '…');
const enc1 = (s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());

function oauth1Header(method, url, c) {
  const p = {
    oauth_consumer_key: c.apiKey, oauth_nonce: crypto.randomBytes(16).toString('hex'), oauth_signature_method: 'HMAC-SHA1',
    oauth_timestamp: String(Math.floor(Date.now() / 1000)), oauth_token: c.accessToken, oauth_version: '1.0',
  };
  const paramString = Object.keys(p).sort().map((k) => `${enc1(k)}=${enc1(p[k])}`).join('&');
  const base = [method, enc1(url), enc1(paramString)].join('&');
  p.oauth_signature = crypto.createHmac('sha1', `${enc1(c.apiSecret)}&${enc1(c.accessSecret)}`).update(base).digest('base64');
  return 'OAuth ' + Object.keys(p).sort().map((k) => `${enc1(k)}="${enc1(p[k])}"`).join(', ');
}

const webhookOk = (hosts, pathPrefix) => (value) => {
  let u;
  try { u = new URL(value); } catch { return 'must be a web address'; }
  if (allowLocal()) return null;
  if (u.protocol !== 'https:' || !hosts.includes(u.hostname) || !u.pathname.startsWith(pathPrefix)) return `must be a ${hosts[0]} webhook address`;
  return null;
};

const PLATFORMS = {
  discord: {
    name: 'Discord', hint: 'Server Settings → Integrations → Webhooks → New Webhook → Copy Webhook URL.',
    fields: [{ key: 'webhook', label: 'Webhook URL', secret: true, check: webhookOk(['discord.com', 'discordapp.com'], '/api/webhooks/') }],
    post: (c, text) => send('POST', c.webhook, { json: { content: clip(text, 1900), allowed_mentions: { parse: [] } } }),
  },
  slack: {
    name: 'Slack', hint: 'Create an Incoming Webhook for a channel in your Slack app settings.',
    fields: [{ key: 'webhook', label: 'Incoming webhook URL', secret: true, check: webhookOk(['hooks.slack.com'], '/services/') }],
    post: (c, text) => send('POST', c.webhook, { json: { text: clip(text, 3000) } }),
  },
  telegram: {
    name: 'Telegram', hint: 'Create a bot with @BotFather, add it to your channel or group as an admin, and use the channel (@name) or numeric chat id.',
    fields: [
      { key: 'botToken', label: 'Bot token', secret: true, check: (v) => (/^\d+:[\w-]{20,}$/.test(v) ? null : 'does not look like a bot token') },
      { key: 'chatId', label: 'Chat or channel id', check: (v) => (/^(-?\d+|@\w{4,})$/.test(v) ? null : 'use a numeric id or @channelname') },
    ],
    post: (c, text) => send('POST', `${process.env.TELEGRAM_BASE || 'https://api.telegram.org'}/bot${c.botToken}/sendMessage`, { json: { chat_id: c.chatId, text: clip(text, 4000) } }),
  },
  mastodon: {
    name: 'Mastodon', hint: 'On your instance: Preferences → Development → New application with the write:statuses scope, then copy the access token.',
    fields: [
      { key: 'instance', label: 'Instance address (https://…)', check: (v) => { try { const u = new URL(v); return u.protocol === 'https:' || allowLocal() ? null : 'must be https'; } catch { return 'must be a web address'; } } },
      { key: 'accessToken', label: 'Access token', secret: true },
    ],
    async post(c, text) {
      const u = await assertPublicHttps(c.instance);
      return send('POST', `${u.origin}/api/v1/statuses`, { headers: { Authorization: `Bearer ${c.accessToken}` }, form: { status: clip(text, 480), visibility: 'public' } });
    },
  },
  bluesky: {
    name: 'Bluesky', hint: 'Use your handle and an App Password from Settings → Privacy and security → App passwords (not your main password).',
    fields: [
      { key: 'handle', label: 'Handle (name.bsky.social)', check: (v) => (/^[\w.-]+\.[\w.-]+$/.test(v) ? null : 'does not look like a handle') },
      { key: 'appPassword', label: 'App password', secret: true },
    ],
    async post(c, text) {
      const base = process.env.BLUESKY_BASE || 'https://bsky.social';
      const s = await send('POST', `${base}/xrpc/com.atproto.server.createSession`, { json: { identifier: c.handle, password: c.appPassword } });
      return send('POST', `${base}/xrpc/com.atproto.repo.createRecord`, {
        headers: { Authorization: `Bearer ${s.accessJwt}` },
        json: { repo: s.did, collection: 'app.bsky.feed.post', record: { $type: 'app.bsky.feed.post', text: clip(text, 290), createdAt: new Date().toISOString() } },
      });
    },
  },
  facebook: {
    name: 'Facebook Page', hint: 'Needs a Page access token with pages_manage_posts permission for your Page.',
    fields: [
      { key: 'pageId', label: 'Page id', check: (v) => (/^\d+$/.test(v) ? null : 'must be numeric') },
      { key: 'pageToken', label: 'Page access token', secret: true },
    ],
    post: (c, text) => send('POST', `${process.env.FACEBOOK_BASE || 'https://graph.facebook.com/v19.0'}/${c.pageId}/feed`, { form: { message: clip(text, 4000), access_token: c.pageToken } }),
  },
  x: {
    name: 'X (Twitter)', hint: 'From the X developer portal, an app with write access: API key and secret plus the account\'s access token and secret. X may charge for API posting.',
    fields: [
      { key: 'apiKey', label: 'API key' },
      { key: 'apiSecret', label: 'API key secret', secret: true },
      { key: 'accessToken', label: 'Access token' },
      { key: 'accessSecret', label: 'Access token secret', secret: true },
    ],
    post(c, text) {
      const url = `${process.env.X_BASE || 'https://api.x.com'}/2/tweets`;
      return send('POST', url, { headers: { Authorization: oauth1Header('POST', url, c) }, json: { text: clip(text, 280) } });
    },
  },
};

module.exports = function createSocial({ db, encrypt, decrypt, needAuth, wrap }) {
  const medals = ['🥇', '🥈', '🥉'];

  function buildMessage(userId, shootId) {
    const shoot = db.prepare('SELECT * FROM shoots WHERE id = ? AND user_id = ?').get(shootId, userId);
    if (!shoot) return null;
    const club = db.prepare('SELECT club_name FROM users WHERE id = ?').get(userId)?.club_name;
    const rows = db.prepare('SELECT shooter, SUM(score) AS total, COUNT(*) AS stands FROM results WHERE shoot_id = ? GROUP BY shooter').all(shootId)
      .sort((a, b) => b.total - a.total || a.shooter.localeCompare(b.shooter));
    const lines = rows.slice(0, 10).map((r) => {
      const place = 1 + rows.filter((o) => o.total > r.total).length;
      const pct = (100 * r.total) / (r.stands * shoot.targets_per_stand);
      return `${medals[place - 1] ?? `${place}.`} ${r.shooter} – ${r.total}/${r.stands * shoot.targets_per_stand} (${pct.toFixed(1)}%)`;
    });
    if (rows.length > 10) lines.push(`…and ${rows.length - 10} more`);
    const head = `🎯 ${shoot.name} – ${shoot.shoot_date}${shoot.shoot_time ? ` ${shoot.shoot_time}` : ''}${shoot.venue ? ` at ${shoot.venue}` : ''}`;
    return [head, '', ...lines, ...(club ? ['', club] : [])].join('\n');
  }

  const config = (row) => JSON.parse(decrypt(row.config));
  async function postTo(row, text) {
    const platform = PLATFORMS[row.platform];
    let status;
    try {
      await platform.post(config(row), text);
      status = 'Posted';
    } catch (e) {
      status = `Failed: ${String(e.message).slice(0, 80)}`;
    }
    db.prepare("UPDATE social_accounts SET last_status = ?, last_at = datetime('now') WHERE id = ?").run(status, row.id);
    return status;
  }

  // Called after an upload; never throws.
  async function postShoot(userId, shootId) {
    try {
      const text = buildMessage(userId, shootId);
      if (!text) return;
      const rows = db.prepare('SELECT * FROM social_accounts WHERE user_id = ? AND enabled = 1').all(userId);
      await Promise.allSettled(rows.map((r) => postTo(r, text)));
    } catch (e) { console.error('social post failed', e.message); }
  }

  const router = express.Router();
  const mine = (req) => db.prepare('SELECT * FROM social_accounts WHERE id = ? AND user_id = ?').get(Number(req.params.id), req.session.userId);

  router.get('/', needAuth, (req, res) => {
    const accounts = db.prepare('SELECT id, platform, label, enabled, last_status, last_at FROM social_accounts WHERE user_id = ? ORDER BY id').all(req.session.userId)
      .map((a) => ({ ...a, platformName: PLATFORMS[a.platform]?.name || a.platform }));
    res.render('social', { accounts, platforms: PLATFORMS, msg: req.query.msg || null, err: req.query.err || null, max: MAX_ACCOUNTS });
  });

  router.post('/add', needAuth, wrap(async (req, res) => {
    const fail = (m) => res.redirect(`/social?err=${encodeURIComponent(m)}`);
    const platform = PLATFORMS[String(req.body.platform)];
    if (!platform) return fail('Choose a platform.');
    if (db.prepare('SELECT COUNT(*) AS n FROM social_accounts WHERE user_id = ?').get(req.session.userId).n >= MAX_ACCOUNTS) return fail(`You can connect up to ${MAX_ACCOUNTS} accounts.`);
    const cfg = {};
    for (const f of platform.fields) {
      const v = String(req.body[`f_${f.key}`] || '').trim();
      if (!v || v.length > 500) return fail(`${f.label} is required.`);
      const problem = f.check?.(v);
      if (problem) return fail(`${f.label} ${problem}.`);
      cfg[f.key] = v;
    }
    if (platform.fields.some((f) => f.key === 'instance')) {
      try { await assertPublicHttps(cfg.instance); } catch (e) { return fail(`Instance address ${e.message}.`); }
    }
    const label = String(req.body.label || '').trim().slice(0, 60) || platform.name;
    db.prepare('INSERT INTO social_accounts (user_id, platform, label, config) VALUES (?,?,?,?)').run(req.session.userId, req.body.platform, label, encrypt(JSON.stringify(cfg)));
    res.redirect(`/social?msg=${encodeURIComponent(`${label} connected. Use “Send test” to check it works.`)}`);
  }));

  router.post('/:id/toggle', needAuth, (req, res) => {
    const a = mine(req);
    if (a) db.prepare('UPDATE social_accounts SET enabled = ? WHERE id = ?').run(a.enabled ? 0 : 1, a.id);
    res.redirect('/social');
  });
  router.post('/:id/delete', needAuth, (req, res) => {
    const a = mine(req);
    if (a) db.prepare('DELETE FROM social_accounts WHERE id = ?').run(a.id);
    res.redirect('/social');
  });
  router.post('/:id/test', needAuth, wrap(async (req, res) => {
    const a = mine(req);
    if (!a) return res.redirect('/social');
    const club = res.locals.user.club_name;
    const status = await postTo(a, `✅ Test post from Clay Shoots (${club}). Results will be posted here when you upload a shoot.`);
    res.redirect(`/social?${status === 'Posted' ? 'msg' : 'err'}=${encodeURIComponent(`${a.label}: ${status}`)}`);
  }));

  return { router, postShoot, buildMessage, PLATFORMS };
};
