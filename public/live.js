// Polls for new/changed results and refreshes the page when they arrive.
const watched = ['/results', '/compare', '/leaderboard', '/dashboard', '/shoots/'];

if (watched.some((p) => location.pathname.startsWith(p))) {
  let last = null;
  const busy = () => {
    const a = document.activeElement;
    return a && (a.matches('input, textarea, select') || a.isContentEditable);
  };
  const check = async () => {
    if (document.hidden) return;
    try {
      const res = await fetch('/live', { headers: { Accept: 'application/json' }, cache: 'no-store' });
      if (!res.ok) return;
      const { v } = await res.json();
      if (last === null) last = v;
      else if (v !== last && !busy()) location.reload();
    } catch { /* offline or restarting: try again next time */ }
  };
  check();
  setInterval(check, 5000);
  document.addEventListener('visibilitychange', check);
}
