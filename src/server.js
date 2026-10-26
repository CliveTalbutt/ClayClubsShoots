require('dotenv').config();
const crypto = require('crypto');
const path = require('path');
const express = require('express');
const session = require('express-session');
const SqliteStore = require('better-sqlite3-session-store')(session);
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const bcrypt = require('bcryptjs');
const { authenticator } = require('otplib');
const QRCode = require('qrcode');
const db = require('./db');

for (const k of ['SESSION_SECRET', 'APP_ENCRYPTION_KEY']) {
  if (!process.env[k]) { console.error(`Missing ${k} in .env`); process.exit(1); }
}
const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';
const PROD = process.env.NODE_ENV === 'production';
const tlsConfig = require('./tls').load(process.env.BASE_URL || '');
// Encrypted transport is mandatory whenever the server terminates TLS itself or runs in production.
const SECURE = PROD || !!tlsConfig;
const encKey = Buffer.from(process.env.APP_ENCRYPTION_KEY, 'hex');

// ---- helpers ----
const encrypt = (text) => {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', encKey, iv);
  const enc = Buffer.concat([c.update(text, 'utf8'), c.final()]);
  return [iv, c.getAuthTag(), enc].map((b) => b.toString('base64')).join('.');
};
const decrypt = (blob) => {
  const [iv, tag, enc] = blob.split('.').map((s) => Buffer.from(s, 'base64'));
  const d = crypto.createDecipheriv('aes-256-gcm', encKey, iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(enc), d.final()]).toString('utf8');
};
// Deterministic, authenticated encryption of "userId:id" so URLs are stable, opaque and user-bound.
const urlKey = crypto.createHmac('sha256', encKey).update('url-id-key').digest();
const urlIvKey = crypto.createHmac('sha256', encKey).update('url-id-iv').digest();
const encodeId = (userId, id) => {
  const pt = Buffer.from(`${userId}:${id}`);
  const iv = crypto.createHmac('sha256', urlIvKey).update(pt).digest().subarray(0, 12);
  const c = crypto.createCipheriv('aes-256-gcm', urlKey, iv);
  const enc = Buffer.concat([c.update(pt), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), enc]).toString('base64url');
};
const decodeId = (userId, token) => {
  try {
    if (typeof token !== 'string' || token.length > 120) return null;
    const b = Buffer.from(token, 'base64url');
    if (b.length < 29) return null;
    const d = crypto.createDecipheriv('aes-256-gcm', urlKey, b.subarray(0, 12));
    d.setAuthTag(b.subarray(12, 28));
    const m = /^(\d+):(\d+)$/.exec(Buffer.concat([d.update(b.subarray(28)), d.final()]).toString());
    return m && Number(m[1]) === Number(userId) ? Number(m[2]) : null;
  } catch { return null; }
};
const hashKey = (k) => crypto.createHash('sha256').update(k).digest('hex');
// With no payment provider configured there is nothing to subscribe to, so every account is active.
const isActive = (u) =>
  u && (u.is_super === 1 || !payments.anyEnabled() || ['active', 'trialing'].includes(u.sub_status) && (u.sub_period_end || 0) * 1000 > Date.now());
const regenerate = (req) => new Promise((res, rej) => req.session.regenerate((e) => (e ? rej(e) : res())));
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

const app = express();
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, '..', 'views'));
app.set('trust proxy', 1);
// Over plain http (local network testing) the default upgrade-insecure-requests and HSTS break CSS/JS.
// HSTS is only sent for publicly trusted certificates; a browser cannot bypass it for a self-signed one.
const selfSignedTls = !!(tlsConfig && tlsConfig.selfSigned);
app.use(helmet(SECURE ? { strictTransportSecurity: selfSignedTls ? false : { maxAge: 31536000, includeSubDomains: true } } : {
  contentSecurityPolicy: { directives: { ...helmet.contentSecurityPolicy.getDefaultDirectives(), 'upgrade-insecure-requests': null } },
  strictTransportSecurity: false,
}));
app.use((req, res, next) => {
  if (!SECURE || req.secure) return next();
  if (req.path.startsWith('/api/')) return res.status(426).json({ error: 'HTTPS is required' });
  return res.status(426).send('HTTPS is required');
});
app.use(express.static(path.join(__dirname, '..', 'public')));

const payments = require('./payments')({ db, baseUrl: BASE_URL, needAuth: (q, s, n) => needAuth(q, s, n), wrap });
app.use('/webhook', payments.webhooks);
const mailer = require('./mailer')({ db, classify: (s) => classify(s), needAuth: (q, r, n) => needAuth(q, r, n), wrap });
const roster = require('./roster')({ db, needAuth: (q, r, n) => needAuth(q, r, n), mailer, baseUrl: BASE_URL, wrap });
const backup = require('./backup')({ db, dir: path.join(__dirname, '..', 'data', 'backups') });
if (process.env.DB_IN_MEMORY !== '1') backup.schedule();
const allowanceLib = require('./allowance');
const reminders = require('./reminders')({ db, mailer, baseUrl: BASE_URL });
reminders.schedule();
const social = require('./social')({ db, encrypt, decrypt, needAuth: (q, r, n) => needAuth(q, r, n), wrap });

