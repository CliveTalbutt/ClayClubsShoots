// Asks before submitting any form marked with data-confirm (CSP forbids inline handlers).
document.addEventListener('submit', (e) => {
  const msg = e.target.dataset?.confirm;
  if (msg && !window.confirm(msg)) e.preventDefault();
});
