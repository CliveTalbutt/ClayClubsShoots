const shooterDialog = document.querySelector('#shooter-dialog');

if (shooterDialog) {
  const cell = (tag, text, className) => {
    const el = document.createElement(tag);
    el.textContent = text;
    if (className) el.className = className;
    return el;
  };
  const fmt = (value, suffix = '') => (value == null ? '–' : `${value.toFixed(1)}${suffix}`);

  // "Send results" button; asks for an email address first when the shooter has none.
  const sendArea = (nameCell) => {
    const name = nameCell.dataset.name;
    const wrap = cell('div', '', 'shooter-send');
    const msg = cell('p', '', 'shooter-send-msg muted');
    msg.setAttribute('role', 'status');
    const button = cell('button', 'Send results', 'btn small secondary');
    button.type = 'button';
    const post = async (email) => {
      button.disabled = true;
      msg.textContent = 'Sending…';
      try {
        const body = new URLSearchParams({ _csrf: shooterDialog.dataset.csrf, name });
        if (email) body.set('email', email);
        const res = await fetch('/shooters/send-all', { method: 'POST', body, headers: { Accept: 'application/json' } });
        const data = await res.json().catch(() => ({ ok: false, message: 'Something went wrong.' }));
        if (data.message === 'needs_email') { askEmail(); return; }
        msg.textContent = data.message;
        if (data.ok) { nameCell.dataset.hasEmail = '1'; wrap.querySelector('input')?.remove(); }
      } catch { msg.textContent = 'Could not reach the server.'; }
      button.disabled = false;
    };
    const askEmail = () => {
      let input = wrap.querySelector('input');
      if (!input) {
        input = document.createElement('input');
        input.type = 'email';
        input.maxLength = 200;
        input.placeholder = 'Email address for ' + name;
        input.setAttribute('aria-label', 'Email address for ' + name);
        input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); button.click(); } });
        wrap.insertBefore(input, button);
      }
      button.disabled = false;
      msg.textContent = 'No email saved for this shooter. Enter one to send.';
      input.focus();
    };
    button.addEventListener('click', () => {
      const input = wrap.querySelector('input');
      if (input) {
        if (!input.value.trim() || !input.checkValidity()) { msg.textContent = 'Enter a valid email address.'; input.focus(); return; }
        post(input.value.trim());
      } else if (nameCell.dataset.hasEmail === '1') post('');
      else askEmail();
    });
    wrap.append(button, msg);
    return wrap;
  };

  let closeTimer;
  const closeSoon = () => { clearTimeout(closeTimer); closeTimer = setTimeout(() => shooterDialog.close(), 250); };
  const keepOpen = () => clearTimeout(closeTimer);
  shooterDialog.addEventListener('mouseenter', keepOpen);
  shooterDialog.addEventListener('mouseleave', closeSoon);
  shooterDialog.addEventListener('focusin', keepOpen);
  shooterDialog.addEventListener('focusout', () => { if (!shooterDialog.matches(':hover')) closeSoon(); });
  shooterDialog.addEventListener('keydown', (e) => { if (e.key === 'Escape') shooterDialog.close(); });

  const showStats = (nameCell) => {
    keepOpen();
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
    shooterDialog.replaceChildren(heading, table, sendArea(nameCell));
    shooterDialog.show();
    const rect = nameCell.getBoundingClientRect();
    const left = Math.min(rect.left, window.innerWidth - shooterDialog.offsetWidth - 8);
    shooterDialog.style.left = `${Math.max(8, left)}px`;
    shooterDialog.style.top = `${rect.bottom + 6}px`;
  };

  document.querySelectorAll('.shooter-name').forEach((nameCell) => {
    nameCell.addEventListener('mouseenter', () => showStats(nameCell));
    nameCell.addEventListener('focus', () => showStats(nameCell));
    nameCell.addEventListener('mouseleave', closeSoon);
    nameCell.addEventListener('blur', closeSoon);
    nameCell.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') shooterDialog.close();
      else if (e.key === 'Enter') shooterDialog.querySelector('button, input')?.focus();
    });
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
