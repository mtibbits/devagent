#!/usr/bin/env node
// tests/lib/family-js-test.js — the node test for the family animation setting
// (#996). Plain node: vm, assert and fs only; no npm.
//
// Usage: node family-js-test.js <path/to/family.js>
//
// Each case runs the REAL family.js source in a fresh vm context. A vm context
// has no ambient localStorage, window or matchMedia (probed on node 24), so the
// stubs below are the whole of the state family.js can see:
//   - window bound to the context itself;
//   - localStorage: a stub over a Map, with a throw mode on get and on set (or
//     absent, or a property whose getter throws);
//   - matchMedia: a stub answering the reduced-motion query, or absent;
//   - document: documentElement.classList, readyState, querySelector (which
//     returns a button stub that records its listeners) and addEventListener.
//
// The key and class are never written here: case 1 observes them (the one
// key a first view writes, the one class it adds) and later cases use what it
// observed, so the bats leg can hold family.js's header to what the code does.
//
// Output: "ok <case>" or "not ok <case>: <error>" per case, the observation
// lines "observed key=<k> class=<c> control=<selector>" and "exports: <a,b>",
// and last "cases: <N>". Exit 0 when every case passed, 1 otherwise, 2 on usage.
'use strict';
const vm = require('vm');
const assert = require('assert');
const fs = require('fs');

if (process.argv.length !== 3) {
  console.error('usage: node family-js-test.js <family.js>');
  process.exit(2);
}
const SRC = fs.readFileSync(process.argv[2], 'utf8');
const REDUCE = '(prefers-reduced-motion: reduce)';

// store(init, mode) — a localStorage stub over a Map. mode: 'get' throws on
// getItem, 'set' throws on setItem, 'both' on either.
function store(init, mode) {
  const map = new Map(Object.entries(init || {}));
  const s = {
    map,
    mode: mode || '',
    api: {
      getItem(k) {
        if (s.mode === 'get' || s.mode === 'both') throw new Error('SecurityError: get blocked');
        return map.has(k) ? map.get(k) : null;
      },
      setItem(k, v) {
        if (s.mode === 'set' || s.mode === 'both') throw new Error('QuotaExceededError: set blocked');
        map.set(k, String(v));
      },
      removeItem(k) { map.delete(k); },
    },
  };
  return s;
}

// view(st, opts) — one page view of family.js. opts: reduced (bool),
// matchMedia ('none' to leave it out), storage ('none' | 'getter-throws'),
// loading (readyState 'loading').
function view(st, opts) {
  opts = opts || {};
  const classes = new Set();
  const docListeners = {};
  const queried = [];
  const button = {
    disabled: true,
    textContent: 'Animations: off',
    listeners: {},
    addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); },
    click() { (this.listeners.click || []).forEach((f) => f({ type: 'click' })); },
  };
  const document = {
    readyState: opts.loading ? 'loading' : 'complete',
    documentElement: {
      classList: {
        add(c) { classes.add(c); },
        remove(c) { classes.delete(c); },
        contains(c) { return classes.has(c); },
      },
    },
    querySelector(sel) { queried.push(sel); return sel === '[data-family-motion]' ? button : null; },
    addEventListener(t, f) { (docListeners[t] = docListeners[t] || []).push(f); },
  };
  const ctx = { document };
  ctx.window = ctx;
  if (opts.storage === 'getter-throws') {
    Object.defineProperty(ctx, 'localStorage', { get() { throw new Error('SecurityError: storage blocked'); }, enumerable: true });
  } else if (opts.storage !== 'none') {
    ctx.localStorage = st.api;
  }
  if (opts.matchMedia !== 'none') {
    ctx.matchMedia = (q) => ({ media: q, matches: q === REDUCE ? !!opts.reduced : false });
  }
  vm.createContext(ctx);
  const before = Object.getOwnPropertyNames(ctx);
  vm.runInContext(SRC, ctx, { filename: 'family.js' });
  return {
    ctx,
    classes,
    button,
    queried,
    before,
    on() { return ctx.familyAnimationsOn(); },
    once(name) { return ctx.familyPlayOnce(name); },
    ready() { (docListeners.DOMContentLoaded || []).forEach((f) => f({ type: 'DOMContentLoaded' })); },
  };
}

