// After a live refresh (see live.js), flash the results cells whose value changed.
(() => {
  const table = document.getElementById('results-table');
  if (!table) return;
  const storeKey = 'resultsSnapshot';
  const shootId = new URLSearchParams(location.search).get('shoot') || '';
  const read = () => {
    const cells = {};
    table.querySelectorAll('tbody tr[data-shooter]').forEach((row) => {
      [...row.children].forEach((cell, i) => {
        if (i > 0) cells[`${row.dataset.shooter}:${i}`] = cell.textContent.replace(/\s+/g, ' ').trim();
      });
    });
    return cells;
  };
  const now = read();

  let before = null;
  try {
    const saved = JSON.parse(sessionStorage.getItem(storeKey) || 'null');
    if (saved && saved.shoot === shootId && sessionStorage.getItem('liveReload') === '1') before = saved.cells;
  } catch { /* ignore unreadable snapshot */ }
  sessionStorage.removeItem('liveReload');

  if (before) {
    table.querySelectorAll('tbody tr[data-shooter]').forEach((row) => {
      [...row.children].forEach((cell, i) => {
        const key = `${row.dataset.shooter}:${i}`;
        if (i === 0 || now[key] === before[key]) return;
        if (before[key] === undefined && ['', '–'].includes(now[key])) return;
        cell.classList.add('value-flash');
        cell.addEventListener('animationend', () => cell.classList.remove('value-flash'), { once: true });
      });
    });
  }
  sessionStorage.setItem(storeKey, JSON.stringify({ shoot: shootId, cells: now }));
})();
