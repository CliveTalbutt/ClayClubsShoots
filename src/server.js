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
const stripe = process.env.STRIPE_SECRET_KEY ? require('stripe')(process.env.STRIPE_SECRET_KEY) : null;
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
// With no Stripe key configured there is nothing to subscribe to, so every account is active.
const isActive = (u) =>
  u && (!stripe || ['active', 'trialing'].includes(u.sub_status) && (u.sub_period_end || 0) * 1000 > Date.now());
const regenerate = (req) => new Promise((res, rej) => req.session.regenerate((e) => (e ? rej(e) : res())));
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

const app = express();
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, '..', 'views'));
app.set('trust proxy', 1);
app.use(helmet());
app.use(express.static(path.join(__dirname, '..', 'public')));

// ---- Stripe webhook (raw body, before JSON parsing) ----
function syncSubscription(sub) {
  const end = sub.current_period_end || sub.items?.data?.[0]?.current_period_end || null;
  db.prepare('UPDATE users SET sub_status = ?, sub_period_end = ? WHERE stripe_customer_id = ?')
    .run(sub.status, end, sub.customer);
}
app.post('/webhook/stripe', express.raw({ type: 'application/json' }), wrap(async (req, res) => {
  if (!stripe || !process.env.STRIPE_WEBHOOK_SECRET) return res.sendStatus(503);
  let event;
  try {
    event = stripe.webhooks.constructEvent(req.body, req.headers['stripe-signature'], process.env.STRIPE_WEBHOOK_SECRET);
  } catch { return res.sendStatus(400); }
  if (event.type === 'checkout.session.completed' && event.data.object.subscription) {
    syncSubscription(await stripe.subscriptions.retrieve(event.data.object.subscription));
  } else if (event.type.startsWith('customer.subscription.')) {
    syncSubscription(event.data.object);
  }
  res.sendStatus(200);
}));

