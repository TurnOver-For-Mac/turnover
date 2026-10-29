// SPDX-License-Identifier: GPL-3.0-or-later
// Plain JavaScript synthetic DOM tests. Runs in system JavaScriptCore or optional
// Node; no external DOM, browser, page content or native action is used.
function runPassiveExtensionTests(source) {
  const results = [];
  const assert = {
    equal(actual, expected) {
      if (actual !== expected) throw new Error('Expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
    },
    deepEqual(actual, expected) {
      if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error('Expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
    }
  };
  function test(name, run) {
    try { run(); results.push({ name, passed: true, error: '' }); }
    catch (e) { results.push({ name, passed: false, error: String(e && e.stack || e) }); }
  }
function fixture(automatic = false) {
  const timers = new Map(), intervals = new Map(), observers = [], effects = [], reads = { text: 0 };
  let nextTimer = 1;
  const listeners = new Map();
  function events(target) {
    target.addEventListener = (name, fn) => { const set = listeners.get(target) || new Map(); const handlers = set.get(name) || new Set(); handlers.add(fn); set.set(name, handlers); listeners.set(target, set); };
    target.removeEventListener = (name, fn) => listeners.get(target)?.get(name)?.delete(fn);
    target.emit = name => { for (const fn of listeners.get(target)?.get(name) || []) fn(); };
  }
  class Text {
    constructor(s) { this.nodeType = 3; this._text = s; this.parentElement = null; }
    get textContent() { if (this.poison) throw new Error('protected text was read'); reads.text++; return this._text; }
  }
  class Element {
    constructor(tag, attrs = {}, children = []) {
      this.nodeType = 1; this.tagName = tag.toUpperCase(); this.attributes = new Map(Object.entries(attrs)); this.childNodes = [];
      this.css = { display: 'block', visibility: 'visible', opacity: '1', webkitTextSecurity: 'none', fontFamily: 'sans-serif', getPropertyValue: () => '' };
      this.rect = { width: 32, height: 16, left: 0, top: 0 }; this.labels = [];
      for (const c of children) this.append(c);
    }
    append(child) { if (typeof child === 'string') child = new Text(child); this.childNodes.push(child); child.parentElement = this; return child; }
    get children() { return this.childNodes.filter(x => x.nodeType === 1); }
    get childElementCount() { return this.children.length; }
    get firstElementChild() { return this.children[0] || null; }
    get id() { return this.getAttribute('id') || ''; }
    get className() { return this.getAttribute('class') || ''; }
    get hidden() { return this.hasAttribute('hidden'); }
    get isContentEditable() { return this.getAttribute('contenteditable') === 'true'; }
    get isConnected() { let p = this; while (p.parentElement) p = p.parentElement; return p === doc.documentElement; }
    get textContent() { if (this.poison) throw new Error('protected container text was read'); return this.childNodes.map(x => x.textContent).join(''); }
    get value() { effects.push('value-read'); throw new Error('field value was read'); }
    set value(_) { effects.push('value-write'); throw new Error('field value was written'); }
    get checked() { if (this.poison) throw new Error('protected checked state was read'); return false; }
    getAttribute(a) { if (this.poison && /^(value|aria-valuetext|aria-valuenow)$/.test(a)) throw new Error('protected value attribute was read'); return this.attributes.get(a) ?? null; }
    hasAttribute(a) { return this.attributes.has(a); }
    setAttribute(a, v) { this.attributes.set(a, String(v)); }
    removeAttribute(a) { this.attributes.delete(a); }
    getBoundingClientRect() { return this.rect; }
    matches(selector) { return selector.split(',').some(part => {
      part = part.trim();
      const compound = part.match(/^([a-z]+)(\[.+\])$/i);
      if (compound) return this.tagName.toLowerCase() === compound[1].toLowerCase() && this.matches(compound[2]);
      const attr = part.match(/^\[([\w-]+)(?:=([^\]]+))?\]$/);
      return attr ? (attr[2] === undefined ? this.hasAttribute(attr[1]) : this.getAttribute(attr[1]) === attr[2].replace(/^['"]|['"]$/g, '')) : this.tagName.toLowerCase() === part;
    }); }
    querySelectorAll(selector) { const found = []; const visit = p => { for (const c of p.children) { if (c.matches(selector)) found.push(c); visit(c); } }; visit(this); return found; }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    closest(selector) { for (let p = this; p; p = p.parentElement) if (p.matches(selector)) return p; return null; }
    click() { effects.push('click'); throw new Error('unexpected click'); }
    focus() { effects.push('focus'); throw new Error('unexpected focus'); }
    dispatchEvent() { effects.push('event'); throw new Error('unexpected event'); }
  }
  const doc = { hidden: false, defaultView: {} };
  events(doc); events(doc.defaultView);
  doc.documentElement = new Element('html'); doc.body = new Element('body'); doc.documentElement.append(doc.body);
  doc.querySelectorAll = selector => doc.documentElement.querySelectorAll(selector);
  doc.getElementById = id => doc.querySelectorAll('[id]').find(x => x.id === id) || null;
  Object.defineProperties(doc, { URL: { get() { throw new Error('URL was read'); } }, title: { get() { throw new Error('title was read'); } } });
  const sandbox = {
    module: automatic ? undefined : { exports: {} }, document: doc, window: doc.defaultView,
    getComputedStyle: el => el.css,
    MutationObserver: class { constructor(callback) { this.callback = callback; this.active = false; observers.push(this); } observe() { this.active = true; } disconnect() { this.active = false; } },
    setTimeout: fn => { const id = nextTimer++; timers.set(id, fn); return id; }, clearTimeout: id => timers.delete(id),
    setInterval: fn => { const id = nextTimer++; intervals.set(id, fn); return id; }, clearInterval: id => intervals.delete(id),
    browser: { runtime: { sendMessage() { effects.push('message'); throw new Error('unexpected message'); }, sendNativeMessage() { effects.push('native-message'); throw new Error('unexpected native message'); } } }
  };
  Function(...Object.keys(sandbox), source)(...Object.values(sandbox));
  return {
    api: sandbox.module?.exports, doc, Element, Text, timers, intervals, observers, effects, reads,
    el: (tag, attrs, children) => new Element(tag, attrs, children),
    flush() { const ready = [...timers.values()]; timers.clear(); for (const fn of ready) fn(); },
    mutate(records = [{ type: 'childList', target: doc.body }]) { for (const o of observers) if (o.active) o.callback(records); }
  };
}

function protectedElement(f, attrs = {}) {
  const el = f.el('input', attrs); el.poison = true; f.doc.body.append(el); return el;
}
function plain(value) { return JSON.parse(JSON.stringify(value)); }

test('normalization: preserves literal repetitions, glued words and brand spellings', () => {
  const { api } = fixture();
  for (const name of ['Talk Talk', 'BoraBora', 'NextNext', 'Leaving at Leaving at', 'TwitterTwitter Share on Twitter', 'Search messages ChevronRight']) {
    assert.equal(api.clean(name), name);
  }
});

test('privacy: password type is protected before every ARIA role and value path', () => {
  for (const role of ['', 'textbox', 'combobox', 'slider', 'spinbutton', 'progressbar', 'checkbox']) {
    const f = fixture(), el = protectedElement(f, { type: 'password', role, 'aria-label': 'Password' });
    assert.equal(f.api.protectedField(el), true); assert.equal(f.api.name(el), '');
    assert.deepEqual(plain(f.api.state(el)), []); assert.equal(f.api.words(el).text, ''); f.api.tidy(f.doc);
    assert.deepEqual(f.effects, []);
  }
});

test('privacy: password and one-time-code autocomplete tokens protect any widget and descendants', () => {
  for (const token of ['password', 'CURRENT-PASSWORD', 'new-password', 'section-login one-time-code']) {
    const f = fixture(), parent = f.el('div', { role: 'combobox', autocomplete: token, contenteditable: 'true' });
    parent.poison = true; const child = parent.append(f.el('span', { role: 'slider', 'aria-valuetext': 'private' })); child.poison = true;
    const secret = child.append(new f.Text('not for extraction')); secret.poison = true; f.doc.body.append(parent);
    assert.equal(f.api.name(parent), ''); assert.equal(f.api.words(f.doc.body).text, ''); assert.deepEqual(plain(f.api.state(child)), []);
    f.api.tidy(f.doc); assert.deepEqual(f.effects, []);
  }
});

test('privacy: CSS masking protects descendant text without reading textContent', () => {
  const f = fixture(), wrapper = f.el('div', { contenteditable: 'true', role: 'textbox' }); wrapper.css.webkitTextSecurity = 'disc'; wrapper.poison = true;
  const child = wrapper.append(f.el('span', { role: 'slider' })); child.poison = true; const secret = child.append(new f.Text('private')); secret.poison = true;
  f.doc.body.append(f.el('button', {}, ['Public', wrapper]));
  assert.equal(f.api.words(f.doc.body).text, 'Public'); assert.equal(f.api.name(child), ''); assert.deepEqual(plain(f.api.state(child)), []);
  f.api.tidy(f.doc); assert.deepEqual(f.effects, []);
});

test('privacy: ordinary field values are also never read by normalization or passive repairs', () => {
  const f = fixture(), field = f.el('input', { role: 'combobox', placeholder: 'Find a station' }); f.doc.body.append(field);
  assert.equal(f.api.name(field), 'Find a station'); assert.deepEqual(plain(f.api.state(field)), []); f.api.tidy(f.doc);
  assert.deepEqual(f.effects, []);
});

test('semantics: explicit site names, roles and live settings are preserved', () => {
  const f = fixture();
  const named = f.el('button', { 'aria-label': 'Discount membership', 'data-turnover-label': '' }, ['Railcard Railcard ChevronRight']);
  const title = f.el('button', { title: 'Search messages' }, ['Search Search']);
  const live = f.el('div', { role: 'alert', 'aria-live': 'assertive', class: 'spinner' });
  const check = f.el('div', { role: 'checkbox', 'aria-checked': 'true' }, ['Blue']);
  const label = f.el('span', { id: 'label' }, ['Site label']);
  const by = f.el('button', { 'aria-labelledby': 'label' }, ['Other Other']);
  for (const x of [named, title, live, check, label, by]) f.doc.body.append(x);
  const before = [named, title, live, check, by].map(x => [...x.attributes]);
  f.api.tidy(f.doc);
  assert.deepEqual([named, title, live, check, by].map(x => [...x.attributes]), before);
  assert.equal(f.api.name(named), 'Discount membership'); assert.equal(f.api.name(by), 'Site label');
  assert.deepEqual(plain(f.api.state(check)), ['checked']);
});

test('actual tidy: proven icon omission preserves ordinary visible text without replacing the control name', () => {
  const f = fixture(), icon = f.el('span', { class: 'material-icons' }, ['chevron_right']);
  const button = f.el('button', {}, ['Talk Talk BoraBora', icon]); f.doc.body.append(button);
  f.api.tidy(f.doc);
  assert.equal(icon.getAttribute('aria-hidden'), 'true');
  assert.equal(button.hasAttribute('aria-label'), false); assert.equal(f.api.name(button), 'Talk Talk BoraBora');
  for (const label of ['Talk Talk', 'BoraBora', 'NextNext', 'Leaving at Leaving at']) {
    const literal = f.el('button', {}, [label]); f.doc.body.append(literal);
    f.api.tidy(f.doc); assert.equal(literal.hasAttribute('aria-label'), false); assert.equal(f.api.name(literal), label);
  }
});

test('actual tidy: only redundant unnamed icons are hidden; named, explicit and sole-action icons remain', () => {
  const f = fixture(), icon = f.el('span', { class: 'material-icons' }, ['chevron_right']);
  const button = f.el('button', {}, ['Help', icon]); f.doc.body.append(button);
  const sole = f.el('svg'), soleButton = f.el('button', {}, [sole]); f.doc.body.append(soleButton);
  const standalone = f.el('svg'), standaloneLigature = f.el('span', { class: 'material-icons' }, ['chevron_right']);
  const emptyNamedIcon = f.el('svg'), emptyNamedControl = f.el('button', { 'aria-label': '' }, [emptyNamedIcon]);
  const anchorIcon = f.el('svg'), anchor = f.el('a', {}, ['Not a link', anchorIcon]);
  const liveIcon = f.el('span', { class: 'material-icons', 'aria-live': 'polite' }, ['chevron_right']), liveControl = f.el('button', {}, ['Updates', liveIcon]);
  const nestedNamed = f.el('svg', {}, [f.el('path', { role: 'img', 'aria-label': 'Site graphic' })]), nestedControl = f.el('button', {}, ['Diagram', nestedNamed]);
  const namedControlIcon = f.el('svg'), namedControl = f.el('button', { 'aria-label': 'Author action' }, [namedControlIcon]);
  const named = f.el('svg', {}, [f.el('title', {}, ['Scene'])]), explicit = f.el('svg', { 'aria-hidden': 'false' }), focusable = f.el('svg', { tabindex: '0' });
  for (const x of [standalone, standaloneLigature, emptyNamedControl, anchor, liveControl, nestedControl, namedControl, named, explicit, focusable]) f.doc.body.append(x);
  f.api.tidy(f.doc);
  assert.equal(icon.getAttribute('aria-hidden'), 'true');
  for (const x of [sole, standalone, standaloneLigature, emptyNamedIcon, anchorIcon, liveIcon, nestedNamed, named, focusable]) assert.equal(x.hasAttribute('aria-hidden'), false);
  assert.equal(namedControlIcon.getAttribute('aria-hidden'), 'true');
  assert.equal(explicit.getAttribute('aria-hidden'), 'false'); assert.equal(f.api.name(button), 'Help');
});

test('ownership: empty or unresolved author references cannot hide a sole icon', () => {
  for (const by of ['', 'missing-label', 'empty-label', 'real-label missing-label']) {
    const f = fixture(), icon = f.el('span', { class: 'material-icons' }, ['chevron_right']);
    f.doc.body.append(f.el('span', { id: 'empty-label' })); f.doc.body.append(f.el('span', { id: 'real-label' }, ['Real author name']));
    f.doc.body.append(f.el('button', { 'aria-labelledby': by }, [icon]));
    f.api.tidy(f.doc); assert.equal(icon.hasAttribute('aria-hidden'), false);
  }
  const f = fixture(), icon = f.el('span', { id: 'sole-icon', class: 'material-icons' }, ['chevron_right']);
  f.doc.body.append(f.el('button', { 'aria-labelledby': 'sole-icon' }, [icon]));
  f.api.tidy(f.doc); assert.equal(icon.hasAttribute('aria-hidden'), false);
});

test('ownership: mutated hidden icon content and lost control names restore the icon', () => {
  for (const change of ['meaningful-text', 'lost-text', 'lost-author-name']) {
    const f = fixture(), icon = f.el('span', { class: 'material-icons' }, ['chevron_right']);
    const button = f.el('button', change === 'lost-author-name' ? { 'aria-label': 'Next' } : {}, change === 'lost-author-name' ? [icon] : ['Next', icon]);
    f.doc.body.append(button); const owner = f.api.start(f.doc); assert.equal(icon.getAttribute('aria-hidden'), 'true');
    // Ordinary name reads still omit the owned root until its classification is retired.
    assert.equal(f.api.words(icon).text, '');
    if (change === 'meaningful-text') icon.childNodes[0]._text = 'Useful note';
    else if (change === 'lost-text') button.childNodes = [icon];
    else button.setAttribute('aria-label', '');
    f.mutate([{ type: change === 'meaningful-text' ? 'characterData' : 'childList', target: button }]); f.flush();
    assert.equal(icon.hasAttribute('aria-hidden'), false); owner.stop();
  }
});

test('ownership: a site replacement of an owned hidden attribute is preserved', () => {
  const f = fixture(), icon = f.el('svg'), button = f.el('button', {}, ['Next', icon]); f.doc.body.append(button);
  const owner = f.api.start(f.doc); assert.equal(icon.getAttribute('aria-hidden'), 'true');
  icon.setAttribute('aria-hidden', 'false'); f.mutate([{ type: 'attributes', target: icon, attributeName: 'aria-hidden' }]); f.flush();
  assert.equal(icon.getAttribute('aria-hidden'), 'false'); owner.stop();
});

test('actual tidy: anonymous spinner is named without announcements, then site semantics win', () => {
  const f = fixture(), spinner = f.el('div', { class: 'spinner' }); f.doc.body.append(spinner);
  f.api.tidy(f.doc); assert.equal(spinner.getAttribute('role'), 'img'); assert.equal(spinner.getAttribute('aria-label'), 'Loading');
  spinner.setAttribute('role', 'status'); spinner.setAttribute('aria-label', 'Site status'); f.api.tidy(f.doc);
  assert.equal(spinner.getAttribute('role'), 'status'); assert.equal(spinner.getAttribute('aria-label'), 'Site status');
  assert.equal(f.doc.querySelectorAll('[aria-live]').length, 0);
});

test('actual tidy: loading classes never replace implicit or explicit interactive semantics', () => {
  const cases = [
    ['button', {}], ['a', { href: '/public' }], ['input', {}], ['select', {}], ['textarea', {}], ['summary', {}],
    ['div', { tabindex: '0' }], ['div', { tabindex: '-1' }], ['div', { contenteditable: 'true' }],
    ['div', { contenteditable: '' }], ['div', { onclick: '' }], ['div', { role: 'button' }]
  ];
  for (const kind of ['spinner', 'progress']) for (const [tag, attrs] of cases) {
    const f = fixture(), el = f.el(tag, { class: kind, ...attrs });
    if (kind === 'progress') { const fill = el.append(f.el('span', { class: 'fill' })); el.rect = { left: 0, width: 300, height: 10 }; fill.rect = { left: 0, width: 75, height: 10 }; }
    f.doc.body.append(el); const before = [...el.attributes]; f.api.tidy(f.doc);
    assert.deepEqual([...el.attributes], before); assert.deepEqual(f.effects, []);
  }
  const f = fixture(), scripted = f.el('div', { class: 'spinner' }); scripted.onclick = () => {}; f.doc.body.append(scripted);
  f.api.tidy(f.doc); assert.equal(scripted.hasAttribute('role'), false); assert.equal(scripted.hasAttribute('aria-label'), false);
  const inherited = f.el('div', { class: 'spinner' }); Object.defineProperty(inherited, 'isContentEditable', { value: true }); f.doc.body.append(inherited);
  f.api.tidy(f.doc); assert.equal(inherited.hasAttribute('role'), false);
  const changed = f.el('div', { class: 'spinner' }); f.doc.body.append(changed); f.api.tidy(f.doc);
  assert.equal(changed.getAttribute('aria-label'), 'Loading'); changed.setAttribute('tabindex', '0'); f.api.tidy(f.doc);
  assert.equal(changed.hasAttribute('role'), false); assert.equal(changed.hasAttribute('aria-label'), false); assert.equal(changed.getAttribute('tabindex'), '0');
});

test('actual tidy: interactive or author-named indicator descendants retain their own semantics', () => {
  const f = fixture(), child = f.el('button'), spinner = f.el('div', { class: 'spinner' }, [child]); f.doc.body.append(spinner);
  const fill = f.el('span', { class: 'fill', tabindex: '0' }), bar = f.el('div', { class: 'progress' }, [fill]);
  bar.rect = { left: 0, width: 300, height: 10 }; fill.rect = { left: 0, width: 75, height: 10 }; f.doc.body.append(bar);
  const namedFill = f.el('span', { class: 'fill', 'aria-label': 'Site progress' }), namedBar = f.el('div', { class: 'progress' }, [namedFill]);
  namedBar.rect = { left: 0, width: 300, height: 10 }; namedFill.rect = { left: 0, width: 75, height: 10 }; f.doc.body.append(namedBar);
  f.api.tidy(f.doc);
  for (const el of [spinner, bar, namedBar]) { assert.equal(el.hasAttribute('role'), false); assert.equal(el.hasAttribute('aria-label'), false); }
  assert.equal(namedFill.getAttribute('aria-label'), 'Site progress'); assert.deepEqual(f.effects, []);
});

test('actual tidy: visual progress updates only owned semantics and respects a site takeover', () => {
  const f = fixture(), fill = f.el('span', { class: 'fill' }), bar = f.el('div', { class: 'progress' }, [fill]);
  bar.rect = { left: 0, width: 300, height: 10 }; fill.rect = { left: 0, width: 75, height: 10 }; f.doc.body.append(bar);
  f.api.tidy(f.doc); assert.equal(bar.getAttribute('role'), 'progressbar'); assert.equal(bar.getAttribute('aria-valuenow'), '25');
  const owner = f.api.start(f.doc); fill.rect.width = 150; for (const fn of f.intervals.values()) fn(); assert.equal(bar.getAttribute('aria-valuenow'), '50'); owner.stop();
  bar.setAttribute('aria-valuenow', '77'); f.api.tidy(f.doc); assert.equal(bar.getAttribute('aria-valuenow'), '77'); assert.equal(bar.hasAttribute('role'), false);
});

test('privacy: a repaired widget that becomes masked is not inspected by ownership or queued delivery', () => {
  const f = fixture(), fill = f.el('span', { class: 'fill' }), bar = f.el('div', { class: 'progress' }, [fill]);
  bar.rect = { left: 0, width: 300, height: 10 }; fill.rect = { left: 0, width: 75, height: 10 }; f.doc.body.append(bar);
  const owner = f.api.start(f.doc); assert.equal(bar.getAttribute('aria-valuenow'), '25');
  bar.css.webkitTextSecurity = 'disc'; bar.poison = true;
  f.mutate([{ type: 'attributes', target: bar, attributeName: 'aria-valuenow' }]); f.flush();
  for (const fn of f.intervals.values()) fn(); assert.deepEqual(f.effects, []); owner.stop();
});

test('passivity: automatic startup and queued changes do not capture, message, click, focus or edit values', () => {
  const f = fixture(true), consent = f.el('button', { id: 'onetrust-accept-btn-handler' }, ['Accept all cookies']); f.doc.body.append(consent);
  assert.equal(f.observers.length, 1); assert.equal(f.observers[0].active, true); f.mutate(); f.flush();
  assert.equal(f.doc.defaultView.turnoverTree, undefined); assert.equal(f.doc.defaultView.turnoverAcceptCookies, undefined);
  assert.deepEqual(f.effects, []); f.doc.defaultView.emit('pagehide'); assert.equal(f.intervals.size, 0);
});

test('bounds: incomplete names and candidates past the cap keep the original semantics', () => {
  const f = fixture(), large = f.el('button', {}, ['Duplicate '.repeat(600)]); f.doc.body.append(large);
  assert.equal(f.api.words(large).complete, false); f.api.tidy(f.doc); assert.equal(large.hasAttribute('aria-label'), false);
  const g = fixture(); for (let i = 0; i < 1000; i++) g.doc.body.append(g.el('span', {}, ['word']));
  const lateIcon = g.el('span', { class: 'material-icons' }, ['chevron_right']), last = g.el('button', {}, ['Next', lateIcon]); g.doc.body.append(last);
  assert.equal(g.api.tidy(g.doc).clipped, true); assert.equal(lateIcon.hasAttribute('aria-hidden'), false);
});

test('bounds: unrelated generic classes never trigger subtree text inspection', () => {
  const f = fixture(); let parent = f.doc.body;
  for (let i = 0; i < 20; i++) parent = parent.append(f.el('div', { class: 'ordinary-layout' }));
  const leaf = parent.append(new f.Text('Ordinary page content')); leaf.poison = true;
  f.api.tidy(f.doc); assert.equal(f.reads.text, 0);
});

test('bounds: aggregate work clips remaining candidates before their semantics change', () => {
  const f = fixture(), icons = [];
  for (let i = 0; i < 200; i++) {
    const icon = f.el('span', { class: 'material-icons' }, ['chevron_right']); icons.push(icon);
    f.doc.body.append(f.el('button', {}, ['Public route ' + i, icon]));
  }
  const result = f.api.tidy(f.doc);
  assert.equal(result.clipped, true); assert.equal(result.work <= 4000, true); assert.equal(f.reads.text <= 4000, true);
  assert.equal(result.hidden > 0, true); assert.equal(icons[icons.length - 1].hasAttribute('aria-hidden'), false);
});

test('bounds: incomplete owned-icon revalidation retains existing semantics', () => {
  const f = fixture(), controls = [];
  for (let i = 0; i < 3; i++) {
    const icon = f.el('span', { class: 'material-icons' }, ['chevron_right']), button = f.el('button', {}, ['Next', icon]);
    controls.push({ icon, button }); f.doc.body.append(button);
  }
  f.api.tidy(f.doc);
  for (const { icon, button } of controls) {
    assert.equal(icon.getAttribute('aria-hidden'), 'true'); button.childNodes = [];
    for (let i = 0; i < 1900; i++) button.append('x'); button.append(icon);
  }
  f.reads.text = 0;
  const result = f.api.tidy(f.doc);
  assert.equal(result.clipped, true); assert.equal(result.work, 4000); assert.equal(f.reads.text <= 4000, true);
  for (const { icon } of controls) assert.equal(icon.getAttribute('aria-hidden'), 'true');
});

test('lifecycle: mutations coalesce, own writes do not loop, and stop cancels delayed work', () => {
  const f = fixture(), icon = f.el('span', { class: 'material-icons' }, ['chevron_right']), button = f.el('button', {}, ['Next', icon]); f.doc.body.append(button);
  const owner = f.api.start(f.doc); assert.equal(f.api.start(f.doc), owner); assert.equal(f.observers.length, 1);
  f.mutate([{ type: 'attributes', target: icon, attributeName: 'aria-hidden' }]); assert.equal(f.timers.size, 0);
  f.mutate(); f.mutate(); assert.equal(f.timers.size, 1);
  owner.stop(); assert.equal(f.intervals.size, 0); assert.equal(f.timers.size, 0); assert.equal(f.observers[0].active, false); f.flush(); assert.deepEqual(f.effects, []);
});

test('lifecycle: hidden tabs defer repairs and pagehide/pageshow retire and resume the pass', () => {
  const f = fixture(); f.doc.hidden = true; const owner = f.api.start(f.doc);
  const icon = f.el('span', { class: 'material-icons' }, ['chevron_right']), button = f.el('button', {}, ['Next', icon]); f.doc.body.append(button); f.mutate(); assert.equal(f.timers.size, 0);
  f.doc.hidden = false; f.doc.emit('visibilitychange'); f.flush(); assert.equal(icon.getAttribute('aria-hidden'), 'true'); assert.equal(f.api.name(button), 'Next');
  f.mutate(); f.doc.defaultView.emit('pagehide'); assert.equal(f.timers.size, 0); assert.equal(f.observers[0].active, false);
  const laterIcon = f.el('svg'), later = f.el('button', {}, ['Later', laterIcon]); f.doc.body.append(later); f.doc.defaultView.emit('pageshow'); assert.equal(laterIcon.getAttribute('aria-hidden'), 'true'); assert.equal(f.api.name(later), 'Later');
  owner.stop();
});

test('ownership: a later site label cannot be overwritten by an earlier extension repair', () => {
  const f = fixture(), spinner = f.el('div', { class: 'spinner' }); f.doc.body.append(spinner); f.api.start(f.doc);
  assert.equal(spinner.getAttribute('aria-label'), 'Loading');
  spinner.setAttribute('aria-label', 'Author replacement'); f.mutate([{ type: 'attributes', target: spinner, attributeName: 'aria-label' }]); f.flush();
  assert.equal(spinner.getAttribute('aria-label'), 'Author replacement'); assert.deepEqual(f.effects, []);
});

  return results;
}
if (typeof module === 'object' && module.exports) module.exports = { runPassiveExtensionTests };
