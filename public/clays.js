// Hover (or focus) a stand score on the results table to see each clay hit and missed.
(function () {
  var pop = document.createElement('div');
  pop.className = 'shooter-dialog clays-pop';
  pop.setAttribute('role', 'tooltip');
  pop.hidden = true;
  document.body.appendChild(pop);

  function el(tag, text, cls) {
    var n = document.createElement(tag);
    if (text != null) n.textContent = text;
    if (cls) n.className = cls;
    return n;
  }

  function show(td) {
    var d = JSON.parse(td.dataset.clays);
    var misses = d.total - d.hits;
    var head = el('h3', d.shooter + ' \u2013 stand ' + d.stand);
    var sub = el('p', d.hits + ' hit' + (d.hits === 1 ? '' : 's') + ', ' + misses + ' miss' + (misses === 1 ? '' : 'es') + ' (of ' + d.total + ')', 'muted');
    if (!d.pattern) {
      pop.replaceChildren(head, sub, el('p', 'The order of hits and misses was not recorded for this shoot.', 'muted'));
    } else {
      var row = el('div', null, 'clay-row');
      d.pattern.split('').forEach(function (c, i) {
        var cls = c === '1' ? 'clay hit' : c === '0' ? 'clay miss' : 'clay none';
        var chip = el('span', c === '1' ? '\u2713' : c === '0' ? '\u2717' : '\u2013', cls);
        chip.title = 'Clay ' + (i + 1) + ': ' + (c === '1' ? 'hit' : c === '0' ? 'miss' : 'not shot');
        row.append(chip);
      });
      pop.replaceChildren(head, sub, row);
    }
    pop.hidden = false;
    var r = td.getBoundingClientRect();
    pop.style.left = Math.max(8, Math.min(r.left, window.innerWidth - pop.offsetWidth - 8)) + 'px';
    pop.style.top = (r.bottom + 6) + 'px';
  }
  function hide() { pop.hidden = true; }

  // Delegated so it survives the live refresh replacing the table.
  document.addEventListener('mouseover', function (e) {
    var td = e.target.closest && e.target.closest('td[data-clays]');
    if (td) show(td); else if (!e.target.closest('.clays-pop')) hide();
  });
  document.addEventListener('focusin', function (e) {
    var td = e.target.closest && e.target.closest('td[data-clays]');
    if (td) show(td);
  });
  document.addEventListener('focusout', hide);
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') hide(); });
  window.addEventListener('scroll', hide, true);
})();
