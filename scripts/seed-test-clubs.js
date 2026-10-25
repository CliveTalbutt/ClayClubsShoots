// Creates four test clubs with admins, members, guests and random shoots.
// Every account password is "password". Safe to re-run: existing emails are skipped.
// Usage: node scripts/seed-test-clubs.js
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const db = require('../src/db');

const PASSWORD = 'password';
const hash = bcrypt.hashSync(PASSWORD, 10);

let seed = 20261025;
const rand = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
const pick = (a) => a[Math.floor(rand() * a.length)];

const first = ['Alex', 'Jamie', 'Casey', 'Robin', 'Sam', 'Chris', 'Morgan', 'Taylor', 'Jordan', 'Riley', 'Drew', 'Avery', 'Harper', 'Quinn', 'Blake', 'Charlie', 'Dana', 'Eli', 'Frankie', 'Gray', 'Hayden', 'Indy', 'Jesse', 'Kit'];
const last = ['Morgan', 'Taylor', 'Patel', 'Clarke', 'Hughes', 'Bennett', 'Walsh', 'Foster', 'Reid', 'Hart', 'Ellis', 'Boyd', 'Shaw', 'Grant', 'Lowe', 'Nash', 'Price', 'Stone', 'Webb', 'Young'];
const usedNames = new Set();
const person = () => {
  for (;;) {
    const n = `${pick(first)} ${pick(last)}`;
    if (!usedNames.has(n)) { usedNames.add(n); return n; }
  }
};

const clubs = [
  { name: 'Ashdown Clay Club', slug: 'ashdown', venue: 'Ashdown Forest', super: true },
  { name: 'Brookfield Shooting School', slug: 'brookfield', venue: 'Brookfield Farm' },
  { name: 'Coppice Gun Club', slug: 'coppice', venue: 'Coppice Wood' },
  { name: 'Downland Sporting', slug: 'downland', venue: 'Downland Estate' },
];
const shootNames = ['Spring Open', 'Summer League', 'Bank Holiday Sporting', 'Club Championship', 'Autumn Cup', 'Twilight Shoot', 'Charity Sporting'];

const insUser = db.prepare('INSERT INTO users (email, club_name, password_hash, is_super) VALUES (?,?,?,?)');
const insRoster = db.prepare('INSERT INTO roster (user_id, name, name_key, email, kind, status, is_admin, guid) VALUES (?,?,?,?,?,?,?,?)');
const insShoot = db.prepare('INSERT INTO shoots (user_id, external_id, name, venue, shoot_date, stands, targets_per_stand) VALUES (?,?,?,?,?,?,?)');
const insResult = db.prepare('INSERT INTO results (shoot_id, shooter, stand, score) VALUES (?,?,?,?)');
const hasUser = db.prepare('SELECT id FROM users WHERE email = ?');

const report = [];

