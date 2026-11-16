/* docs-site/assets/landing.js — the landing page's enhancements (#998).
   With scripts off the page is complete: every phase list is open, the
   buttons are disabled and the commands are selectable text. This script
   enables the copy buttons, collapses the phase lists, enables "Show me every
   step", and makes each phase of the loop diagram open its own list. A link
   to #phase-<id> keeps that phase's list open. */
(function () {
  'use strict';

  function each(list, fn) { Array.prototype.forEach.call(list, fn); }

  function selectText(node) {
    var range = document.createRange();
    var sel = window.getSelection();
    range.selectNodeContents(node);
    sel.removeAllRanges();
    sel.addRange(range);
  }

  function initCopy() {
    each(document.querySelectorAll('[data-copy]'), function (button) {
      var code = document.getElementById(button.getAttribute('data-copy'));
      var label = button.textContent;
      var timer = 0;
      if (!code) { return; }
      button.disabled = false;
      button.setAttribute('aria-live', 'polite');
      button.addEventListener('click', function () {
        var text = code.textContent;
        var copied = function () {
          button.textContent = 'Copied';
          clearTimeout(timer);
          timer = setTimeout(function () { button.textContent = label; }, 1500);
        };
        var failed = function () { selectText(code); };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(copied, failed);
        } else {
          failed();
        }
      });
    });
  }

  function initLoop() {
    var loop = document.getElementById('loop');
    var lists, all, target;
    if (!loop) { return; }
    lists = loop.querySelectorAll('details');
    target = location.hash.indexOf('#phase-') === 0 && document.getElementById(location.hash.slice(1));
    each(lists, function (d) { d.open = !!target && target.contains(d); });
    all = loop.querySelector('[data-loop-all]');
    if (all) {
      all.disabled = false;
      all.addEventListener('click', function () {
        each(lists, function (d) { d.open = true; });
      });
    }
    each(loop.querySelectorAll('svg a'), function (link) {
      link.addEventListener('click', function (event) {
        var phase = link.querySelector('[data-phase]');
        var item = phase && document.getElementById('phase-' + phase.getAttribute('data-phase'));
        var summary;
        if (!item) { return; }
        event.preventDefault();
        each(lists, function (d) { d.open = item.contains(d); });
        summary = item.querySelector('summary');
        if (summary) { summary.focus(); }
      });
    });
  }

  function init() {
    initCopy();
    initLoop();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
}());