// ---- JSON API for the iPhone app (bearer key, no cookies/CSRF) ----
db.exec(`CREATE TABLE IF NOT EXISTS device_keys (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  key_hash TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
)`);
// A club's main key or any per-device key issued to one of its members.
const userByKey = (key) => {
  const h = hashKey(key);
  return db.prepare('SELECT * FROM users WHERE api_key_hash = ?').get(h)
    || db.prepare('SELECT u.* FROM device_keys d JOIN users u ON u.id = d.user_id WHERE d.key_hash = ?').get(h);
};
// TESTING ONLY: identify a member by email alone, list their clubs, and issue a per-device key.
// Anyone who knows a member's email can do this, so it is off unless ALLOW_EMAIL_ONLY_LOGIN=1 and never in production.
const emailLoginOn = () => process.env.ALLOW_EMAIL_ONLY_LOGIN === '1' && process.env.NODE_ENV !== 'production';
const loginLimiter = rateLimit({ windowMs: 15 * 60_000, limit: 30, standardHeaders: true, legacyHeaders: false });
function memberClubs(email) {
  const rows = db.prepare(`SELECT u.id, u.club_name,
      (SELECT COUNT(*) FROM shoots s WHERE s.user_id = u.id) AS shoots
    FROM roster r JOIN users u ON u.id = r.user_id
    WHERE lower(r.email) = ? AND r.kind = 'member' AND r.status = 'current' AND u.is_super = 0`).all(email);
  const best = new Map();
  for (const r of rows) { const c = best.get(r.club_name); if (!c || r.shoots > c.shoots) best.set(r.club_name, r); }
  return [...best.values()].sort((a, b) => a.club_name.localeCompare(b.club_name));
}
const cleanEmail = (v) => String(v || '').trim().toLowerCase().slice(0, 200);
app.post('/api/v1/clubs/lookup', loginLimiter, express.json({ limit: '2kb' }), (req, res) => {
  if (!emailLoginOn()) return res.status(404).json({ error: 'not_enabled' });
  const email = cleanEmail(req.body && req.body.email);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return res.status(400).json({ error: 'invalid_email' });
  res.set('Cache-Control', 'no-store').json({ clubs: memberClubs(email).map((c) => ({ id: c.id, name: c.club_name })) });
});
app.post('/api/v1/clubs/connect', loginLimiter, express.json({ limit: '2kb' }), (req, res) => {
  if (!emailLoginOn()) return res.status(404).json({ error: 'not_enabled' });
  const email = cleanEmail(req.body && req.body.email);
  const id = Number(req.body && req.body.id);
  const club = memberClubs(email).find((c) => c.id === id);
  if (!club) return res.status(403).json({ error: 'not_a_member' });
  const key = 'cs_' + crypto.randomBytes(24).toString('hex');
  db.prepare('INSERT INTO device_keys (user_id, key_hash, email) VALUES (?,?,?)').run(club.id, hashKey(key), email);
  db.prepare('DELETE FROM device_keys WHERE id IN (SELECT id FROM device_keys WHERE user_id = ? AND email = ? ORDER BY id DESC LIMIT -1 OFFSET 5)').run(club.id, email);
  res.set('Cache-Control', 'no-store').json({ club: club.club_name, apiKey: key });
});
const apiLimiter = rateLimit({ windowMs: 60_000, limit: 60, standardHeaders: true, legacyHeaders: false });
// Devices poll the current shoot about once a second, so this needs far more headroom.
// Live scoring sends an upload per change, so uploads get a far higher allowance than other calls.
const uploadLimiter = rateLimit({ windowMs: 60_000, limit: 600, standardHeaders: true, legacyHeaders: false });
const pollLimiter = rateLimit({ windowMs: 60_000, limit: 600, standardHeaders: true, legacyHeaders: false });
app.get('/api/v1/ping', apiLimiter, (req, res) => {
  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization || '');
  const user = m && userByKey(m[1]);
  if (!user) return res.status(401).json({ error: 'invalid_api_key' });
  if (!isActive(user)) return res.status(402).json({ error: 'subscription_required' });
  res.json({ ok: true, club: user.club_name });
});
// Roster of registered shooters for the club that owns the API key.
const apiUser = (req, res) => {
  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization || '');
  const user = m && userByKey(m[1]);
  if (!user) { res.status(401).json({ error: 'invalid_api_key' }); return null; }
  if (!isActive(user)) { res.status(402).json({ error: 'subscription_required' }); return null; }
  return user;
};
app.get('/api/v1/shooters', apiLimiter, (req, res) => {
  const user = apiUser(req, res);
  if (user) res.set('Cache-Control', 'no-store').json({ club: user.club_name, shooters: roster.listCurrent(user.id) });
});
app.post('/api/v1/shooters', apiLimiter, express.json({ limit: '10kb' }), (req, res) => {
  const user = apiUser(req, res);
  if (!user) return;
  const kind = req.body && req.body.kind === 'member' ? 'member' : 'guest';
  const r = roster.add(user.id, req.body, kind, !!(req.body && req.body.isAdmin));
  if (r.status === 201) roster.sendVerification(user.id, r.body.shooter.id).catch(() => {});
  res.status(r.status).json(r.body);
});
// Emails shooters and posts to social accounts, once per shoot, when it is complete.
function notifyOnce(userId, shootId, flags) {
  const claimed = db.prepare('UPDATE shoots SET notified = 1 WHERE id = ? AND user_id = ? AND notified = 0').run(shootId, userId);
  if (!claimed.changes) return;
  if (flags.email) mailer.sendShoot(userId, shootId);
  if (flags.social) social.postShoot(userId, shootId);
}
// Stores a handicap shoot's flag and each shooter's handicap (set when the shoot starts, never recomputed).
function saveHandicaps(shootId, b) {
  if (b.handicap !== true) return;
  db.prepare('UPDATE shoots SET is_handicap = 1 WHERE id = ?').run(shootId);
  const up = db.prepare('INSERT OR REPLACE INTO shoot_handicaps (shoot_id, shooter, handicap) VALUES (?,?,?)');
  for (const s of b.shooters) if (typeof s.handicap === 'number') up.run(shootId, s.name.trim(), Math.floor(s.handicap + 1e-9));
}
app.post('/api/v1/shoots', uploadLimiter, express.json({ limit: '1mb' }), (req, res) => {
  const m = /^Bearer (.+)$/.exec(req.headers.authorization || '');
  const user = m && userByKey(m[1]);
  if (!user) return res.status(401).json({ error: 'invalid_api_key' });
  if (!isActive(user)) return res.status(402).json({ error: 'subscription_required' });

  const b = req.body || {};
  const flags = { email: b.emailResults !== false, social: b.postToSocial !== false };
  const errors = [];
  const str = (v, max) => typeof v === 'string' && v.trim().length > 0 && v.length <= max;
  if (!str(b.name, 120)) errors.push('name required');
  if (b.venue != null && !str(b.venue, 120)) errors.push('venue invalid');
  if (b.time != null && !(typeof b.time === 'string' && /^([01]\d|2[0-3]):(00|30)$/.test(b.time))) errors.push('time must be HH:MM on the hour or half hour');
  if (typeof b.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(b.date) || isNaN(Date.parse(b.date))) errors.push('date must be YYYY-MM-DD');
  if (!Number.isInteger(b.stands) || b.stands < 1 || b.stands > 25) errors.push('stands must be an integer 1-25');
  const tps = b.targetsPerStand ?? 10;
  if (!Number.isInteger(tps) || tps < 1 || tps > 100) errors.push('targetsPerStand must be an integer 1-100');
  if (Array.isArray(b.shooters) && b.shooters.some((s) => s && s.email != null && s.email !== '' && !mailer.validEmail(s.email))) errors.push('shooter email invalid');
  if (b.complete != null && typeof b.complete !== 'boolean') errors.push('complete must be true or false');
  if (b.externalId != null && !str(b.externalId, 100)) errors.push('externalId invalid');
  if (b.ownedStands != null && !(Array.isArray(b.ownedStands) && b.ownedStands.every((n) => Number.isInteger(n) && n >= 1 && n <= (b.stands || 0)))) errors.push('ownedStands must list stand numbers within the shoot');
  if (b.handicap != null && typeof b.handicap !== 'boolean') errors.push('handicap must be true or false');
  if (Array.isArray(b.shooters) && b.shooters.some((s) => s && s.handicap != null && !(typeof s.handicap === 'number' && s.handicap >= 0 && s.handicap <= 2500))) errors.push('shooter handicap must be a number 0-2500');
  if (b.standTargets != null && !(Array.isArray(b.standTargets) && b.standTargets.length === b.stands && b.standTargets.every((n) => Number.isInteger(n) && n >= 1 && n <= tps))) errors.push('standTargets must list the targets on each stand, up to targetsPerStand');
  if (b.lockedStands != null && !(Array.isArray(b.lockedStands) && b.lockedStands.every((n) => Number.isInteger(n) && n >= 1 && n <= (b.stands || 0)))) errors.push('lockedStands must list stand numbers within the shoot');
  if (!Array.isArray(b.shooters) || b.shooters.length < 1 || b.shooters.length > 500) errors.push('shooters must be an array of 1-500');
  else {
    const seen = new Set();
    b.shooters.forEach((s, i) => {
      if (!s || !str(s.name, 80)) return errors.push(`shooters[${i}].name required`);
      if (seen.has(s.name.trim().toLowerCase())) errors.push(`shooters[${i}] duplicate name`);
      seen.add(s.name.trim().toLowerCase());
      if (!Array.isArray(s.scores) || s.scores.length !== b.stands ||
          !s.scores.every((x, k) => Number.isInteger(x) && x >= 0 && x <= (Array.isArray(b.standTargets) && Number.isInteger(b.standTargets[k]) ? b.standTargets[k] : tps)))
        errors.push(`shooters[${i}].scores must be ${b.stands} integers between 0 and ${tps}`);
      // Optional per-clay detail: one string per stand, '1' hit, '0' miss, '-' not shot.
      if (s.patterns != null) {
        const ok = Array.isArray(s.patterns) && s.patterns.length === b.stands && s.patterns.every((p, k) =>
          typeof p === 'string' && p.length === tps && /^[01-]+$/.test(p) && Array.isArray(s.scores) &&
          (p.match(/1/g) || []).length === s.scores[k]);
        if (!ok) errors.push(`shooters[${i}].patterns must be ${b.stands} strings of ${tps} characters (1, 0 or -) matching the scores`);
      }
    });
  }
  if (errors.length) return res.status(400).json({ error: 'validation_failed', details: errors });

  try {
    let existing = b.externalId != null
      ? db.prepare('SELECT id FROM shoots WHERE user_id = ? AND external_id = ?').get(user.id, b.externalId) : null;
    // All devices of a club share its one live shoot: an unknown live shoot id joins the club's
    // unfinished shoot (if it matches in size) and its scores are merged in rather than replacing.
    let aliased = false;
    if (!existing && b.externalId != null) {
      existing = db.prepare('SELECT s.id FROM shoot_aliases a JOIN shoots s ON s.id = a.shoot_id WHERE a.user_id = ? AND a.alias = ?').get(user.id, b.externalId) || null;
      if (!existing && b.complete === false) {
        existing = db.prepare("SELECT id FROM shoots WHERE user_id = ? AND complete = 0 AND external_id IS NOT NULL AND stands = ? AND targets_per_stand = ? AND updated_at >= datetime('now', '-12 hours') ORDER BY id ASC LIMIT 1").get(user.id, b.stands, tps) || null;
        if (existing) db.prepare('INSERT OR REPLACE INTO shoot_aliases (user_id, alias, shoot_id) VALUES (?,?,?)').run(user.id, b.externalId, existing.id);
      }
      aliased = !!existing;
    }
    if (existing) {
      db.transaction(() => {
        db.prepare("UPDATE shoots SET updated_at = datetime('now') WHERE id = ?").run(existing.id);
        if (!aliased && Array.isArray(b.standTargets)) db.prepare('UPDATE shoots SET stand_targets = ? WHERE id = ?').run(JSON.stringify(b.standTargets), existing.id);
        if (!aliased) db.prepare("UPDATE shoots SET name = ?, venue = ?, shoot_date = ?, shoot_time = ?, stands = ?, targets_per_stand = ? WHERE id = ?")
          .run(b.name.trim(), b.venue?.trim() ?? null, b.date, b.time ?? null, b.stands, tps, existing.id);
        const ins = db.prepare('INSERT OR REPLACE INTO results (shoot_id, shooter, stand, score, pattern) VALUES (?,?,?,?,?)');
        if (aliased) {
          // Keep whichever record of each stand has more clays scored.
          const row = db.prepare('SELECT pattern FROM results WHERE shoot_id = ? AND shooter = ? AND stand = ?');
          const shot = (p) => (p ? (p.match(/[01]/g) || []).length : 0);
          for (const s of b.shooters) s.scores.forEach((sc, i) => {
            const old = row.get(existing.id, s.name.trim(), i + 1);
            const mine = s.patterns?.[i] ?? null;
            if (!old || shot(mine) > shot(old.pattern) || (mine == null && old.pattern == null && sc > 0)) ins.run(existing.id, s.name.trim(), i + 1, sc, mine);
          });
        } else if (Array.isArray(b.ownedStands)) {
          // Several devices share one shoot: each writes only the stands assigned to it and
          // leaves the rest (and shooters it has not heard of) as other devices recorded them.
          const owned = new Set(b.ownedStands);
          const has = db.prepare('SELECT 1 FROM results WHERE shoot_id = ? AND shooter = ? AND stand = ?');
          for (const s of b.shooters) s.scores.forEach((sc, i) => {
            if (owned.has(i + 1) || !has.get(existing.id, s.name.trim(), i + 1)) ins.run(existing.id, s.name.trim(), i + 1, sc, s.patterns?.[i] ?? null);
          });
        } else {
          db.prepare('DELETE FROM results WHERE shoot_id = ?').run(existing.id);
          for (const s of b.shooters) s.scores.forEach((sc, i) => ins.run(existing.id, s.name.trim(), i + 1, sc, s.patterns?.[i] ?? null));
        }
        saveHandicaps(existing.id, b);
        if (Array.isArray(b.lockedStands)) {
          // A device only decides the locks of the stands it owns; a locked stand stays locked.
          const old = JSON.parse(db.prepare('SELECT locked_stands FROM shoots WHERE id = ?').get(existing.id).locked_stands || '[]');
          const owned = Array.isArray(b.ownedStands) ? new Set(b.ownedStands) : null;
          const kept = owned ? old.filter((n) => !owned.has(n)) : [];
          const locked = [...new Set([...kept, ...b.lockedStands])].sort((x, y) => x - y);
          db.prepare('UPDATE shoots SET locked_stands = ? WHERE id = ?').run(JSON.stringify(locked), existing.id);
        }
        if (b.complete === true) db.prepare('UPDATE shoots SET complete = 1 WHERE id = ?').run(existing.id);
      })();
      mailer.saveEmails(user.id, b.shooters);
      if (b.complete === true) notifyOnce(user.id, existing.id, flags);
      return res.status(201).json({ id: existing.id, updated: true, url: `${BASE_URL}/shoots/${encodeId(user.id, existing.id)}` });
    }
    const id = db.transaction(() => {
      const r = db.prepare(
        "INSERT INTO shoots (user_id, external_id, name, venue, shoot_date, shoot_time, stands, targets_per_stand, complete, updated_at) VALUES (?,?,?,?,?,?,?,?,?, datetime('now'))"
      ).run(user.id, b.externalId ?? null, b.name.trim(), b.venue?.trim() ?? null, b.date, b.time ?? null, b.stands, tps, b.complete === false ? 0 : 1);
      saveHandicaps(r.lastInsertRowid, b);
      if (Array.isArray(b.standTargets)) db.prepare('UPDATE shoots SET stand_targets = ? WHERE id = ?').run(JSON.stringify(b.standTargets), r.lastInsertRowid);
      if (Array.isArray(b.lockedStands)) db.prepare('UPDATE shoots SET locked_stands = ? WHERE id = ?').run(JSON.stringify([...new Set(b.lockedStands)].sort((x, y) => x - y)), r.lastInsertRowid);
      const ins = db.prepare('INSERT INTO results (shoot_id, shooter, stand, score, pattern) VALUES (?,?,?,?,?)');
      for (const s of b.shooters) s.scores.forEach((sc, i) => ins.run(r.lastInsertRowid, s.name.trim(), i + 1, sc, s.patterns?.[i] ?? null));
      return r.lastInsertRowid;
    })();
    mailer.saveEmails(user.id, b.shooters);
    // Clients that stream live results send complete:false until the shoot ends
    if (b.complete !== false) notifyOnce(user.id, id, flags);
    res.status(201).json({ id, url: `${BASE_URL}/shoots/${encodeId(user.id, id)}` });
  } catch (e) {
    if (String(e.code).startsWith('SQLITE_CONSTRAINT')) return res.status(409).json({ error: 'duplicate_externalId' });
    throw e;
  }
});

