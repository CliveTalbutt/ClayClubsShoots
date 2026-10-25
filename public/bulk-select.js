// Shows the bulk delete button only while at least one shoot is ticked.
(() => {
  const form = document.getElementById('bulk-delete');
  if (!form) return;
  const boxes = [...document.querySelectorAll('.shoot-select')];
  const all = document.getElementById('select-all');
  const count = document.getElementById('bulk-count');
  const update = () => {
    const n = boxes.filter((b) => b.checked).length;
    form.hidden = n === 0;
    count.textContent = n;
    if (all) { all.checked = n === boxes.length; all.indeterminate = n > 0 && n < boxes.length; }
  };
  boxes.forEach((b) => b.addEventListener('change', update));
  if (all) all.addEventListener('change', () => { boxes.forEach((b) => { b.checked = all.checked; }); update(); });
  update();
})();
