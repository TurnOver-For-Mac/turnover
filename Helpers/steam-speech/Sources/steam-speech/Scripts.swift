// SPDX-License-Identifier: GPL-3.0-or-later
// The scripts this program installs in Steam's pages and in Electron games (the debugging protocol's
// Runtime.evaluate). They run in the page, call back through a binding, and touch nothing outside it. MIT.

enum Scripts {
    /// Big Picture: Valve's semantics do the work. aria-label first, then a title-like descendant, then the element's
    /// own text, capped, first line only (a news card is not its whole body). Versioned so a newer build replaces an
    /// older observer; named for Steam Speak so it runs beside nothing else that hears the same events.
    static let bigPicture = #"""
    (() => {
      if (window.__steamSpeakReader === 11) return 'already';
      window.__steamSpeakReader = 11;
      if (window.__steamSpeakStop) { try { window.__steamSpeakStop(); } catch (e) {} }
      const clean = s => (s || '').replace(/\s+/g, ' ').trim();
      const firstLine = s => (s || '').split('\n').map(x => x.trim()).filter(Boolean)[0] || '';
      const name = el => {
        const al = el.getAttribute('aria-label'); if (al) return clean(al);
        const ti = el.getAttribute('title'); if (ti) return clean(ti);
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') { const v = (el.type === 'password' ? '' : el.value) || el.getAttribute('placeholder'); if (v) return clean(v); }
        const lb = el.getAttribute('aria-labelledby');
        if (lb) { const t = clean(lb.split(/\s+/).map(id => (document.getElementById(id) || {}).innerText || '').join(' ')); if (t) return t; }
        const cands = Array.from(el.querySelectorAll('h1,h2,h3,h4,[class*="Title" i],[class*="Name" i],[class*="Label" i]'))
          .map(n => clean(firstLine(n.innerText))).filter(s => s && s.length <= 90);
        if (cands.length) return cands.sort((a, b) => a.length - b.length)[0];
        const own = clean(firstLine(el.innerText || el.textContent));
        if (own) return own.length > 90 ? own.slice(0, 90).replace(/\s+\S*$/, '') : own;
        const img = el.querySelector('img[alt]'); if (img && img.alt) return clean(img.alt);
        if (BOX.test(el.getAttribute('role') || '') || (el.tagName === 'INPUT' && /^(checkbox|radio)$/.test(el.type))) return rowText(el);
        return '';
      };
      // A box with no words of its own takes its row's (Add Non-Steam Game: the box, the program and its path are
      // three cells of one row, 16 Oct 2026): the nearest ancestor with a short text.
      const BOX = /^(checkbox|radio|switch)$/;
      const rowText = el => {
        for (let p = el.parentElement, i = 0; p && p !== document.body && i < 5; p = p.parentElement, i++) {
          const t = clean(p.innerText || ''); if (t) return t.length > 160 ? t.slice(0, 160).replace(/\s+\S*$/, '') : t;
        }
        return '';
      };
      const cap = s => s.length > 140 ? s.slice(0, 140).replace(/\s+\S*$/, '') + '…' : s;
      const blurb = (el, nm) => {
        const all = clean(el.innerText || '');
        if (all && all.length > nm.length + 12) return cap(clean(all.replace(nm, '')));
        // A note beside a button, not focusable itself (a game page's "UPDATE FAILED Not enough free disk space"
        // next to Resume; "LAST PLAYED" and "PLAY TIME" next to Play): the next sibling's text, after the pause
        // (16 Oct 2026: Resume instead of Play, and no word of why).
        const nx = el.nextElementSibling;
        if (nx && !/Focusable/.test(nx.className || '')) {
          const t = clean(textBefore(nx)); if (t && t !== nm) return cap(t);
        }
        return '';
      };
      // The text of a container up to its first focusable thing (the note stops where the next control starts).
      const textBefore = root => {
        let out = '';
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
          acceptNode: n => n.nodeType === 1 ? (/Focusable/.test(n.className || '') || /^(BUTTON|A|INPUT)$/.test(n.tagName) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP) : NodeFilter.FILTER_ACCEPT });
        let n; while ((n = walker.nextNode())) { if (n.nodeType === 1) break; out += ' ' + n.data; }
        return out;
      };
      const role = el => el.getAttribute('role') || (el.tagName === 'BUTTON' ? 'button' : el.tagName === 'INPUT' ? (el.type || 'input') : '');
      const state = el => {
        const s = [];
        if (el.getAttribute('aria-selected') === 'true' && el.getAttribute('role') !== 'tab') s.push('selected');
        if (el.getAttribute('aria-checked') === 'true' || el.getAttribute('aria-pressed') === 'true') s.push('on');
        if (el.getAttribute('aria-checked') === 'false' || el.getAttribute('aria-pressed') === 'false') s.push('off');
        if (el.getAttribute('aria-disabled') === 'true') s.push('unavailable');
        const v = el.getAttribute('aria-valuetext') || el.getAttribute('aria-valuenow'); if (v) s.push(v);
        return s.join(', ');
      };
      let last = null, hadGamepadFocus = false;
      // Big Picture moves Valve's own focus class; the desktop window (the library, Settings, the store) moves
      // real DOM focus instead, so where there is no gpfocus the focused element is read (8 Oct 2026).
      // Steam's own menus (the main menu, Quick Access) are pop-up pages that a controller moves through without the
      // Mac's keyboard ever being theirs: they speak whether or not they have it (16 Oct 2026: the
      // controller's Home, Settings and Power menu went silent after its first item).
      const POPUP = /^(MainMenu|QuickAccess)/.test(document.title || '');
      const report = () => {
        // Only the page that has the keyboard speaks: with Steam's menu open, the page behind it kept reporting and
        // cut the menu's items off (14 Oct 2026). Losing the keyboard still says focusGone, below.
        if (!document.hasFocus() && !POPUP) {
          if (last !== null) { last = null; if (hadGamepadFocus) window.__steamSpeak(JSON.stringify({ focusGone: true })); }
          return;
        }
        let el = document.querySelector('.gpfocus');
        if (el) hadGamepadFocus = true;
        else if (!hadGamepadFocus) { el = document.activeElement; if (el === document.body || el === document.documentElement) el = null; }
        if (!el) {
          if (last !== null) { last = null; if (hadGamepadFocus) window.__steamSpeak(JSON.stringify({ focusGone: true })); }
          return;
        }
        if (el === last) return;
        last = el;
        // The desktop window: Tab moved the real focus, so the cursor goes with it and Return presses what has the
        // focus (16 Oct 2026: Tab to "Add Selected Programs", Return, and the cursor's row was ticked instead).
        if (!hadGamepadFocus) syncCursor(el);
        const nm = name(el);
        if (!nm && !role(el)) {
          window.__steamSpeak(JSON.stringify({ skipped: true, tag: el.tagName, cls: (el.className || '').toString().slice(0, 90),
            text: (el.textContent || '').trim().slice(0, 90) }));
          return;
        }
        window.__steamSpeak(JSON.stringify({ name: nm, role: role(el), state: state(el), blurb: blurb(el, nm) }));
      };
      const focusObserver = new MutationObserver(report);
      focusObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['class'], subtree: true });
      const liveObserver = new MutationObserver(muts => {
        for (const m of muts) {
          const el = m.target.nodeType === 1 ? m.target : m.target.parentElement;
          const region = el && el.closest('[aria-live]');
          if (!region) continue;
          const t = clean(region.textContent);
          if (t) window.__steamSpeak(JSON.stringify({ name: t, role: '', state: '' }));
        }
      });
      liveObserver.observe(document.documentElement, { childList: true, characterData: true, subtree: true });
      document.addEventListener('focusin', report, true);
      // The desktop window: almost nothing in it can take keyboard focus (the library home has one link), so
      // Up and Down walk a cursor of TurnOver's own over the visible text and controls, Left and Right over the
      // controls alone, Return or Space presses the one under it, Home and End jump. Only where there is no
      // gamepad focus and no text field has the keyboard (8 Oct 2026).
      const CLICK = 'button,a,[role="button"],[role="tab"],[role="link"],[role="menuitem"],[role="option"],[role="checkbox"],[role="switch"],input,select,textarea,[onclick]';
      const clickableOf = el => {
        const c = el.closest(CLICK); if (c) return c;
        for (let e = el, i = 0; e && e !== document.body && i < 4; e = e.parentElement, i++) { if (getComputedStyle(e).cursor === 'pointer') return e; }
        return null;
      };
      const visible = el => { const r = el.getBoundingClientRect(); if (!r.width && !r.height) return false; const cs = getComputedStyle(el); return cs.visibility !== 'hidden' && cs.display !== 'none'; };
      // A row that holds a box with no words of its own (a list of programs to tick) is one item, the box's: its
      // text is the row's, Return ticks the box. The row is the box's nearest ancestor with a short text.
      const rowOf = box => {
        if (name(box) !== rowText(box)) return null;
        for (let p = box.parentElement, i = 0; p && p !== document.body && i < 5; p = p.parentElement, i++) {
          const t = clean(p.innerText || ''); if (t) return p;
        }
        return null;
      };
      const items = () => {
        const out = [], seen = new Set(), rows = new Map();
        for (const box of document.querySelectorAll('[role="checkbox"],[role="radio"],[role="switch"],input[type="checkbox"],input[type="radio"]')) {
          if (!visible(box)) continue;
          const row = rowOf(box); if (row && !rows.has(row)) rows.set(row, box);
        }
        const rowAbove = el => { for (let p = el, i = 0; p && i < 6; p = p.parentElement, i++) { if (rows.has(p)) return p; } return null; };
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let n;
        while ((n = walker.nextNode())) {
          const t = clean(n.data); if (!t) continue;
          const el = n.parentElement; if (!el || el.closest('script,style,noscript,[aria-hidden="true"]')) continue;
          if (!visible(el)) continue;
          const row = rowAbove(el);
          if (row) { if (seen.has(row)) continue; seen.add(row); const box = rows.get(row); seen.add(box); out.push({ el: row, control: true, text: rowText(box), box }); continue; }
          const c = clickableOf(el);
          const key = c || el; if (seen.has(key)) continue; seen.add(key);
          let nm = t;
          if (c) { const all = clean(c.innerText || ''); if (all && all.length <= 90) nm = all; else if (!all) nm = name(c) || t; }
          out.push({ el: key, control: !!c, text: nm });
          if (out.length > 4000) break;
        }
        for (const el of document.querySelectorAll('input,textarea,select,[role="checkbox"],[role="switch"],[role="slider"]')) {
          if (seen.has(el) || !visible(el)) continue; seen.add(el); out.push({ el, control: true, text: name(el) || el.getAttribute('placeholder') || el.tagName.toLowerCase() });
        }
        return out;
      };
      let cursor = null;
      const roleOf = it => {
        if (!it.control) return '';
        if (it.box) return it.box.getAttribute('role') || it.box.type;
        const el = it.el, r = el.getAttribute('role') || '';
        if (r) return r; if (el.tagName === 'A') return 'link'; if (el.tagName === 'INPUT') return el.type === 'text' || !el.type ? 'text field' : el.type; if (el.tagName === 'SELECT') return 'pop-up';
        return 'button';
      };
      const stateOf = it => {
        const el = it.box || it.el, s = [];
        if (el.getAttribute('aria-selected') === 'true' || /\b(selected|active|Selected|Active)\b/.test(el.className && el.className.toString ? el.className.toString() : '')) s.push('selected');
        const st = state(el); if (st) s.push(st);
        return s.join(', ');
      };
      const say = it => { window.__steamSpeak(JSON.stringify({ name: it.text, role: roleOf(it), state: stateOf(it) })); };
      const move = (step, controlsOnly, edge) => {
        const list = controlsOnly ? items().filter(i => i.control) : items();
        if (!list.length) { window.__steamSpeak(JSON.stringify({ name: 'nothing to read here', role: '', state: '', own: true })); return; }
        let i = cursor ? list.findIndex(x => x.el === cursor) : -1;
        if (edge === 'first') i = 0; else if (edge === 'last') i = list.length - 1;
        else if (i < 0) i = step > 0 ? 0 : list.length - 1;
        else { i += step; if (i < 0 || i >= list.length) { window.__steamSpeak(JSON.stringify({ name: (i < 0 ? 'top' : 'bottom'), role: '', state: '', own: true })); i = Math.max(0, Math.min(list.length - 1, i)); } }
        cursor = list[i].el; cursorBox = list[i].box || null;
        try { cursor.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch (e) {}
        say(list[i]);
      };
      let cursorBox = null;
      const syncCursor = el => {
        if (BOX.test(el.getAttribute('role') || '') || (el.tagName === 'INPUT' && /^(checkbox|radio)$/.test(el.type))) { cursor = rowOf(el) || el; cursorBox = el; }
        else { cursor = el; cursorBox = null; }
      };
      const press = () => {
        if (!cursor) return;
        const el = cursorBox || clickableOf(cursor) || cursor;
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
          try { el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window })); } catch (e) {}
        }
        if (el.focus) { try { el.focus(); } catch (e) {} }
      };
      const editing = () => { const a = document.activeElement; return a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.isContentEditable); };
      const onKey = e => {
        if (document.querySelector('.gpfocus') || editing() || e.metaKey || e.ctrlKey || e.altKey) return;
        let handled = true;
        switch (e.key) {
          case 'ArrowDown': move(1, false); break;
          case 'ArrowUp': move(-1, false); break;
          case 'ArrowRight': move(1, true); break;
          case 'ArrowLeft': move(-1, true); break;
          case 'Home': move(0, false, 'first'); break;
          case 'End': move(0, false, 'last'); break;
          case 'Enter': case ' ': if (cursor) press(); else handled = false; break;
          default: handled = false;
        }
        if (handled) { e.preventDefault(); e.stopPropagation(); }
      };
      window.addEventListener('keydown', onKey, true);
      window.__steamSpeakList = () => items().map(i => (i.control ? '[' + roleOf(i) + '] ' : '') + i.text);
      window.__steamSpeakReport = () => { last = null; report(); };
      window.addEventListener('focus', window.__steamSpeakReport);
      window.__steamSpeakStop = () => { focusObserver.disconnect(); liveObserver.disconnect(); document.removeEventListener('focusin', report, true); window.removeEventListener('keydown', onKey, true); window.removeEventListener('focus', window.__steamSpeakReport); };
      // A box's state said as it switches, not only when you come back to it (16 Oct 2026: Space on a
      // program in Add a Non-Steam Game ticked it silently): aria-checked and aria-pressed changing on the item
      // under the cursor or the focus.
      let lastStateAt = 0, lastStateWord = '';
      const stateObserver = new MutationObserver(muts => {
        for (const m of muts) {
          const t = m.target; if (!t || t.nodeType !== 1) continue;
          const mine = t === cursorBox || t === cursor || t === last || (last && last.contains && last.contains(t)) || (cursor && cursor.contains && cursor.contains(t));
          if (!mine) continue;
          const v = t.getAttribute(m.attributeName); if (v === m.oldValue) continue;
          const word = v === 'true' ? 'on' : v === 'false' ? 'off' : v === 'mixed' ? 'mixed' : '';
          if (!word) continue;
          const now = Date.now(); if (word === lastStateWord && now - lastStateAt < 300) continue;
          lastStateWord = word; lastStateAt = now;
          window.__steamSpeak(JSON.stringify({ name: word, role: '', state: '', own: true }));
        }
      });
      stateObserver.observe(document.documentElement, { attributes: true, attributeOldValue: true, attributeFilter: ['aria-checked', 'aria-pressed'], subtree: true });
      const stopBefore = window.__steamSpeakStop;
      window.__steamSpeakStop = () => { stopBefore(); stateObserver.disconnect(); };
      report();
      return 'installed v11';
    })()
    """#

    /// Electron games: every change inside an aria-live region (or role alert, status, log) and every focus move.
    static let liveRegions = #"""
    (function(){
      if (window.__speechBridge) return 'already';
      window.__speechBridge = true;
      var last = '', lastAt = 0;
      function speak(t){ t = String(t||'').replace(/\s+/g,' ').trim(); if(!t) return;
        var now = Date.now(); if (t === last && now - lastAt < 800) return; last = t; lastAt = now;
        try { window.speechBridge(t); } catch(e){} }
      function inLive(el){ for (var e = el; e && e.nodeType === 1; e = e.parentElement) {
        var a = e.getAttribute('aria-live'); if (a && a !== 'off') return true;
        var r = e.getAttribute('role'); if (r === 'alert' || r === 'status' || r === 'log') return true; }
        return false; }
      new MutationObserver(function(ms){ for (var i = 0; i < ms.length; i++) { var m = ms[i];
        var target = m.type === 'characterData' ? m.target.parentElement : m.target;
        if (!inLive(target)) continue;
        if (m.type === 'characterData') speak(m.target.data);
        else for (var j = 0; j < m.addedNodes.length; j++) speak(m.addedNodes[j].textContent); } })
        .observe(document.documentElement, {subtree: true, childList: true, characterData: true});
      document.addEventListener('focusin', function(e){ var el = e.target; if (!el || el === document.body) return;
        var name = el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].textContent) || el.textContent || el.getAttribute('placeholder') || (el.type === 'password' ? '' : el.value) || '';
        var role = el.getAttribute('role') || el.tagName.toLowerCase();
        speak(name.trim() + (role ? ', ' + role : '')); }, true);
      return 'installed';
    })()
    """#
}
