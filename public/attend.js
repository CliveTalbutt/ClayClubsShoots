document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-attend]');
  if (b) { document.getElementById(b.dataset.attend)?.showModal(); return; }
  const d = e.target;
  if (d.tagName === 'DIALOG' && d.classList.contains('attend-dialog')) d.close();
});
