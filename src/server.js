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
  u && (!payments.anyEnabled() || ['active', 'trialing'].includes(u.sub_status) && (u.sub_period_end || 0) * 1000 > Date.now());
const regenerate = (req) => new Promise((res, rej) => req.session.regenerate((e) => (e ? rej(e) : res())));
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

const app = express();
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, '..', 'views'));
app.set('trust proxy', 1);
// Over plain http (local network testing) the default upgrade-insecure-requests and HSTS break CSS/JS.
app.use(helmet(PROD ? {} : {
  contentSecurityPolicy: { directives: { ...helmet.contentSecurityPolicy.getDefaultDirectives(), 'upgrade-insecure-requests': null } },
  strictTransportSecurity: false,
}));
app.use(express.static(path.join(__dirname, '..', 'public')));

const payments = require('./payments')({ db, baseUrl: BASE_URL, needAuth: (q, s, n) => needAuth(q, s, n), wrap });
app.use('/webhook', payments.webhooks);
const mailer = require('./mailer')({ db, classify: (s) => classify(s), needAuth: (q, r, n) => needAuth(q, r, n), wrap });
const roster = require('./roster')({ db, needAuth: (q, r, n) => needAuth(q, r, n), mailer, baseUrl: BASE_URL, wrap });
const backup = require('./backup')({ db, dir: path.join(__dirname, '..', 'data', 'backups') });
if (process.env.DB_IN_MEMORY !== '1') backup.schedule();
const social = require('./social')({ db, encrypt, decrypt, needAuth: (q, r, n) => needAuth(q, r, n), wrap });

