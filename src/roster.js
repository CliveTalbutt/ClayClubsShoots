// Per-club roster of registered shooters: members and guests, current or expired.
const crypto = require('crypto');
const express = require('express');

const sha = (t) => crypto.createHash('sha256').update(t).digest('hex');
const TOKEN_DAYS = 7;
const RESEND_MINUTES = 5;
const esc = (v) => String(v).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const NAME_RE = /^[\p{L}][\p{L}'’. -]{0,59}$/u;

const cleanName = (raw) => String(raw || '').trim().replace(/\s+/g, ' ')
  .toLowerCase().replace(/(^|[\s'’-])(\p{L})/gu, (m, p, c) => p + c.toUpperCase());

module.exports = function createRoster({ db, needAuth, mailer, baseUrl, wrap }) {
  const key = (n) => String(n).trim().toLowerCase();

  function validate(body) {
    const name = cleanName(body && body.name);
    const email = String((body && body.email) || '').trim().toLowerCase();
    const errors = [];
    if (!NAME_RE.test(name)) errors.push('name must be 1-60 letters');
    if (!mailer.validEmail(email)) errors.push('a valid email address is required');
    return { name, email, errors };
  }

  const present = (r) => ({ id: r.id, guid: r.guid, name: r.name, email: r.email, kind: r.kind, isAdmin: r.is_admin === 1, verified: !!r.email_verified_at });

  // What the app shows: guests and current members only.
  function listCurrent(userId) {
    return db.prepare("SELECT * FROM roster WHERE user_id = ? AND status = 'current' ORDER BY name COLLATE NOCASE, email").all(userId).map(present);
  }

  function listAll(userId) {
    return db.prepare('SELECT * FROM roster WHERE user_id = ? ORDER BY status, name COLLATE NOCASE, email').all(userId);
  }

  // Adds a shooter to this club's roster only; the same person may exist in other clubs.
  function add(userId, body, kind = 'guest', admin = false) {
    const { name, email, errors } = validate(body);
    if (errors.length) return { status: 400, body: { error: 'validation', details: errors } };
    const existing = db.prepare('SELECT * FROM roster WHERE user_id = ? AND name_key = ? AND email = ?').get(userId, key(name), email);
    if (existing) {
      if (existing.status === 'expired') {
        return { status: 409, body: { error: 'membership_expired', details: ['That shooter\'s membership has expired. Renew it on the website first.'] } };
      }
      return { status: 200, body: { shooter: present(existing), existing: true } };
    }
    const r = db.prepare('INSERT INTO roster (user_id, name, name_key, email, kind, is_admin, guid) VALUES (?,?,?,?,?,?,?)').run(userId, name, key(name), email, kind, kind === 'member' && admin ? 1 : 0, crypto.randomUUID());
    mailer.saveEmails(userId, [{ name, email }]);
    return { status: 201, body: { shooter: present(db.prepare('SELECT * FROM roster WHERE id = ?').get(r.lastInsertRowid)) } };
  }

  // Emails the shooter a link to confirm the address belongs to them.
  async function sendVerification(userId, id) {
    const r = db.prepare('SELECT * FROM roster WHERE id = ? AND user_id = ?').get(id, userId);
    if (!r) return { ok: false, message: 'Unknown shooter.' };
    if (r.email_verified_at) return { ok: false, message: 'Already verified.' };
    if (r.verify_sent_at && Date.now() - Date.parse(r.verify_sent_at + 'Z') < RESEND_MINUTES * 60e3) {
      return { ok: false, message: `A verification email was sent less than ${RESEND_MINUTES} minutes ago.` };
    }
    const token = crypto.randomBytes(32).toString('hex');
    const club = db.prepare('SELECT club_name FROM users WHERE id = ?').get(userId)?.club_name || 'Clay Shoots';
    const link = `${baseUrl}/verify-email/${token}`;
    try {
      await mailer.sendRaw(r.email, {
        subject: `Please confirm your email address for ${club}`,
        text: `Hi ${r.name},\n\n${club} would like to send you your shoot results by email. Please confirm this is your address:\n\n${link}\n\nThe link works for ${TOKEN_DAYS} days. If you did not expect this, ignore this message.`,
        html: `<div style="font-family:-apple-system,Segoe UI,Arial,sans-serif;max-width:560px;margin:auto;color:#1f2937"><h2>Confirm your email</h2><p>Hi ${esc(r.name)}, ${esc(club)} would like to send you your shoot results by email.</p><p><a href="${esc(link)}" style="background:#16a34a;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none;font-weight:600">Confirm my email address</a></p><p style="color:#6b7280;font-size:12px">The link works for ${TOKEN_DAYS} days. If you did not expect this, ignore this message.</p></div>`,
      });
    } catch (e) {
      return { ok: false, message: e.code === 'not_configured' ? 'Outgoing email is not set up yet (SMTP settings in .env).' : 'The email could not be sent.' };
    }
    db.prepare("UPDATE roster SET verify_token_hash = ?, verify_sent_at = datetime('now') WHERE id = ?").run(sha(token), r.id);
    return { ok: true, message: `Verification email sent to ${r.email}.` };
  }

  // Public: followed from the email. Matching the token proves control of the mailbox.
  function verifyToken(token) {
    if (!/^[0-9a-f]{64}$/.test(String(token))) return null;
    const r = db.prepare('SELECT * FROM roster WHERE verify_token_hash = ?').get(sha(token));
    if (!r) return null;
    if (r.email_verified_at) return r;
    if (Date.now() - Date.parse(r.verify_sent_at + 'Z') > TOKEN_DAYS * 86400e3) return null;
    db.prepare("UPDATE roster SET email_verified_at = datetime('now'), verify_token_hash = NULL WHERE id = ?").run(r.id);
    return db.prepare('SELECT * FROM roster WHERE id = ?').get(r.id);
  }

  const router = express.Router();
  const back = (res, msg, err) => res.redirect('/shooters?' + (err ? 'err=' : 'msg=') + encodeURIComponent(err || msg) + '#roster');
  const mine = (req) => db.prepare('SELECT * FROM roster WHERE id = ? AND user_id = ?').get(Number(req.params.id) || 0, req.session.userId);

  router.post('/add', needAuth, (req, res) => {
    const admin = req.body.kind === 'admin';
    const kind = admin || req.body.kind === 'member' ? 'member' : 'guest';
    const r = add(req.session.userId, req.body, kind, admin);
    if (r.status === 201) sendVerification(req.session.userId, r.body.shooter.id).catch(() => {});
    if (r.status === 201) return back(res, `Added ${r.body.shooter.name} as ${admin ? 'an admin member' : 'a ' + kind}.`);
    if (r.status === 200) return back(res, null, 'That shooter is already in the membership.');
    back(res, null, (r.body.details || ['Could not add shooter.']).join('; '));
  });

  // Edits every detail of one roster entry. Identity is the guid, so a rename is carried through to the
  // shoot results and saved email for that club instead of orphaning them.
  router.post('/:id/edit', needAuth, (req, res) => {
    const uid = req.session.userId;
    const r = mine(req);
    if (!r) return back(res, null, 'Unknown shooter.');
    const { name, email, errors } = validate(req.body);
    if (errors.length) return back(res, null, errors.join('; '));
    const admin = req.body.kind === 'admin';
    const kind = admin || req.body.kind === 'member' ? 'member' : 'guest';
    const status = req.body.status === 'expired' ? 'expired' : 'current';
    const nk = key(name);
    if (db.prepare('SELECT 1 FROM roster WHERE user_id = ? AND id != ? AND (name_key = ? AND (email = ? OR ? != ?))').get(uid, r.id, nk, email, nk, r.name_key)) {
      return back(res, null, 'Another membership entry already uses that name or name and email.');
    }
    const emailChanged = email !== r.email;
    try {
      db.exec('BEGIN');
      if (nk !== r.name_key) {
        db.prepare('UPDATE results SET shooter = ? WHERE lower(shooter) = ? AND shoot_id IN (SELECT id FROM shoots WHERE user_id = ?)').run(name, r.name_key, uid);
        db.prepare('DELETE FROM shooter_emails WHERE user_id = ? AND shooter_key = ?').run(uid, r.name_key);
      } else {
        db.prepare('UPDATE results SET shooter = ? WHERE lower(shooter) = ? AND shoot_id IN (SELECT id FROM shoots WHERE user_id = ?)').run(name, nk, uid);
      }
      db.prepare(`UPDATE roster SET name = ?, name_key = ?, email = ?, kind = ?, is_admin = ?, status = ?,
        email_verified_at = CASE WHEN ? THEN NULL ELSE email_verified_at END,
        verify_token_hash = CASE WHEN ? THEN NULL ELSE verify_token_hash END,
        verify_sent_at = CASE WHEN ? THEN NULL ELSE verify_sent_at END WHERE id = ?`)
        .run(name, nk, email, kind, kind === 'member' && admin ? 1 : 0, status, +emailChanged, +emailChanged, +emailChanged, r.id);
      mailer.saveEmails(uid, [{ name, email }]);
      db.exec('COMMIT');
    } catch (e) {
      try { db.exec('ROLLBACK'); } catch {}
      return back(res, null, 'Could not save: that name clashes with existing shoot results.');
    }
    if (emailChanged) sendVerification(uid, r.id).catch(() => {});
    back(res, `Saved changes to ${name}.`);
  });

  router.post('/:id/verify', needAuth, wrap(async (req, res) => {
    const r = mine(req);
    if (!r) return back(res, null, 'Unknown shooter.');
    const out = await sendVerification(req.session.userId, r.id);
    out.ok ? back(res, out.message) : back(res, null, out.message);
  }));

  router.post('/:id/kind', needAuth, (req, res) => {
    const r = mine(req);
    if (!r) return back(res, null, 'Unknown shooter.');
    const kind = req.body.kind === 'member' ? 'member' : 'guest';
    db.prepare('UPDATE roster SET kind = ?, is_admin = CASE WHEN ? = \'member\' THEN is_admin ELSE 0 END WHERE id = ?').run(kind, kind, r.id);
    back(res, `${r.name} is now a ${kind}.`);
  });

  router.post('/:id/admin', needAuth, (req, res) => {
    const r = mine(req);
    if (!r) return back(res, null, 'Unknown shooter.');
    if (r.kind !== 'member') return back(res, null, 'Only members can be admins.');
    const on = req.body.admin === '1' ? 1 : 0;
    db.prepare('UPDATE roster SET is_admin = ? WHERE id = ?').run(on, r.id);
    back(res, on ? `${r.name} is now an admin.` : `${r.name} is no longer an admin.`);
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
    back(res, `Removed ${r.name} from the membership. Past results are kept.`);
  });

  return { router, add, listCurrent, listAll, sendVerification, verifyToken };
};
