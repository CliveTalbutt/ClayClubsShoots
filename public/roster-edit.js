(function () {
  var form = document.getElementById('roster-edit');
  if (!form) return;
  var rows = document.querySelectorAll('tr[data-edit]');
  var selected = null;
  function pick(row) {
    var d = JSON.parse(row.dataset.edit);
    if (selected) selected.classList.remove('selected');
    selected = row; row.classList.add('selected');
    form.action = '/shooters/roster/' + d.id + '/edit';
    form.elements.name.value = d.name;
    form.elements.email.value = d.email;
    form.elements.kind.value = d.kind;
    form.elements.status.value = d.status;
    form.querySelector('[data-edit-guid]').textContent = 'ID ' + d.guid;
    form.hidden = false;
    form.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    form.elements.name.focus();
  }
  rows.forEach(function (row) {
    row.addEventListener('click', function (e) {
      if (e.target.closest('button, a, form, input, select, dialog')) return;
      pick(row);
    });
  });
  form.elements.name.addEventListener('input', function () {
    var el = form.elements.name, pos = el.selectionStart;
    var v = el.value.toLowerCase().replace(/(^|[\s'’-])(\p{L})/gu, function (m, p, c) { return p + c.toUpperCase(); });
    if (v !== el.value) { el.value = v; el.setSelectionRange(pos, pos); }
  });
  form.querySelector('[data-edit-cancel]').addEventListener('click', function () {
    form.hidden = true;
    if (selected) selected.classList.remove('selected');
    selected = null;
  });
})();
