// Clawd chat page: the renderer and the bridge's page side. Swift calls ClawdChat.apply and ClawdChat.reset (callAsyncJavaScript with
// arguments, never string-built JS); the page posts only `ready`, `open`, `selection` (a Boolean, never the text), `copy` (an entry id), `copy-code`
// (an entry id and a fence ordinal), `copy-link` (a URL the page is showing), `layer` (a Boolean) and `view` (the reader's place) back. Every piece of text from the transcript reaches the DOM
// through textContent, or through marked's output after the allow-list walk below; there is no other path to innerHTML.
(function () {
  'use strict';

  var column = document.getElementById('column');
  var scroller = document.getElementById('scroller');

  // ---- text ---------------------------------------------------------------------------------------------------------------------

  // The one place a string becomes the text of an element.
  function setText(el, text) { el.textContent = text; }

  function clip(text, limit) { return text.length > limit ? text.slice(0, limit) : text; }

  function escapeHtml(text) {
    return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function el(tag, className) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    return node;
  }

  function span(className, text) {
    var node = el('span', className);
    if (text !== undefined) setText(node, text);
    return node;
  }

  function post(message) {
    try { window.webkit.messageHandlers.clawd.postMessage(message); } catch (error) { /* not inside Clawd's web view */ }
  }

  // ---- icons: Lucide (ISC) 0.577.0 paths, inlined as DOM nodes (no image loads, no markup strings) -----------------------------------
  var SVG_NS = 'http://www.w3.org/2000/svg';
  var ICONS = {
    eye: [['path', { d: 'M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0' }], ['circle', { cx: '12', cy: '12', r: '3' }]],
    terminal: [['path', { d: 'm7 11 2-2-2-2' }], ['path', { d: 'M11 13h4' }], ['rect', { width: '18', height: '18', x: '3', y: '3', rx: '2', ry: '2' }]],
    pencil: [['path', { d: 'M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z' }], ['path', { d: 'm15 5 4 4' }]],
    search: [['path', { d: 'm21 21-4.34-4.34' }], ['circle', { cx: '11', cy: '11', r: '8' }]],
    globe: [['circle', { cx: '12', cy: '12', r: '10' }], ['path', { d: 'M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20' }], ['path', { d: 'M2 12h20' }]],
    bot: [['path', { d: 'M12 8V4H8' }], ['rect', { width: '16', height: '12', x: '4', y: '8', rx: '2' }], ['path', { d: 'M2 14h2' }], ['path', { d: 'M20 14h2' }], ['path', { d: 'M15 13v2' }], ['path', { d: 'M9 13v2' }]],
    wrench: [['path', { d: 'M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.106-3.105c.32-.322.863-.22.983.218a6 6 0 0 1-8.259 7.057l-7.91 7.91a1 1 0 0 1-2.999-3l7.91-7.91a6 6 0 0 1 7.057-8.259c.438.12.54.662.219.984z' }]],
    spinner: [['path', { d: 'M21 12a9 9 0 1 1-6.219-8.56' }]],
    copy: [['rect', { width: '14', height: '14', x: '8', y: '8', rx: '2', ry: '2' }], ['path', { d: 'M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2' }]],
    check: [['path', { d: 'M20 6 9 17l-5-5' }]],
    image: [['rect', { width: '18', height: '18', x: '3', y: '3', rx: '2', ry: '2' }], ['circle', { cx: '9', cy: '9', r: '2' }], ['path', { d: 'm21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21' }]],
    arrowUp: [['path', { d: 'm5 12 7-7 7 7' }], ['path', { d: 'M12 19V5' }]],
    arrowDown: [['path', { d: 'M12 5v14' }], ['path', { d: 'm19 12-7 7-7-7' }]],
    externalLink: [['path', { d: 'M15 3h6v6' }], ['path', { d: 'M10 14 21 3' }], ['path', { d: 'M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6' }]]
  };

  function icon(name, className) {
    var svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('class', className ? 'icon ' + className : 'icon');
    svg.setAttribute('viewBox', '0 0 24 24');
    ICONS[name].forEach(function (shape) {
      var node = document.createElementNS(SVG_NS, shape[0]);
      Object.keys(shape[1]).forEach(function (key) { node.setAttribute(key, shape[1][key]); });
      svg.appendChild(node);
    });
    return svg;
  }

  // ---- Markdown: marked 12.0.2, gfm + breaks, raw HTML escaped, links inert, images as their alt text ---------------------------------
  var renderer = new marked.Renderer();
  renderer.html = function (html) { return escapeHtml(html); };
  renderer.link = function (href, title, text) { return '<a data-href="' + escapeHtml(href == null ? '' : href) + '">' + text + '</a>'; };
  renderer.image = function (href, title, text) { return escapeHtml(text == null ? '' : text); };
  renderer.checkbox = function (checked) { return checked ? '[x] ' : '[ ] '; };
  renderer.code = function (code, infostring) {
    var language = ((infostring || '').match(/^\S*/) || [''])[0];
    return '<pre data-lang="' + escapeHtml(language) + '"><code>' + escapeHtml(code) + '</code></pre>';
  };

  // marked enters a raw-block state after an inline <code>, <pre>, <kbd> or <script> tag and emits the text after it unescaped. A tokenizer
  // with no inline `tag` rule never enters it: every tag-looking piece of text is then lexed as text and escaped.
  var tokenizer = new marked.Tokenizer();
  tokenizer.tag = function () { return undefined; };

  // The elements and attributes an entry's Markdown may produce. Anything else is replaced by its text.
  var MAX_ELEMENTS = 20000;
  var ALLOWED = {
    p: [], br: [], strong: [], em: [], del: [], code: [], pre: ['data-lang'], ul: [], ol: ['start'], li: [], blockquote: [],
    h1: [], h2: [], h3: [], h4: [], h5: [], h6: [], hr: [], a: ['data-href'], table: [], thead: [], tbody: [], tr: [],
    th: ['align'], td: ['align']
  };

  function markdownHtml(text) {
    try {
      return marked.parse(String(text), { gfm: true, breaks: true, renderer: renderer, tokenizer: tokenizer, async: false });
    } catch (error) {
      return '<p>' + escapeHtml(text) + '</p>';
    }
  }

  function sanitize(root) {
    var all = root.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var node = all[i];
      var tag = node.localName;
      if (!Object.prototype.hasOwnProperty.call(ALLOWED, tag)) {
        if (node.parentNode) node.replaceWith(document.createTextNode(node.textContent));
        continue;
      }
      var keep = ALLOWED[tag];
      for (var j = node.attributes.length - 1; j >= 0; j--) {
        var name = node.attributes[j].name;
        if (keep.indexOf(name) < 0) node.removeAttribute(name);
      }
    }
  }

  // Orca's code-block language labels (rich-markdown-code-block-languages.ts:14-40); any other value is shown as it is (:61-63).
  var LANGUAGE_LABELS = {
    bash: 'Bash', c: 'C', cpp: 'C++', css: 'CSS', diff: 'Diff', go: 'Go', graphql: 'GraphQL', html: 'HTML', java: 'Java',
    javascript: 'JavaScript', json: 'JSON', kotlin: 'Kotlin', markdown: 'Markdown', mermaid: 'Mermaid', python: 'Python', ruby: 'Ruby',
    rust: 'Rust', scss: 'SCSS', shell: 'Shell', sql: 'SQL', swift: 'Swift', typescript: 'TypeScript', xml: 'XML', yaml: 'YAML'
  };
  function languageLabel(language) {
    return Object.prototype.hasOwnProperty.call(LANGUAGE_LABELS, language) ? LANGUAGE_LABELS[language] : language;
  }

  // Orca's fenced block (C/NativeChatCodeBlock.tsx:17-53). A fence with a language has a 30 pt header with the label and, at its right end, the copy
  // button; a fence without one has no header and a copy button inside the block's top right corner, shown on hover or keyboard focus. Only a fence
  // with code has the button. A click only asks Swift (`copy-code`, the entry id and the fence's ordinal in that entry); Swift pulls the text.
  function decorate(root) {
    var blocks = root.querySelectorAll('pre');
    for (var i = 0; i < blocks.length; i++) {
      var pre = blocks[i];
      var language = pre.getAttribute('data-lang') || '';
      var hasCode = (pre.textContent || '').length > 0;
      var wrapper = el('div', 'code-block');
      pre.removeAttribute('data-lang');
      pre.replaceWith(wrapper);
      if (language) {
        var head = el('div', 'code-head');
        head.appendChild(span('code-lang', languageLabel(language)));
        if (hasCode) head.appendChild(codeCopyButton(wrapper, 'head'));
        wrapper.appendChild(head);
        pre.className = 'with-head';
      }
      wrapper.appendChild(pre);
      if (!language && hasCode) wrapper.appendChild(codeCopyButton(wrapper, 'float'));
    }
    var tables = root.querySelectorAll('table');
    for (var k = 0; k < tables.length; k++) {
      var table = tables[k];
      var wrap = el('div', 'table-wrap');
      table.replaceWith(wrap);
      wrap.appendChild(table);
    }
  }

  // Markdown into `target`: marked's string is parsed inside an inert template, walked, and only then moved into the page.
  function renderMarkdown(target, text) { renderHtml(target, markdownHtml(text), text); }

  function renderHtml(target, html, text) {
    var template = document.createElement('template');
    template.innerHTML = html;
    var fragment = template.content;
    // A reply that parses into a huge element tree (nested brackets and emphasis) is shown as plain text: the tree would cost more to lay out
    // than the reply is worth, and nothing is lost but the styling.
    if (fragment.querySelectorAll('*').length > MAX_ELEMENTS) {
      target.classList.add('plain');
      target.textContent = String(text === undefined ? html : text);
      return;
    }
    target.classList.remove('plain');
    sanitize(fragment);
    decorate(fragment);
    target.replaceChildren(fragment);
  }

  // ---- tool lines (C/native-chat-tool-line-label.ts:25-120 for the words) -----------------------------------------------------------
  var TOOLS = {
    Read: ['read', 'eye'], NotebookRead: ['read', 'eye'],
    Edit: ['edit', 'pencil'], MultiEdit: ['edit', 'pencil'], Write: ['edit', 'pencil'], NotebookEdit: ['edit', 'pencil'],
    Bash: ['command', 'terminal'], BashOutput: ['command', 'terminal'], KillShell: ['command', 'terminal'],
    Grep: ['search', 'search'], Glob: ['list', 'search'], LS: ['list', 'search'],
    WebFetch: ['fetch', 'globe'], WebSearch: ['web', 'globe'],
    Task: ['agent', 'bot'], Agent: ['agent', 'bot']
  };
  // running, done, failed
  var VERBS = {
    read: ['Reading', 'Read', 'Tried to read'], edit: ['Editing', 'Edited', 'Tried to edit'], command: ['Running', 'Ran', 'Ran'],
    search: ['Searching', 'Searched', 'Tried to search'], list: ['Listing', 'Listed', 'Tried to list'],
    fetch: ['Fetching', 'Fetched', 'Tried to fetch'], web: ['Searching the web', 'Searched the web', 'Tried to search the web'],
    agent: ['Subagent', 'Subagent', 'Subagent']
  };

  function lastPathPart(text) {
    var parts = text.split(/[\\/]/).filter(function (part) { return part.length > 0; });
    return parts.length ? parts[parts.length - 1] : text;
  }

  function formatSeconds(seconds) {
    var whole = Math.max(0, Math.round(seconds));
    if (whole < 60) return whole + 's';
    var minutes = Math.floor(whole / 60);
    return minutes + 'm ' + (whole % 60) + 's';
  }

  function buildTool() {
    var row = el('div', 'row tool-row');
    var run = el('div', 'tool-run');
    var line = el('div', 'tool-line');
    var glyph = el('span', 'glyph');
    var verb = span('verb');
    var target = span('target');
    var meta = span('tool-meta');
    line.appendChild(glyph); line.appendChild(verb); line.appendChild(target); line.appendChild(meta);
    run.appendChild(line); row.appendChild(run);
    return { el: row, line: line, glyph: glyph, verb: verb, target: target, meta: meta, iconName: null };
  }

  function updateTool(rec, entry) {
    var name = entry.tool || '';
    var known = Object.prototype.hasOwnProperty.call(TOOLS, name) ? TOOLS[name] : null;
    var category = known ? known[0] : null;
    var iconName = known ? known[1] : 'wrench';
    var status = entry.status || 'running';
    rec.line.className = 'tool-line ' + status;
    if (rec.iconName !== iconName) {
      rec.glyph.replaceChildren(icon(iconName));
      rec.iconName = iconName;
    }
    var verbs = category ? VERBS[category] : null;
    var verbText = name;
    if (verbs) verbText = status === 'running' ? verbs[0] : status === 'failed' ? verbs[2] : verbs[1];
    setText(rec.verb, verbText);
    var text = clip(entry.text || '', 500);
    var chip = category === 'command' || category === null;
    rec.target.className = chip && text ? 'chip' : 'target';
    setText(rec.target, category === 'read' || category === 'edit' ? lastPathPart(text) : text);
    var meta = [];
    if (status === 'failed') meta.push('failed');
    if (status === 'unknown') meta.push('no result');
    if (typeof entry.seconds === 'number' && entry.seconds >= 1 && status === 'running') meta.push(formatSeconds(entry.seconds));
    setText(rec.meta, meta.join(' '));
  }

  // ---- entries ----------------------------------------------------------------------------------------------------------------
  var nodes = new Map();          // entry id -> record
  var turn = 'none';
  var turnStartedAt = 0;
  var clock = null;               // the one interval, alive only while a turn runs
  var BIG_BYTES = 32 * 1024;
  var MIN_REPARSE_MS = 250;

  function build(entry) {
    var rec = { id: entry.id, kind: entry.kind, el: null, mdEl: null, textEl: null, parsedText: null, pending: null,
                lastParseMs: 0, lastParseAt: -Infinity, timer: null, tool: null, copyEl: null, copyTimer: null,
                metaEl: null, metaKey: null, timeEl: null, bubbleEl: null, imagesEl: null, imagesKey: null };
    if (entry.kind === 'user') {
      var row = el('div', 'row');
      var userRow = el('div', 'user-row');
      var bubble = el('div', 'user-bubble native-chat-message-text');
      rec.bubbleEl = bubble;
      rec.mdEl = el('div', 'native-chat-markdown native-chat-message-text text-sm');
      bubble.appendChild(rec.mdEl);
      userRow.appendChild(bubble);
      var meta = el('div', 'user-meta');
      rec.copyEl = copyButton(entry.id);
      meta.appendChild(rec.copyEl);
      rec.metaEl = meta;
      userRow.appendChild(meta);
      row.appendChild(userRow);
      rec.el = row;
    } else if (entry.kind === 'assistant') {
      var arow = el('div', 'row');
      var assistant = el('div', 'assistant-row native-chat-message-text');
      rec.mdEl = el('div', 'native-chat-markdown native-chat-message-text text-sm');
      assistant.appendChild(rec.mdEl);
      var controls = el('div', 'agent-controls');
      rec.copyEl = copyButton(entry.id);
      controls.appendChild(rec.copyEl);
      controls.appendChild(scrollTopButton(rec));
      rec.metaEl = controls;
      assistant.appendChild(controls);
      arow.appendChild(assistant);
      rec.el = arow;
    } else if (entry.kind === 'tool') {
      rec.tool = buildTool();
      rec.el = rec.tool.el;
    } else if (entry.kind === 'footer') {
      var frow = el('div', 'row');
      var bar = el('div', 'turn-bar');
      rec.textEl = span('label');
      rec.costEl = span('cost');
      bar.appendChild(rec.textEl); bar.appendChild(rec.costEl);
      frow.appendChild(bar);
      rec.el = frow;
    } else if (entry.kind === 'divider') {
      // Orca's compaction separator (NC/NativeChatNoticeRow.tsx:38-49): a rule on each side of a 12 px muted label, 8 px above and below.
      var drow = el('div', 'row');
      var separator = el('div', 'separator');
      separator.setAttribute('role', 'separator');
      rec.textEl = span('');
      separator.appendChild(span('rule'));
      separator.appendChild(rec.textEl);
      separator.appendChild(span('rule'));
      drow.appendChild(separator);
      rec.el = drow;
    } else {
      var nrow = el('div', 'row');
      rec.textEl = el('div', entry.kind === 'error' ? 'error-line' : 'notice');
      nrow.appendChild(rec.textEl);
      rec.el = nrow;
    }
    rec.el.setAttribute('data-id', String(entry.id));
    return rec;
  }

  // Orca's NativeChatCopyButton (C/NativeChatCopyButton.tsx:34-68): a 24 px rounded-md button, label "Copy message". A click only asks Swift
  // (`copy`, the entry id): Swift writes the pasteboard and answers with ClawdChat.copied(id), which swaps the icon for a check and the label for
  // "Copied" for 1500 ms. A failed write changes nothing.
  function copyButton(id) {
    var button = el('button', 'copy-btn');
    button.type = 'button';
    button.setAttribute('aria-label', 'Copy message');
    button.title = 'Copy message';
    button.appendChild(icon('copy'));
    button.addEventListener('click', function () { post({ type: 'copy', id: id }); });
    return button;
  }

  function showCopied(rec) {
    var button = rec.copyEl;
    if (!button) return;
    if (rec.copyTimer !== null) clearTimeout(rec.copyTimer);
    button.classList.add('copied');
    button.setAttribute('aria-label', 'Copied');
    button.title = 'Copied';
    button.replaceChildren(icon('check'));
    rec.copyTimer = setTimeout(function () {
      rec.copyTimer = null;
      button.classList.remove('copied');
      button.setAttribute('aria-label', 'Copy message');
      button.title = 'Copy message';
      button.replaceChildren(icon('copy'));
    }, 1500);
  }

  function copied(id) {
    var rec = nodes.get(id);
    if (rec) showCopied(rec);
    return true;
  }

  // A button that shows a check and a new label for 1500 ms, then goes back (the message button's rule, for the buttons that have no record).
  var flashTimers = new Map();
  function flash(button, iconName, label, doneLabel, ms) {
    var old = flashTimers.get(button);
    if (old !== undefined) clearTimeout(old);
    button.classList.add('copied');
    button.setAttribute('aria-label', doneLabel);
    button.title = doneLabel;
    button.replaceChildren(icon('check'));
    flashTimers.set(button, setTimeout(function () {
      flashTimers.delete(button);
      button.classList.remove('copied');
      button.setAttribute('aria-label', label);
      button.title = label;
      button.replaceChildren(icon(iconName));
    }, ms === undefined ? 1500 : ms));
  }

  // ---- code fences (Q1) ---------------------------------------------------------------------------------------------------------
  function fenceOf(wrapper) {
    var row = wrapper.closest('[data-id]');
    if (!row) return null;
    var id = Number(row.getAttribute('data-id'));
    var fences = row.querySelectorAll('.code-block');
    for (var i = 0; i < fences.length; i++) if (fences[i] === wrapper) return { id: id, index: i };
    return null;
  }

  function codeCopyButton(wrapper, place) {
    var button = el('button', place === 'float' ? 'copy-btn code-float' : 'copy-btn code-copy');
    button.type = 'button';
    button.setAttribute('aria-label', 'Copy code');
    button.title = 'Copy code';
    button.appendChild(icon('copy'));
    button.addEventListener('click', function () {
      var fence = fenceOf(wrapper);
      if (fence) post({ type: 'copy-code', id: fence.id, index: fence.index });
    });
    return button;
  }

  function fenceButton(id, index) {
    var rec = nodes.get(id);
    if (!rec || !rec.mdEl) return null;
    var wrapper = rec.mdEl.querySelectorAll('.code-block')[index];
    return wrapper ? wrapper.querySelector('.copy-btn') : null;
  }

  // Swift pulls the text with a constant function body: the page answers with the fence's code, or null when there is no such fence.
  function codeText(id, index) {
    var rec = nodes.get(id);
    if (!rec || !rec.mdEl) return null;
    var wrapper = rec.mdEl.querySelectorAll('.code-block')[index];
    var pre = wrapper ? wrapper.querySelector('pre') : null;
    var text = pre ? pre.textContent : '';
    // Orca's code text ends in a newline (mdast-util-to-hast code.js:18: a non-empty fence's value plus "\n").
    return text ? text + '\n' : null;
  }

  // The fences whose "Copied" is still showing, by "id/index": a re-render of the entry puts the flash back on the new button.
  var liveCopied = new Map();
  function codeCopied(id, index) {
    liveCopied.set(id + '/' + index, performance.now() + 1500);
    var button = fenceButton(id, index);
    if (button) flash(button, 'copy', 'Copy code', 'Copied');
    return true;
  }

  function reapplyCopied(id) {
    var now = performance.now();
    liveCopied.forEach(function (expiry, key) {
      if (expiry <= now) { liveCopied.delete(key); return; }
      var parts = key.split('/');
      if (Number(parts[0]) !== id) return;
      var button = fenceButton(id, Number(parts[1]));
      if (button) flash(button, 'copy', 'Copy code', 'Copied', expiry - now);
    });
  }

  // A primary press inside an entry's text holds that entry's re-render until the release (and the click that follows it), so a streaming
  // update cannot replace the Copy code button or the link under the finger.
  var heldRec = null;
  function releaseHeld() {
    var rec = heldRec;
    heldRec = null;
    if (rec !== null && rec.pending !== null) flushParse(rec);
  }
  document.addEventListener('mousedown', function (event) {
    if (event.button !== 0 || !event.target.closest) return;
    var row = event.target.closest('[data-id]');
    var rec = row ? nodes.get(Number(row.getAttribute('data-id'))) : null;
    if (rec && rec.mdEl && rec.mdEl.contains(event.target)) heldRec = rec;
  }, true);
  document.addEventListener('mouseup', function () { if (heldRec !== null) setTimeout(releaseHeld, 0); }, true);
  document.documentElement.addEventListener('mouseleave', releaseHeld);

  // ---- timestamps (Q3): Orca's formatters (C/NativeChatMessageTimestamp.tsx:7-55), built on first use ------------------------------------
  var formatters = null;
  function timeFormatters() {
    if (formatters === null) {
      formatters = {
        time: new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }),
        full: new Intl.DateTimeFormat(undefined, { dateStyle: 'full', timeStyle: 'long' })
      };
    }
    return formatters;
  }

  // The `<time>` of a message, or null when the time is missing or not a date.
  function timeElement(ms, focusable) {
    if (typeof ms !== 'number' || !isFinite(ms)) return null;
    var date = new Date(ms);
    if (isNaN(date.getTime())) return null;
    var f = timeFormatters();
    var node = el('time', 'msg-time');
    node.setAttribute('datetime', date.toISOString());
    node.setAttribute('aria-label', f.full.format(date));
    if (focusable) node.tabIndex = 0;
    setText(node, f.time.format(date));
    return node;
  }

  // The part of a message row after its buttons: the time, or "Sending…" in its place (the user row, until the turn answers), and for an
  // assistant row the controls only while the message has text (Orca NativeChatMessageRow.tsx:253).
  function updateMeta(rec, entry) {
    if (!rec.metaEl) return;
    var sending = rec.kind === 'user' && entry.sending === true;
    // A send in doubt (Q13) shows "Not confirmed" where the time would be, in the same always-visible label.
    var unconfirmed = rec.kind === 'user' && !sending && entry.unconfirmed === true;
    if (rec.kind === 'assistant') rec.metaEl.hidden = !entry.text;
    // A user row keeps its time, but shows no copy button while it has no text (an image-only prompt): Swift refuses `copy` for it (Orca :61).
    if (rec.kind === 'user') rec.copyEl.hidden = !entry.text;
    var key = (sending ? 'sending' : unconfirmed ? 'unconfirmed' : 'time') + '|' + (typeof entry.time === 'number' ? entry.time : '');
    if (rec.metaKey === key) return;
    rec.metaKey = key;
    if (rec.timeEl) { rec.timeEl.remove(); rec.timeEl = null; }
    rec.metaEl.classList.toggle('sending', sending || unconfirmed);
    rec.timeEl = sending ? span('sending-label', 'Sending…') : unconfirmed ? span('sending-label', 'Not confirmed') : timeElement(entry.time, rec.kind === 'user');
    if (rec.timeEl) rec.metaEl.appendChild(rec.timeEl);
  }

  // ---- "Scroll this message to top" (Q2): NativeChatAgentControls (C/NativeChatTranscriptChrome.tsx:272-299) ----------------------------
  function scrollTopButton(rec) {
    var button = el('button', 'copy-btn');
    button.type = 'button';
    button.setAttribute('aria-label', 'Scroll this message to top');
    button.title = 'Scroll this message to top';
    button.appendChild(icon('arrowUp'));
    button.addEventListener('click', function () { scrollRowToTop(rec.el.firstElementChild || rec.el); });
    return button;
  }

  function byteLength(text) { return new TextEncoder().encode(text).length; }

  function flushParse(rec) {
    if (heldRec === rec) return;
    if (rec.timer !== null) { clearTimeout(rec.timer); rec.timer = null; }
    if (rec.pending === null) return;
    var text = rec.pending;
    rec.pending = null;
    var started = performance.now();
    renderMarkdown(rec.mdEl, text);
    rec.lastParseAt = performance.now();
    rec.lastParseMs = rec.lastParseAt - started;
    rec.parsedText = text;
    reapplyCopied(rec.id);
  }

  // An entry over 32 KiB that is still streaming is parsed again at most every max(250 ms, 4 x its last parse); a smaller one, at once.
  function scheduleParse(rec, text) {
    if (rec.parsedText === text && rec.pending === null) return;
    rec.pending = text;
    var big = text.length * 3 > BIG_BYTES && byteLength(text) > BIG_BYTES;
    if (!big || turn !== 'running') { flushParse(rec); return; }
    var wait = Math.max(MIN_REPARSE_MS, 4 * rec.lastParseMs) - (performance.now() - rec.lastParseAt);
    if (wait <= 0) { flushParse(rec); return; }
    if (rec.timer === null) {
      rec.timer = setTimeout(function () {
        rec.timer = null;
        following(function () { flushParse(rec); });
      }, wait);
    }
  }

  // ---- sent images (Q17): Orca's name chips (C/NativeChatTranscriptChrome.tsx:208-250, the branch without previews). The page loads no image. ----
  // A chip per path above the text: the image icon and the name ("Pasted image" for a pasted file), the full path as its tooltip.
  var PASTED_NAME = /^clawd-paste-.*\.png$/;
  function imageName(path) {
    var base = path.slice(path.lastIndexOf('/') + 1);
    return PASTED_NAME.test(base) ? 'Pasted image' : base;
  }

  // The container exists only while the entry has images (no attribute but the class), and sits before the text in the bubble.
  function updateImages(rec, entry) {
    if (!rec.bubbleEl) return;
    var paths = Array.isArray(entry.images) ? entry.images.filter(function (path) { return typeof path === 'string'; }) : [];
    var key = paths.join('\n');
    if (rec.imagesKey === key) return;
    rec.imagesKey = key;
    if (paths.length === 0) {
      if (rec.imagesEl) { rec.imagesEl.remove(); rec.imagesEl = null; }
      return;
    }
    if (!rec.imagesEl) {
      rec.imagesEl = el('div', 'msg-images');
      rec.bubbleEl.insertBefore(rec.imagesEl, rec.mdEl);
    }
    rec.imagesEl.replaceChildren();
    paths.forEach(function (path) {
      var chip = el('div', 'msg-image');
      chip.title = path;
      chip.appendChild(icon('image'));
      chip.appendChild(span('msg-image-name', imageName(path)));
      rec.imagesEl.appendChild(chip);
    });
  }

  function updateEntry(rec, entry) {
    if (rec.kind === 'user' || rec.kind === 'assistant') {
      updateImages(rec, entry);
      updateMeta(rec, entry);
      scheduleParse(rec, entry.text || '');
    } else if (rec.kind === 'tool') {
      updateTool(rec.tool, entry);
    } else if (rec.kind === 'footer') {
      setText(rec.textEl, 'Worked for ' + formatSeconds((entry.ms || 0) / 1000));
      setText(rec.costEl, typeof entry.cost === 'number' ? ' · $' + entry.cost.toFixed(4) : '');
    } else if (rec.kind === 'divider') {
      setText(rec.textEl, entry.text || '');
      rec.el.firstChild.setAttribute('aria-label', entry.text || '');
    } else {
      setText(rec.textEl, entry.text || '');
    }
  }

  function drop(rec) {
    if (rec.timer !== null) clearTimeout(rec.timer);
    if (rec.copyTimer !== null) clearTimeout(rec.copyTimer);
    rec.el.querySelectorAll('button').forEach(function (button) {
      var timer = flashTimers.get(button);
      if (timer !== undefined) { clearTimeout(timer); flashTimers.delete(button); }
    });
    rec.el.remove();
    nodes.delete(rec.id);
  }

  // ---- the live tail: "Working for 14s" and the spinner line, only while a turn runs -----------------------------------------------
  var tail = el('div', 'tail');
  var tailBar = el('div', 'turn-bar');
  tailBar.setAttribute('data-native-chat-turn-status', 'active');
  var tailBarText = span('label');
  tailBar.appendChild(tailBarText);
  var activity = el('div', 'activity');
  activity.setAttribute('aria-live', 'polite');
  var spin = icon('spinner', 'spin still');
  var activityLabel = span('label');
  activity.appendChild(spin); activity.appendChild(activityLabel);
  tail.appendChild(tailBar); tail.appendChild(activity);
  tail.hidden = true;
  column.appendChild(tail);

  function paintTail() {
    if (turn === 'running') {
      setText(tailBarText, 'Working for ' + formatSeconds((Date.now() - turnStartedAt) / 1000));
      setText(activityLabel, 'Working…');
    } else if (turn === 'stopping') {
      setText(tailBarText, 'Stopping');
      setText(activityLabel, 'Stopping…');
    } else {
      setText(tailBarText, '');
      setText(activityLabel, '');
    }
  }

  function setTurn(next) {
    if (next === turn) return;
    var previous = turn;
    turn = next;
    if (clock !== null) { clearInterval(clock); clock = null; }
    if (next === 'running') {
      if (previous !== 'stopping') turnStartedAt = Date.now();
      clock = setInterval(paintTail, 1000);
    }
    tail.hidden = next === 'none';
    spin.setAttribute('class', next === 'running' ? 'icon spin' : 'icon spin still');
    paintTail();
    if (next !== 'running') nodes.forEach(function (rec) { if (rec.pending !== null) flushParse(rec); });
  }

  // ---- following the tail (Q4): Orca's rules (C/native-chat-autoscroll.ts:14-72, C/use-native-chat-transcript-scroll.ts:83-185) ------------
  var FOLLOW_REARM_PX = 4;          // NATIVE_CHAT_FOLLOW_REARM_PX
  var JUMP_THRESHOLD_PX = 48;       // NATIVE_CHAT_BOTTOM_THRESHOLD_PX
  var isFollowing = true;           // the view follows the tail until the reader scrolls away
  var previousDistance = Infinity;  // the distance from the end at the previous scroll event
  var marks = [];                   // offsets the page itself wrote: a scroll event landing on one is the page's, not the reader's
  var jump = null;
  var readerScrolls = 0;            // how many scrolls were the reader's own (not one of the page's marks); the view restore reads it (Q18)

  function distanceFromEnd() { return Math.max(0, scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop); }
  function maxOffset() { return Math.max(0, scroller.scrollHeight - scroller.clientHeight); }

  // Orca's programmatic-scroll-marks: a bounded queue of 16 targets, matched within 2 px (or the clamped end for a target past it); a match
  // takes its own mark and every older one with it.
  function markScroll(target) { marks.push(target); if (marks.length > 16) marks.shift(); }
  function consumeMark() {
    var top = scroller.scrollTop, max = maxOffset();
    for (var i = 0; i < marks.length; i++) {
      var target = marks[i];
      if (Math.abs(top - target) <= 2 || (target > max + 2 && top >= max - 2)) { marks.splice(0, i + 1); return true; }
    }
    return false;
  }

  function pin() {
    var before = scroller.scrollTop;
    scroller.scrollTop = scroller.scrollHeight;
    if (scroller.scrollTop !== before) markScroll(scroller.scrollTop);
  }

  // The jump affordance (C/NativeChatMessageList.tsx:418-428): only when the reader has left the end by more than 48 px.
  function updateJump() {
    var show = !isFollowing && distanceFromEnd() > JUMP_THRESHOLD_PX;
    if (show && jump === null) {
      jump = el('button', 'jump');
      jump.type = 'button';
      jump.setAttribute('aria-label', 'Jump to latest');
      jump.appendChild(icon('arrowDown'));
      jump.appendChild(span('jump-label', 'Jump to latest'));
      jump.addEventListener('click', function () {
        readerScrolls += 1;
        isFollowing = true;
        pin();
        updateJump();
      });
      scroller.parentNode.appendChild(jump);
    }
    if (jump !== null) jump.hidden = !show;
  }

  scroller.addEventListener('scroll', function () {
    if (scroller.clientHeight <= 0) return;
    var distance = distanceFromEnd();
    var programmatic = consumeMark();
    if (!programmatic) {
      // A reader's scroll: while detached it stays detached as long as it moves away from the end, and re-attaches on arriving within 4 px.
      isFollowing = !isFollowing && distance > previousDistance ? false : distance <= FOLLOW_REARM_PX;
      readerScrolls += 1;
    }
    previousDistance = distance;
    updateJump();
    // A following view that already reported following has nothing new to say about the page's own pins (restore pins whatever it carried).
    if (!(programmatic && isFollowing && viewLastFollowing)) viewChanged();
  }, { passive: true });

  // The column grows as a reply streams and the scroller as the panel resizes: while following, either pins to the end; else it only recomputes
  // the jump state.
  if (typeof ResizeObserver !== 'undefined') {
    new ResizeObserver(function () { if (isFollowing) pin(); else updateJump(); viewChanged(); }).observe(scroller);
    new ResizeObserver(function () { if (isFollowing) pin(); else updateJump(); }).observe(column);
  }
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(function () { if (isFollowing) pin(); });

  function following(change) {
    var follow = isFollowing;
    change();
    if (follow) pin();
  }

  // "Scroll this message to top" (C/use-native-chat-transcript-window.ts:247-270): the row's top meets the viewport's top, clamped to the range;
  // the view stops following, and the landing is marked as the page's own.
  function scrollRowToTop(row) {
    isFollowing = false;
    readerScrolls += 1;
    var top = row.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
    var landing = Math.max(0, Math.min(top, maxOffset()));
    if (scroller.scrollTop !== landing) markScroll(landing);
    scroller.scrollTo({ top: top, behavior: 'smooth' });
    updateJump();
  }

  // ---- the view state (Q18, D2): what survives a close, since the page itself does not --------------------------------------------------
  // The page tells Swift where the reader is (`view`: following, the first entry crossing the viewport's top, the distance from that entry's top
  // to the viewport's top, and a selection as entry ids plus character offsets), at most 4 times a second, and Swift hands it back after the
  // next open's first reset (`restoreView`). Nothing is reported before that call: a fresh page sits at the end and would overwrite the place.
  var VIEW_MAX = 10000000;
  var VIEW_GAP_MS = 250;
  var viewArmed = false;
  var viewLastKey = '';
  var viewLastAt = -Infinity;
  var viewLastFollowing = false;    // whether the last posted view followed
  var viewTimer = null;
  var restoredState = null;         // the state the last restoreView put back, for its second pass at fonts.ready
  var restoredScrolls = 0;          // readerScrolls at that restore

  function entryRows() { return column.querySelectorAll(':scope > .row[data-id]'); }

  function rowOf(node) {
    var element = node && node.nodeType === 1 ? node : node && node.parentElement;
    return element && element.closest ? element.closest('#column > .row[data-id]') : null;
  }

  // The first entry whose box ends below the viewport's top (the rows are in order, so a binary search on their bottoms).
  function firstCrossing(rows) {
    var viewTop = scroller.getBoundingClientRect().top;
    var low = 0, high = rows.length;
    while (low < high) {
      var mid = (low + high) >> 1;
      if (rows[mid].getBoundingClientRect().bottom > viewTop) high = mid; else low = mid + 1;
    }
    return low < rows.length ? rows[low] : rows.length ? rows[rows.length - 1] : null;
  }

  // A boundary point as a character offset inside its entry's text (the text nodes in order; the same count restore walks).
  function charOffset(row, node, offset) {
    var range = document.createRange();
    range.setStart(row, 0);
    range.setEnd(node, offset);
    return range.toString().length;
  }

  function selectionBounds() {
    var selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
    var range = selection.getRangeAt(0);
    if (!scroller.contains(range.commonAncestorContainer)) return null;
    var first = rowOf(range.startContainer), last = rowOf(range.endContainer);
    if (!first || !last) return null;
    var bounds = [Number(first.getAttribute('data-id')), charOffset(first, range.startContainer, range.startOffset),
                  Number(last.getAttribute('data-id')), charOffset(last, range.endContainer, range.endOffset)];
    return bounds.every(function (n) { return isFinite(n) && n >= 0 && n <= VIEW_MAX; }) ? bounds : null;
  }

  function currentView() {
    var row = firstCrossing(entryRows());
    var state = { type: 'view', following: isFollowing, anchor: 0, offset: 0 };
    if (row !== null) {
      var offset = Math.round(scroller.getBoundingClientRect().top - row.getBoundingClientRect().top);
      state.anchor = Math.max(0, Math.min(VIEW_MAX, Number(row.getAttribute('data-id')) || 0));
      state.offset = Math.max(0, Math.min(VIEW_MAX, offset));
    }
    var bounds = selectionBounds();
    if (bounds !== null) state.sel = bounds;
    return state;
  }

  function postView() {
    var state = currentView();
    var key = JSON.stringify(state);
    if (key === viewLastKey) return;
    viewLastKey = key;
    viewLastAt = performance.now();
    viewLastFollowing = state.following === true;
    post(state);
  }

  // At most one message per 250 ms, the first at once and the last change after the quiet (a trailing timer that exists only while a change waits).
  function viewChanged() {
    if (!viewArmed || viewTimer !== null) return;
    var wait = VIEW_GAP_MS + 1 - (performance.now() - viewLastAt);
    if (wait <= 0) { postView(); return; }
    viewTimer = setTimeout(function () { viewTimer = null; postView(); }, wait);
  }

  function pointAt(row, chars) {
    var walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
    var seen = 0, node;
    while ((node = walker.nextNode())) {
      var length = node.data.length;
      if (chars <= seen + length) return { node: node, offset: chars - seen };
      seen += length;
    }
    return null;
  }

  // The selection comes back as a DOM Range when both entries are still there and both offsets fit their text; else it is dropped.
  function applySelection(bounds) {
    var selection = window.getSelection();
    if (!selection || !Array.isArray(bounds) || bounds.length !== 4 || !bounds.every(Number.isInteger)) return;
    var first = nodes.get(bounds[0]), last = nodes.get(bounds[2]);
    if (!first || !last) return;
    var start = pointAt(first.el, bounds[1]), end = pointAt(last.el, bounds[3]);
    if (!start || !end) return;
    var range = document.createRange();
    range.setStart(start.node, start.offset);
    range.setEnd(end.node, end.offset);
    if (range.collapsed) return;
    selection.removeAllRanges();
    selection.addRange(range);
  }

  // Puts the view back; answers 'found' (the anchor entry is there), 'next' (it is gone: the next entry in order, at its top) or 'none' (pinned).
  function applyView(state, second) {
    var kind = 'none', target = null;
    if (state && Number.isInteger(state.anchor)) {
      // By id, not by page order: the trim notice sits first with the highest id, and a steer's user entry sits last with a low one.
      var rec = nodes.get(state.anchor);
      if (rec) { target = rec.el; kind = 'found'; }
      else {
        var rows = entryRows(), best = Infinity;
        for (var i = 0; i < rows.length; i++) {
          var id = Number(rows[i].getAttribute('data-id'));
          if (id > state.anchor && id < best) { best = id; target = rows[i]; kind = 'next'; }
        }
      }
    }
    if (!state || state.following === true || target === null) {
      isFollowing = true;
      pin();
      updateJump();
    } else {
      isFollowing = false;
      var offset = kind === 'found' && Number.isFinite(state.offset) ? state.offset : 0;
      var top = target.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop + offset;
      var landing = Math.max(0, Math.min(top, maxOffset()));
      if (Math.abs(scroller.scrollTop - landing) > 0.5) { markScroll(landing); scroller.scrollTop = landing; }
      updateJump();
    }
    if (state && state.sel && !(second && currentSelection() !== '')) applySelection(state.sel);
    return kind;
  }

  // The second pass: web fonts that arrive late change the line heights above the anchor, so the restore is applied once more at
  // document.fonts.ready, unless the reader has scrolled since (a reader's move is never undone).
  function secondPass(state) {
    if (restoredState !== state || readerScrolls !== restoredScrolls) return;
    applyView(state, true);
    viewChanged();
  }

  // A mousedown in the page is the reader's too (it may clear the selection), so the second pass leaves the view alone after one.
  document.addEventListener('mousedown', function () { readerScrolls += 1; }, true);

  function restoreView(state) {
    var kind = applyView(state, false);
    restoredState = state || null;
    restoredScrolls = readerScrolls;
    viewArmed = true;
    if (state && document.fonts && document.fonts.ready) document.fonts.ready.then(function () { secondPass(state); });
    viewChanged();
    return kind;
  }

  // ---- the bridge: apply({order?, upserts, turn?}) and reset({entries, turn}) -------------------------------------------------------
  function applyChange(message) {
    var upserts = Array.isArray(message.upserts) ? message.upserts : [];
    upserts.forEach(function (entry) {
      var rec = nodes.get(entry.id);
      if (rec && rec.kind !== entry.kind) { drop(rec); rec = undefined; }
      if (!rec) {
        rec = build(entry);
        nodes.set(entry.id, rec);
        column.insertBefore(rec.el, tail);
      }
      updateEntry(rec, entry);
    });
    if (Array.isArray(message.order)) {
      var present = new Set(message.order);
      Array.from(nodes.values()).forEach(function (rec) { if (!present.has(rec.id)) drop(rec); });
      message.order.forEach(function (id, index) {
        var rec = nodes.get(id);
        if (!rec) return;
        var current = column.children[index];
        if (current !== rec.el) column.insertBefore(rec.el, current);
      });
    }
    if (typeof message.turn === 'string') setTurn(message.turn);
  }

  function apply(message) {
    following(function () { applyChange(message); });
    return true;
  }

  function reset(snapshot) {
    var entries = Array.isArray(snapshot.entries) ? snapshot.entries : [];
    following(function () {
      Array.from(nodes.values()).forEach(drop);
      applyChange({ order: entries.map(function (entry) { return entry.id; }), upserts: entries, turn: snapshot.turn || 'none' });
    });
    return true;
  }

  // ---- links (Q5): Orca's link popover (LA/LinkActionPopover.tsx, NC/native-chat-web-link-actions.ts:38-82) ---------------------------------
  // A plain primary click on an http(s) link opens a popover drawn in the page; Cmd-click (with or without Shift) asks Swift to open it at once.
  // Swift allows only http(s) up to 2 KiB. mailto: and every other scheme stay inert.
  var layer = null;               // the open popover, or null

  function linkTarget(event) {
    var target = event.target;
    return target && target.closest ? target.closest('a[data-href]') : null;
  }

  function closeLayer() {
    if (layer === null) return false;
    layer.remove();
    layer = null;
    post({ type: 'layer', open: false });
    return true;
  }

  function keyCap(label) { return span('keycap', label); }

  function openLayer(url, anchorX, anchorY) {
    closeLayer();
    var pop = el('div', 'link-popover');
    pop.setAttribute('role', 'dialog');
    var head = el('div', 'lp-head');
    var destination = span('lp-url', url);
    destination.title = url;
    var copyLink = el('button', 'copy-btn lp-copy');
    copyLink.type = 'button';
    copyLink.setAttribute('aria-label', 'Copy link');
    copyLink.title = 'Copy link';
    copyLink.appendChild(icon('copy'));
    copyLink.addEventListener('click', function () { post({ type: 'copy-link', url: url }); });
    head.appendChild(destination); head.appendChild(copyLink);
    var row = el('button', 'lp-row');
    row.type = 'button';
    row.appendChild(icon('externalLink'));
    var label = span('lp-label', 'System Browser');
    label.title = 'System Browser';
    var keys = span('lp-keys');
    keys.appendChild(keyCap('\u2318')); keys.appendChild(keyCap('Click'));
    row.appendChild(label); row.appendChild(keys);
    row.addEventListener('click', function () {
      closeLayer();
      post({ type: 'open', url: url });
    });
    pop.appendChild(head); pop.appendChild(row);
    pop.style.maxWidth = Math.max(0, Math.min(336, document.documentElement.clientWidth - 16)) + 'px';
    document.body.appendChild(pop);
    // Above the anchor, start-aligned, 6 pt away, kept 8 pt inside the viewport; below it when there is no room above.
    var width = pop.offsetWidth, height = pop.offsetHeight;
    var viewW = document.documentElement.clientWidth, viewH = document.documentElement.clientHeight;
    var top = anchorY - 6 - height;
    if (top < 8) top = anchorY + 6;
    top = Math.max(8, Math.min(top, viewH - 8 - height));
    var left = Math.max(8, Math.min(anchorX, viewW - 8 - width));
    pop.style.left = left + 'px';
    pop.style.top = top + 'px';
    layer = pop;
    post({ type: 'layer', open: true });
  }

  document.addEventListener('click', function (event) {
    var link = linkTarget(event);
    if (!link) return;
    event.preventDefault();
    var url = link.getAttribute('data-href') || '';
    if (event.button !== 0 || event.altKey) return;
    if (event.metaKey) { post({ type: 'open', url: url }); return; }
    if (event.shiftKey || event.ctrlKey || !/^https?:/i.test(url)) return;
    // A keyboard activation (detail 0) anchors at the link's bottom left, as Orca does.
    var rect = event.detail === 0 ? link.getBoundingClientRect() : null;
    openLayer(url, rect ? rect.left : event.clientX, rect ? rect.bottom : event.clientY);
  }, true);
  document.addEventListener('auxclick', function (event) { if (linkTarget(event)) event.preventDefault(); }, true);

  // A press anywhere in the page outside the popover closes it (the press itself goes on).
  document.addEventListener('mousedown', function (event) {
    if (layer !== null && !layer.contains(event.target)) closeLayer();
  }, true);

  // Swift's Esc and its presses outside the web view: closes the popover, and says whether there was one.
  function dismissLayer() { return closeLayer(); }

  // The popover's copy button worked: its icon is a check for 1500 ms.
  function linkCopied() {
    if (layer === null) return true;
    var button = layer.querySelector('.lp-copy');
    if (button) flash(button, 'copy', 'Copy link', 'Copied');
    return true;
  }

  // ---- the context menu's Copy (Orca use-native-chat-context-menu.tsx:124-138, NativeChatResolvedView.tsx:327-332) ---------------------------
  // `lastSelected` is the last non-empty selection inside the transcript and is never cleared. A context mouse-down (right button, or control with the left), in the capture phase, stores
  // the selection at that moment (WebKit may select the word under a context click before the menu opens) and stops the event. Swift hears only a
  // Boolean `has` (whether a Copy has text), never the text; the text is asked for when Copy is chosen.
  var lastSelected = '';
  var pressSelected = '';
  var reportedHas = false;

  function currentSelection() {
    var selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return '';
    var range = selection.getRangeAt(0);
    if (!scroller.contains(range.commonAncestorContainer)) return '';
    return selection.toString();
  }

  function menuCopyText() { return pressSelected || currentSelection() || lastSelected; }

  function reportSelection() {
    var has = menuCopyText().trim().length > 0;
    if (has === reportedHas) return;
    reportedHas = has;
    post({ type: 'selection', has: has });
  }

  document.addEventListener('selectionchange', function () {
    var current = currentSelection();
    if (current.trim().length > 0) lastSelected = current;
    reportSelection();
    viewChanged();
  });
  document.addEventListener('mousedown', function (event) {
    // A context click is a right button or a control-click (which opens WebKit's menu too); any other press ends the stored selection.
    if (!(event.button === 2 || (event.button === 0 && event.ctrlKey))) { pressSelected = ''; reportSelection(); return; }
    pressSelected = currentSelection();
    event.preventDefault();
    event.stopPropagation();
    reportSelection();
  }, true);

  window.ClawdChat = { apply: apply, reset: reset, markdownHtml: markdownHtml, renderHtml: renderHtml, menuCopyText: menuCopyText, copied: copied,
                       codeText: codeText, codeCopied: codeCopied, linkCopied: linkCopied, dismissLayer: dismissLayer, restoreView: restoreView };
  pin();
  post({ type: 'ready' });
})();