// Each shooter's average score per stand over the last year, for handicap shoots. Only stands
// actually shot (not placeholder rows from unfinished shoots) count.
app.get('/api/v1/handicaps', pollLimiter, (req, res) => {
  const user = apiUser(req, res);
  if (!user) return;
  const period = req.query.period;
  const lastShoots = { last6shoots: 6, last3shoots: 3 }[period];
  const cutoff = new Date();
  if (period === 'all') cutoff.setTime(0);
  else if (period === '3months') cutoff.setMonth(cutoff.getMonth() - 3);
  else if (period === '1month') cutoff.setMonth(cutoff.getMonth() - 1);
  else cutoff.setFullYear(cutoff.getFullYear() - 1);
  // For "last N shoots" each shooter's own most recent N shoots count, whatever their dates.
  const rows = db.prepare(`SELECT shooter, AVG(score) AS avg, COUNT(*) AS stands FROM (
      SELECT r.shooter, r.score, s.shoot_date,
        DENSE_RANK() OVER (PARTITION BY r.shooter COLLATE NOCASE ORDER BY s.shoot_date DESC, s.id DESC) AS recency
      FROM results r JOIN shoots s ON s.id = r.shoot_id
      WHERE s.user_id = ? AND (r.pattern IS NULL OR r.pattern GLOB '*[01]*'))
    WHERE ${lastShoots ? 'recency <= ?' : 'shoot_date >= ?'}
    GROUP BY shooter COLLATE NOCASE`).all(user.id, lastShoots ?? cutoff.toISOString().slice(0, 10));
  res.set('Cache-Control', 'no-store').json({
    averages: rows.map((r) => ({ name: r.shooter, average: Math.round(r.avg * 100) / 100, stands: r.stands })),
  });
});

