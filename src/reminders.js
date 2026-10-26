'use strict';
// Renewal reminders. A daily sweep emails each club account as its subscription nears the end,
// when it lapses, and once more a week later. Each reminder is sent once per subscription period
// (a renewal changes the period end, so the cycle starts again). Every attempt is logged.
const BEFORE = [30, 14, 7, 1];
const LAPSED_DAY = 7;
const LAPSED_STOP_DAYS = 60;
const DAY = 86400;

module.exports = function createReminders({ db, mailer, baseUrl }) {
  db.exec(`CREATE TABLE IF NOT EXISTS reminder_log (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    period_end INTEGER NOT NULL,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
  )`);
  db.exec('CREATE INDEX IF NOT EXISTS idx_reminder_user ON reminder_log(user_id, period_end)');

  const now = () => Math.floor(Date.now() / 1000);
  const fmt = (sec) => new Date(sec * 1000).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });

  // The reminder (if any) that is due for a subscription ending at `end`.
  function dueKind(end, at = now()) {
    const left = end - at;
    if (left > 0) {
      const days = Math.ceil(left / DAY);
      const t = BEFORE.filter((d) => days <= d).sort((a, b) => a - b)[0];
      return t ? `before-${t}` : null;
    }
    const since = Math.floor(-left / DAY);
    if (since >= LAPSED_STOP_DAYS) return null;
    return since >= LAPSED_DAY ? 'lapsed-late' : 'lapsed';
  }

  function compose(user, kind, end) {
    const link = `${baseUrl}/dashboard`;
    const club = user.club_name;
    let subject; let lead;
    if (kind.startsWith('before-')) {
      const d = Number(kind.slice(7));
      subject = `${club}: your Clay Shoots subscription ends in ${d === 1 ? '1 day' : `${d} days`}`;
      lead = `Your Clay Shoots subscription for ${club} ends on ${fmt(end)}.`;
    } else if (kind === 'lapsed') {
      subject = `${club}: your Clay Shoots subscription has ended`;
      lead = `Your Clay Shoots subscription for ${club} ended on ${fmt(end)}. Shoots can't be uploaded until it is renewed.`;
    } else if (kind === 'lapsed-late') {
      subject = `${club}: renew Clay Shoots to keep your results coming in`;
      lead = `Your Clay Shoots subscription for ${club} ended on ${fmt(end)}. Your results are safe, but new shoots can't be recorded until you renew.`;
    } else {
      subject = `${club}: Clay Shoots subscription reminder`;
      lead = `This is a reminder about your Clay Shoots subscription for ${club}${end ? ` (current period ends ${fmt(end)})` : ''}.`;
    }
    const text = `${lead}\n\nRenew here: ${link}\n\nThank you,\nClay Shoots`;
    const esc = (v) => String(v).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    const html = `<p>${esc(lead)}</p><p><a href="${esc(link)}">Renew your subscription</a></p><p>Thank you,<br>Clay Shoots</p>`;
    return { subject, text, html };
  }

  const sentAlready = (userId, kind, end) =>
    !!db.prepare("SELECT 1 FROM reminder_log WHERE user_id = ? AND kind = ? AND period_end = ? AND status = 'sent'").get(userId, kind, end);
  const logRow = (userId, kind, end, status) =>
    db.prepare('INSERT INTO reminder_log (user_id, kind, period_end, status) VALUES (?,?,?,?)').run(userId, kind, end, status);

  async function deliver(user, kind, end) {
    if (!mailer.configured()) {
      const status = 'not sent: outgoing email is not configured';
      const last = db.prepare('SELECT status FROM reminder_log WHERE user_id = ? AND kind = ? AND period_end = ? ORDER BY id DESC LIMIT 1').get(user.id, kind, end);
      if (!last || last.status !== status) logRow(user.id, kind, end, status);
      return status;
    }
    try {
      await mailer.sendRaw(user.email, compose(user, kind, end));
      logRow(user.id, kind, end, 'sent');
      return 'sent';
    } catch (e) {
      const status = `failed: ${String(e.message).slice(0, 120)}`;
      logRow(user.id, kind, end, status);
      return status;
    }
  }

  // Checks every club account once. Safe to run as often as you like.
  async function sweep() {
    const rows = db.prepare("SELECT * FROM users_v WHERE is_super = 0 AND sub_period_end IS NOT NULL AND sub_status IN ('active', 'trialing', 'canceled', 'past_due', 'expired')").all();
    let sent = 0;
    for (const u of rows) {
      const kind = dueKind(u.sub_period_end);
      if (!kind || sentAlready(u.id, kind, u.sub_period_end)) continue;
      if (await deliver(u, kind, u.sub_period_end) === 'sent') sent++;
    }
    return sent;
  }

  // Super admin "send now": always sends, regardless of schedule.
  async function sendNow(userId) {
    const u = db.prepare('SELECT * FROM users_v WHERE id = ?').get(userId);
    if (!u) return 'unknown account';
    const end = u.sub_period_end || 0;
    const kind = end ? (dueKind(end) || 'manual') : 'manual';
    return deliver(u, kind === 'manual' ? 'manual' : kind, end);
  }

  const recent = (userId, limit = 10) =>
    db.prepare('SELECT kind, period_end, status, created_at FROM reminder_log WHERE user_id = ? ORDER BY id DESC LIMIT ?').all(userId, limit);

  function schedule() {
    const run = () => sweep().then((n) => { if (n) console.log(`Renewal reminders sent: ${n}`); }).catch((e) => console.error('reminders', e.message));
    setTimeout(run, 30_000).unref();
    setInterval(run, 6 * 3600_000).unref();
  }

  return { sweep, sendNow, recent, schedule, dueKind };
};
