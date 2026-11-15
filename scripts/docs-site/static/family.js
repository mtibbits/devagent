/* family v1.0: family.js — the animation setting: familyAnimationsOn(), familyPlayOnce(name) */
/*
 * One of the four family files (family.css, family.js, family-topbar.html,
 * family-footer.html) shared by devagent, Gantry and the Journeyman course.
 * Copy it byte for byte; never edit a copy.
 *
 * Contract (family v1.0):
 *   key: mtibbits-family-v1
 *   value: ^(on|off)((?: [a-z0-9][a-z0-9-]{0,31})*)$
 *   class: family-motion
 *   control: [data-family-motion]
 *   exports: familyAnimationsOn, familyPlayOnce
 *
 * key      the one localStorage key. Its major version is part of the key, so
 *          a v1 copy and a v2 copy on one origin never write each other's
 *          value. Family sites share the setting only while they are served
 *          from the same origin (https://mtibbits.github.io/).
 * value    the motion choice (on or off), then the play-once names recorded,
 *          in the order they were recorded. An absent key means no family
 *          page has been viewed in this browser yet. A value that does not
 *          match reads as "off" with no records, and a page load never
 *          rewrites it.
 * unavailable  no localStorage, reading the property throws, or getItem or
 *          setItem throws: animations are off and nothing is recorded.
 * class    set on <html> while animations are on. Every animation and
 *          transition in the family files applies only under it, so with
 *          scripts off nothing moves.
 * control  the footer button (family-footer.html). It is static and disabled
 *          in the HTML; this script enables it once the page has loaded.
 *
 * A page view: the first view of any family page in this browser plays
 * animations once and stores "off"; every later view follows the stored
 * choice. Under prefers-reduced-motion: reduce (or with no matchMedia),
 * animations are always off, whatever is stored; that masks the result only.
 *
 * familyAnimationsOn() -> boolean
 *   whether animations are on in this view: the current state, which a click
 *   on the control changes. Other scripts (a hero animation) call it.
 * familyPlayOnce(name) -> boolean
 *   true the first time it is called for name in this browser, which it
 *   records; false after, under reduced motion, or when storage is
 *   unavailable or the write fails. It ignores the motion choice by design: a
 *   visitor-started sequence (Gantry's elevator ride) plays once even when
 *   animations are off. name must match ^[a-z0-9][a-z0-9-]{0,31}$, else it
 *   throws TypeError. Turning animations on with the control clears every
 *   record, so the visitor sees each sequence again.
 *
 * Every write re-reads the key first: records are a union across tabs, and
 * the choice is the writer's.
 *
 * Versions (D2): a minor bump (v1.1) is additive (CSS values, markup that
 * adds no live key, a new optional export). A major bump (v2.0) changes the
 * stored value grammar, the set of live keys the partials use, the
 * placeholder syntax or the live-settings format, and moves the key to
 * mtibbits-family-v2.
 */
(function () {
  'use strict';
  var KEY = 'mtibbits-family-v1';
  var CLASS = 'family-motion';
  var CONTROL = '[data-family-motion]';
  var VALUE = /^(on|off)((?: [a-z0-9][a-z0-9-]{0,31})*)$/;
  var NAME = /^[a-z0-9][a-z0-9-]{0,31}$/;
  var LABEL_ON = 'Animations: on';
  var LABEL_OFF = 'Animations: off';
  var LABEL_REDUCED = 'Animations: off (reduced motion)';
  var LABEL_FIRST = 'Animations: on for this page only — keep them on';

  // read() -> { ok: false } when storage is unavailable, else { ok: true,
  // raw: the stored string or null }.
  function read() {
    try {
      var s = window.localStorage;
      if (!s) return { ok: false };
      return { ok: true, raw: s.getItem(KEY) };
    } catch (e) {
      return { ok: false };
    }
  }

  function write(v) {
    try {
      var s = window.localStorage;
      if (!s) return false;
      s.setItem(KEY, v);
      return true;
    } catch (e) {
      return false;
    }
  }

  // parse(raw) -> { absent, choice, records }
  function parse(raw) {
    if (raw === null || raw === undefined) return { absent: true, choice: 'off', records: [] };
    var m = VALUE.exec(String(raw));
    if (!m) return { absent: false, choice: 'off', records: [] };
    return { absent: false, choice: m[1], records: m[2] ? m[2].slice(1).split(' ') : [] };
  }

  function reduced() {
    try {
      if (typeof window.matchMedia !== 'function') return true;
      return !!window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    } catch (e) {
      return true;
    }
  }

  function setClass(on) {
    var cl = document.documentElement && document.documentElement.classList;
    if (!cl) return;
    if (on) cl.add(CLASS); else cl.remove(CLASS);
  }

  // The page view.
  var first = read();
  var available = first.ok;
  var on = false;
  var firstView = false;
  if (available) {
    var v = parse(first.raw);
    if (v.absent) {
      if (write('off')) {
        on = true;
        firstView = true;
      } else {
        available = false;
      }
    } else {
      on = v.choice === 'on';
    }
  }
  var reducedMotion = reduced();
  if (reducedMotion) on = false;
  setClass(on);

  function label(button) {
    if (firstView) button.textContent = LABEL_FIRST;
    else button.textContent = on ? LABEL_ON : LABEL_OFF;
  }

  function click(button) {
    var now = read();
    if (!now.ok) return;
    var v = parse(now.raw);
    if (on && !firstView) {
      if (!write(['off'].concat(v.records).join(' '))) return;
      on = false;
    } else {
      if (!write('on')) return;
      on = true;
      firstView = false;
    }
    setClass(on);
    label(button);
  }

  function wire() {
    var button = document.querySelector(CONTROL);
    if (!button) return;
    if (reducedMotion || !available) {
      button.disabled = true;
      button.textContent = reducedMotion ? LABEL_REDUCED : LABEL_OFF;
      return;
    }
    button.disabled = false;
    label(button);
    button.addEventListener('click', function () { click(button); });
  }

  window.familyAnimationsOn = function () {
    return on;
  };

  window.familyPlayOnce = function (name) {
    if (typeof name !== 'string' || !NAME.test(name)) {
      throw new TypeError('familyPlayOnce: name must match ' + NAME);
    }
    if (reduced()) return false;
    var now = read();
    if (!now.ok) return false;
    var v = parse(now.raw);
    if (v.records.indexOf(name) !== -1) return false;
    return write([v.choice].concat(v.records, [name]).join(' '));
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', wire);
  } else {
    wire();
  }
})();