// Finished shoots, newest first, for the app's "previous shoots" list.
app.get('/api/v1/shoots/history', pollLimiter, (req, res) => {
  const user = apiUser(req, res);
  if (!user) return;
  const rows = db.prepare(`SELECT s.external_id AS id, s.name, s.venue, s.shoot_date AS date, s.stands, s.is_handicap AS handicap,
      (SELECT COUNT(DISTINCT r.shooter) FROM results r WHERE r.shoot_id = s.id) AS shooters
    FROM shoots s WHERE s.user_id = ? AND s.complete = 1 AND s.external_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM results r WHERE r.shoot_id = s.id)
    ORDER BY s.shoot_date DESC, s.id DESC LIMIT 60`).all(user.id);
  res.set('Cache-Control', 'no-store').json({ shoots: rows.map((r) => ({ ...r, handicap: r.handicap === 1 })) });
});

// One finished shoot with every shooter's stand scores and finishing place.
app.get('/api/v1/shoots/history/:externalId', pollLimiter, (req, res) => {
  const user = apiUser(req, res);
  if (!user) return;
  const shoot = db.prepare('SELECT * FROM shoots WHERE user_id = ? AND external_id = ?').get(user.id, String(req.params.externalId));
  if (!shoot) return res.status(404).json({ error: 'not_found' });
  const hcaps = new Map(db.prepare('SELECT shooter, handicap FROM shoot_handicaps WHERE shoot_id = ?').all(shoot.id).map((h) => [h.shooter, h.handicap]));
  const by = new Map();
  for (const r of db.prepare('SELECT shooter, stand, score, pattern FROM results WHERE shoot_id = ? ORDER BY rowid').all(shoot.id)) {
    if (!by.has(r.shooter)) by.set(r.shooter, { name: r.shooter, total: 0, scores: Array(shoot.stands).fill(0) });
    const e = by.get(r.shooter);
    e.total += r.score;
    if (r.stand >= 1 && r.stand <= shoot.stands) e.scores[r.stand - 1] = r.score;
  }
  const list = [...by.values()].map((e) => {
    const handicap = shoot.is_handicap ? (hcaps.get(e.name) ?? 0) : 0;
    return { ...e, handicap, net: e.total - handicap };
  }).sort((a, b) => b.net - a.net || a.name.localeCompare(b.name));
  let place = 0;
  list.forEach((e, i) => { if (i === 0 || e.net !== list[i - 1].net) place = i + 1; e.place = place; });
  res.set('Cache-Control', 'no-store').json({ id: shoot.external_id, name: shoot.name, venue: shoot.venue, date: shoot.shoot_date,
    stands: shoot.stands, handicap: shoot.is_handicap === 1, shooters: list });
});

// The club's current shoot: the newest one still being scored. Apps load it at startup and
// poll it so several devices can score different stands of the same shoot.
app.get('/api/v1/shoots/current', pollLimiter, (req, res) => {
  const user = apiUser(req, res);
  if (!user) return;
  const shape = (row) => {
    const tps = row.targets_per_stand;
    const by = new Map();
    const handicaps = new Map(db.prepare('SELECT shooter, handicap FROM shoot_handicaps WHERE shoot_id = ?').all(row.id).map((h) => [h.shooter, h.handicap]));
    for (const r of db.prepare('SELECT shooter, stand, score, pattern FROM results WHERE shoot_id = ? ORDER BY rowid').all(row.id)) {
      if (!by.has(r.shooter)) by.set(r.shooter, { name: r.shooter, patterns: Array(row.stands).fill('-'.repeat(tps)) });
      if (r.stand >= 1 && r.stand <= row.stands && r.pattern) by.get(r.shooter).patterns[r.stand - 1] = r.pattern;
    }
    return { externalId: row.external_id, name: row.name, venue: row.venue, date: row.shoot_date, time: row.shoot_time,
      stands: row.stands, targetsPerStand: tps, standTargets: row.stand_targets ? JSON.parse(row.stand_targets) : null, handicap: row.is_handicap === 1,
      shooters: [...by.values()].map((s) => ({ ...s, handicap: handicaps.get(s.name) ?? null })) };
  };
  const cur = db.prepare('SELECT * FROM shoots WHERE user_id = ? AND complete = 0 AND external_id IS NOT NULL ORDER BY id DESC LIMIT 1').get(user.id);
  const ext = typeof req.query.externalId === 'string' ? req.query.externalId.slice(0, 100) : null;
  const mine = ext ? (db.prepare('SELECT complete FROM shoots WHERE user_id = ? AND external_id = ?').get(user.id, ext)
    || db.prepare('SELECT s.complete FROM shoot_aliases a JOIN shoots s ON s.id = a.shoot_id WHERE a.user_id = ? AND a.alias = ?').get(user.id, ext)) : null;
  res.set('Cache-Control', 'no-store').json({
    current: cur ? shape(cur) : null,
    requested: mine ? { externalId: ext, complete: mine.complete === 1 } : null,
  });
});

// ---- Web app ----
app.use(express.urlencoded({ extended: false, limit: '10kb' }));
app.use(session({
  name: 'cs.sid',
  store: new SqliteStore({ client: db, expired: { clear: true, intervalMs: 900000 } }),
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, sameSite: 'lax', secure: SECURE, maxAge: 1000 * 60 * 60 * 8 },
}));

app.use((req, res, next) => {
  if (!req.session.csrf) req.session.csrf = crypto.randomBytes(24).toString('hex');
  res.locals.csrf = req.session.csrf;
  res.locals.user = req.session.userId
    ? db.prepare('SELECT * FROM users WHERE id = ?').get(req.session.userId) : null;
  res.locals.active = isActive(res.locals.user);
  // The most recently active shoot is shown in the header.
  res.locals.currentShoot = res.locals.user
    ? db.prepare('SELECT name FROM shoots WHERE user_id = ? ORDER BY COALESCE(updated_at, \'\') DESC, id DESC LIMIT 1').get(res.locals.user.id)?.name || null
    : null;
  // Logins are club accounts: the super admin is you, a club's own login is its admin, and a login
  // whose email is a non-admin member on that club's membership list is shown as a member.
  res.locals.userRole = null;
  if (res.locals.user) {
    const u = res.locals.user;
    const m = u.is_super === 1 ? null : db.prepare("SELECT kind, is_admin FROM roster WHERE user_id = ? AND lower(email) = lower(?) AND status = 'current' LIMIT 1").get(u.id, u.email);
    res.locals.userRole = u.is_super === 1 ? 'Super admin' : (m && m.kind === 'member' && m.is_admin !== 1 ? 'Member' : 'Admin');
  }
  // A super admin can open any club account; session.superId remembers who they really are.
  const realId = req.session.superId || req.session.userId;
  const real = realId ? (realId === req.session.userId ? res.locals.user : db.prepare('SELECT * FROM users WHERE id = ?').get(realId)) : null;
  res.locals.realSuper = !!(real && real.is_super === 1);
  res.locals.acting = !!(req.session.superId && res.locals.realSuper);
  if (req.session.superId && !res.locals.realSuper) { delete req.session.superId; }
  res.locals.when = (s) => s.shoot_date + (s.shoot_time ? ` ${s.shoot_time}` : '');
  res.locals.cpsaClasses = CPSA_CLASSES;
  res.locals.eid = (id) => encodeId(req.session.userId, id);
  res.locals.error = null;
  if (req.method === 'POST') {
    const a = Buffer.from(String(req.body?._csrf || ''));
    const b = Buffer.from(req.session.csrf);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return res.status(403).send('Invalid CSRF token');
  }
  next();
});

