const shooterDialog = document.querySelector('#shooter-dialog');

if (shooterDialog) {
  const cell = (tag, text, className) => {
    const el = document.createElement(tag);
    el.textContent = text;
    if (className) el.className = className;
    return el;
  };
  const fmt = (value, suffix = '') => (value == null ? '–' : `${value.toFixed(1)}${suffix}`);

  const showStats = (nameCell) => {
    const stats = JSON.parse(nameCell.dataset.stats);
    const table = document.createElement('table');
    const head = table.createTHead().insertRow();
    ['', 'All time', 'Last 12 months'].forEach((text) => head.append(cell('th', text, text ? 'num' : '')));
    [
      ['Shoots', (s) => String(s.shoots)],
      ['Average score', (s) => fmt(s.avgScore)],
      ['Average %', (s) => fmt(s.avgPct, '%')],
    ].forEach(([label, get]) => {
      const row = table.insertRow();
      row.append(cell('th', label), cell('td', get(stats.allTime), 'num'), cell('td', get(stats.last12), 'num'));
    });
    const heading = cell('h3', nameCell.dataset.name);
    if (stats.cpsa) {
      const badge = cell('span', `${stats.cpsa.icon} Class ${stats.cpsa.name}`, 'class-badge');
      badge.title = `CPSA class from ${stats.cpsa.basis} average`;
      heading.append(badge);
    } else {
      heading.append(cell('span', 'Unclassified', 'class-badge'));
    }
    shooterDialog.replaceChildren(heading, table);
    shooterDialog.show();
    const rect = nameCell.getBoundingClientRect();
    const left = Math.min(rect.left, window.innerWidth - shooterDialog.offsetWidth - 8);
    shooterDialog.style.left = `${Math.max(8, left)}px`;
    shooterDialog.style.top = `${rect.bottom + 6}px`;
  };

  document.querySelectorAll('.shooter-name').forEach((nameCell) => {
    nameCell.addEventListener('mouseenter', () => showStats(nameCell));
    nameCell.addEventListener('focus', () => showStats(nameCell));
    nameCell.addEventListener('mouseleave', () => shooterDialog.close());
    nameCell.addEventListener('blur', () => shooterDialog.close());
    nameCell.addEventListener('keydown', (e) => { if (e.key === 'Escape') shooterDialog.close(); });
  });
}

