const Database = require('better-sqlite3');
const path = require('path');

const db = new Database(path.join(__dirname, '..', 'data', 'app.db'));
db.pragma('foreign_keys = ON');

const user = db.prepare('SELECT id FROM users_v WHERE club_name = ?').get('West Peckham Gun Club');
if (!user) { console.error('No user with club_name "West Peckham Gun Club" found.'); process.exit(1); }

const shooters = ['Alex Morgan', 'Jamie Taylor', 'Casey Patel', 'Robin Clarke', 'Sam Hughes', 'Chris Bennett'];
const shoots = [
  { id: 'wp-2026-05-03', name: 'Spring Open Sporting', venue: 'West Peckham', date: '2026-05-03', stands: 6 },
  { id: 'wp-2026-05-24', name: 'Bank Holiday Sporting', venue: 'West Peckham', date: '2026-05-24', stands: 8 },
  { id: 'wp-2026-06-14', name: 'Summer League Round 1', venue: 'West Peckham', date: '2026-06-14', stands: 6 },
  { id: 'wp-2026-07-12', name: 'Summer League Round 2', venue: 'West Peckham', date: '2026-07-12', stands: 6 },
  { id: 'wp-2026-08-30', name: 'Club Championship', venue: 'West Peckham', date: '2026-08-30', stands: 10 },
];
const targets = 10;

// deterministic pseudo-random so scores are stable
let seed = 42;
const rand = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
const skill = [0.85, 0.8, 0.7, 0.75, 0.6, 0.55];

const insShoot = db.prepare(
  'INSERT INTO shoots (user_id, external_id, name, venue, shoot_date, stands, targets_per_stand) VALUES (?,?,?,?,?,?,?)');
const insResult = db.prepare('INSERT INTO results (shoot_id, shooter, stand, score) VALUES (?,?,?,?)');
const exists = db.prepare('SELECT 1 FROM shoots WHERE user_id = ? AND external_id = ?');

db.transaction(() => {
  for (const s of shoots) {
    if (exists.get(user.id, s.id)) { console.log(`skip ${s.name}`); continue; }
    const shootId = insShoot.run(user.id, s.id, s.name, s.venue, s.date, s.stands, targets).lastInsertRowid;
    shooters.forEach((name, i) => {
      if (rand() < 0.12) return; // some shooters miss some shoots
      for (let stand = 1; stand <= s.stands; stand++) {
        let hits = 0;
        for (let t = 0; t < targets; t++) if (rand() < skill[i]) hits++;
        insResult.run(shootId, name, stand, hits);
      }
    });
    console.log(`added ${s.name}`);
  }
})();