const authLimiter = rateLimit({ windowMs: 15 * 60_000, limit: 10, standardHeaders: true, legacyHeaders: false });
const needAuth = (req, res, next) => (res.locals.user ? next() : res.redirect('/login'));

app.get('/', (req, res) => res.render('home'));

app.get('/register', (req, res) => res.render('register'));
app.post('/register', authLimiter, wrap(async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  const club = String(req.body.club_name || '').trim();
  const pw = String(req.body.password || '');
  const estMembers = allowanceLib.parseCount(req.body.est_members, { min: 1 });
  const estGuests = allowanceLib.parseCount(req.body.est_guests);
  let error = null;
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 200) error = 'Enter a valid email.';
  else if (!club || club.length > 120) error = 'Enter your club or organiser name.';
  else if (pw.length < 12 || pw.length > 128) error = 'Password must be 12-128 characters.';
  else if (estMembers == null) error = 'Enter how many members your club expects (at least 1).';
  else if (estGuests == null) error = 'Enter how many guests you expect (0 or more).';
  else if (db.prepare('SELECT 1 FROM users WHERE email = ?').get(email)) error = 'Could not create account with those details.';
  if (error) return res.status(400).render('register', { error, form: req.body });
  const hash = await bcrypt.hash(pw, 12);
  const r = db.prepare('INSERT INTO users (email, club_name, password_hash, est_members, est_guests) VALUES (?,?,?,?,?)').run(email, club, hash, estMembers, estGuests);
  await regenerate(req);
  req.session.pending = { userId: r.lastInsertRowid, setup: true };
  res.redirect('/2fa/setup');
}));

app.get('/login', (req, res) => res.render('login'));
app.post('/login', authLimiter, wrap(async (req, res) => {
  const email = String(req.body.email || '').trim().toLowerCase();
  const u = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
  const dummy = '$2a$12$C6UzMDM.H6dfI/f/IKcEeO5pH3m6V1b3r3o8w4x7kYH2m0T1wZb1e';
  const ok = await bcrypt.compare(String(req.body.password || ''), u ? u.password_hash : dummy);
  if (!u || !ok) return res.status(401).render('login', { error: 'Invalid email or password.' });
  await regenerate(req);
  req.session.pending = { userId: u.id, setup: !u.totp_secret };
  res.redirect(u.totp_secret ? '/2fa/verify' : '/2fa/setup');
}));

app.get('/2fa/setup', wrap(async (req, res) => {
  const p = req.session.pending;
  if (!p || !p.setup) return res.redirect('/login');
  req.session.tempSecret = req.session.tempSecret || authenticator.generateSecret();
  const u = db.prepare('SELECT email FROM users WHERE id = ?').get(p.userId);
  const uri = authenticator.keyuri(u.email, 'Clay Shoots', req.session.tempSecret);
  res.render('2fa-setup', { qr: await QRCode.toDataURL(uri), secret: req.session.tempSecret });
}));
app.post('/2fa/setup', authLimiter, wrap(async (req, res) => {
  const p = req.session.pending;
  if (!p || !p.setup || !req.session.tempSecret) return res.redirect('/login');
  const code = String(req.body.code || '').replace(/\s/g, '');
  if (!authenticator.check(code, req.session.tempSecret)) {
    const u = db.prepare('SELECT email FROM users WHERE id = ?').get(p.userId);
    const uri = authenticator.keyuri(u.email, 'Clay Shoots', req.session.tempSecret);
    return res.status(400).render('2fa-setup', { error: 'Incorrect code.', qr: await QRCode.toDataURL(uri), secret: req.session.tempSecret });
  }
  db.prepare('UPDATE users SET totp_secret = ? WHERE id = ?').run(encrypt(req.session.tempSecret), p.userId);
  await regenerate(req);
  req.session.userId = p.userId;
  const fresh = db.prepare('SELECT * FROM users WHERE id = ?').get(p.userId);
  res.redirect(isActive(fresh) ? '/dashboard' : '/dashboard?pay=welcome');
}));

app.get('/2fa/verify', (req, res) => (req.session.pending && !req.session.pending.setup ? res.render('2fa-verify') : res.redirect('/login')));
app.post('/2fa/verify', authLimiter, wrap(async (req, res) => {
  const p = req.session.pending;
  if (!p || p.setup) return res.redirect('/login');
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(p.userId);
  const code = String(req.body.code || '').replace(/\s/g, '');
  if (!u || !authenticator.check(code, decrypt(u.totp_secret))) return res.status(401).render('2fa-verify', { error: 'Incorrect code.' });
  await regenerate(req);
  req.session.userId = u.id;
  res.redirect('/dashboard');
}));

app.post('/logout', (req, res) => req.session.destroy(() => { res.clearCookie('cs.sid'); res.redirect('/'); }));

function accountData(u) {
  const paymentsOn = payments.anyEnabled();
  const end = u.sub_period_end ? u.sub_period_end * 1000 : null;
  let state;
  if (!paymentsOn) state = { label: 'Active', cls: 'ok', note: 'No payment provider is configured, so every account has full access.' };
  else if (isActive(u)) state = { label: 'Active', cls: 'ok', note: `Paid until ${new Date(end).toLocaleDateString('en-GB')}.` };
  else if (end) state = { label: 'Expired', cls: 'warn', note: `Ended on ${new Date(end).toLocaleDateString('en-GB')}. Renew to keep recording shoots.` };
  else state = { label: 'Inactive', cls: 'warn', note: 'No plan yet. Choose one on the Dashboard to record shoots.' };
  const lastPayment = db.prepare("SELECT provider, plan, created_at FROM payments WHERE user_id = ? AND status = 'paid' ORDER BY id DESC LIMIT 1").get(u.id);
  const counts = db.prepare('SELECT COUNT(*) AS shoots FROM shoots WHERE user_id = ?').get(u.id);
  return { isSuper: u.is_super === 1, backups: u.is_super === 1 ? backup.list().slice(0, 15) : [], backupMsg: null, state, paymentsOn, lastPayment, counts, hasKey: !!u.api_key_hash, hasPortal: payments.hasStripePortal && !!u.stripe_customer_id };
}
app.get('/account', needAuth, (req, res) => {
  const u = res.locals.user;
  res.render('account', { msg: req.query.saved ? 'Changes saved.' : null, error: null, form: null, acct: u, ...accountData(u), backupMsg: req.query.backup || null });
});

const needRealSuper = (req, res, next) => (res.locals.realSuper ? next() : res.status(404).send('Not found'));

