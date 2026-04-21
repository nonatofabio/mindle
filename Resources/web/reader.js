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

  // Allow file: URLs (we rewrite them to our custom scheme) and preserve data:
  // URLs intact so base64 payloads aren't percent-encoded to death. Still block
  // javascript:/vbscript: for general link safety.
  md.validateLink = function (url) {
    const lower = String(url).toLowerCase();
    if (/^(javascript|vbscript):/.test(lower)) return false;
    if (/^data:/.test(lower) && !/^data:image\/(gif|png|jpeg|webp|svg\+xml);/.test(lower)) return false;
    return true;
  };
  const _origNormalizeLink = md.normalizeLink;
  md.normalizeLink = function (url) {
    if (/^(data|file):/i.test(url)) return url;
    return _origNormalizeLink.call(md, url);
  };

  const doc = document.getElementById("doc");

  // -------- State --------
  let annotations = [];
  let currentMarkSets = new Map();
  let renderedHTML = "";
  let searchState = { query: "", current: 0, total: 0, matchSets: [] };
  let baseDir = "";   // absolute filesystem path of the current file's parent dir

  // -------- Swift <-> JS bridge --------
  function postToSwift(channel, payload) {
    try {
      window.webkit.messageHandlers[channel].postMessage(payload);
    } catch (_) {}
  }

  function reportSearchResult() {
    postToSwift("searchResult", { total: searchState.total, current: searchState.current });
  }

  window.mindleSetBaseDir = function (dir) {
    baseDir = dir || "";
  };

  window.mindleLoad = function (markdown) {
    renderedHTML = md.render(markdown || "");
    // Switching documents clears search state; annotations are replayed below.
    searchState = { query: "", current: 0, total: 0, matchSets: [] };
    applyAll();
    reportSearchResult();
  };

  window.mindleSetTheme = function (theme) {
    document.documentElement.dataset.theme = theme;
  };

  window.mindleSetFontScale = function (scale) {
    document.documentElement.style.fontSize = (18 * scale) + "px";
  };

  window.mindleSetAnnotations = function (list) {
    annotations = list || [];
    applyAll();
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

  window.mindleSearch = function (query) {
    searchState.query = query || "";
    searchState.current = 0;
    applyAll();
    if (searchState.total > 0) {
      searchState.current = 1;
      applyCurrentMatchClass();
      scrollCurrentMatch();
    }
    reportSearchResult();
  };

  window.mindleSearchNext = function () {
    if (searchState.total === 0) return;
    searchState.current = (searchState.current % searchState.total) + 1;
    applyCurrentMatchClass();
    scrollCurrentMatch();
    reportSearchResult();
  };

  window.mindleSearchPrev = function () {
    if (searchState.total === 0) return;
    searchState.current = ((searchState.current - 2 + searchState.total) % searchState.total) + 1;
    applyCurrentMatchClass();
    scrollCurrentMatch();
    reportSearchResult();
  };

  // -------- Selection capture --------

  function getDocFlatText() {
    const map = buildTextMap(doc);
    return map.fullText;
  }

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

    const flatSel = getSelectionAsFlatText(range);
    if (!flatSel || !flatSel.trim()) return null;

    const fullFlat = getDocFlatText();
    let prefix = "", suffix = "";
    const idx = fullFlat.indexOf(flatSel);
    if (idx >= 0) {
      prefix = fullFlat.substring(Math.max(0, idx - 48), idx);
      suffix = fullFlat.substring(idx + flatSel.length, idx + flatSel.length + 48);
    }
    return { text: flatSel, prefix: prefix, suffix: suffix };
  }

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

  // -------- Unified render pipeline: annotations + search --------

  function applyAll() {
    doc.innerHTML = renderedHTML;
    rewriteImages();
    currentMarkSets.clear();
    searchState.matchSets = [];
    searchState.total = 0;

    if (annotations.length) {
      const annoMap = buildTextMap(doc);
      for (const ann of annotations) {
        try {
          const marks = highlightInTextMap(annoMap, ann);
          if (marks.length) currentMarkSets.set(ann.id, marks);
        } catch (_) {}
      }
    }

    applySearchMarks();
  }

  // -------- Images: rewrite src, block remote, handle broken --------

  function rewriteImages() {
    const imgs = doc.querySelectorAll("img");
    imgs.forEach(img => {
      const src = img.getAttribute("src") || "";
      const res = resolveImageSrc(src);
      if (res.blocked) {
        const ph = document.createElement("span");
        ph.className = "mindle-img-blocked";
        ph.textContent = "[remote image hidden — " + (img.alt || src) + "]";
        img.replaceWith(ph);
      } else if (res.url !== null && res.url !== src) {
        img.setAttribute("src", res.url);
        img.addEventListener("error", () => {
          const ph = document.createElement("span");
          ph.className = "mindle-img-missing";
          ph.textContent = "[image not found — " + (img.alt || src) + "]";
          img.replaceWith(ph);
        });
      } else if (res.url !== null) {
        // Left as-is (data: URL etc.) — still add broken-image handler.
        img.addEventListener("error", () => {
          const ph = document.createElement("span");
          ph.className = "mindle-img-missing";
          ph.textContent = "[image not found — " + (img.alt || src) + "]";
          img.replaceWith(ph);
        });
      }
    });
  }

  function resolveImageSrc(src) {
    if (!src) return { url: null };
    if (src.startsWith("data:")) return { url: src };
    if (/^https?:/i.test(src)) return { blocked: true };
    if (/^file:\/\//i.test(src)) {
      const path = src.replace(/^file:\/\//i, "");
      return { url: "mindle-file://" + path };
    }
    if (src.startsWith("/")) {
      return { url: "mindle-file://" + encodeURI(src) };
    }
    if (!baseDir) return { url: src };
    const resolved = resolveRelativePath(baseDir, src);
    return { url: "mindle-file://" + encodeURI(resolved) };
  }

  function resolveRelativePath(base, rel) {
    const baseParts = base.split("/").filter(Boolean);
    const relParts = rel.split("/");
    for (const p of relParts) {
      if (p === "" || p === ".") continue;
      if (p === "..") {
        baseParts.pop();
      } else {
        baseParts.push(p);
      }
    }
    return "/" + baseParts.join("/");
  }

  function applySearchMarks() {
    if (!searchState.query) return;
    const needle = searchState.query.toLowerCase();
    if (!needle) return;

    const textMap = buildTextMap(doc);
    const full = textMap.fullText.toLowerCase();

    const ranges = [];
    let i = full.indexOf(needle, 0);
    while (i !== -1) {
      ranges.push({ start: i, end: i + needle.length });
      i = full.indexOf(needle, i + needle.length);
    }

    const matchSets = new Array(ranges.length);
    // Wrap from the last match backward — earlier ranges' offsets
    // into their text nodes stay valid because we only split at higher positions.
    for (let r = ranges.length - 1; r >= 0; r--) {
      matchSets[r] = wrapSearchRange(textMap.chunks, ranges[r].start, ranges[r].end, r);
    }

    searchState.total = matchSets.length;
    searchState.matchSets = matchSets;
    if (searchState.current > matchSets.length) searchState.current = matchSets.length;
  }

  function wrapSearchRange(chunks, rangeStart, rangeEnd, matchIndex) {
    const segments = [];
    for (const chunk of chunks) {
      const cStart = chunk.start;
      const cEnd = cStart + chunk.length;
      if (cEnd <= rangeStart) continue;
      if (cStart >= rangeEnd) break;
      segments.push({
        node: chunk.node,
        oStart: Math.max(rangeStart, cStart) - cStart,
        oEnd: Math.min(rangeEnd, cEnd) - cStart
      });
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
      if (!highlighted) continue;

      const mark = document.createElement("mark");
      mark.className = "mindle-search";
      mark.dataset.matchIndex = String(matchIndex);
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

  function applyCurrentMatchClass() {
    doc.querySelectorAll("mark.mindle-search.current").forEach(m => m.classList.remove("current"));
    if (searchState.current < 1 || searchState.current > searchState.matchSets.length) return;
    const marks = searchState.matchSets[searchState.current - 1];
    if (marks) marks.forEach(m => m.classList.add("current"));
  }

  function scrollCurrentMatch() {
    if (searchState.current < 1) return;
    const marks = searchState.matchSets[searchState.current - 1];
    if (marks && marks.length) {
      marks[0].scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }

  // -------- Text map + annotation wrapping (shared with search) --------

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
