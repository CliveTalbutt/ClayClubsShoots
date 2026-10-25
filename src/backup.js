// Daily JSON backup of every table (except login sessions) and restore from those files.
const fs = require('fs');
const path = require('path');

const KEEP_DAILY = 30;
const KEEP_SAFETY = 10;
const NAME_RE = /^(backup|prerestore)-\d{4}-\d{2}-\d{2}-\d{6}\.json$/;

module.exports = function createBackup({ db, dir }) {
  const tables = () => db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'sessions' ORDER BY name").all().map((t) => t.name);
  const stamp = (d = new Date()) => {
    const p = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
  };

  function write(prefix) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const data = {};
    db.transaction(() => { for (const t of tables()) data[t] = db.prepare(`SELECT * FROM "${t}"`).all(); })();
    const file = `${prefix}-${stamp()}.json`;
    const full = path.join(dir, file);
    fs.writeFileSync(full + '.tmp', JSON.stringify({ version: 1, createdAt: new Date().toISOString(), tables: data }), { mode: 0o600 });
    fs.renameSync(full + '.tmp', full);
    prune();
    return file;
  }

  function list() {
    if (!fs.existsSync(dir)) return [];
    return fs.readdirSync(dir).filter((f) => NAME_RE.test(f)).map((f) => {
      const st = fs.statSync(path.join(dir, f));
      return { file: f, size: st.size, when: st.mtime, kind: f.startsWith('prerestore') ? 'Safety copy before a restore' : 'Daily backup' };
    }).sort((a, b) => b.when - a.when || b.file.localeCompare(a.file));
  }

  function prune() {
    for (const [prefix, keep] of [['backup', KEEP_DAILY], ['prerestore', KEEP_SAFETY]]) {
      list().filter((b) => b.file.startsWith(prefix)).slice(keep).forEach((b) => fs.rmSync(path.join(dir, b.file), { force: true }));
    }
  }

  function read(file) {
    if (!NAME_RE.test(file)) throw new Error('Unknown backup.');
    const parsed = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
    if (!parsed || parsed.version !== 1 || typeof parsed.tables !== 'object') throw new Error('Not a valid backup file.');
    return parsed;
  }

  // Replaces the database contents with the backup, atomically. A safety copy is taken first.
  function restore(file) {
    const { tables: data } = read(file);
    if (!Array.isArray(data.users) || !data.users.some((u) => u.is_super === 1)) throw new Error('That backup has no super admin account, so it cannot be restored.');
    const safety = write('prerestore');
    const live = new Set(tables());
    db.pragma('foreign_keys = OFF');
    try {
      db.transaction(() => {
        for (const t of live) db.prepare(`DELETE FROM "${t}"`).run();
        for (const [t, rows] of Object.entries(data)) {
          if (!live.has(t) || !Array.isArray(rows) || !rows.length) continue;
          const cols = new Set(db.prepare(`SELECT name FROM pragma_table_info('${t.replace(/'/g, "''")}')`).all().map((c) => c.name));
          for (const row of rows) {
            const keys = Object.keys(row).filter((k) => cols.has(k));
            db.prepare(`INSERT INTO "${t}" (${keys.map((k) => `"${k}"`).join(',')}) VALUES (${keys.map(() => '?').join(',')})`).run(...keys.map((k) => row[k]));
          }
        }
        if (db.pragma('foreign_key_check').length) throw new Error('The backup is inconsistent (broken links between records); nothing was changed.');
      })();
    } finally {
      db.pragma('foreign_keys = ON');
    }
    return safety;
  }

  // Runs at each local midnight, for as long as the server is up.
  function schedule() {
    const next = new Date();
    next.setHours(24, 0, 0, 0);
    const t = setTimeout(() => {
      try { console.log('Backup written:', write('backup')); } catch (e) { console.error('Backup failed:', e.message); }
      schedule();
    }, next - Date.now());
    t.unref();
  }

  return { write: () => write('backup'), list, restore, schedule };
};
