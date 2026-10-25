'use strict';
// Emails each shooter who has an address their own results after a shoot is uploaded.
// Sending never blocks or fails an upload: each address records its last outcome.
const express = require('express');
const nodemailer = require('nodemailer');

const EMAIL_RE = /^[^@\s,;<>"]+@[^@\s,;<>"]+\.[^@\s,;<>"]+$/;
const MAX_PER_SHOOT = 50;
const MEDALS = ['🥇', '🥈', '🥉'];
const ordinal = (n) => { const s = ['th', 'st', 'nd', 'rd']; const v = n % 100; return n + (s[(v - 20) % 10] || s[v] || s[0]); };
const esc = (v) => String(v).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const key = (name) => String(name).trim().toLowerCase();
const validEmail = (e) => typeof e === 'string' && e.length <= 200 && EMAIL_RE.test(e.trim());

module.exports = function createMailer({ db, classify, needAuth, wrap }) {
  let transport;
  const configured = () => Boolean(process.env.SMTP_HOST || process.env.MAIL_TRANSPORT_JSON === '1');
  const getTransport = () => {
    if (transport) return transport;
    transport = process.env.MAIL_TRANSPORT_JSON === '1'
      ? nodemailer.createTransport({ jsonTransport: true })
      : nodemailer.createTransport({
        host: process.env.SMTP_HOST,
        port: Number(process.env.SMTP_PORT) || 587,
        secure: process.env.SMTP_SECURE === '1',
        auth: process.env.SMTP_USER ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS } : undefined,
      });
    return transport;
  };

  // Everything needed to describe one shooter's performance in one shoot.
  function summary(userId, shootId, shooterName) {
    const shoot = db.prepare('SELECT * FROM shoots WHERE id = ? AND user_id = ?').get(shootId, userId);
    if (!shoot) return null;
    const rows = db.prepare('SELECT shooter, stand, score FROM results WHERE shoot_id = ? ORDER BY stand').all(shootId);
    const totals = new Map();
    const mine = [];
    for (const r of rows) {
      totals.set(r.shooter, (totals.get(r.shooter) || 0) + r.score);
      if (key(r.shooter) === key(shooterName)) mine.push(r.score);
    }
    if (!mine.length) return null;
    const name = rows.find((r) => key(r.shooter) === key(shooterName)).shooter;
    const total = mine.reduce((a, b) => a + b, 0);
    const tps = shoot.targets_per_stand;
    const possible = mine.length * tps;
    const board = [...totals].map(([n, t]) => ({ name: n, total: t })).sort((a, b) => b.total - a.total || a.name.localeCompare(b.name));
    const place = 1 + board.filter((o) => o.total > total).length;

    const cutoff = new Date(); cutoff.setFullYear(cutoff.getFullYear() - 1);
    const cutoffDate = cutoff.toISOString().slice(0, 10);
    const history = db.prepare(`SELECT s.id, s.shoot_date, SUM(r.score) AS total, COUNT(*) * s.targets_per_stand AS possible
      FROM results r JOIN shoots s ON s.id = r.shoot_id WHERE s.user_id = ? AND r.shooter = ? COLLATE NOCASE GROUP BY s.id`).all(userId, name);
    const pct = (list) => (list.length ? (100 * list.reduce((n, h) => n + h.total, 0)) / list.reduce((n, h) => n + h.possible, 0) : null);
    const recentOthers = history.filter((h) => h.id !== shootId && h.shoot_date >= cutoffDate);
    const last12 = history.filter((h) => h.shoot_date >= cutoffDate);
    const avg = { last12: { avgPct: pct(last12) }, allTime: { avgPct: pct(history) } };
    return {
      shoot, name, total, possible, tps, place, field: board.length, board: board.slice(0, 3), stands: mine,
      pct: (100 * total) / possible, prevPct: pct(recentOthers), prevCount: recentOthers.length,
      cpsa: classify(avg), club: db.prepare('SELECT club_name FROM users WHERE id = ?').get(userId)?.club_name || 'Clay Shoots',
    };
  }

  function compose(s) {
    const { shoot, tps } = s;
    const when = shoot.shoot_date + (shoot.shoot_time ? ` at ${shoot.shoot_time}` : '');
    const where = shoot.venue ? ` at ${shoot.venue}` : '';
    const best = Math.max(...s.stands);
    const worst = Math.min(...s.stands);
    const bestStands = s.stands.map((v, i) => (v === best ? i + 1 : null)).filter(Boolean);
    const worstStands = s.stands.map((v, i) => (v === worst ? i + 1 : null)).filter(Boolean);
    const list = (a) => (a.length === 1 ? `stand ${a[0]}` : `stands ${a.slice(0, -1).join(', ')} and ${a.at(-1)}`);
    const placeText = `${MEDALS[s.place - 1] ? `${MEDALS[s.place - 1]} ` : ''}${ordinal(s.place)} of ${s.field}`;

    const notes = [];
    if (s.prevPct != null) {
      const diff = s.pct - s.prevPct;
      notes.push(Math.abs(diff) < 0.5
        ? `That is in line with your recent average of ${s.prevPct.toFixed(1)}%.`
        : `That is ${Math.abs(diff).toFixed(1)} points ${diff > 0 ? 'above' : 'below'} your average of ${s.prevPct.toFixed(1)}% over your last ${s.prevCount} shoot${s.prevCount === 1 ? '' : 's'}.`);
    } else {
      notes.push('This is your first recorded shoot in the last 12 months, so there is nothing to compare it with yet.');
    }
    if (s.stands.length > 1 && best !== worst) {
      notes.push(`Your strongest ${best === tps ? 'was a clean ' : 'was '}${list(bestStands)} (${best}/${tps}); the one to work on is ${list(worstStands)} (${worst}/${tps}).`);
    } else if (best === tps) {
      notes.push('A clean sheet on every stand.');
    }
    if (s.cpsa) notes.push(`On your last 12 months of scores you are currently ${s.cpsa.icon} Class ${s.cpsa.name} (unofficial estimate).`);

    const subject = `Your results: ${shoot.name} – ${shoot.shoot_date}`;
    const dots = (v) => '●'.repeat(v) + '○'.repeat(Math.max(0, tps - v));

    const text = [
      `Hi ${s.name},`, '',
      `Here are your results from ${shoot.name}${where} on ${when}.`, '',
      `Position: ${placeText}`,
      `Score: ${s.total}/${s.possible} (${s.pct.toFixed(1)}%)`, '',
      'Stand by stand:',
      ...s.stands.map((v, i) => `  Stand ${i + 1}: ${v}/${tps}  ${dots(v)}`), '',
      ...notes, '',
      'Top of the field:',
      ...s.board.map((b, i) => `  ${MEDALS[i] || `${i + 1}.`} ${b.name} – ${b.total}`), '',
      `Sent by ${s.club}.`,
    ].join('\n');

    const html = `<div style="font-family:-apple-system,Segoe UI,Arial,sans-serif;max-width:560px;margin:auto;color:#1f2937">
<h2 style="margin:0 0 4px">${esc(shoot.name)}</h2>
<p style="margin:0 0 16px;color:#6b7280">${esc(when)}${esc(where)}</p>
<p>Hi ${esc(s.name)}, here are your results.</p>
<table style="width:100%;border-collapse:collapse;margin:12px 0"><tr>
<td style="padding:12px;background:#f3f4f6;border-radius:8px;text-align:center"><div style="font-size:12px;color:#6b7280">Position</div><div style="font-size:22px;font-weight:700">${esc(placeText)}</div></td>
<td style="width:8px"></td>
<td style="padding:12px;background:#f3f4f6;border-radius:8px;text-align:center"><div style="font-size:12px;color:#6b7280">Score</div><div style="font-size:22px;font-weight:700">${s.total}/${s.possible}</div><div style="font-size:12px;color:#6b7280">${s.pct.toFixed(1)}%</div></td>
</tr></table>
<table style="width:100%;border-collapse:collapse">${s.stands.map((v, i) => `<tr style="border-top:1px solid #e5e7eb"><td style="padding:6px 0">Stand ${i + 1}</td><td style="text-align:right;font-weight:600">${v}/${tps}</td><td style="text-align:right;color:#b45309;letter-spacing:1px">${dots(v)}</td></tr>`).join('')}</table>
${notes.map((n) => `<p>${esc(n)}</p>`).join('')}
<p style="margin-bottom:4px"><strong>Top of the field</strong></p>
<table style="border-collapse:collapse">${s.board.map((b, i) => `<tr><td style="padding:2px 10px 2px 0">${MEDALS[i] || i + 1}</td><td style="padding-right:14px">${esc(b.name)}</td><td>${b.total}</td></tr>`).join('')}</table>
<p style="color:#9ca3af;font-size:12px;margin-top:24px">Sent by ${esc(s.club)}. Ask the club to remove your address if you do not want these emails.</p></div>`;
    return { subject, text, html };
  }

  // One email covering every shoot a shooter has taken part in.
  function historySummary(userId, shooterName) {
    const rows = db.prepare(`SELECT s.id, s.name, s.venue, s.shoot_date, s.shoot_time, s.targets_per_stand AS tps, r.shooter, r.score
      FROM results r JOIN shoots s ON s.id = r.shoot_id WHERE s.user_id = ?
      AND s.id IN (SELECT shoot_id FROM results WHERE shooter = ? COLLATE NOCASE)`).all(userId, shooterName);
    const byShoot = new Map();
    for (const r of rows) {
      if (!byShoot.has(r.id)) byShoot.set(r.id, { ...r, totals: new Map(), stands: 0 });
      const s = byShoot.get(r.id);
      s.totals.set(r.shooter, (s.totals.get(r.shooter) || 0) + r.score);
      if (key(r.shooter) === key(shooterName)) s.stands += 1;
    }
    const shoots = [...byShoot.values()].map((s) => {
      const mineKey = [...s.totals.keys()].find((k) => key(k) === key(shooterName));
      const total = s.totals.get(mineKey);
      const possible = s.stands * s.tps;
      return {
        name: s.name, venue: s.venue, date: s.shoot_date, time: s.shoot_time, total, possible,
        pct: (100 * total) / possible, place: 1 + [...s.totals.values()].filter((t) => t > total).length, field: s.totals.size,
      };
    }).sort((a, b) => (b.date + (b.time || '')).localeCompare(a.date + (a.time || '')));
    if (!shoots.length) return null;
    const cutoff = new Date(); cutoff.setFullYear(cutoff.getFullYear() - 1);
    const cutoffDate = cutoff.toISOString().slice(0, 10);
    const pct = (list) => (list.length ? (100 * list.reduce((n, h) => n + h.total, 0)) / list.reduce((n, h) => n + h.possible, 0) : null);
    const last12 = shoots.filter((s) => s.date >= cutoffDate);
    const name = [...rows].find((r) => key(r.shooter) === key(shooterName)).shooter;
    return {
      name, shoots, allPct: pct(shoots), last12Pct: pct(last12), wins: shoots.filter((s) => s.place === 1).length,
      best: shoots.reduce((a, b) => (b.pct > a.pct ? b : a)),
      cpsa: classify({ last12: { avgPct: pct(last12) }, allTime: { avgPct: pct(shoots) } }),
      club: db.prepare('SELECT club_name FROM users WHERE id = ?').get(userId)?.club_name || 'Clay Shoots',
    };
  }

  function composeHistory(h) {
    const when = (s) => s.date + (s.time ? ` ${s.time}` : '');
    const placeText = (s) => `${MEDALS[s.place - 1] ? `${MEDALS[s.place - 1]} ` : ''}${ordinal(s.place)} of ${s.field}`;
    const notes = [
      `${h.shoots.length} shoot${h.shoots.length === 1 ? '' : 's'} recorded, averaging ${h.allPct.toFixed(1)}% overall${h.last12Pct != null ? ` and ${h.last12Pct.toFixed(1)}% over the last 12 months` : ''}.`,
      `Your best was ${h.best.pct.toFixed(1)}% at ${h.best.name} on ${h.best.date}${h.wins ? `, and you have won ${h.wins} shoot${h.wins === 1 ? '' : 's'}` : ''}.`,
    ];
    if (h.cpsa) notes.push(`You are currently ${h.cpsa.icon} Class ${h.cpsa.name} (unofficial estimate).`);
    const subject = `Your results from all ${h.shoots.length} shoot${h.shoots.length === 1 ? '' : 's'}`;
    const text = [
      `Hi ${h.name},`, '', 'Here are your results from every shoot on record:', '',
      ...h.shoots.map((s) => `  ${when(s)}  ${s.name}${s.venue ? ` (${s.venue})` : ''}\n      ${placeText(s)} · ${s.total}/${s.possible} · ${s.pct.toFixed(1)}%`),
      '', ...notes, '', `Sent by ${h.club}.`,
    ].join('\n');
    const html = `<div style="font-family:-apple-system,Segoe UI,Arial,sans-serif;max-width:620px;margin:auto;color:#1f2937">
<h2 style="margin:0 0 8px">Your results</h2><p>Hi ${esc(h.name)}, here is every shoot on record.</p>
<table style="width:100%;border-collapse:collapse"><tr style="text-align:left;color:#6b7280;font-size:12px"><th>Date</th><th>Shoot</th><th>Position</th><th style="text-align:right">Score</th><th style="text-align:right">%</th></tr>
${h.shoots.map((s) => `<tr style="border-top:1px solid #e5e7eb"><td style="padding:6px 8px 6px 0;white-space:nowrap">${esc(when(s))}</td><td>${esc(s.name)}${s.venue ? `<div style="font-size:12px;color:#6b7280">${esc(s.venue)}</div>` : ''}</td><td>${esc(placeText(s))}</td><td style="text-align:right">${s.total}/${s.possible}</td><td style="text-align:right;font-weight:600">${s.pct.toFixed(1)}%</td></tr>`).join('')}</table>
${notes.map((n) => `<p>${esc(n)}</p>`).join('')}
<p style="color:#9ca3af;font-size:12px;margin-top:24px">Sent by ${esc(h.club)}. Ask the club to remove your address if you do not want these emails.</p></div>`;
    return { subject, text, html };
  }

  const sentLog = new Map();
  const tooMany = (userId) => {
    const now = Date.now();
    const recent = (sentLog.get(userId) || []).filter((t) => now - t < 3600e3);
    if (recent.length >= 20) { sentLog.set(userId, recent); return true; }
    recent.push(now); sentLog.set(userId, recent);
    return false;
  };

  const setStatus = (userId, k, status) => db.prepare(
    "UPDATE shooter_emails SET last_status = ?, last_at = datetime('now') WHERE user_id = ? AND shooter_key = ?"
  ).run(status, userId, k);

  async function sendTo(userId, shootId, row) {
    if (!configured()) return setStatus(userId, row.shooter_key, 'Not sent: outgoing email is not configured');
    const s = summary(userId, shootId, row.shooter);
    if (!s) return setStatus(userId, row.shooter_key, 'Not sent: no results for this shooter');
    try {
      const m = compose(s);
      await getTransport().sendMail({
        from: process.env.MAIL_FROM || process.env.SMTP_USER || 'Clay Shoots <no-reply@localhost>',
        to: row.email, subject: m.subject, text: m.text, html: m.html,
      });
      setStatus(userId, row.shooter_key, `Sent: ${s.shoot.name} (${s.shoot.shoot_date})`);
    } catch (e) {
      setStatus(userId, row.shooter_key, `Failed: ${String(e.code || 'error').slice(0, 30)}`);
    }
  }

  // Called after a new upload; never throws.
  async function sendShoot(userId, shootId) {
    try {
      const user = db.prepare('SELECT email_results FROM users WHERE id = ?').get(userId);
      if (!user || !user.email_results) return;
      const names = db.prepare('SELECT DISTINCT shooter FROM results WHERE shoot_id = ?').all(shootId).map((r) => key(r.shooter));
      if (!names.length) return;
      const rows = db.prepare(`SELECT * FROM shooter_emails WHERE user_id = ? AND shooter_key IN (${names.map(() => '?').join(',')})`)
        .all(userId, ...names).slice(0, MAX_PER_SHOOT);
      for (const row of rows) await sendTo(userId, shootId, row);
    } catch (e) { console.error('shooter email failed', e.message); }
  }

  function saveEmails(userId, shooters) {
    const up = db.prepare(`INSERT INTO shooter_emails (user_id, shooter_key, shooter, email) VALUES (?,?,?,?)
      ON CONFLICT (user_id, shooter_key) DO UPDATE SET email = excluded.email, shooter = excluded.shooter`);
    for (const s of shooters) if (validEmail(s.email)) up.run(userId, key(s.name), s.name.trim(), s.email.trim());
  }

  const router = express.Router();
  router.get('/', needAuth, (req, res) => {
    const uid = req.session.userId;
    const names = db.prepare('SELECT shooter, COUNT(DISTINCT shoot_id) AS shoots FROM results r JOIN shoots s ON s.id = r.shoot_id WHERE s.user_id = ? GROUP BY shooter COLLATE NOCASE ORDER BY shooter COLLATE NOCASE').all(uid);
    const emails = new Map(db.prepare('SELECT * FROM shooter_emails WHERE user_id = ?').all(uid).map((e) => [e.shooter_key, e]));
    const shooters = names.map((n) => ({ name: n.shooter, shoots: n.shoots, rec: emails.get(key(n.shooter)) || null }));
    const auto = db.prepare('SELECT email_results FROM users WHERE id = ?').get(uid).email_results === 1;
    const counts = new Map(names.map((n) => [key(n.shooter), n.shoots]));
    const roster = (res.locals.roster || []).map((r) => ({ ...r, shoots: counts.get(r.name_key) || 0 }));
    res.render('shooters', { roster, shooters, auto, configured: configured(), msg: req.query.msg || null, err: req.query.err || null });
  });

  router.post('/email', needAuth, (req, res) => {
    const uid = req.session.userId;
    const name = String(req.body.name || '').trim();
    const email = String(req.body.email || '').trim();
    const exists = db.prepare('SELECT 1 FROM results r JOIN shoots s ON s.id = r.shoot_id WHERE s.user_id = ? AND r.shooter = ? COLLATE NOCASE LIMIT 1').get(uid, name);
    if (!exists) return res.redirect('/shooters?err=' + encodeURIComponent('Unknown shooter.'));
    if (!email) {
      db.prepare('DELETE FROM shooter_emails WHERE user_id = ? AND shooter_key = ?').run(uid, key(name));
      return res.redirect('/shooters?msg=' + encodeURIComponent(`Removed the email for ${name}.`));
    }
    if (!validEmail(email)) return res.redirect('/shooters?err=' + encodeURIComponent('Enter a valid email address.'));
    saveEmails(uid, [{ name, email }]);
    res.redirect('/shooters?msg=' + encodeURIComponent(`Saved the email for ${name}.`));
  });

  // Used by the hover dialog: emails all of a shooter's results, saving a new address if one is given.
  router.post('/send-all', needAuth, wrap(async (req, res) => {
    const uid = req.session.userId;
    const reply = (status, ok, message) => res.status(status).json({ ok, message });
    const name = String(req.body.name || '').trim();
    const given = String(req.body.email || '').trim();
    const h = name ? historySummary(uid, name) : null;
    if (!h) return reply(404, false, 'No results found for this shooter.');
    if (!configured()) return reply(503, false, 'Outgoing email is not set up yet.');
    let row = db.prepare('SELECT * FROM shooter_emails WHERE user_id = ? AND shooter_key = ?').get(uid, key(name));
    if (given) {
      if (!validEmail(given)) return reply(400, false, 'Enter a valid email address.');
      saveEmails(uid, [{ name: h.name, email: given }]);
      row = db.prepare('SELECT * FROM shooter_emails WHERE user_id = ? AND shooter_key = ?').get(uid, key(name));
    }
    if (!row) return reply(409, false, 'needs_email');
    if (tooMany(uid)) return reply(429, false, 'Too many emails sent this hour. Try again later.');
    try {
      const m = composeHistory(h);
      await getTransport().sendMail({
        from: process.env.MAIL_FROM || process.env.SMTP_USER || 'Clay Shoots <no-reply@localhost>',
        to: row.email, subject: m.subject, text: m.text, html: m.html,
      });
      setStatus(uid, row.shooter_key, `Sent: all ${h.shoots.length} shoots`);
      return reply(200, true, `Sent all ${h.shoots.length} shoot${h.shoots.length === 1 ? '' : 's'} to ${row.email}.`);
    } catch (e) {
      setStatus(uid, row.shooter_key, `Failed: ${String(e.code || 'error').slice(0, 30)}`);
      return reply(502, false, 'The email could not be sent.');
    }
  }));

  router.post('/auto', needAuth, (req, res) => {
    const on = req.body.auto === '1' ? 1 : 0;
    db.prepare('UPDATE users SET email_results = ? WHERE id = ?').run(on, req.session.userId);
    res.redirect('/shooters?msg=' + encodeURIComponent(on ? 'Results will be emailed after each upload.' : 'Automatic emails are off.'));
  });

  router.post('/send', needAuth, wrap(async (req, res) => {
    const uid = req.session.userId;
    const name = String(req.body.name || '').trim();
    const row = db.prepare('SELECT * FROM shooter_emails WHERE user_id = ? AND shooter_key = ?').get(uid, key(name));
    if (!row) return res.redirect('/shooters?err=' + encodeURIComponent('Add an email address first.'));
    const latest = db.prepare(`SELECT s.id FROM shoots s JOIN results r ON r.shoot_id = s.id
      WHERE s.user_id = ? AND r.shooter = ? COLLATE NOCASE ORDER BY s.shoot_date DESC, s.shoot_time DESC, s.id DESC LIMIT 1`).get(uid, row.shooter);
    if (!latest) return res.redirect('/shooters?err=' + encodeURIComponent('No results for this shooter.'));
    await sendTo(uid, latest.id, row);
    const status = db.prepare('SELECT last_status FROM shooter_emails WHERE user_id = ? AND shooter_key = ?').get(uid, row.shooter_key).last_status;
    res.redirect('/shooters?' + (status.startsWith('Sent') ? 'msg=' : 'err=') + encodeURIComponent(status));
  }));

  return { router, sendShoot, saveEmails, validEmail, compose, summary, historySummary, composeHistory };
};
