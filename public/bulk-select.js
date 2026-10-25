// Shoot list tools: search, sortable columns, select-all (shown rows only) and a
// bulk delete button that appears while at least one shoot is ticked.
(() => {
  const form = document.getElementById('bulk-delete');
  if (!form) return;
  const table = document.getElementById('shoots-table');
  const body = table && table.tBodies[0];
  const all = document.getElementById('select-all');
  const count = document.getElementById('bulk-count');
  const search = document.getElementById('shoot-search');
  const rows = () => [...body.rows];
  const shown = () => rows().filter((r) => !r.hidden);
  const box = (r) => r.querySelector('.shoot-select');

  const update = () => {
    const ticked = rows().filter((r) => box(r).checked).length;
    form.hidden = ticked === 0;
    count.textContent = ticked;
    const vis = shown();
    const visTicked = vis.filter((r) => box(r).checked).length;
    all.checked = vis.length > 0 && visTicked === vis.length;
    all.indeterminate = visTicked > 0 && visTicked < vis.length;
  };

  rows().forEach((r) => box(r).addEventListener('change', update));
  all.addEventListener('change', () => { shown().forEach((r) => { box(r).checked = all.checked; }); update(); });

  if (search) {
    search.addEventListener('input', () => {
      const q = search.value.trim().toLowerCase();
      rows().forEach((r) => { r.hidden = q !== '' && !r.textContent.toLowerCase().includes(q); });
      update();
    });
  }

  const cellValue = (r, col, type) => {
    const c = r.cells[col + 1];
    const v = c.dataset.v ?? c.textContent.trim();
    return type === 'number' ? Number(v) || 0 : v.toLowerCase();
  };
  table.querySelectorAll('.sort-button').forEach((btn) => {
    btn.addEventListener('click', () => {
      const col = Number(btn.dataset.sort);
      const dir = btn.dataset.dir === 'asc' ? 'desc' : 'asc';
      table.querySelectorAll('.sort-button').forEach((b) => { delete b.dataset.dir; b.querySelector('.sort-indicator').textContent = ''; });
      btn.dataset.dir = dir;
      btn.querySelector('.sort-indicator').textContent = dir === 'asc' ? '↑' : '↓';
      const sign = dir === 'asc' ? 1 : -1;
      rows().sort((a, b) => {
        const x = cellValue(a, col, btn.dataset.type), y = cellValue(b, col, btn.dataset.type);
        return (x < y ? -1 : x > y ? 1 : 0) * sign;
      }).forEach((r) => body.appendChild(r));
    });
  });
  update();
})();
