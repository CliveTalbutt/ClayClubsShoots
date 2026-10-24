(() => {
  const select = document.getElementById('social-platform');
  const groups = document.querySelectorAll('.social-fields');
  if (!select) return;
  const show = () => {
    groups.forEach((g) => {
      const on = g.dataset.platform === select.value;
      g.hidden = !on;
      g.querySelectorAll('input').forEach((i) => { i.disabled = !on; });
    });
  };
  select.addEventListener('change', show);
  show();
})();
