// One form serves both "new member" and "edit member"; clicking a row switches it to edit mode.
(function () {
  var form = document.getElementById('roster-form');
  if (!form) return;
  var el = form.elements, title = form.querySelector('[data-form-title]');
  var submit = form.querySelector('[data-form-submit]'), cancel = form.querySelector('[data-form-cancel]');
  var status = form.querySelector('[data-edit-only]'), guid = form.querySelector('[data-edit-guid]');
  var remove = form.querySelector('[data-form-remove]'), delForm = document.getElementById('roster-delete');
  var addAction = form.getAttribute('action');
  var selected = null;
  var guestOnly = form.querySelector('[data-guest-only]');

  var proper = function (v) {
    return v.toLowerCase().replace(/(^|[\s'’-])(\p{L})/gu, function (m, p, c) { return p + c.toUpperCase(); });
  };
  el.name.addEventListener('input', function () {
    var pos = el.name.selectionStart, v = proper(el.name.value);
    if (v !== el.name.value) { el.name.value = v; el.name.setSelectionRange(pos, pos); }
  });
  el.name.addEventListener('blur', function () { el.name.value = proper(el.name.value.trim().replace(/\s+/g, ' ')); });

  function ready() {
    var guest = el.kind.value === 'guest';
    guestOnly.hidden = !guest;
    el.email.required = !guest;
    submit.hidden = !(el.name.value.trim() && (guest || el.email.value.trim()) && el.email.checkValidity());
  }
  form.addEventListener('input', ready);

  function setMode(row) {
    if (selected) selected.classList.remove('selected');
    selected = row;
    var editing = !!row;
    status.hidden = status.disabled = !editing;
    cancel.hidden = remove.hidden = !editing;
    if (editing) {
      var d = JSON.parse(row.dataset.edit);
      row.classList.add('selected');
      form.action = '/shooters/roster/' + d.id + '/edit';
      delForm.action = '/shooters/roster/' + d.id + '/delete';
      delForm.dataset.confirm = 'Remove ' + d.name + ' from the membership? Past results are kept. This cannot be undone.';
      title.textContent = 'Edit member';
      submit.textContent = 'Save';
      el.name.value = d.name; el.email.value = d.email; el.kind.value = d.kind; status.value = d.status; el.signedGuestBook.checked = !!d.signed;
      guid.textContent = 'ID ' + d.guid;
      form.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      el.name.focus();
    } else {
      form.action = addAction;
      title.textContent = 'New member';
      submit.textContent = 'Add to membership';
      form.reset();
      guid.textContent = '';
    }
    ready();
  }

  document.querySelectorAll('tr[data-edit]').forEach(function (row) {
    row.addEventListener('click', function (e) {
      if (e.target.closest('button, a, form, input, select, dialog')) return;
      setMode(row);
    });
  });
  cancel.addEventListener('click', function () { setMode(null); });
  ready();
})();
