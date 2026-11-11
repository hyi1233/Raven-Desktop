/* Raven Desktop diagnostics -- observe-only, injected ONLY into this app's
 * WKWebView through WKUserScript (WKWebViewConfiguration layer). It is not
 * part of the served page, so the browser/web client never sees it.
 *
 * It never prevents a key, never changes the DOM, never writes to the composer,
 * never uploads anything. It only pushes redacted event metadata into a small
 * queue; the native side holds a fixed in-memory ring and writes a file ONLY
 * when an anomaly is detected or the reader asks for an export.
 *
 * No message text is ever reported: input/IME/paste/error payloads are replaced
 * by their LENGTH. What remains is the event kind, key code, composing flag,
 * field length, RPC method name and byte count -- enough to answer "was this a
 * real Enter, a 229 pseudo-Enter, or no user action at all?".
 */
(function () {
  if (window.__ravenDiag) return;
  window.__ravenDiag = true;

  var VERBOSE = !!window.__ravenDiagVerbose;
  var handler = (window.webkit && window.webkit.messageHandlers)
    ? window.webkit.messageHandlers.ravenDiag : null;

  var pageId = Math.random().toString(36).slice(2, 10);
  var queue = [];
  var MAXQ = 500;          // hard ceiling: never grow unbounded in the page
  var FLUSH_MS = 1000;     // one cross-process message per second at most

  function href() {
    try { return String(location.href.split('#')[0].split('?')[0] || ''); }
    catch (e) { return ''; }
  }
  function len(el) { return el && typeof el.value === 'string' ? el.value.length : -1; }
  function isField(e) {
    var el = e.target;
    return !!el && (el.id === 'ta' || (el.tagName === 'TEXTAREA' && el.closest &&
      el.closest('.field')));
  }
  function redact(v) { return '<' + String(v == null ? '' : v).length + '>'; }
  function keyInfo(e) {
    var el = e.target;
    var o = {
      key: String(e.key || ''), code: String(e.code || ''),
      keyCode: e.keyCode | 0, composing: e.isComposing ? 1 : 0,
      shift: e.shiftKey ? 1 : 0, meta: e.metaKey ? 1 : 0,
      ctrl: e.ctrlKey ? 1 : 0, alt: e.altKey ? 1 : 0,
      repeat: e.repeat ? 1 : 0, len: len(el),
      active: el && document.activeElement === el ? 1 : 0
    };
    if (VERBOSE && el) {
      o.selStart = el.selectionStart | 0;
      o.selEnd = el.selectionEnd | 0;
    }
    return o;
  }

  /* layer: interaction | bridge | page. Native layers (boot/conn/nav/ui) are
     added by the Swift side, which owns the ring buffer and the anomaly rules. */
  function emit(layer, ev, extra) {
    var o = { layer: layer, ev: ev, page: pageId, t: Date.now() };
    if (extra) { for (var k in extra) if (extra.hasOwnProperty(k)) o[k] = extra[k]; }
    if (queue.length < MAXQ) queue.push(o);
  }
  function flush() {
    if (!handler || !queue.length) return;
    var batch = queue.splice(0, queue.length);
    try { handler.postMessage({ batch: batch }); } catch (e) { /* never disturb the page */ }
  }
  setInterval(flush, FLUSH_MS);
  window.addEventListener('pagehide', flush);
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') flush();
  });

  /* ---- bridge / page layer -------------------------------------------- */
  emit('bridge', 'ready', { href: href(), handler: handler ? 1 : 0, verbose: VERBOSE ? 1 : 0 });

  window.addEventListener('error', function (e) {
    emit('page', 'error', { kind: 'error', msgLen: String(e.message || '').length });
  }, true);
  window.addEventListener('unhandledrejection', function (e) {
    emit('page', 'error', { kind: 'rejection', msgLen: String(e.reason || '').length });
  }, true);

  /* ---- interaction layer ---------------------------------------------- */
  document.addEventListener('compositionstart', function (e) {
    if (isField(e)) emit('interaction', 'compositionstart', { data: redact(e.data), len: len(e.target) });
  }, true);
  document.addEventListener('compositionupdate', function (e) {
    if (isField(e)) emit('interaction', 'compositionupdate', { data: redact(e.data), len: len(e.target) });
  }, true);
  document.addEventListener('compositionend', function (e) {
    if (!isField(e)) return;
    emit('interaction', 'compositionend', { data: redact(e.data), len: len(e.target) });
    var el = e.target;
    setTimeout(function () {
      emit('interaction', 'after:compositionend', { len: len(el), active: document.activeElement === el ? 1 : 0 });
    }, 0);
  }, true);

  document.addEventListener('beforeinput', function (e) {
    if (isField(e)) emit('interaction', 'beforeinput', {
      data: redact(e.data), len: len(e.target), inputType: String(e.inputType || '')
    });
  }, true);
  document.addEventListener('input', function (e) {
    if (isField(e)) emit('interaction', 'input', {
      data: redact(e.data), len: len(e.target), composing: e.isComposing ? 1 : 0,
      inputType: String(e.inputType || '')
    });
  }, true);

  document.addEventListener('keydown', function (e) {
    if (!isField(e)) return;
    emit('interaction', 'keydown', keyInfo(e));
    if (e.key === 'Enter') {
      var el = e.target;
      setTimeout(function () {
        emit('interaction', 'after:enter', { len: len(el), active: document.activeElement === el ? 1 : 0 });
      }, 0);
    }
  }, true);
  document.addEventListener('keyup', function (e) {
    if (isField(e) && e.key === 'Enter') emit('interaction', 'keyup', keyInfo(e));
  }, true);

  document.addEventListener('click', function (e) {
    var el = e.target;
    var id = el && el.id;
    var go = el && el.closest && el.closest('#go');
    if (id === 'go' || go) emit('interaction', 'click:go', { len: len(document.getElementById('ta')) });
  }, true);
  document.addEventListener('focus', function (e) {
    if (isField(e)) emit('interaction', 'focus', { len: len(e.target) });
  }, true);
  document.addEventListener('blur', function (e) {
    if (isField(e)) emit('interaction', 'blur', { len: len(e.target) });
  }, true);

  /* ---- RPC: proves how many chat messages actually left the page -------- */
  var WS = window.WebSocket;
  if (WS && WS.prototype) {
    var origSend = WS.prototype.send;
    WS.prototype.send = function (data) {
      try {
        var s = String(data), parsed = null;
        try { parsed = JSON.parse(s); } catch (e) { /* not JSON */ }
        if (parsed && parsed.method) {
          var p = parsed.params || {};
          var t = p.content || p.text || p.message || p.prompt || '';
          emit('interaction', 'rpc.send', {
            method: String(parsed.method),
            rpcLen: typeof t === 'string' ? t.length : -1,
            bytes: s.length
          });
        } else {
          emit('interaction', 'ws.send', { bytes: s.length });
        }
      } catch (e) { /* never disturb the page */ }
      return origSend.apply(this, arguments);
    };
  }
})();