let KEY = null;
let CLASS = null;
const results = [];
function kase(name, fn) {
  try {
    fn();
    results.push(true);
    console.log(`ok ${name}`);
  } catch (e) {
    results.push(false);
    console.log(`not ok ${name}: ${(e && e.message ? e.message : String(e)).split('\n').join(' | ')}`);
  }
}
const at = (v) => ({ [KEY]: v });
const value = (st) => st.map.get(KEY);
const LABEL = {
  on: 'Animations: on',
  off: 'Animations: off',
  reduced: 'Animations: off (reduced motion)',
  first: 'Animations: on for this page only — keep them on',
};

kase('first view on, second view off', () => {
  const st = store();
  const v1 = view(st);
  assert.strictEqual(st.map.size, 1, 'a first view writes exactly one key');
  KEY = [...st.map.keys()][0];
  assert.strictEqual(value(st), 'off', 'a first view stores off');
  assert.strictEqual(v1.classes.size, 1, 'a first view adds exactly one class');
  CLASS = [...v1.classes][0];
  assert.strictEqual(v1.on(), true);
  console.log(`observed key=${KEY} class=${CLASS} control=${v1.queried.join(',')}`);
  const v2 = view(st);
  assert.strictEqual(v2.on(), false);
  assert.strictEqual(v2.classes.size, 0);
  assert.strictEqual(value(st), 'off');
});

if (KEY === null) {
  console.log('cases: 1');
  process.exit(1);
}

kase('the function and the class agree before and after a click', () => {
  const st = store(at('off'));
  const v = view(st);
  assert.strictEqual(v.on(), false);
  assert.strictEqual(v.classes.has(CLASS), false);
  v.button.click();
  assert.strictEqual(v.on(), true);
  assert.strictEqual(v.classes.has(CLASS), true);
  v.button.click();
  assert.strictEqual(v.on(), false);
  assert.strictEqual(v.classes.has(CLASS), false);
});

kase('an on choice survives a reload', () => {
  const st = store();
  view(st);
  const v2 = view(st);
  assert.strictEqual(v2.on(), false);
  v2.button.click();
  assert.strictEqual(value(st), 'on');
  const v3 = view(st);
  assert.strictEqual(v3.on(), true);
  assert.strictEqual(v3.classes.has(CLASS), true);
});

kase('reduced motion is off even after on', () => {
  const st = store(at('on'));
  const v = view(st, { reduced: true });
  assert.strictEqual(v.on(), false);
  assert.strictEqual(v.classes.size, 0);
  assert.strictEqual(v.button.disabled, true);
  assert.strictEqual(v.button.textContent, LABEL.reduced);
  assert.strictEqual(value(st), 'on', 'reduced motion masks the result; what is stored is unchanged');
});

kase('storage unavailable is off', () => {
  const st = store({}, 'both');
  const v = view(st);
  assert.strictEqual(v.on(), false);
  assert.strictEqual(v.classes.size, 0);
  assert.strictEqual(v.button.disabled, true);
  assert.strictEqual(v.button.textContent, LABEL.off);
  assert.strictEqual(st.map.size, 0);
  const none = view(store(), { storage: 'none' });
  assert.strictEqual(none.on(), false);
  assert.strictEqual(none.button.disabled, true);
});

kase('a failed first-view write is off', () => {
  const st = store({}, 'set');
  const v = view(st);
  assert.strictEqual(v.on(), false);
  assert.strictEqual(v.classes.size, 0);
  assert.strictEqual(v.button.disabled, true);
  assert.strictEqual(v.button.textContent, LABEL.off);
});