const SOON_DAYS = 30;
function subInfo(u) {
  if (u.is_super === 1) return { state: 'ok', label: 'Super admin', note: 'Always active', end: null };
  const end = u.sub_period_end || 0;
  const nowSec = Math.floor(Date.now() / 1000);
  if (!end || !['active', 'trialing'].includes(u.sub_status)) {
    return end && end <= nowSec ? { state: 'expired', label: 'Expired', end } : { state: 'none', label: 'No subscription', end: null };
  }
  if (end <= nowSec) return { state: 'expired', label: 'Expired', end };
  const days = Math.ceil((end - nowSec) / 86400);
  return days <= SOON_DAYS ? { state: 'soon', label: `Ends in ${days}d`, end, days } : { state: 'ok', label: 'Active', end, days };
}
app.get('/admin/clubs', needAuth, needRealSuper, (req, res) => {
  const accounts = db.prepare(`SELECT u.id, u.email, u.is_super, u.sub_status, u.sub_period_end,
      (SELECT COUNT(*) FROM shoots s WHERE s.user_id = u.id) AS shoots,
      (SELECT MAX(shoot_date) FROM shoots s WHERE s.user_id = u.id) AS last_shoot,
      (SELECT COUNT(*) FROM roster r WHERE r.user_id = u.id AND r.status = 'current') AS people,
      (SELECT COUNT(DISTINCT shooter) FROM results x JOIN shoots s ON s.id = x.shoot_id WHERE s.user_id = u.id) AS shooters,
      (SELECT kind FROM roster r WHERE r.user_id = u.id AND lower(r.email) = lower(u.email) AND r.status = 'current' LIMIT 1) AS rkind,
      (SELECT is_admin FROM roster r WHERE r.user_id = u.id AND lower(r.email) = lower(u.email) AND r.status = 'current' LIMIT 1) AS radmin,
      u.club_name FROM users u ORDER BY u.club_name COLLATE NOCASE, u.email`).all();
  const clubs = new Map();
  for (const a of accounts) {
    a.role = a.is_super === 1 ? 'Super admin' : (a.rkind === 'member' && a.radmin !== 1 ? 'Member' : 'Admin');
    if (!clubs.has(a.club_name)) clubs.set(a.club_name, { name: a.club_name, accounts: [], shoots: [] });
    clubs.get(a.club_name).accounts.push(a);
  }
  const shootsOf = db.prepare('SELECT id, name, venue, shoot_date, stands, targets_per_stand, (SELECT COUNT(DISTINCT shooter) FROM results WHERE shoot_id = shoots.id) AS shooters FROM shoots WHERE user_id = ? ORDER BY shoot_date DESC LIMIT 200');
  const shootersOf = db.prepare(`SELECT x.shooter, COUNT(DISTINCT x.shoot_id) AS shoots, SUM(x.score) AS total,
      (SELECT kind FROM roster r WHERE r.user_id = s.user_id AND r.name_key = lower(trim(x.shooter)) LIMIT 1) AS kind,
      (SELECT status FROM roster r WHERE r.user_id = s.user_id AND r.name_key = lower(trim(x.shooter)) LIMIT 1) AS status
    FROM results x JOIN shoots s ON s.id = x.shoot_id WHERE s.user_id = ? GROUP BY x.shooter ORDER BY total DESC, x.shooter`);
  for (const c of clubs.values()) {
    for (const a of c.accounts) {
      a.shootList = shootsOf.all(a.id); a.shooterList = shootersOf.all(a.id);
      a.sub = subInfo(a);
      a.payList = db.prepare("SELECT provider, plan, status, created_at FROM payments WHERE user_id = ? ORDER BY id DESC LIMIT 8").all(a.id);
      a.reminderList = reminders.recent(a.id, 8);
    }
    const order = { ok: 0, soon: 1, none: 2, expired: 3 };
    const nonSuper = c.accounts.filter((a) => a.is_super !== 1);
    c.sub = (nonSuper.length ? nonSuper : c.accounts).map((a) => a.sub).sort((x, y) => order[x.state] - order[y.state])[0];
  }
  res.render('clubs', { clubs: [...clubs.values()], note: req.query.note ? String(req.query.note).slice(0, 200) : null });
});
app.post('/admin/clubs/open', needAuth, needRealSuper, (req, res) => {
  const id = Number(req.body.id);
  const target = Number.isInteger(id) && db.prepare('SELECT id FROM users WHERE id = ?').get(id);
  if (!target) return res.redirect('/admin/clubs');
  if (!req.session.superId) req.session.superId = req.session.userId;
  req.session.userId = target.id;
  res.redirect('/dashboard');
});
app.post('/admin/clubs/subscription', needAuth, needRealSuper, wrap(async (req, res) => {
  const id = Number(req.body.id);
  const u = Number.isInteger(id) && db.prepare('SELECT * FROM users WHERE id = ? AND is_super = 0').get(id);
  if (!u) return res.redirect('/admin/clubs');
  const nowSec = Math.floor(Date.now() / 1000);
  const action = String(req.body.action || '');
  const set = (status, end) => db.prepare('UPDATE users SET sub_status = ?, sub_period_end = ? WHERE id = ?').run(status, end, u.id);
  if (action === 'extend') {
    const base = new Date(Math.max(nowSec, u.sub_status === 'active' ? u.sub_period_end || 0 : 0) * 1000);
    base.setMonth(base.getMonth() + 12);
    set('active', Math.floor(base.getTime() / 1000));
    db.prepare("INSERT INTO payments (user_id, provider, plan, provider_ref, status) VALUES (?, 'admin', 'annual', ?, 'paid')").run(u.id, `admin_${crypto.randomUUID()}`);
  } else if (action === 'expiring7') set('active', nowSec + 7 * 86400);
  else if (action === 'expire') set('active', nowSec - 86400);
  else if (action === 'clear') set('none', null);
  else if (action === 'remind') {
    const r = await reminders.sendNow(u.id);
    return res.redirect('/admin/clubs?note=' + encodeURIComponent(`Reminder to ${u.email}: ${r}`));
  }
  res.redirect('/admin/clubs?note=' + encodeURIComponent(`Subscription updated for ${u.email}.`));
}));
app.post('/admin/reminders/run', needAuth, needRealSuper, wrap(async (req, res) => {
  const n = await reminders.sweep();
  res.redirect('/admin/clubs?note=' + encodeURIComponent(`Reminder check complete: ${n} sent.`));
}));
app.post('/admin/return', needAuth, (req, res) => {
  if (req.session.superId && res.locals.realSuper) { req.session.userId = req.session.superId; delete req.session.superId; }
  res.redirect('/admin/clubs');
});

const needSuper = (req, res, next) => (res.locals.user && res.locals.user.is_super === 1 ? next() : res.status(404).send('Not found'));
const backupDone = (res, msg) => res.redirect('/account?backup=' + encodeURIComponent(msg) + '#backups');
app.post('/account/backups/run', needAuth, needSuper, (req, res) => {
  try { backupDone(res, 'Backup written: ' + backup.write()); } catch (e) { backupDone(res, 'Backup failed: ' + e.message); }
});
app.post('/account/backups/restore', needAuth, needSuper, authLimiter, wrap(async (req, res) => {
  const u = res.locals.user;
  if (!(await bcrypt.compare(String(req.body.password || ''), u.password_hash))) return backupDone(res, 'Restore cancelled: the password was wrong.');
  try {
    const safety = backup.restore(String(req.body.file || ''));
    backupDone(res, `Restored ${req.body.file}. A copy of the data before the restore was saved as ${safety}.`);
  } catch (e) { backupDone(res, 'Restore failed: ' + e.message); }
}));

app.post('/account', needAuth, authLimiter, wrap(async (req, res) => {
  const u = res.locals.user;
  const email = String(req.body.email || '').trim().toLowerCase();
  const club = String(req.body.club_name || '').trim();
  let error = null;
  if (!club || club.length > 120) error = 'Enter your club or organiser name.';
  else if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 200) error = 'Enter a valid email.';
  else if (email !== u.email) {
    if (!(await bcrypt.compare(String(req.body.password || ''), u.password_hash))) error = 'Enter your current password to change your email.';
    else if (db.prepare('SELECT 1 FROM users WHERE lower(email) = ? AND id <> ?').get(email, u.id)) error = 'That email address cannot be used.';
  }
  if (error) {
    return res.status(400).render('account', { msg: null, error, form: { email, club_name: club }, acct: u, ...(await accountData(u)) });
  }
  try {
    db.prepare('UPDATE users SET email = ?, club_name = ? WHERE id = ?').run(email, club, u.id);
  } catch (e) {
    if (!/UNIQUE/.test(e.message)) throw e;
    return res.status(400).render('account', { msg: null, error: 'That email address cannot be used.', form: { email, club_name: club }, acct: u, ...(await accountData(u)) });
  }
  res.redirect('/account?saved=1');
}));

