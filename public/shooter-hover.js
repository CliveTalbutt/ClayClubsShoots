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


// Hint showing what each CPSA class means as an average, for anything marked .cpsa-hint
const cpsaData = document.querySelector('#cpsa-data');
const cpsaTargets = document.querySelectorAll('.cpsa-hint');

if (cpsaData && cpsaTargets.length) {
  const classes = JSON.parse(cpsaData.textContent);
  const pop = document.createElement('div');
  pop.className = 'shooter-dialog';
  pop.hidden = true;
  pop.setAttribute('role', 'tooltip');
  document.body.append(pop);

  const build = (current, basis) => {
    const h = document.createElement('h3');
    h.textContent = 'CPSA classes by average %';
    const table = document.createElement('table');
    classes.forEach((c, i) => {
      const upper = i === 0 ? null : classes[i - 1].min;
      const range = i === 0 ? `${c.min}% and above` : c.min === 0 ? `under ${upper}%` : `${c.min}% to under ${upper}%`;
      const row = table.insertRow();
      if (c.name === current) row.className = 'cpsa-current';
      const label = document.createElement('th');
      label.textContent = `${c.icon} ${c.name}`;
      const cellRange = row.insertCell();
      cellRange.textContent = range;
      row.prepend(label);
    });
    const note = document.createElement('p');
    note.className = 'muted';
    note.textContent = `Based on ${basis || 'the last 12 months'} average. Unofficial estimate.`;
    pop.replaceChildren(h, table, note);
  };

  const show = (el) => {
    build(el.dataset.cpsa, el.dataset.basis);
    pop.hidden = false;
    const rect = el.getBoundingClientRect();
    const left = Math.min(rect.left, window.innerWidth - pop.offsetWidth - 8);
    pop.style.left = `${Math.max(8, left)}px`;
    const below = rect.bottom + 6;
    pop.style.top = `${below + pop.offsetHeight > window.innerHeight ? Math.max(8, rect.top - pop.offsetHeight - 6) : below}px`;
  };
  const hide = () => { pop.hidden = true; };

  cpsaTargets.forEach((el) => {
    el.addEventListener('mouseenter', () => show(el));
    el.addEventListener('focus', () => show(el));
    el.addEventListener('mouseleave', hide);
    el.addEventListener('blur', hide);
    el.addEventListener('keydown', (e) => { if (e.key === 'Escape') hide(); });
  });
}