kase('an unparseable value reads as off', () => {
  for (const bad of ['', 'ON', 'on ', 'maybe', 'off Elevator', 'off  a', 'on\ndoor']) {
    const st = store(at(bad));
    const v = view(st);
    assert.strictEqual(v.on(), false, `value ${JSON.stringify(bad)}`);
    assert.strictEqual(v.classes.size, 0);
    assert.strictEqual(value(st), bad, 'a load never rewrites a value it cannot parse');
    assert.strictEqual(v.once('door'), true, 'an unparseable value holds no records');
    assert.strictEqual(value(st), 'off door');
  }
});

kase('playOnce: true once per name, then false', () => {
  const st = store(at('off'));
  const v = view(st);
  assert.strictEqual(v.once('elevator'), true);
  assert.strictEqual(value(st), 'off elevator');
  assert.strictEqual(v.once('elevator'), false);
  assert.strictEqual(view(st).once('elevator'), false);
  assert.strictEqual(value(st), 'off elevator');
});

kase('playOnce plays even when animations are off', () => {
  const st = store(at('off'));
  const v = view(st);
  assert.strictEqual(v.on(), false);
  assert.strictEqual(v.once('door'), true);
  assert.strictEqual(v.on(), false, 'playOnce does not turn animations on');
});

kase('playOnce is false under reduced motion and records nothing', () => {
  const st = store(at('on'));
  const v = view(st, { reduced: true });
  assert.strictEqual(v.once('elevator'), false);
  assert.strictEqual(value(st), 'on');
});

kase('playOnce is false when storage is unavailable', () => {
  assert.strictEqual(view(store(at('off'), 'get')).once('elevator'), false);
  const st = store(at('off'));
  const v = view(st);
  st.mode = 'set';
  assert.strictEqual(v.once('elevator'), false, 'a failed write is false');
  assert.strictEqual(value(st), 'off');
});

kase('turning animations on clears the play-once records', () => {
  const st = store(at('off elevator door'));
  const v = view(st);
  assert.strictEqual(v.once('elevator'), false);
  v.button.click();
  assert.strictEqual(value(st), 'on');
  assert.strictEqual(v.once('elevator'), true);
  assert.strictEqual(value(st), 'on elevator');
});

kase('the control turns them off again, keeping records', () => {
  const st = store(at('on door'));
  const v = view(st);
  assert.strictEqual(v.on(), true);
  v.button.click();
  assert.strictEqual(value(st), 'off door');
  assert.strictEqual(v.on(), false);
  assert.strictEqual(v.classes.has(CLASS), false);
  assert.strictEqual(v.button.textContent, LABEL.off);
});

kase('names are independent', () => {
  const st = store(at('off'));
  const v = view(st);
  assert.strictEqual(v.once('a'), true);
  assert.strictEqual(v.once('b'), true);
  assert.strictEqual(v.once('a'), false);
  assert.strictEqual(value(st), 'off a b');
});

kase('an invalid name throws TypeError', () => {
  const v = view(store(at('off')));
  for (const bad of ['', 'Elevator', 'a b', '-a', 'x'.repeat(33), 42, null, undefined]) {
    assert.throws(() => v.once(bad), (e) => e && e.name === 'TypeError', `name ${JSON.stringify(bad)}`);
  }
  assert.strictEqual(v.once('x'.repeat(32)), true, 'a 32-character name is valid');
});

kase('no matchMedia counts as reduced', () => {
  const st = store(at('on'));
  const v = view(st, { matchMedia: 'none' });
  assert.strictEqual(v.on(), false);
  assert.strictEqual(v.classes.size, 0);
  assert.strictEqual(v.button.disabled, true);
  assert.strictEqual(v.button.textContent, LABEL.reduced);
  assert.strictEqual(v.once('door'), false);
});

kase('only the two functions are exported', () => {
  const v = view(store(at('off')));
  const added = Object.getOwnPropertyNames(v.ctx).filter((k) => !v.before.includes(k)).sort();
  assert.deepStrictEqual(added, ['familyAnimationsOn', 'familyPlayOnce']);
  for (const k of added) assert.strictEqual(typeof v.ctx[k], 'function');
  console.log(`exports: ${added.join(',')}`);
});