app.get('/dashboard', needAuth, (req, res) => {
  const shoots = db.prepare(`
    SELECT s.*, COUNT(DISTINCT r.shooter) AS shooters, COALESCE(SUM(r.score),0) AS total
    FROM shoots s LEFT JOIN results r ON r.shoot_id = s.id
    WHERE s.user_id = ? GROUP BY s.id ORDER BY s.shoot_date DESC, s.shoot_time DESC, s.id DESC`).all(req.session.userId);
  const newKey = req.session.newKey; delete req.session.newKey;
  res.render('dashboard', { shoots, newKey, baseUrl: BASE_URL, payOptions: payments.options(res.locals.user), allowance: payments.allowanceInfo(res.locals.user), payMsg: req.query.msg ? String(req.query.msg).slice(0, 300) : null, payStatus: req.query.pay || null, hasPortal: payments.hasStripePortal && !!res.locals.user.stripe_customer_id });
});

// Minimum average % per class, highest first. Classified on the last 12 months, else all time.
const CPSA_CLASSES = [
  { name: 'AAA', min: 92, icon: '👑' },
  { name: 'AA', min: 85, icon: '🏆' },
  { name: 'A', min: 77, icon: '⭐' },
  { name: 'B', min: 68, icon: '🎯' },
  { name: 'C', min: 55, icon: '🔹' },
  { name: 'D', min: 0, icon: '🌱' },
];
const classify = (stats) => {
  const basis = stats.last12.avgPct != null ? stats.last12 : stats.allTime;
  if (basis.avgPct == null) return null;
  const c = CPSA_CLASSES.find((k) => basis.avgPct >= k.min);
  return { name: c.name, icon: c.icon, rank: CPSA_CLASSES.indexOf(c), basis: basis === stats.last12 ? 'last 12 months' : 'all time' };
};

// Lazily computed per-request hover stats, exposed to views as shooterAttrs(name).
app.use((req, res, next) => {
  let stats;
  res.locals.shooterAttrs = (name) => {
    if (!req.session?.userId) return '';
    if (!stats) {
      const cutoff = new Date(); cutoff.setFullYear(cutoff.getFullYear() - 1);
      const cutoffDate = cutoff.toISOString().slice(0, 10);
      const history = db.prepare(`SELECT r.shooter, s.shoot_date, SUM(r.score) AS total, COUNT(*) * s.targets_per_stand AS possible
        FROM results r JOIN shoots s ON s.id = r.shoot_id WHERE s.user_id = ? GROUP BY r.shooter, s.id`).all(req.session.userId);
      const summarise = (rows) => ({
        shoots: rows.length,
        avgScore: rows.length ? rows.reduce((n, r) => n + r.total, 0) / rows.length : null,
        avgPct: rows.length ? (100 * rows.reduce((n, r) => n + r.total, 0)) / rows.reduce((n, r) => n + r.possible, 0) : null,
      });
      stats = new Map();
      for (const shooter of new Set(history.map((h) => h.shooter))) {
        const mine = history.filter((h) => h.shooter === shooter);
        const s = { allTime: summarise(mine), last12: summarise(mine.filter((h) => h.shoot_date >= cutoffDate)) };
        s.cpsa = classify(s);
        stats.set(shooter, s);
      }
    }
    const s = stats.get(name);
    const hasEmail = db.prepare('SELECT 1 FROM shooter_emails WHERE user_id = ? AND shooter_key = ?').get(req.session.userId, String(name).trim().toLowerCase()) ? ' data-has-email="1"' : '';
    return s ? ` class="shooter-name" tabindex="0" data-name="${escapeAttr(name)}"${hasEmail} data-stats="${escapeAttr(JSON.stringify(s))}"` : '';
  };
  next();
});
const escapeAttr = (v) => String(v).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

app.get('/results', needAuth, (req, res) => {
  const shoots = db.prepare(
    'SELECT id, name, venue, shoot_date, shoot_time, updated_at FROM shoots WHERE user_id = ? ORDER BY shoot_date DESC, shoot_time DESC, id DESC'
  ).all(req.session.userId);
  let shoot = null;
  let shooters = [];
  // With no explicit choice, show whichever shoot was most recently active or updated.
  const latest = shoots.reduce((a, s) => (!a || (s.updated_at || '') > (a.updated_at || '') || ((s.updated_at || '') === (a.updated_at || '') && s.id > a.id) ? s : a), null);
  const chosen = req.query.shoot != null && req.query.shoot !== '' ? req.query.shoot : (latest ? encodeId(req.session.userId, latest.id) : null);
  if (chosen != null) {
    const shootId = decodeId(req.session.userId, chosen);
    if (shootId == null) return res.sendStatus(404);
    shoot = db.prepare('SELECT * FROM shoots WHERE id = ? AND user_id = ?').get(shootId, req.session.userId);
    if (!shoot) return res.sendStatus(404);

    const map = new Map();
    const rows = db.prepare(
      'SELECT shooter, stand, score, pattern FROM results WHERE shoot_id = ? ORDER BY shooter, stand'
    ).all(shoot.id);
    for (const row of rows) {
      if (!map.has(row.shooter)) {
        map.set(row.shooter, {
          name: row.shooter,
          scores: Array(shoot.stands).fill(null),
          patterns: Array(shoot.stands).fill(null),
          total: 0,
        });
      }
      const shooter = map.get(row.shooter);
      shooter.scores[row.stand - 1] = row.score;
      shooter.patterns[row.stand - 1] = row.pattern;
      shooter.total += row.score;
    }
    // Handicap shoots rank on the net score: the total less the shooter's handicap.
    const handicaps = new Map(db.prepare('SELECT shooter, handicap FROM shoot_handicaps WHERE shoot_id = ?').all(shoot.id).map((h) => [h.shooter, h.handicap]));
    for (const s of map.values()) { s.handicap = shoot.is_handicap ? (handicaps.get(s.name) ?? 0) : 0; s.net = s.total - s.handicap; }
    shooters = [...map.values()].sort((a, b) => b.net - a.net || a.name.localeCompare(b.name));
    // tied totals share a place
    const cutoff = new Date(); cutoff.setFullYear(cutoff.getFullYear() - 1);
    const cutoffDate = cutoff.toISOString().slice(0, 10);
    const history = db.prepare(`SELECT r.shooter, s.shoot_date, SUM(r.score) AS total, COUNT(*) * s.targets_per_stand AS possible
      FROM results r JOIN shoots s ON s.id = r.shoot_id WHERE s.user_id = ? GROUP BY r.shooter, s.id`).all(req.session.userId);
    const summarise = (rows) => ({
      shoots: rows.length,
      avgScore: rows.length ? rows.reduce((n, r) => n + r.total, 0) / rows.length : null,
      avgPct: rows.length ? (100 * rows.reduce((n, r) => n + r.total, 0)) / rows.reduce((n, r) => n + r.possible, 0) : null,
    });
    shooters.forEach((s) => {
      const mine = history.filter((h) => h.shooter === s.name);
      s.stats = { allTime: summarise(mine), last12: summarise(mine.filter((h) => h.shoot_date >= cutoffDate)) };
      s.stats.cpsa = classify(s.stats);
    });
    shooters.forEach((s) => { s.place = 1 + shooters.filter((o) => o.net > s.net).length; });
  }
  const lockedStands = shoot ? JSON.parse(shoot.locked_stands || '[]') : [];
  res.render('results', { shoots, shoot, shooters, lockedStands });
});

