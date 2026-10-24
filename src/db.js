const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, '..', 'data');
const inMemory = process.env.DB_IN_MEMORY === '1';
if (!inMemory) fs.mkdirSync(dir, { recursive: true });
const db = new Database(inMemory ? ':memory:' : path.join(dir, 'app.db'));
if (!inMemory) db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  club_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  totp_secret TEXT,
  api_key_hash TEXT UNIQUE,
  stripe_customer_id TEXT UNIQUE,
  sub_status TEXT NOT NULL DEFAULT 'none',
  sub_period_end INTEGER,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS shoots (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  external_id TEXT,
  name TEXT NOT NULL,
  venue TEXT,
  shoot_date TEXT NOT NULL,
  stands INTEGER NOT NULL CHECK (stands BETWEEN 1 AND 20),
  targets_per_stand INTEGER NOT NULL DEFAULT 10,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (user_id, external_id)
);
CREATE TABLE IF NOT EXISTS results (
  shoot_id INTEGER NOT NULL REFERENCES shoots(id) ON DELETE CASCADE,
  shooter TEXT NOT NULL,
  stand INTEGER NOT NULL,
  score INTEGER NOT NULL,
  PRIMARY KEY (shoot_id, shooter, stand)
);
CREATE INDEX IF NOT EXISTS idx_results_shooter ON results(shooter);
CREATE TABLE IF NOT EXISTS payments (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  plan TEXT NOT NULL,
  provider_ref TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  meta TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (provider, provider_ref)
);
CREATE TABLE IF NOT EXISTS social_accounts (
  id INTEGER PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform TEXT NOT NULL,
  label TEXT NOT NULL,
  config TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  last_status TEXT,
  last_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_social_user ON social_accounts(user_id);
CREATE TABLE IF NOT EXISTS pay_links (
  provider TEXT NOT NULL,
  kind TEXT NOT NULL,
  external_id TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan TEXT,
  PRIMARY KEY (provider, kind, external_id)
);
`);

if (inMemory && process.env.SEED_EXAMPLE_DATA === '1') {
  const password = crypto.randomBytes(18).toString('hex');
  const userId = db.prepare(
    'INSERT INTO users (email, club_name, password_hash) VALUES (?, ?, ?)'
  ).run('sample@clayshoots.local', 'Sample Clay Club', bcrypt.hashSync(password, 12)).lastInsertRowid;
  const shoots = [
    { name: 'Summer League Round 1', venue: 'Green Valley', date: '2026-06-07' },
    { name: 'Riverside Open', venue: 'Riverside Grounds', date: '2026-06-21' },
    { name: 'Club Championship', venue: 'Green Valley', date: '2026-07-05' },
  ];
  const scores = [
    { shooter: 'Alex Morgan', rounds: [[8, 9, 7, 10, 8], [9, 9, 8, 8, 9], [9, 10, 9, 8, 9]] },
    { shooter: 'Jamie Taylor', rounds: [[9, 8, 9, 8, 9], [8, 9, 10, 9, 8], [9, 9, 8, 10, 9]] },
    { shooter: 'Casey Patel', rounds: [[7, 9, 8, 7, 8], [8, 8, 9, 9, 7], [9, 8, 9, 8, 9]] },
    { shooter: 'Robin Clarke', rounds: [[10, 7, 9, 9, 8], [9, 8, 8, 9, 10], [8, 9, 9, 10, 9]] },
  ];
  const insertShoot = db.prepare(
    'INSERT INTO shoots (user_id, name, venue, shoot_date, stands) VALUES (?, ?, ?, ?, 5)'
  );
  const insertResult = db.prepare(
    'INSERT INTO results (shoot_id, shooter, stand, score) VALUES (?, ?, ?, ?)'
  );
  db.transaction(() => {
    shoots.forEach((shoot, index) => {
      const shootId = insertShoot.run(userId, shoot.name, shoot.venue, shoot.date).lastInsertRowid;
      scores.forEach(({ shooter, rounds }) => {
        rounds[index].forEach((score, stand) => insertResult.run(shootId, shooter, stand + 1, score));
      });
    });
  })();
  console.log(`Sample data login: sample@clayshoots.local / ${password}`);
}

// Shoot start time (HH:MM, 30-minute resolution); added after first release
if (!db.prepare("SELECT 1 FROM pragma_table_info('shoots') WHERE name = 'shoot_time'").get()) {
  db.exec('ALTER TABLE shoots ADD COLUMN shoot_time TEXT');
}
// Emails and social posts go out once, when a shoot is first reported complete
if (!db.prepare("SELECT 1 FROM pragma_table_info('shoots') WHERE name = 'notified'").get()) {
  db.exec('ALTER TABLE shoots ADD COLUMN notified INTEGER NOT NULL DEFAULT 0');
  db.exec('UPDATE shoots SET notified = 1');
}

db.exec(`CREATE TABLE IF NOT EXISTS shooter_emails (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  shooter_key TEXT NOT NULL,
  shooter TEXT NOT NULL,
  email TEXT NOT NULL,
  last_status TEXT,
  last_at TEXT,
  PRIMARY KEY (user_id, shooter_key)
)`);
if (!db.prepare("SELECT 1 FROM pragma_table_info('users') WHERE name = 'email_results'").get()) {
  db.exec('ALTER TABLE users ADD COLUMN email_results INTEGER NOT NULL DEFAULT 1');
}

module.exports = db;