kase('wires the control on DOMContentLoaded when loading', () => {
  const st = store(at('off'));
  const v = view(st, { loading: true });
  assert.strictEqual((v.button.listeners.click || []).length, 0, 'not wired before DOMContentLoaded');
  assert.strictEqual(v.button.disabled, true);
  v.ready();
  assert.strictEqual((v.button.listeners.click || []).length, 1, 'wired once on DOMContentLoaded');
  assert.strictEqual(v.button.disabled, false);
  v.button.click();
  assert.strictEqual(value(st), 'on');
  assert.strictEqual(v.on(), true);
});

kase('a throwing localStorage getter is unavailable', () => {
  const v = view(store(), { storage: 'getter-throws' });
  assert.strictEqual(typeof v.ctx.familyAnimationsOn, 'function');
  assert.strictEqual(typeof v.ctx.familyPlayOnce, 'function');
  assert.strictEqual(v.on(), false);
  assert.strictEqual(v.once('door'), false);
  assert.strictEqual(v.button.disabled, true);
});

kase("a v1 reader leaves another major's key alone", () => {
  const m = /^(.*-v)([0-9]+)$/.exec(KEY);
  assert.ok(m, `key ${KEY} ends in its major version`);
  const other = `${m[1]}${Number(m[2]) + 1}`;
  const st = store({ [other]: 'on whatever' });
  const v = view(st);
  assert.strictEqual(value(st), 'off', 'the first view writes its own key');
  v.button.click();
  v.once('door');
  view(st).button.click();
  assert.strictEqual(st.map.get(other), 'on whatever');
  assert.deepStrictEqual([...st.map.keys()].sort(), [KEY, other].sort());
});

kase('a write re-reads the store', () => {
  const st = store(at('on'));
  const v = view(st);
  st.map.set(KEY, 'on door');
  v.button.click();
  assert.strictEqual(value(st), 'off door', 'the click keeps a record another tab wrote');
  st.map.set(KEY, 'off door window');
  assert.strictEqual(v.once('elevator'), true);
  assert.strictEqual(value(st), 'off door window elevator', 'playOnce keeps records another tab wrote');
  st.map.set(KEY, 'off door window elevator stair');
  assert.strictEqual(v.once('stair'), false, 'a name another tab recorded is already played');
});

kase('first view offers to keep animations on with one click', () => {
  const st = store();
  const v = view(st);
  assert.strictEqual(v.button.disabled, false);
  assert.strictEqual(v.button.textContent, LABEL.first);
  v.button.click();
  assert.strictEqual(value(st), 'on');
  assert.strictEqual(v.on(), true);
  assert.strictEqual(v.classes.has(CLASS), true);
  assert.strictEqual(v.button.textContent, LABEL.on);
  const v2 = view(st);
  assert.strictEqual(v2.on(), true);
  assert.strictEqual(v2.button.textContent, LABEL.on);
});

kase('the control labels on later views', () => {
  const off = view(store(at('off')));
  assert.strictEqual(off.button.textContent, LABEL.off);
  assert.strictEqual(off.button.disabled, false);
  const on = view(store(at('on')));
  assert.strictEqual(on.button.textContent, LABEL.on);
  assert.strictEqual(on.button.disabled, false);
  on.button.click();
  assert.strictEqual(on.button.textContent, LABEL.off);
  on.button.click();
  assert.strictEqual(on.button.textContent, LABEL.on);
});

kase('a page without the control still loads', () => {
  const st = store(at('on'));
  const ctx = { document: {
    readyState: 'complete',
    documentElement: { classList: { add() {}, remove() {}, contains() { return false; } } },
    querySelector() { return null; },
    addEventListener() {},
  } };
  ctx.window = ctx;
  ctx.localStorage = st.api;
  ctx.matchMedia = () => ({ matches: false });
  vm.createContext(ctx);
  vm.runInContext(SRC, ctx, { filename: 'family.js' });
  assert.strictEqual(ctx.familyAnimationsOn(), true);
});

console.log(`cases: ${results.length}`);
process.exit(results.every(Boolean) ? 0 : 1);