db.transaction(() => {
  for (const club of clubs) {
    const people = {
      admins: [person(), person()],
      members: [person(), person(), person(), person()],
      guests: [person(), person()],
      expired: person(),
    };
    const email = (n) => `${n.toLowerCase().replace(/[^a-z]+/g, '.')}@${club.slug}.example.test`;
    const everyone = [...people.admins, ...people.members, ...people.guests, people.expired];
    const skill = Object.fromEntries(everyone.map((n) => [n, 0.45 + rand() * 0.45]));

    // One shared set of shoots per club, generated once and copied into each account.
    const shoots = Array.from({ length: 5 }, (_, i) => {
      const stands = 4 + Math.floor(rand() * 7);
      const date = new Date(Date.UTC(2026, 4 + i, 2 + Math.floor(rand() * 26))).toISOString().slice(0, 10);
      const entrants = everyone.filter(() => rand() > 0.2);
      const scores = {};
      for (const n of entrants) {
        scores[n] = Array.from({ length: stands }, () => {
          let hits = 0;
          for (let t = 0; t < 10; t++) if (rand() < skill[n]) hits++;
          return hits;
        });
      }
      return { ext: `${club.slug}-${date}`, name: `${club.name.split(' ')[0]} ${shootNames[i % shootNames.length]}`, date, stands, scores };
    });

    // Each login is its own account, so each gets the club's roster and shoots.
    const accounts = [
      ...people.admins.map((n, i) => ({ name: n, role: i === 0 ? 'Admin (owner)' : 'Admin (roster admin)', kind: i === 0 ? null : 'member', admin: 1 })),
      ...people.members.map((n) => ({ name: n, role: 'Member', kind: 'member', admin: 0 })),
    ];
    if (club.super) accounts.unshift({ name: 'Super Admin', role: 'Super admin', kind: null, admin: 0, superUser: true, emailOverride: 'superadmin@clayshoots.example.test' });

    for (const acc of accounts) {
      const login = acc.emailOverride || email(acc.name);
      if (hasUser.get(login)) { report.push({ club: club.name, ...acc, email: login, note: 'already existed' }); continue; }
      const uid = insUser.run(login, club.name, hash, acc.superUser ? 1 : 0).lastInsertRowid;
      const addRoster = (n, kind, status, admin) =>
        insRoster.run(uid, n, n.trim().toLowerCase(), email(n), kind, status, admin, crypto.randomUUID());
      people.admins.forEach((n, i) => addRoster(n, 'member', 'current', 1));
      people.members.forEach((n) => addRoster(n, 'member', 'current', 0));
      people.guests.forEach((n) => addRoster(n, 'guest', 'current', 0));
      addRoster(people.expired, 'member', 'expired', 0);
      for (const s of shoots) {
        const sid = insShoot.run(uid, s.ext, s.name, club.venue, s.date, s.stands, 10).lastInsertRowid;
        for (const [n, arr] of Object.entries(s.scores)) arr.forEach((v, k) => insResult.run(sid, n, k + 1, v));
      }
      report.push({ club: club.name, ...acc, email: login });
    }
  }
})();

// Dummy subscriptions, one scenario per club, applied to every account of that club.
const nowSec = Math.floor(Date.now() / 1000);
const scenarios = {
  'Ashdown Clay Club': ['active', nowSec + 200 * 86400, 'active, 200 days left'],
  'Brookfield Shooting School': ['active', nowSec + 6 * 86400, 'ends in 6 days (renewal reminder due)'],
  'Coppice Gun Club': ['active', nowSec - 3 * 86400, 'expired 3 days ago'],
  'Downland Sporting': ['none', null, 'no subscription (new sign-up, pay with the dummy card)'],
};
for (const [club, [status, end]] of Object.entries(scenarios)) {
  db.prepare('UPDATE users SET sub_status = ?, sub_period_end = ? WHERE club_name = ? AND is_super = 0').run(status, end, club);
}
// Paid-for allowance (members, guests). Brookfield is exactly full so the limit can be tried.
const allowances = { 'Ashdown Clay Club': [12, 6], 'Brookfield Shooting School': [6, 2], 'Coppice Gun Club': [8, 4], 'Downland Sporting': [10, 4] };
for (const [club, [m, g]] of Object.entries(allowances)) {
  db.prepare('UPDATE users SET est_members = ?, est_guests = ?, req_members = NULL, req_guests = NULL WHERE club_name = ? AND is_super = 0').run(m, g, club);
}
console.log('Subscriptions:');
for (const [club, [, , text]] of Object.entries(scenarios)) console.log(`  ${club}: ${text}; allowance ${allowances[club][0]} members, ${allowances[club][1]} guests`);
console.log();

console.log(`Password for every account: ${PASSWORD}\n`);
for (const r of report) console.log(`${r.club.padEnd(28)} ${r.role.padEnd(22)} ${r.name.padEnd(18)} ${r.email}${r.note ? '  (' + r.note + ')' : ''}`);
