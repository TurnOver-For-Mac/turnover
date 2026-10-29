// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver's passive page shaping, restored 29 Oct 2026 from the 28 Oct prototype.
// Only missing accessibility semantics are supplied. No page tree, field value, URL,
// native message, keyboard event, focus change or click leaves this script.
(function () {
  'use strict';

  const ICON_NAME = /^(Chevron|Arrow|Icon|Caret|Close|Cross|Tick|Check|Menu|Burger|Search|Plus|Minus|Dot|Star|Info|Warning|Error|External|Filter|Sort|Calendar|Clock|Pin|Location)(Left|Right|Up|Down|Small|Large|Outline|Filled)?$/;
  const LIGATURE = /^[a-z]+(_[a-z0-9]+)+$/;
  const CONTROL = 'a[href], button, [role=button], [role=link]';
  const CANDIDATES = 'img, svg, span, i, div, a, button, [role=button], [role=link], [role=slider]';
  const SECRET_AUTOCOMPLETE = new Set(['password', 'current-password', 'new-password', 'one-time-code']);
  const owned = new WeakMap();
  const spinners = new Set();
  const progressBars = new Set();
  const hiddenIcons = new Set();
  const documents = new WeakMap();

  function text(s) { return (s || '').replace(/\s+/g, ' ').trim(); }
  function style(el) { return getComputedStyle(el); }

  // One shared allowance covers repeated text/shape walks and ancestor protection
  // checks during a pass. Exhaustion is incomplete evidence, never a negative match.
  function workBudget() { return { used: 0, clipped: false }; }
  function spend(budget) {
    if (!budget) return true;
    if (budget.clipped) return false;
    if (budget.used >= 4000) { budget.clipped = true; return false; }
    budget.used++; return true;
  }
  function incomplete(budget) { if (budget) budget.clipped = true; }

  // Check the actual input type before its ARIA role. A password presented as a
  // slider/combobox still contains a secret. CSS masking and autocomplete can mark
  // non-input widgets, so descendants inherit the refusal too. No value is read.
  function protectedField(el, budget = null) {
    let depth = 0;
    for (let p = el; p && p.nodeType === 1; p = p.parentElement) {
      if (!spend(budget) || ++depth > 64) { incomplete(budget); return true; }
      if ((p.getAttribute('type') || '').trim().toLowerCase() === 'password') return true;
      const tokens = (p.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
      if (tokens.some(t => SECRET_AUTOCOMPLETE.has(t))) return true;
      const css = style(p);
      const mask = css.webkitTextSecurity || css.getPropertyValue?.('-webkit-text-security');
      if (mask && mask !== 'none') return true;
    }
    return false;
  }

  function visible(el, budget = null, ignoreOwnHidden = false) {
    if (!el || el.nodeType !== 1 || protectedField(el, budget) || el.hidden) return false;
    if (el.getAttribute('aria-hidden') === 'true' && !(ignoreOwnHidden && owns(el, 'aria-hidden', budget))) return false;
    const css = style(el);
    if (css.display === 'none' || css.visibility === 'hidden' || css.opacity === '0') return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 || r.height > 0;
  }

  // Walk text nodes rather than reading a container's textContent: the latter can
  // copy a masked contenteditable's text before its child can be excluded. Clipped
  // reads cannot become an accessible name. Ordinary form values are never read.
  function words(root, omit = null, budget = null, ignoreOwnHiddenRoot = false) {
    const pieces = [];
    let nodes = 0, length = 0, complete = true;
    function visit(n, depth) {
      if (!complete || n === omit) return;
      if (!spend(budget) || ++nodes > 2000 || depth > 64) { incomplete(budget); complete = false; return; }
      if (n.nodeType === 3) {
        const s = n.textContent || '';
        length += s.length;
        if (length > 4096) { incomplete(budget); complete = false; return; }
        pieces.push(s); return;
      }
      if (n.nodeType !== 1 || protectedField(n, budget)) { if (budget?.clipped) complete = false; return; }
      const ownRoot = n === root && ignoreOwnHiddenRoot && owns(n, 'aria-hidden', budget);
      if (n.hidden || (n.getAttribute('aria-hidden') === 'true' && !ownRoot) || /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|INPUT|TEXTAREA|SELECT)$/.test(n.tagName) || n.isContentEditable) return;
      if (n !== root && !visible(n, budget)) { if (budget?.clipped) complete = false; return; }
      for (const c of n.childNodes) { visit(c, depth + 1); if (!complete) break; }
    }
    visit(root, 0);
    return { text: text(pieces.join(' ')), complete };
  }

  function gluedIcon(w) {
    const parts = w.replace(/([a-z])([A-Z])/g, '$1 $2').split(' ');
    return parts.length > 1 && parts.every(x => ICON_NAME.test(x) || /^(Left|Right|Up|Down|Small|Large|Outline|Filled)$/.test(x));
  }

  // Repeated literal words and brand spellings are meaningful. Only DOM-proven
  // redundant icon nodes may be omitted; ordinary text is never deduplicated.
  function clean(name) { return text(name); }

  function authorName(el) {
    return ['aria-label', 'aria-labelledby', 'title', 'alt'].some(a => el.hasAttribute(a));
  }

  function name(el, budget = null, omit = null) {
    if (protectedField(el, budget)) return '';
    if (el.hasAttribute('aria-labelledby')) {
      const by = text(el.getAttribute('aria-labelledby'));
      if (!by) return '';
      const ids = by.split(/\s+/);
      if (by.length > 4096 || ids.length > 32) { incomplete(budget); return ''; }
      const labels = [];
      for (const id of ids) {
        if (!spend(budget)) return '';
        const label = document.getElementById(id);
        if (!label) return ''; // Broken references cannot justify hiding a sole icon.
        const result = words(label, omit, budget);
        if (!result.complete) return '';
        labels.push(result.text);
      }
      return text(labels.join(' '));
    }
    for (const a of ['aria-label', 'alt', 'title', 'placeholder']) {
      if (a === 'alt' && !/^(IMG|AREA|INPUT)$/.test(el.tagName)) continue;
      if (el.hasAttribute(a)) return text(el.getAttribute(a));
    }
    const w = words(el, omit, budget);
    return w.complete ? clean(w.text) : '';
  }

  // Semantic states are retained for the normalization tests, without the old
  // prototype's field-value extraction. Protection precedes every ARIA role.
  function state(el) {
    if (protectedField(el)) return [];
    const result = [], role = el.getAttribute('role') || (el.getAttribute('type') || '').toLowerCase();
    if (['checkbox', 'radio', 'switch'].includes(role)) result.push(el.checked || el.getAttribute('aria-checked') === 'true' ? 'checked' : 'not checked');
    if (el.hasAttribute('aria-expanded')) result.push(el.getAttribute('aria-expanded') === 'true' ? 'expanded' : 'collapsed');
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') result.push('dimmed');
    if (el.getAttribute('aria-selected') === 'true') result.push('selected');
    if (['slider', 'spinbutton', 'progressbar'].includes(role)) {
      const v = el.getAttribute('aria-valuetext') || el.getAttribute('aria-valuenow');
      if (v) result.push(v);
    }
    return result;
  }

  function owns(el, attr, budget = null) {
    if (!el || el.nodeType !== 1 || protectedField(el, budget)) return false;
    const record = owned.get(el);
    return record?.has(attr) && el.getAttribute(attr) === record.get(attr);
  }

  // Data attributes on a page do not prove ownership. Remember the exact value
  // written in this content-script instance, and relinquish it if the site edits it.
  function supply(el, attr, value) {
    if (protectedField(el)) return false;
    let record = owned.get(el);
    if (record?.has(attr) && !owns(el, attr)) { record.delete(attr); return false; }
    if (el.hasAttribute(attr) && !owns(el, attr)) return false;
    if (el.getAttribute(attr) === value) return false;
    if (!record) { record = new Map(); owned.set(el, record); }
    el.setAttribute(attr, value); record.set(attr, value); return true;
  }
  function release(el, attr) {
    if (protectedField(el)) { owned.delete(el); return; }
    if (owns(el, attr)) el.removeAttribute(attr);
    owned.get(el)?.delete(attr);
  }

  function decorative(el, budget = null, ignoreOwnHidden = false) {
    const tag = el.tagName.toLowerCase();
    if (tag === 'img') return false; // Missing alt is a site error; guessing could hide meaningful content.
    if (tag !== 'svg') {
      const cls = typeof el.className === 'string' ? el.className : '';
      // Ordinary generic containers never trigger a subtree text read.
      if (!/icon|ligature|glyph|material|symbol/i.test(cls + ' ' + style(el).fontFamily)) return false;
      if (el.childElementCount !== 0 || el.closest('kbd, code, pre')) return false;
    }
    if (!visible(el, budget, ignoreOwnHidden) || authorName(el) || el.hasAttribute('role') || el.hasAttribute('aria-live') || !plainContainer(el, budget)) return false;
    if (tag === 'svg') return !el.querySelector('title, desc');
    const w = words(el, null, budget, ignoreOwnHidden);
    return w.complete && (LIGATURE.test(w.text) || gluedIcon(w.text));
  }

  function canHide(el, budget = null) {
    let control = el.parentElement, depth = 0;
    while (control && !control.matches(CONTROL)) {
      if (!spend(budget) || ++depth > 64) { incomplete(budget); return false; }
      control = control.parentElement;
    }
    if (!control) return false;
    // Empty/broken author references are not names, and an unrelated alt attribute
    // on a button is not an HTML naming mechanism. Do not fall back to icon text.
    if (authorName(control)) {
      if (!['aria-label', 'aria-labelledby', 'title'].some(a => control.hasAttribute(a))) return false;
      return !!name(control, budget, el);
    }
    const other = words(control, el, budget);
    return other.complete && /[\p{L}\p{N}]/u.test(clean(other.text));
  }

  function interactive(el) {
    return /^(A|AREA|BUTTON|INPUT|SELECT|TEXTAREA|SUMMARY|DETAILS|LABEL|OPTION|AUDIO|VIDEO|IFRAME|OBJECT|EMBED)$/.test(el.tagName)
      || el.hasAttribute('tabindex') || el.hasAttribute('contenteditable') || el.isContentEditable
      || el.hasAttribute('onclick') || typeof el.onclick === 'function';
  }

  // CSS class names do not erase implicit HTML semantics. Only small generic
  // containers with no interactive or author-named descendants can receive
  // guessed semantics; a clipped inspection is refused.
  function plainContainer(el, budget = null) {
    if (!/^(DIV|SPAN|I|SVG)$/.test(el.tagName)) return false;
    let count = 0;
    function inspect(node, depth) {
      if (!spend(budget) || ++count > 32 || depth > 8) { incomplete(budget); return false; }
      if (protectedField(node, budget) || interactive(node)) return false;
      if (node !== el && (authorName(node) || node.hasAttribute('role') || node.hasAttribute('aria-live'))) return false;
      for (const child of node.children) if (!inspect(child, depth + 1)) return false;
      return true;
    }
    return inspect(el, 0);
  }

  function spinner(el, budget = null) {
    const cls = ((typeof el.className === 'string' ? el.className : '') + ' ' + (el.id || '')).toLowerCase();
    if (!/(^|[\s_-])(spinner|loader|loading|spin|throbber)([\s_-]|$)/.test(cls) || el.childElementCount > 3) return false;
    if (protectedField(el, budget) || !plainContainer(el, budget)) return false;
    if (['role', 'aria-label'].some(a => el.hasAttribute(a) && !owns(el, a, budget)) || el.hasAttribute('aria-labelledby') || el.hasAttribute('title') || el.hasAttribute('aria-live')) return false;
    const w = words(el, null, budget);
    if (!w.complete || w.text || el.querySelector('title, desc')) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.width <= 96 && r.height > 0 && r.height <= 96;
  }

  function progress(el, budget = null) {
    if (!/progress/i.test(typeof el.className === 'string' ? el.className : '') || el.childElementCount !== 1) return null;
    if (protectedField(el, budget) || !plainContainer(el, budget)) return null;
    if (['role', 'aria-label', 'aria-labelledby', 'title', 'aria-live', 'aria-valuemin', 'aria-valuemax', 'aria-valuenow', 'aria-valuetext'].some(a => el.hasAttribute(a) && !owns(el, a, budget))) return null;
    const w = words(el, null, budget), fill = el.firstElementChild;
    if (!w.complete || w.text || fill.childElementCount !== 0 || !/fill|bar|value|progress|indicator|inner/i.test(typeof fill.className === 'string' ? fill.className : '')) return null;
    const r = el.getBoundingClientRect(), f = fill.getBoundingClientRect();
    if (r.width < 40 || r.height <= 0 || r.height > 40 || f.width < 0 || f.width > r.width || Math.abs(f.left - r.left) > 2) return null;
    return Math.max(0, Math.min(100, Math.round(f.width / r.width * 100)));
  }

  function tidy(root = document) {
    let hidden = 0, renamed = 0, seen = 0;
    const budget = workBudget();
    function result() { return { hidden, renamed, clipped: budget.clipped, work: budget.used }; }
    // Reassess only the exact hidden root we own. Ordinary names still omit it;
    // no temporary unhide/re-hide events are needed to inspect its new contents.
    for (const el of hiddenIcons) {
      if (!spend(budget)) return result();
      const ownedHide = owns(el, 'aria-hidden', budget);
      if (budget.clipped) return result();
      if (!ownedHide) { owned.get(el)?.delete('aria-hidden'); hiddenIcons.delete(el); continue; }
      const keep = el.isConnected && decorative(el, budget, true) && canHide(el, budget);
      if (budget.clipped) return result();
      if (keep) continue;
      release(el, 'aria-hidden'); hiddenIcons.delete(el);
    }
    for (const el of spinners) {
      if (!spend(budget)) return result();
      const keep = el.isConnected && visible(el, budget) && spinner(el, budget);
      if (budget.clipped) return result();
      if (keep) continue;
      release(el, 'role'); release(el, 'aria-label'); spinners.delete(el);
    }
    for (const el of progressBars) {
      if (!spend(budget)) return result();
      const keep = el.isConnected && visible(el, budget) && progress(el, budget) !== null;
      if (budget.clipped) return result();
      if (keep) continue;
      for (const attr of ['role', 'aria-valuemin', 'aria-valuemax', 'aria-valuenow']) release(el, attr);
      progressBars.delete(el);
    }
    // Candidate enumeration is also finite at the script level; the browser's
    // selector/layout calls are not preemptible, so this is no hard time limit.
    for (const el of root.querySelectorAll(CANDIDATES)) {
      if (++seen > 1000) { budget.clipped = true; break; }
      if (!spend(budget)) break;
      const isVisible = visible(el, budget);
      if (budget.clipped) break;
      if (!isVisible) continue;
      const isSpinner = spinner(el, budget);
      if (budget.clipped) break;
      if (isSpinner) {
        if (supply(el, 'role', 'img')) renamed++;
        if (supply(el, 'aria-label', 'Loading')) renamed++;
        spinners.add(el); continue;
      }
      const value = progress(el, budget);
      if (budget.clipped) break;
      if (value !== null) {
        for (const [attr, v] of [['role', 'progressbar'], ['aria-valuemin', '0'], ['aria-valuemax', '100'], ['aria-valuenow', String(value)]]) if (supply(el, attr, v)) renamed++;
        progressBars.add(el); continue;
      }
      const hide = decorative(el, budget) && canHide(el, budget);
      if (budget.clipped) break;
      if (hide && supply(el, 'aria-hidden', 'true')) { hiddenIcons.add(el); hidden++; }
    }
    return result();
  }

  function start(doc = document) {
    if (!doc.documentElement || documents.has(doc)) return documents.get(doc);
    let timer = null, progressTimer = null, active = false, missed = false;
    const observer = new MutationObserver(records => {
      if (doc.hidden) { missed = true; return; }
      // Our exact writes cause no rescan; if the site replaced a value, it does.
      if (records.every(r => r.type === 'attributes' && owns(r.target, r.attributeName))) return;
      schedule();
    });
    function run() { timer = null; if (!active || doc.hidden) { missed = true; return; } missed = false; tidy(doc); }
    function schedule() { if (active && timer === null) timer = setTimeout(run, 150); }
    function refreshProgress() {
      if (!active || doc.hidden) return;
      const budget = workBudget();
      for (const el of progressBars) {
        if (!spend(budget)) break;
        const value = el.isConnected && visible(el, budget) ? progress(el, budget) : null;
        if (budget.clipped) break;
        if (value !== null) supply(el, 'aria-valuenow', String(value));
      }
    }
    function resume() {
      if (active) return;
      active = true;
      observer.observe(doc.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
      progressTimer = setInterval(refreshProgress, 2000);
      run();
    }
    function pause() {
      active = false; observer.disconnect();
      if (timer !== null) clearTimeout(timer);
      if (progressTimer !== null) clearInterval(progressTimer);
      timer = null; progressTimer = null;
    }
    function visibility() { if (!doc.hidden && missed) schedule(); }
    const win = doc.defaultView;
    doc.addEventListener('visibilitychange', visibility);
    win?.addEventListener('pagehide', pause);
    win?.addEventListener('pageshow', resume);
    const controller = { stop() {
      pause(); doc.removeEventListener('visibilitychange', visibility);
      win?.removeEventListener('pagehide', pause); win?.removeEventListener('pageshow', resume);
      documents.delete(doc);
    } };
    documents.set(doc, controller); resume(); return controller;
  }

  // The plain injected test harness evaluates this exact script with DOM globals. Safari gets
  // no debug/tree API on window, and no browser/native messaging entry point.
  if (typeof module === 'object' && module.exports) module.exports = Object.freeze({ clean, name, state, words, protectedField, tidy, start });
  else if (typeof document === 'object') start(document);
})();
