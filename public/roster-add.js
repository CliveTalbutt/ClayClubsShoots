(function () {
  var form = document.querySelector('form[action="/shooters/roster/add"]');
  if (!form) return;
  var name = form.elements.name, email = form.elements.email;
  var btn = form.querySelector('button');
  var proper = function (v) {
    return v.toLowerCase().replace(/(^|[\s'’-])(\p{L})/gu, function (m, p, c) { return p + c.toUpperCase(); });
  };
  name.addEventListener('input', function () {
    var pos = name.selectionStart, v = proper(name.value);
    if (v !== name.value) { name.value = v; name.setSelectionRange(pos, pos); }
  });
  name.addEventListener('blur', function () { name.value = proper(name.value.trim().replace(/\s+/g, ' ')); });
  function update() {
    btn.hidden = !(name.value.trim() && email.value.trim() && email.checkValidity());
  }
  form.addEventListener('input', update);
  update();
})();
