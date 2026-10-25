document.addEventListener('click', (e) => {
  const btn = e.target.closest('[data-dialog]');
  if (btn) {
    const d = document.getElementById(btn.dataset.dialog);
    if (d && d.showModal) d.showModal();
    return;
  }
  // Click on the backdrop closes an open club dialog.
  if (e.target.classList && e.target.classList.contains('club-dialog')) e.target.close();
});
