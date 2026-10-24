const shootForm = document.querySelector('#results-shoot-form');
const shootSelect = document.querySelector('#results-shoot');

if (shootForm && shootSelect) {
  shootSelect.addEventListener('change', () => {
    if (shootSelect.value) shootForm.requestSubmit();
  });
}

const resultsTable = document.querySelector('#results-table');
const resultsFilter = document.querySelector('#results-filter');

if (resultsTable && resultsFilter) {
  const rows = [...resultsTable.tBodies[0].rows];
  const visibleCount = document.querySelector('#results-visible-count');

  resultsFilter.addEventListener('input', () => {
    const query = resultsFilter.value.trim().toLocaleLowerCase();
    let count = 0;
    rows.forEach((row) => {
      row.hidden = !row.dataset.shooter.includes(query);
      if (!row.hidden) count += 1;
    });
    visibleCount.textContent = count;
    document.querySelector('#results-count').hidden = query === '';
  });

  resultsTable.querySelectorAll('.results-sort').forEach((button) => {
    button.addEventListener('click', () => {
      const column = Number(button.dataset.sortColumn);
      const header = button.closest('th');
      const ascending = header.getAttribute('aria-sort') !== 'ascending';
      resultsTable.querySelectorAll('thead th').forEach((th) => {
        th.setAttribute('aria-sort', 'none');
        th.querySelector('.results-sort span').textContent = '↕';
      });
      header.setAttribute('aria-sort', ascending ? 'ascending' : 'descending');
      button.querySelector('span').textContent = ascending ? '↑' : '↓';

      rows.sort((a, b) => {
        const aCell = a.cells[column];
        const bCell = b.cells[column];
        const aValue = aCell.dataset.sortValue ?? aCell.textContent.trim();
        const bValue = bCell.dataset.sortValue ?? bCell.textContent.trim();
        if (aValue === '' || bValue === '') {
          if (aValue !== bValue) return aValue === '' ? 1 : -1;
          return 0;
        }
        const result = header.dataset.sortType === 'number'
          ? Number(aValue) - Number(bValue)
          : aValue.localeCompare(bValue, undefined, { sensitivity: 'base' });
        return ascending ? result : -result;
      });
      rows.forEach((row) => resultsTable.tBodies[0].append(row));
    });
  });
}

const shooterDialog = document.querySelector('#shooter-dialog');

if (resultsTable && shooterDialog) {
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

  resultsTable.querySelectorAll('.shooter-name').forEach((nameCell) => {
    nameCell.addEventListener('mouseenter', () => showStats(nameCell));
    nameCell.addEventListener('focus', () => showStats(nameCell));
    nameCell.addEventListener('mouseleave', () => shooterDialog.close());
    nameCell.addEventListener('blur', () => shooterDialog.close());
    nameCell.addEventListener('keydown', (e) => { if (e.key === 'Escape') shooterDialog.close(); });
  });
}

const shareMenu = document.querySelector('#share-menu');

if (resultsTable && shareMenu) {
  const note = document.querySelector('#share-note');
  const headers = [...resultsTable.tHead.rows[0].cells].map((th) => th.textContent.replace(/[↕↑↓]/g, '').trim());
  const visibleRows = () => [...resultsTable.tBodies[0].rows].filter((row) => !row.hidden);
  const cellValue = (cell) => cell.dataset.export ?? cell.textContent.replace(/\s+/g, ' ').trim();
  const title = `${resultsTable.dataset.title} – ${resultsTable.dataset.date}${resultsTable.dataset.venue ? ` – ${resultsTable.dataset.venue}` : ''}`;
  const totalIndex = headers.findIndex((h) => h.startsWith('Total'));
  const avgIndex = headers.indexOf('Avg %');
  const placeIndex = headers.indexOf('Place');

  const summary = (limit) => {
    const medals = ['🥇', '🥈', '🥉'];
    const rows = visibleRows().slice(0, limit);
    const lines = rows.map((row) => {
      const c = [...row.cells].map(cellValue);
      const place = Number(c[placeIndex]);
      return `${medals[place - 1] ?? `${place}.`} ${c[0]} – ${c[totalIndex]} (${c[avgIndex]})`;
    });
    return `${title}\n\n${lines.join('\n')}`;
  };

  const csvEscape = (value) => {
    let text = String(value);
    // prevent spreadsheet formula injection from shooter names
    if (/^[=+\-@\t\r]/.test(text) && Number.isNaN(Number(text))) text = `'${text}`;
    return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
  };

  const actions = {
    csv() {
      const lines = [headers, ...visibleRows().map((row) => [...row.cells].map(cellValue))];
      const blob = new Blob([`\ufeff${lines.map((l) => l.map(csvEscape).join(',')).join('\r\n')}`], { type: 'text/csv;charset=utf-8' });
      const link = document.createElement('a');
      link.href = URL.createObjectURL(blob);
      link.download = `${title.replace(/[^\w-]+/g, '-').replace(/-+/g, '-')}.csv`;
      document.body.append(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(link.href), 1000);
      return 'Spreadsheet downloaded';
    },
    email() {
      window.location.href = `mailto:?subject=${encodeURIComponent(title)}&body=${encodeURIComponent(summary(50))}`;
      return 'Opening your email app';
    },
    x() {
      window.open(`https://twitter.com/intent/tweet?text=${encodeURIComponent(summary(5))}`, '_blank', 'noopener');
      return 'Opening X';
    },
    whatsapp() {
      window.open(`https://wa.me/?text=${encodeURIComponent(summary(10))}`, '_blank', 'noopener');
      return 'Opening WhatsApp';
    },
    native() {
      navigator.share({ title, text: summary(10) }).catch(() => {});
      return '';
    },
  };

  if (navigator.share) shareMenu.querySelector('[data-share="native"]').hidden = false;

  shareMenu.querySelectorAll('[data-share]').forEach((button) => {
    button.addEventListener('click', () => {
      note.textContent = actions[button.dataset.share]();
      shareMenu.open = false;
      setTimeout(() => { note.textContent = ''; }, 3000);
    });
  });
  document.addEventListener('click', (e) => { if (!shareMenu.contains(e.target)) shareMenu.open = false; });
  shareMenu.addEventListener('keydown', (e) => { if (e.key === 'Escape') { shareMenu.open = false; shareMenu.querySelector('summary').focus(); } });
}