// ---- JSON API for the iPhone app (bearer key, no cookies/CSRF) ----
const apiLimiter = rateLimit({ windowMs: 60_000, limit: 60, standardHeaders: true, legacyHeaders: false });
app.get('/api/v1/ping', apiLimiter, (req, res) => {
  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.authorization || '');
  const user = m && db.prepare('SELECT * FROM users WHERE api_key_hash = ?').get(hashKey(m[1]));
  if (!user) return res.status(401).json({ error: 'invalid_api_key' });
  if (!isActive(user)) return res.status(402).json({ error: 'subscription_required' });
  res.json({ ok: true, club: user.club_name });
});
app.post('/api/v1/shoots', apiLimiter, express.json({ limit: '1mb' }), (req, res) => {
  const m = /^Bearer (.+)$/.exec(req.headers.authorization || '');
  const user = m && db.prepare('SELECT * FROM users WHERE api_key_hash = ?').get(hashKey(m[1]));
  if (!user) return res.status(401).json({ error: 'invalid_api_key' });
  if (!isActive(user)) return res.status(402).json({ error: 'subscription_required' });

  const b = req.body || {};
  const errors = [];
  const str = (v, max) => typeof v === 'string' && v.trim().length > 0 && v.length <= max;
  if (!str(b.name, 120)) errors.push('name required');
  if (b.venue != null && !str(b.venue, 120)) errors.push('venue invalid');
  if (typeof b.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(b.date) || isNaN(Date.parse(b.date))) errors.push('date must be YYYY-MM-DD');
  if (!Number.isInteger(b.stands) || b.stands < 1 || b.stands > 20) errors.push('stands must be an integer 1-20');
  const tps = b.targetsPerStand ?? 10;
  if (!Number.isInteger(tps) || tps < 1 || tps > 100) errors.push('targetsPerStand must be an integer 1-100');
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
    const id = db.transaction(() => {
      const r = db.prepare(
        'INSERT INTO shoots (user_id, external_id, name, venue, shoot_date, stands, targets_per_stand) VALUES (?,?,?,?,?,?,?)'
      ).run(user.id, b.externalId ?? null, b.name.trim(), b.venue?.trim() ?? null, b.date, b.stands, tps);
      const ins = db.prepare('INSERT INTO results (shoot_id, shooter, stand, score) VALUES (?,?,?,?)');
      for (const s of b.shooters) s.scores.forEach((sc, i) => ins.run(r.lastInsertRowid, s.name.trim(), i + 1, sc));
      return r.lastInsertRowid;
    })();
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

app.get('/dashboard', needAuth, (req, res) => {
  const shoots = db.prepare(`
    SELECT s.*, COUNT(DISTINCT r.shooter) AS shooters, COALESCE(SUM(r.score),0) AS total
    FROM shoots s LEFT JOIN results r ON r.shoot_id = s.id
    WHERE s.user_id = ? GROUP BY s.id ORDER BY s.shoot_date DESC, s.id DESC`).all(req.session.userId);
  const newKey = req.session.newKey; delete req.session.newKey;
  res.render('dashboard', { shoots, newKey, baseUrl: BASE_URL });
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

app.get('/results', needAuth, (req, res) => {
  const shoots = db.prepare(
    'SELECT id, name, venue, shoot_date FROM shoots WHERE user_id = ? ORDER BY shoot_date DESC, id DESC'
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
    const history = db.prepare(`SELECT r.shooter, s.shoot_date, SUM(r.score) AS total, s.stands * s.targets_per_stand AS possible
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
  res.redirect('/dashboard');
});

app.get('/compare', needAuth, (req, res) => {
  const all = db.prepare('SELECT id, name, shoot_date, targets_per_stand, stands FROM shoots WHERE user_id = ? ORDER BY shoot_date, id').all(req.session.userId);
  let ids = [].concat(req.query.ids || []).map((t) => decodeId(req.session.userId, t)).filter(Number.isInteger);
  const owned = new Set(all.map((s) => s.id));
  ids = ids.filter((i) => owned.has(i));
  if (!req.query.ids && all.length) ids = all.map((s) => s.id);
  const selected = all.filter((s) => ids.includes(s.id));
  const map = new Map();
  if (selected.length) {
    const rows = db.prepare(`SELECT shoot_id, shooter, SUM(score) AS total FROM results
      WHERE shoot_id IN (${selected.map(() => '?').join(',')}) GROUP BY shoot_id, shooter`).all(...selected.map((s) => s.id));
    const byId = new Map(selected.map((s) => [s.id, s]));
    for (const r of rows) {
      if (!map.has(r.shooter)) map.set(r.shooter, { name: r.shooter, per: {}, total: 0, possible: 0 });
      const s = map.get(r.shooter), sh = byId.get(r.shoot_id);
      s.per[r.shoot_id] = r.total; s.total += r.total; s.possible += sh.stands * sh.targets_per_stand;
    }
  }
  const shootBySortKey = new Map(all.map((shoot) => [`shoot-${encodeId(req.session.userId, shoot.id)}`, shoot.id]));
  const allowedSortKeys = new Set(['name', 'total', 'pct', ...shootBySortKey.keys()]);
  const requestedSort = [].concat(req.query.sort || []).filter((value) => typeof value === 'string');
  let sortOrder;
  if (!requestedSort.length) {
    sortOrder = [{ key: 'pct', direction: 'desc' }];
  } else if (requestedSort.includes('none')) {
    sortOrder = [];
  } else {
    sortOrder = requestedSort.flatMap((value) => {
      if (['name', 'total', 'pct'].includes(value)) {
        return [{ key: value, direction: value === 'name' ? 'asc' : 'desc' }];
      }
      const match = /^(name|total|pct|shoot-[\w-]+):(asc|desc)$/.exec(value);
      return match && allowedSortKeys.has(match[1])
        ? [{ key: match[1], direction: match[2] }]
        : [];
    }).filter((sort, index, sorts) => sorts.findIndex((item) => item.key === sort.key) === index);
  }
  const shooters = [...map.values()].map((s) => ({ ...s, pct: s.possible ? (100 * s.total) / s.possible : 0 }));
  shooters.sort((a, b) => {
    for (const { key, direction } of sortOrder) {
      const aValue = shootBySortKey.has(key) ? a.per[shootBySortKey.get(key)] : a[key];
      const bValue = shootBySortKey.has(key) ? b.per[shootBySortKey.get(key)] : b[key];
      if (aValue == null || bValue == null) {
        if (aValue !== bValue) return aValue == null ? 1 : -1;
        continue;
      }
      const result = typeof aValue === 'string' ? aValue.localeCompare(bValue) : aValue - bValue;
      if (result) return direction === 'asc' ? result : -result;
    }
    return 0;
  });
  res.render('compare', { all, selected, shooters, sortOrder, ids });
});

app.post('/settings/api-key', needAuth, (req, res) => {
  const key = 'cs_' + crypto.randomBytes(32).toString('hex');
  db.prepare('UPDATE users SET api_key_hash = ? WHERE id = ?').run(hashKey(key), req.session.userId);
  req.session.newKey = key;
  res.redirect('/dashboard');
});

app.post('/billing/checkout', needAuth, wrap(async (req, res) => {
  if (!stripe || !process.env.STRIPE_PRICE_ID) return res.status(503).send('Billing not configured');
  const u = res.locals.user;
  let customer = u.stripe_customer_id;
  if (!customer) {
    customer = (await stripe.customers.create({ email: u.email, name: u.club_name, metadata: { user_id: String(u.id) } })).id;
    db.prepare('UPDATE users SET stripe_customer_id = ? WHERE id = ?').run(customer, u.id);
  }
  const s = await stripe.checkout.sessions.create({
    mode: 'subscription', customer,
    line_items: [{ price: process.env.STRIPE_PRICE_ID, quantity: 1 }],
    success_url: `${BASE_URL}/dashboard`, cancel_url: `${BASE_URL}/dashboard`,
  });
  res.redirect(303, s.url);
}));
app.post('/billing/portal', needAuth, wrap(async (req, res) => {
  const u = res.locals.user;
  if (!stripe || !u.stripe_customer_id) return res.redirect('/dashboard');
  const s = await stripe.billingPortal.sessions.create({ customer: u.stripe_customer_id, return_url: `${BASE_URL}/dashboard` });
  res.redirect(303, s.url);
}));

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).send('Something went wrong.');
});

app.listen(process.env.PORT || 3000, () => console.log(`Clay Shoots running on ${BASE_URL}`));
