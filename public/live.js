// Polls for new/changed results and refreshes the page when they arrive.
const watched = ['/results', '/leaderboard', '/dashboard', '/shoots/', '/shooters'];

if (watched.some((p) => location.pathname.startsWith(p))) {
  let last = null;
  const busy = () => {
    const a = document.activeElement;
    return a && (a.matches('input, textarea') || a.isContentEditable);
  };
  // Keep the shoot dropdown current in place, even while it is open or focused.
  const refreshDropdown = async () => {
    const select = document.getElementById('results-shoot');
    if (!select) return;
    const html = await (await fetch(location.href, { cache: 'no-store' })).text();
    const fresh = new DOMParser().parseFromString(html, 'text/html').getElementById('results-shoot');
    if (!fresh) return;
    const keep = select.value;
    select.replaceChildren(...[...fresh.children].map((o) => document.importNode(o, true)));
    if ([...select.options].some((o) => o.value === keep)) select.value = keep;
  };
  const check = async () => {
    if (document.hidden) return;
    try {
      const res = await fetch('/live', { headers: { Accept: 'application/json' }, cache: 'no-store' });
      if (!res.ok) return;
      const { v } = await res.json();
      if (last === null) last = v;
      else if (v !== last) {
        last = v;
        await refreshDropdown();
        if (!busy() && document.activeElement?.tagName !== 'SELECT') location.reload();
      }
    } catch { /* offline or restarting: try again next time */ }
  };
  check();
  setInterval(check, 5000);
  document.addEventListener('visibilitychange', check);
}
