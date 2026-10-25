'use strict';
// Per-head pricing and shooter limits. A club pays for a number of members and guests
// (£1 per member, 50p per guest, per year). The paid-for numbers live on the user as
// est_members / est_guests; req_* hold a requested larger or smaller allowance until it is paid for.
// A NULL allowance (older accounts and the super admin) means no limit.
const MEMBER_PENCE = 100;
const GUEST_PENCE = 50;
const MAX_PEOPLE = 5000;

const price = (members, guests) => members * MEMBER_PENCE + guests * GUEST_PENCE;
const money = (pence) => `£${(pence / 100).toFixed(2)}`;

function parseCount(v, { min = 0 } = {}) {
  const s = String(v == null ? '' : v).trim();
  if (!/^\d{1,4}$/.test(s)) return null;
  const n = Number(s);
  return n >= min && n <= MAX_PEOPLE ? n : null;
}

module.exports = function createAllowance(db) {
  const counts = (userId) => {
    const r = db.prepare(`SELECT
      COALESCE(SUM(kind = 'member'), 0) AS members, COALESCE(SUM(kind = 'guest'), 0) AS guests
      FROM roster WHERE user_id = ? AND status = 'current'`).get(userId);
    return { members: r.members, guests: r.guests };
  };

  function get(userId) {
    const u = db.prepare('SELECT is_super, est_members, est_guests, req_members, req_guests FROM users WHERE id = ?').get(userId);
    if (!u || u.is_super === 1 || u.est_members == null || u.est_guests == null) return { limited: false };
    return {
      limited: true, members: u.est_members, guests: u.est_guests,
      reqMembers: u.req_members, reqGuests: u.req_guests,
    };
  }

  // Returns an error message when making `kind` a current entry (other than entry `excludeId`)
  // would go over what the club has paid for, otherwise null.
  function check(userId, kind, excludeId = 0) {
    const a = get(userId);
    if (!a.limited) return null;
    const used = db.prepare("SELECT COUNT(*) AS n FROM roster WHERE user_id = ? AND status = 'current' AND kind = ? AND id != ?").get(userId, kind, excludeId).n;
    const limit = kind === 'member' ? a.members : a.guests;
    if (used + 1 <= limit) return null;
    return `Your subscription covers ${a.members} member${a.members === 1 ? '' : 's'} and ${a.guests} guest${a.guests === 1 ? '' : 's'}, and all ${limit} ${kind} places are used. Increase your allowance on the Dashboard to add more.`;
  }

  // Saves a requested allowance; it only takes effect once paid for. Returns an error message or null.
  function request(userId, members, guests) {
    const c = counts(userId);
    if (members < c.members || guests < c.guests) {
      return `You already have ${c.members} members and ${c.guests} guests, so the allowance can't be lower than that. Mark people as expired or remove them first.`;
    }
    db.prepare('UPDATE users SET req_members = ?, req_guests = ? WHERE id = ?').run(members, guests, userId);
    return null;
  }

  // Called when a payment completes: a requested allowance becomes the paid-for one.
  function applyRequested(userId) {
    db.prepare(`UPDATE users SET est_members = req_members, est_guests = req_guests, req_members = NULL, req_guests = NULL
      WHERE id = ? AND req_members IS NOT NULL AND req_guests IS NOT NULL`).run(userId);
  }

  return { get, counts, check, request, applyRequested };
};
module.exports.price = price;
module.exports.money = money;
module.exports.parseCount = parseCount;
module.exports.MEMBER_PENCE = MEMBER_PENCE;
module.exports.GUEST_PENCE = GUEST_PENCE;
