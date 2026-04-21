"use strict";

(function () {
  const md = window.markdownit({
    html: true,
    linkify: true,
    typographer: true,
    breaks: false,
    highlight: function (str, lang) {
      if (window.hljs && lang && window.hljs.getLanguage(lang)) {
        try {
          return window.hljs.highlight(str, { language: lang, ignoreIllegals: true }).value;
        } catch (_) {}
      }
      if (window.hljs) {
        try { return window.hljs.highlightAuto(str).value; } catch (_) {}
      }
      return "";
    }
  });
  if (window.markdownitTaskLists) md.use(window.markdownitTaskLists, { enabled: true, label: true });
  if (window.markdownitFootnote) md.use(window.markdownitFootnote);
  if (window.markdownItAnchor) md.use(window.markdownItAnchor, { permalink: false });

  const doc = document.getElementById("doc");

  // -------- State --------
  let annotations = [];
  let currentMarkSets = new Map();
  let renderedHTML = "";

  // -------- Swift <-> JS bridge --------
  function postToSwift(channel, payload) {
    try {
      window.webkit.messageHandlers[channel].postMessage(payload);
    } catch (_) {}
  }

  window.mindleLoad = function (markdown) {
    renderedHTML = md.render(markdown || "");
    doc.innerHTML = renderedHTML;
    applyAnnotations();
  };

  window.mindleSetTheme = function (theme) {
    document.body.dataset.theme = theme;
  };

  window.mindleSetFontScale = function (scale) {
    document.documentElement.style.fontSize = (18 * scale) + "px";
  };

  window.mindleSetAnnotations = function (list) {
    annotations = list || [];
    applyAnnotations();
  };

  window.mindleFocusAnnotation = function (id) {
    document.querySelectorAll("mark.mindle-hl.focused").forEach(m => m.classList.remove("focused"));
    const marks = currentMarkSets.get(id);
    if (marks && marks.length) {
      marks.forEach(m => m.classList.add("focused"));
      marks[0].scrollIntoView({ behavior: "smooth", block: "center" });
    }
  };

  window.mindleGetSelection = function () {
    return captureSelection();
  };

  // -------- Selection capture --------

  /**
   * Build the same flat text that buildTextMap produces, so we can
   * locate the selection within it and compute prefix/suffix.
   */
  function getDocFlatText() {
    const map = buildTextMap(doc);
    return map.fullText;
  }

  /**
   * Get the flat-text representation of the current DOM selection by walking
   * the selected range's text nodes (matches how buildTextMap concatenates).
   */
  function getSelectionAsFlatText(range) {
    const walker = document.createTreeWalker(doc, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (range.intersectsNode(node)) return NodeFilter.FILTER_ACCEPT;
        return NodeFilter.FILTER_REJECT;
      }
    });
    let result = "";
    while (walker.nextNode()) {
      const n = walker.currentNode;
      const val = n.nodeValue;
      if (!val) continue;
      // Determine overlap with the range
      let start = 0, end = val.length;
      if (n === range.startContainer) start = range.startOffset;
      if (n === range.endContainer) end = range.endOffset;
      result += val.substring(start, end);
    }
    return result;
  }

  function captureSelection() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
    const range = sel.getRangeAt(0);
    if (!doc.contains(range.commonAncestorContainer)) return null;

    // Get the flat-text version of the selection (same space as buildTextMap)
    const flatSel = getSelectionAsFlatText(range);
    if (!flatSel || !flatSel.trim()) return null;

    // Find it in the full flat text for prefix/suffix context
    const fullFlat = getDocFlatText();
    let prefix = "", suffix = "";
    const idx = fullFlat.indexOf(flatSel);
    if (idx >= 0) {
      prefix = fullFlat.substring(Math.max(0, idx - 48), idx);
      suffix = fullFlat.substring(idx + flatSel.length, idx + flatSel.length + 48);
    }
    return { text: flatSel, prefix: prefix, suffix: suffix };
  }

  // Debounce selection reports so dragging doesn't trigger a storm of messages
  let selTimer = null;
  document.addEventListener("selectionchange", () => {
    if (selTimer) clearTimeout(selTimer);
    selTimer = setTimeout(() => {
      selTimer = null;
      const cap = captureSelection();
      postToSwift("selectionChanged", cap || { text: "", prefix: "", suffix: "" });
    }, 150);
  });

  doc.addEventListener("click", (ev) => {
    const m = ev.target.closest("mark.mindle-hl");
    if (!m) return;
    const id = m.dataset.annId;
    if (!id) return;
    postToSwift("annotationClicked", { id: id });
  });

  // -------- Apply annotations (non-destructive) --------
  function applyAnnotations() {
    doc.innerHTML = renderedHTML;
    currentMarkSets.clear();
    if (!annotations.length) return;

    // Build text map ONCE from clean DOM, apply all annotations
    const textMap = buildTextMap(doc);

    for (const ann of annotations) {
      try {
        const marks = highlightInTextMap(textMap, ann);
        if (marks.length) {
          currentMarkSets.set(ann.id, marks);
        }
      } catch (_) {}
    }
  }

  /**
   * Collect all text nodes under `root` into a flat string with node references.
   */
  function buildTextMap(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    const chunks = [];
    let offset = 0;
    while (walker.nextNode()) {
      const n = walker.currentNode;
      const len = n.nodeValue.length;
      chunks.push({ node: n, start: offset, length: len });
      offset += len;
    }
    return { chunks, fullText: chunks.map(c => c.node.nodeValue).join("") };
  }

  /**
   * Find `ann.text` in the flat text (best match via prefix/suffix scoring),
   * then wrap the matching portions of individual text nodes in <mark> elements.
   * Never extracts or moves DOM nodes — only splits text nodes and wraps in place.
   */
  function highlightInTextMap(textMap, ann) {
    const { chunks, fullText } = textMap;
    if (!ann.text) return [];

    const text = ann.text;
    const prefix = ann.prefix || "";
    const suffix = ann.suffix || "";

    let best = -1, bestScore = -1;
    let idx = fullText.indexOf(text, 0);
    while (idx !== -1) {
      let score = 0;
      const prefLen = Math.min(prefix.length, idx);
      if (prefLen > 0) {
        const a = fullText.substring(idx - prefLen, idx);
        const b = prefix.substring(prefix.length - prefLen);
        score += suffixMatch(a, b);
      }
      const aft = fullText.substring(idx + text.length, idx + text.length + suffix.length);
      score += prefixMatch(aft, suffix);

      if (score > bestScore) {
        bestScore = score;
        best = idx;
      }
      idx = fullText.indexOf(text, idx + 1);
    }

    if (best < 0) return [];
    const rangeStart = best;
    const rangeEnd = best + text.length;

    const segments = [];
    for (const chunk of chunks) {
      const cStart = chunk.start;
      const cEnd = cStart + chunk.length;
      if (cEnd <= rangeStart) continue;
      if (cStart >= rangeEnd) break;
      const oStart = Math.max(rangeStart, cStart) - cStart;
      const oEnd = Math.min(rangeEnd, cEnd) - cStart;
      segments.push({ node: chunk.node, oStart, oEnd });
    }

    const marks = [];
    for (let i = segments.length - 1; i >= 0; i--) {
      const seg = segments[i];
      const textNode = seg.node;
      const parent = textNode.parentNode;
      if (!parent) continue;

      const fullVal = textNode.nodeValue;
      const before = fullVal.substring(0, seg.oStart);
      const highlighted = fullVal.substring(seg.oStart, seg.oEnd);
      const after = fullVal.substring(seg.oEnd);

      // Skip whitespace-only segments between block elements — avoids yellow bars in gaps
      if (!highlighted.trim()) continue;

      const mark = document.createElement("mark");
      mark.className = "mindle-hl";
      mark.dataset.annId = ann.id;
      mark.classList.toggle("has-note", !!(ann.note && ann.note.length));
      mark.textContent = highlighted;

      if (after) {
        parent.insertBefore(document.createTextNode(after), textNode.nextSibling);
      }
      parent.insertBefore(mark, textNode.nextSibling);
      if (before) {
        textNode.nodeValue = before;
      } else {
        parent.removeChild(textNode);
      }

      marks.unshift(mark);
    }

    return marks;
  }

  function prefixMatch(a, b) {
    const n = Math.min(a.length, b.length);
    let i = 0;
    while (i < n && a.charCodeAt(i) === b.charCodeAt(i)) i++;
    return i;
  }
  function suffixMatch(a, b) {
    const n = Math.min(a.length, b.length);
    let i = 0;
    while (i < n && a.charCodeAt(a.length - 1 - i) === b.charCodeAt(b.length - 1 - i)) i++;
    return i;
  }
})();