// ---- JSON API for the iPhone app (bearer key, no cookies/CSRF) ----
const apiLimiter = rateLimit({ windowMs: 60_000, limit: 60, standardHeaders: true, legacyHeaders: false });
app.get('/api/v1/ping', apiLimiter, (req, res) => {
  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization || '');
  const user = m && db.prepare('SELECT * FROM users WHERE api_key_hash = ?').get(hashKey(m[1]));
  if (!user) return res.status(401).json({ error: 'invalid_api_key' });
  if (!isActive(user)) return res.status(402).json({ error: 'subscription_required' });
  res.json({ ok: true, club: user.club_name });
});
// Roster of registered shooters for the club that owns the API key.
const apiUser = (req, res) => {
  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization || '');
  const user = m && db.prepare('SELECT * FROM users WHERE api_key_hash = ?').get(hashKey(m[1]));
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
app.post('/api/v1/shoots', apiLimiter, express.json({ limit: '1mb' }), (req, res) => {
  const m = /^Bearer (.+)$/.exec(req.headers.authorization || '');
  const user = m && db.prepare('SELECT * FROM users WHERE api_key_hash = ?').get(hashKey(m[1]));
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
  if (!Array.isArray(b.shooters) || b.shooters.length < 1 || b.shooters.length > 500) errors.push('shooters must be an array of 1-500');
  else {
    const seen = new Set();
    b.shooters.forEach((s, i) => {
      if (!s || !str(s.name, 80)) return errors.push(`shooters[${i}].name required`);
      if (seen.has(s.name.trim().toLowerCase())) errors.push(`shooters[${i}] duplicate name`);
      seen.add(s.name.trim().toLowerCase());
      if (!Array.isArray(s.scores) || s.scores.length !== b.stands ||
          !s.scores.every((x) => Number.isInteger(x) && x >= 0 && x <= tps))
        errors.push(`shooters[${i}].scores must be ${b.stands} integers between 0 and ${tps}`);
    });
  }
  if (errors.length) return res.status(400).json({ error: 'validation_failed', details: errors });

  try {
    const existing = b.externalId != null
      ? db.prepare('SELECT id FROM shoots WHERE user_id = ? AND external_id = ?').get(user.id, b.externalId) : null;
    if (existing) {
      db.transaction(() => {
        db.prepare('UPDATE shoots SET name = ?, venue = ?, shoot_date = ?, shoot_time = ?, stands = ?, targets_per_stand = ? WHERE id = ?')
          .run(b.name.trim(), b.venue?.trim() ?? null, b.date, b.time ?? null, b.stands, tps, existing.id);
        db.prepare('DELETE FROM results WHERE shoot_id = ?').run(existing.id);
        const ins = db.prepare('INSERT INTO results (shoot_id, shooter, stand, score) VALUES (?,?,?,?)');
        for (const s of b.shooters) s.scores.forEach((sc, i) => ins.run(existing.id, s.name.trim(), i + 1, sc));
      })();
      mailer.saveEmails(user.id, b.shooters);
      if (b.complete === true) notifyOnce(user.id, existing.id, flags);
      return res.status(201).json({ id: existing.id, updated: true, url: `${BASE_URL}/shoots/${encodeId(user.id, existing.id)}` });
    }
    const id = db.transaction(() => {
      const r = db.prepare(
        'INSERT INTO shoots (user_id, external_id, name, venue, shoot_date, shoot_time, stands, targets_per_stand) VALUES (?,?,?,?,?,?,?,?)'
      ).run(user.id, b.externalId ?? null, b.name.trim(), b.venue?.trim() ?? null, b.date, b.time ?? null, b.stands, tps);
      const ins = db.prepare('INSERT INTO results (shoot_id, shooter, stand, score) VALUES (?,?,?,?)');
      for (const s of b.shooters) s.scores.forEach((sc, i) => ins.run(r.lastInsertRowid, s.name.trim(), i + 1, sc));
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

// ---- Web app ----
app.use(express.urlencoded({ extended: false, limit: '10kb' }));
app.use(session({
  name: 'cs.sid',
  store: new SqliteStore({ client: db, expired: { clear: true, intervalMs: 900000 } }),
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { httpOnly: true, sameSite: 'lax', secure: PROD, maxAge: 1000 * 60 * 60 * 8 },
}));

app.use((req, res, next) => {
  if (!req.session.csrf) req.session.csrf = crypto.randomBytes(24).toString('hex');
  res.locals.csrf = req.session.csrf;
  res.locals.user = req.session.userId
    ? db.prepare('SELECT * FROM users WHERE id = ?').get(req.session.userId) : null;
  res.locals.active = isActive(res.locals.user);
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
  let error = null;
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 200) error = 'Enter a valid email.';
  else if (!club || club.length > 120) error = 'Enter your club or organiser name.';
  else if (pw.length < 12 || pw.length > 128) error = 'Password must be 12-128 characters.';
  else if (db.prepare('SELECT 1 FROM users WHERE email = ?').get(email)) error = 'Could not create account with those details.';
  if (error) return res.status(400).render('register', { error });
  const hash = await bcrypt.hash(pw, 12);
  const r = db.prepare('INSERT INTO users (email, club_name, password_hash) VALUES (?,?,?)').run(email, club, hash);
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
  res.redirect('/dashboard');
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
  res.render('dashboard', { shoots, newKey, baseUrl: BASE_URL, payOptions: payments.options(), payStatus: req.query.pay || null, hasPortal: payments.hasStripePortal && !!res.locals.user.stripe_customer_id });
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
    'SELECT id, name, venue, shoot_date, shoot_time FROM shoots WHERE user_id = ? ORDER BY shoot_date DESC, shoot_time DESC, id DESC'
  ).all(req.session.userId);
  let shoot = null;
  let shooters = [];
  if (req.query.shoot != null) {
    const shootId = decodeId(req.session.userId, req.query.shoot);
    if (shootId == null) return res.sendStatus(404);
    shoot = db.prepare('SELECT * FROM shoots WHERE id = ? AND user_id = ?').get(shootId, req.session.userId);
    if (!shoot) return res.sendStatus(404);

    const map = new Map();
    const rows = db.prepare(
      'SELECT shooter, stand, score FROM results WHERE shoot_id = ? ORDER BY shooter, stand'
    ).all(shoot.id);
    for (const row of rows) {
      if (!map.has(row.shooter)) {
        map.set(row.shooter, {
          name: row.shooter,
          scores: Array(shoot.stands).fill(null),
          total: 0,
        });
      }
      const shooter = map.get(row.shooter);
      shooter.scores[row.stand - 1] = row.score;
      shooter.total += row.score;
    }
    shooters = [...map.values()].sort((a, b) => b.total - a.total || a.name.localeCompare(b.name));
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
    shooters.forEach((s) => { s.place = 1 + shooters.filter((o) => o.total > s.total).length; });
  }
  res.render('results', { shoots, shoot, shooters });
});

// Cheap change fingerprint of this user's data, polled by public/live.js
app.get('/live', needAuth, (req, res) => {
  const uid = req.session.userId;
  const s = db.prepare('SELECT COUNT(*) AS n, COALESCE(MAX(id),0) AS m, COALESCE(group_concat(shoot_date || COALESCE(shoot_time, \'\') || name || COALESCE(venue, \'\'), \'|\'), \'\') AS d FROM shoots WHERE user_id = ?').get(uid);
  const r = db.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(r.score),0) AS t FROM results r JOIN shoots s ON s.id = r.shoot_id WHERE s.user_id = ?').get(uid);
  const ro = db.prepare("SELECT COUNT(*) AS n, COALESCE(SUM(id * (1 + (kind = 'member') + 2 * (status = 'expired') + 4 * is_admin)), 0) AS t FROM roster WHERE user_id = ?").get(uid);
  res.set('Cache-Control', 'no-store').json({ v: `${ro.n}:${ro.t}:${s.n}:${s.m}:${require('crypto').createHash('md5').update(s.d).digest('hex')}:${r.n}:${r.t}` });
});

app.get('/leaderboard', needAuth, (req, res) => {
  const cutoff = new Date(); cutoff.setFullYear(cutoff.getFullYear() - 1);
  const cutoffDate = cutoff.toISOString().slice(0, 10);
  const rows = db.prepare(`SELECT shooter, COUNT(*) AS shoots, SUM(total) AS hits, SUM(possible) AS possible FROM (
      SELECT r.shooter, SUM(r.score) AS total, COUNT(*) * s.targets_per_stand AS possible
      FROM results r JOIN shoots s ON s.id = r.shoot_id
      WHERE s.user_id = ? AND s.shoot_date >= ? GROUP BY r.shooter, s.id)
    GROUP BY shooter`).all(req.session.userId, cutoffDate);
  const board = rows.map((r) => {
    const avgPct = (100 * r.hits) / r.possible;
    return { name: r.shooter, shoots: r.shoots, hits: r.hits, avgPct, cpsa: classify({ last12: { avgPct }, allTime: { avgPct } }) };
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
  const sort = req.query.sort === 'name' ? 'name' : 'total';
  const shooters = [...map.values()].sort((a, b) => (sort === 'name' ? a.name.localeCompare(b.name) : b.total - a.total));
  res.render('shoot', { shoot, shooters, sort, max: shoot.stands * shoot.targets_per_stand });
});

app.post('/shoots/:token/delete', needAuth, (req, res) => {
  const shootId = decodeId(req.session.userId, req.params.token);
  if (shootId != null) db.prepare('DELETE FROM shoots WHERE id = ? AND user_id = ?').run(shootId, req.session.userId);
  res.redirect(['/results', '/dashboard'].includes(req.body.from) ? req.body.from : '/dashboard');
});

app.post('/settings/api-key', needAuth, (req, res) => {
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
app.use('/shooters', needAuth, (req, res, next) => { res.locals.roster = roster.listAll(req.session.userId); next(); }, mailer.router);

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).send('Something went wrong.');
});

app.listen(process.env.PORT || 3000, () => console.log(`Clay Shoots running on ${BASE_URL}`));
