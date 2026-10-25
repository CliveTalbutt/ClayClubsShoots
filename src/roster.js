// Per-club roster of registered shooters: members and guests, current or expired.
const express = require('express');

const NAME_RE = /^[\p{L}][\p{L}'’. -]{0,59}$/u;

const cleanName = (raw) => String(raw || '').trim().replace(/\s+/g, ' ')
  .toLowerCase().replace(/(^|[\s'’-])(\p{L})/gu, (m, p, c) => p + c.toUpperCase());

module.exports = function createRoster({ db, needAuth, mailer }) {
  const key = (n) => String(n).trim().toLowerCase();

  function validate(body) {
    const name = cleanName(body && body.name);
    const email = String((body && body.email) || '').trim().toLowerCase();
    const errors = [];
    if (!NAME_RE.test(name)) errors.push('name must be 1-60 letters');
    if (!mailer.validEmail(email)) errors.push('a valid email address is required');
    return { name, email, errors };
  }

  const present = (r) => ({ id: r.id, name: r.name, email: r.email, kind: r.kind });

  // What the app shows: guests and current members only.
  function listCurrent(userId) {
    return db.prepare("SELECT * FROM roster WHERE user_id = ? AND status = 'current' ORDER BY name COLLATE NOCASE, email").all(userId).map(present);
  }

  function listAll(userId) {
    return db.prepare('SELECT * FROM roster WHERE user_id = ? ORDER BY status, name COLLATE NOCASE, email').all(userId);
  }

  // Adds a shooter to this club's roster only; the same person may exist in other clubs.
  function add(userId, body, kind = 'guest') {
    const { name, email, errors } = validate(body);
    if (errors.length) return { status: 400, body: { error: 'validation', details: errors } };
    const existing = db.prepare('SELECT * FROM roster WHERE user_id = ? AND name_key = ? AND email = ?').get(userId, key(name), email);
    if (existing) {
      if (existing.status === 'expired') {
        return { status: 409, body: { error: 'membership_expired', details: ['That shooter\'s membership has expired. Renew it on the website first.'] } };
      }
      return { status: 200, body: { shooter: present(existing), existing: true } };
    }
    const r = db.prepare('INSERT INTO roster (user_id, name, name_key, email, kind) VALUES (?,?,?,?,?)').run(userId, name, key(name), email, kind);
    mailer.saveEmails(userId, [{ name, email }]);
    return { status: 201, body: { shooter: present(db.prepare('SELECT * FROM roster WHERE id = ?').get(r.lastInsertRowid)) } };
  }

  const router = express.Router();
  const back = (res, msg, err) => res.redirect('/shooters?' + (err ? 'err=' : 'msg=') + encodeURIComponent(err || msg) + '#roster');
  const mine = (req) => db.prepare('SELECT * FROM roster WHERE id = ? AND user_id = ?').get(Number(req.params.id) || 0, req.session.userId);

  router.post('/add', needAuth, (req, res) => {
    const kind = req.body.kind === 'member' ? 'member' : 'guest';
    const r = add(req.session.userId, req.body, kind);
    if (r.status === 201) return back(res, `Added ${r.body.shooter.name} as a ${kind}.`);
    if (r.status === 200) return back(res, null, 'That shooter is already on the roster.');
    back(res, null, (r.body.details || ['Could not add shooter.']).join('; '));
  });

  router.post('/:id/kind', needAuth, (req, res) => {
    const r = mine(req);
    if (!r) return back(res, null, 'Unknown shooter.');
    const kind = req.body.kind === 'member' ? 'member' : 'guest';
    db.prepare('UPDATE roster SET kind = ? WHERE id = ?').run(kind, r.id);
    back(res, `${r.name} is now a ${kind}.`);
  });

  router.post('/:id/status', needAuth, (req, res) => {
    const r = mine(req);
    if (!r) return back(res, null, 'Unknown shooter.');
    const status = req.body.status === 'expired' ? 'expired' : 'current';
    db.prepare('UPDATE roster SET status = ? WHERE id = ?').run(status, r.id);
    back(res, status === 'expired' ? `${r.name}'s membership is marked expired. Past results are kept.` : `${r.name} is current again.`);
  });

  router.post('/:id/delete', needAuth, (req, res) => {
    const r = mine(req);
    if (!r) return back(res, null, 'Unknown shooter.');
    db.prepare('DELETE FROM roster WHERE id = ?').run(r.id);
    back(res, `Removed ${r.name} from the roster. Past results are kept.`);
  });

  return { router, add, listCurrent, listAll };
};
