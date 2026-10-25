// Live price for the per-head subscription: 100p per member, 50p per guest.
(function () {
  const m = document.getElementById('est-members');
  const g = document.getElementById('est-guests');
  const out = document.getElementById('est-price');
  if (!m || !g || !out) return;
  function update() {
    const pence = (parseInt(m.value, 10) || 0) * 100 + (parseInt(g.value, 10) || 0) * 50;
    out.textContent = '£' + (pence / 100).toFixed(2);
  }
  m.addEventListener('input', update);
  g.addEventListener('input', update);
  update();
})();
