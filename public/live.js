// Polls for new/changed results and refreshes the page when they arrive.
const watched = ['/results', '/leaderboard', '/dashboard', '/shoots/', '/shooters'];

if (watched.some((p) => location.pathname.startsWith(p))) {
  let last = null;
  let lastAdded = null;
  const busy = () => {
    const a = document.activeElement;
    return a && (a.matches('input, textarea') || a.isContentEditable || !!a.closest('.shoot-picker'));
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
      const { v, added } = await res.json();
      const isNew = lastAdded !== null && added > lastAdded;
      lastAdded = added;
      // A newly added shoot takes over the results page.
      if (isNew && location.pathname.startsWith('/results') && !busy()) { location.href = '/results'; return; }
      if (last === null) last = v;
      else if (v !== last) {
        last = v;
        await refreshDropdown();
        if (!busy() && document.activeElement?.tagName !== 'SELECT') {
          sessionStorage.setItem('liveReload', '1');
          location.reload();
        }
      }
    } catch { /* offline or restarting: try again next time */ }
  };
  check();
  setInterval(check, 500);
  document.addEventListener('visibilitychange', check);
}
