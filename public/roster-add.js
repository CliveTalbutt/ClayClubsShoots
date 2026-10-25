(function () {
  var form = document.querySelector('form[action="/shooters/roster/add"]');
  if (!form) return;
  var name = form.elements.name, email = form.elements.email;
  var btn = form.querySelector('button');
  function update() {
    btn.hidden = !(name.value.trim() && email.value.trim() && email.checkValidity());
  }
  form.addEventListener('input', update);
  update();
})();