// Cheap change fingerprint of this user's data, polled by public/live.js
app.get('/live', needAuth, (req, res) => {
  const uid = req.session.userId;
  const s = db.prepare('SELECT COUNT(*) AS n, COALESCE(MAX(id),0) AS m, COALESCE(MAX(updated_at), \'\') AS u, COALESCE(group_concat(shoot_date || COALESCE(shoot_time, \'\') || name || COALESCE(venue, \'\') || locked_stands, \'|\'), \'\') AS d FROM shoots WHERE user_id = ?').get(uid);
  const r = db.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(r.score),0) AS t FROM results r JOIN shoots s ON s.id = r.shoot_id WHERE s.user_id = ?').get(uid);
  const ro = db.prepare("SELECT COUNT(*) AS n, COALESCE(SUM(id * (1 + (kind = 'member') + 2 * (status = 'expired') + 4 * is_admin)), 0) AS t FROM roster WHERE user_id = ?").get(uid);
  res.set('Cache-Control', 'no-store').json({ added: s.m, v: `${ro.n}:${ro.t}:${s.n}:${s.m}:${s.u}:${require('crypto').createHash('md5').update(s.d).digest('hex')}:${r.n}:${r.t}` });
});

app.get('/leaderboard', needAuth, (req, res) => {
  const cutoff = new Date(); cutoff.setFullYear(cutoff.getFullYear() - 1);
  const cutoffDate = cutoff.toISOString().slice(0, 10);
  const rows = db.prepare(`SELECT shooter, COUNT(*) AS shoots, SUM(total) AS hits, SUM(possible) AS possible FROM (
      SELECT r.shooter, SUM(r.score) AS total, COUNT(*) * s.targets_per_stand AS possible
      FROM results r JOIN shoots s ON s.id = r.shoot_id
      WHERE s.user_id = ? AND s.shoot_date >= ? GROUP BY r.shooter, s.id)
    GROUP BY shooter`).all(req.session.userId, cutoffDate);
  const totalShoots = db.prepare('SELECT COUNT(DISTINCT s.id) AS n FROM shoots s JOIN results r ON r.shoot_id = s.id WHERE s.user_id = ? AND s.shoot_date >= ?').get(req.session.userId, cutoffDate).n;
  const board = rows.map((r) => {
    const avgPct = (100 * r.hits) / r.possible;
    return { name: r.shooter, shoots: r.shoots, attendPct: totalShoots ? (100 * r.shoots) / totalShoots : 0, hits: r.hits, avgPct, cpsa: classify({ last12: { avgPct }, allTime: { avgPct } }) };
  }).sort((a, b) => b.avgPct - a.avgPct || b.shoots - a.shoots || a.name.localeCompare(b.name));
  board.forEach((s) => { s.place = 1 + board.filter((o) => o.avgPct > s.avgPct).length; });
  res.render('leaderboard', { board, since: cutoffDate });
});

app.get('/shoots/:token', needAuth, (req, res) => {
  const shootId = decodeId(req.session.userId, req.params.token);
  const shoot = shootId != null && db.prepare('SELECT * FROM shoots WHERE id = ? AND user_id = ?').get(shootId, req.session.userId);
  if (!shoot) return res.sendStatus(404);
  const rows = db.prepare('SELECT shooter, stand, score FROM results WHERE shoot_id = ?').all(shoot.id);
  const map = new Map();
  for (const r of rows) {
    if (!map.has(r.shooter)) map.set(r.shooter, { name: r.shooter, scores: Array(shoot.stands).fill(null), total: 0 });
    const s = map.get(r.shooter); s.scores[r.stand - 1] = r.score; s.total += r.score;
  }
  const hcaps = new Map(db.prepare('SELECT shooter, handicap FROM shoot_handicaps WHERE shoot_id = ?').all(shoot.id).map((h) => [h.shooter, h.handicap]));
  for (const s of map.values()) { s.handicap = shoot.is_handicap ? (hcaps.get(s.name) ?? 0) : 0; s.net = s.total - s.handicap; }
  const sort = req.query.sort === 'name' ? 'name' : 'total';
  const shooters = [...map.values()].sort((a, b) => (sort === 'name' ? a.name.localeCompare(b.name) : b.net - a.net));
  res.render('shoot', { shoot, shooters, lockedStands: JSON.parse(shoot.locked_stands || '[]'), sort, max: shoot.stands * shoot.targets_per_stand });
});

const needShootAdmin = (req, res, next) => {
  if (res.locals.user && (res.locals.user.is_super === 1 || res.locals.userRole === 'Admin')) return next();
  res.status(403).send('Only admins can delete shoots.');
};

app.post('/shoots/:token/delete', needAuth, needShootAdmin, (req, res) => {
  const shootId = decodeId(req.session.userId, req.params.token);
  if (shootId != null) db.prepare('DELETE FROM shoots WHERE id = ? AND user_id = ?').run(shootId, req.session.userId);
  res.redirect(['/results', '/dashboard'].includes(req.body.from) ? req.body.from : '/dashboard');
});

app.post('/shoots/delete-selected', needAuth, needShootAdmin, (req, res) => {
  const raw = [].concat(req.body.ids || []).slice(0, 500);
  const del = db.prepare('DELETE FROM shoots WHERE id = ? AND user_id = ?');
  db.transaction(() => {
    for (const token of raw) {
      const id = decodeId(req.session.userId, String(token));
      if (id != null) del.run(id, req.session.userId);
    }
  })();
  res.redirect(['/results', '/dashboard'].includes(req.body.from) ? req.body.from : '/dashboard');
});

app.post('/settings/api-key', needAuth, needSuper, (req, res) => {
  const key = 'cs_' + crypto.randomBytes(32).toString('hex');
  db.prepare('UPDATE users SET api_key_hash = ? WHERE id = ?').run(hashKey(key), req.session.userId);
  req.session.newKey = key;
  res.redirect('/dashboard');
});

app.use('/billing', payments.billing);
app.use('/social', social.router);
app.get('/verify-email/:token', rateLimit({ windowMs: 15 * 60_000, limit: 30, standardHeaders: true, legacyHeaders: false }), (req, res) => {
  const r = roster.verifyToken(req.params.token);
  res.status(r ? 200 : 400).render('verify', { ok: !!r, name: r ? r.name : null, club: r ? db.prepare('SELECT club_name FROM users WHERE id = ?').get(r.user_id)?.club_name : null });
});
app.use('/shooters/roster', roster.router);
app.use('/shooters', needAuth, (req, res, next) => { res.locals.roster = roster.listAll(req.session.userId); res.locals.allowance = payments.allowanceInfo(res.locals.user); next(); }, mailer.router);

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).send('Something went wrong.');
});

const port = process.env.PORT || 3000;
if (tlsConfig) {
  require('https').createServer({ cert: tlsConfig.cert, key: tlsConfig.key, minVersion: 'TLSv1.2', honorCipherOrder: true,
    // Classic curves only: Apple's hybrid post-quantum key share makes this Node build abort the handshake.
    ecdhCurve: 'X25519:prime256v1:secp384r1' }, app)
    .listen(port, () => {
      console.log(`Clay Shoots running securely on ${BASE_URL}`);
      if (tlsConfig.fingerprint) console.log(`Server key fingerprint (enter this in the phone app): ${tlsConfig.fingerprint}`);
    });
} else {
  app.listen(port, () => console.log(`Clay Shoots running on ${BASE_URL} (NOT encrypted)`));
}
