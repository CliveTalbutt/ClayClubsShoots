// Admin-only replacement for the "Choose a shoot" dropdown. Each shoot has a red X that marks it
// for deletion; a Delete button then removes every marked shoot. The native <select> stays in the
// page (hidden) so selecting a shoot and the live refresh keep working as before.
(() => {
  const form = document.getElementById('results-shoot-form');
  const select = document.getElementById('results-shoot');
  const deleteForm = document.getElementById('bulk-delete');
  if (!form || !select) return;
  const canDelete = form.dataset.canDelete === '1' && !!deleteForm;

  const marked = new Set();
  const wrap = document.createElement('div');
  wrap.className = 'shoot-picker';
  const toggle = document.createElement('button');
  toggle.type = 'button';
  toggle.className = 'shoot-picker-button';
  toggle.setAttribute('aria-haspopup', 'listbox');
  const list = document.createElement('ul');
  list.className = 'shoot-picker-list';
  list.hidden = true;
  const del = document.createElement('button');
  del.type = 'button';
  del.className = 'btn small danger shoot-picker-delete';
  del.hidden = true;
  wrap.append(toggle, list, del);
  select.hidden = true;
  select.after(wrap);

  const render = () => {
    toggle.replaceChildren();
    const text = document.createElement('span');
    text.className = 'shoot-picker-text';
    text.textContent = (select.selectedOptions[0] || select.options[0]).textContent;
    const arrow = document.createElement('span');
    arrow.className = 'shoot-picker-arrow';
    arrow.textContent = '▾';
    toggle.append(text, arrow);
    list.replaceChildren();
    [...select.options].filter((o) => o.value).forEach((o) => {
      const li = document.createElement('li');
      li.className = 'shoot-picker-item' + (o.value === select.value ? ' current' : '') + (marked.has(o.value) ? ' marked' : '');
      const label = document.createElement('button');
      label.type = 'button';
      label.className = 'shoot-picker-label';
      label.textContent = o.textContent;
      label.addEventListener('click', () => {
        list.hidden = true;
        select.value = o.value;
        select.dispatchEvent(new Event('change', { bubbles: true }));
      });
      const x = document.createElement('button');
      x.type = 'button';
      x.className = 'shoot-picker-x';
      x.textContent = '✕';
      x.title = marked.has(o.value) ? 'Unmark this shoot' : 'Mark this shoot for deletion';
      x.setAttribute('aria-label', x.title);
      x.addEventListener('click', (e) => {
        e.stopPropagation();
        if (!marked.delete(o.value)) marked.add(o.value);
        render();
      });
      li.append(label);
      if (canDelete) li.append(x);
      list.append(li);
    });
    del.hidden = marked.size === 0;
    del.textContent = `Delete marked (${marked.size})`;
  };

  // Show at most 10 shoots at once; any more scroll.
  const fitList = () => {
    const items = [...list.children].slice(0, 10);
    list.style.maxHeight = items.length ? `${items.reduce((h, li) => h + li.offsetHeight, 0) + 10}px` : '';
  };
  toggle.addEventListener('click', () => { list.hidden = !list.hidden; toggle.setAttribute('aria-expanded', String(!list.hidden)); if (!list.hidden) fitList(); });
  document.addEventListener('click', (e) => { if (!wrap.contains(e.target)) list.hidden = true; });
  const submitDelete = () => {
    deleteForm.querySelectorAll('input[name="ids"]').forEach((i) => i.remove());
    marked.forEach((id) => {
      const input = document.createElement('input');
      input.type = 'hidden';
      input.name = 'ids';
      input.value = id;
      deleteForm.append(input);
    });
    deleteForm.submit();
  };

  // Styled confirmation dialog in place of the browser's default confirm box.
  const confirmDelete = () => {
    const n = marked.size;
    const overlay = document.createElement('div');
    overlay.className = 'modal-overlay';
    overlay.innerHTML = '<div class="modal" role="dialog" aria-modal="true"><h3></h3><p></p><div class="modal-actions"><button type="button" class="btn small" data-act="cancel">Cancel</button><button type="button" class="btn small danger" data-act="ok">Delete</button></div></div>';
    overlay.querySelector('h3').textContent = `Delete ${n} shoot${n === 1 ? '' : 's'}?`;
    overlay.querySelector('p').textContent = `The ${n === 1 ? 'shoot and its' : 'marked shoots and all their'} results will be permanently removed. This cannot be undone.`;
    const close = () => { overlay.remove(); document.removeEventListener('keydown', onKey); };
    const onKey = (e) => { if (e.key === 'Escape') close(); };
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay || e.target.dataset.act === 'cancel') close();
      else if (e.target.dataset.act === 'ok') { close(); submitDelete(); }
    });
    document.addEventListener('keydown', onKey);
    document.body.append(overlay);
    overlay.querySelector('[data-act="cancel"]').focus();
  };
  del.addEventListener('click', () => { if (marked.size) confirmDelete(); });

  // The live refresh rewrites the hidden select's options in place; keep the list in step.
  new MutationObserver(() => {
    const ids = new Set([...select.options].map((o) => o.value));
    [...marked].forEach((id) => { if (!ids.has(id)) marked.delete(id); });
    render();
  }).observe(select, { childList: true });
  render();
})();
