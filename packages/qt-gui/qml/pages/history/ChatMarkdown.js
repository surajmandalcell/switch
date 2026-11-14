.pragma library

// Port of ChatMessagePresenter (history.md 2.5, ChatMessagePresentation.swift:83-308): message text to
// blocks, blocks to sections, inline Markdown to Qt rich text. Limits and rules match the Mac parser.

var MAX_SOURCE = 120000
var MAX_BLOCKS = 256
var CODE_LINES = 600
var CODE_CHARS = 60000

function trimWs(s) { return s.replace(/^[ \t]+|[ \t]+$/g, "") }
function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;") }

// Returns { blocks, sections, truncated }. Block: { id, type, ... } with inline text already as HTML.
function parse(role, text) {
  var truncated = text.length > MAX_SOURCE
  var source = text.substring(0, MAX_SOURCE).replace(/\r\n/g, "\n")
  var blocks = []
  // Tool output is preformatted: one code block, no Markdown.
  if (role === "tool") {
    var tl = source.split("\n")
    var tc = tl.slice(0, CODE_LINES).join("\n").substring(0, CODE_CHARS)
    blocks.push({ id: 0, type: "code", language: "", preview: tc, expanded: tc.length === source.length ? null : source,
                  srcTrunc: truncated })
    return { blocks: blocks, sections: sections(blocks), truncated: truncated }
  }
  var lines = source.split("\n"), i = 0, bid = 0
  while (i < lines.length && blocks.length < MAX_BLOCKS) {
    var line = lines[i], t = trimWs(line)
    if (t === "") { i++; continue }

    if (t.indexOf("```") === 0) {
      // A longer fence can hold a shorter one ("````markdown" around "```swift").
      var fl = /^`*/.exec(t)[0].length
      var lang = trimWs(t.substring(fl))
      i++
      var code = []
      while (i < lines.length && !closingFence(lines[i], fl)) code.push(lines[i++])
      if (i < lines.length) i++
      var full = code.join("\n")
      var cmp = code.slice(0, CODE_LINES).join("\n").substring(0, CODE_CHARS)
      blocks.push({ id: bid++, type: "code", language: lang, preview: cmp, expanded: cmp.length === full.length ? null : full,
                    srcTrunc: truncated && i >= lines.length })
      continue
    }

    var hdr = i + 1 < lines.length ? tableHeader(line, lines[i + 1]) : null
    if (hdr) {
      i += 2
      var rows = [], cells
      while (i < lines.length && (cells = tableCells(lines[i]))) {
        var r = []
        for (var c = 0; c < hdr.length; ++c) r.push(inline(c < cells.length ? cells[c] : ""))
        rows.push(r)
        i++
      }
      blocks.push({ id: bid++, type: "table", headers: hdr.map(inline), rows: rows })
      continue
    }

    var h = heading(t)
    if (h) { blocks.push({ id: bid++, type: "heading", level: h.level, html: inline(h.text), plain: h.text }); i++; continue }

    if (t === "---" || t === "***" || t === "___") { blocks.push({ id: bid++, type: "divider" }); i++; continue }

    if (t.charAt(0) === ">") {
      var q = []
      while (i < lines.length) {
        var qc = trimWs(lines[i])
        if (qc.charAt(0) !== ">") break
        q.push(trimWs(qc.substring(1)))
        i++
      }
      blocks.push({ id: bid++, type: "quote", html: inline(q.join("\n")) })
      continue
    }

    if (unorderedItem(t) !== null) {
      var ui = [], u
      while (i < lines.length && (u = unorderedItem(trimWs(lines[i]))) !== null) { ui.push(inline(u)); i++ }
      blocks.push({ id: bid++, type: "ul", items: ui })
      continue
    }

    if (orderedItem(t) !== null) {
      var oi = [], o
      while (i < lines.length && (o = orderedItem(trimWs(lines[i]))) !== null) { oi.push(inline(o)); i++ }
      blocks.push({ id: bid++, type: "ol", items: oi })
      continue
    }

    var para = []
    while (i < lines.length) {
      var pc = trimWs(lines[i])
      if (pc === "" || (startsBlock(pc) && para.length > 0)) break
      if (para.length > 0 && i + 1 < lines.length && tableHeader(pc, lines[i + 1])) break
      para.push(lines[i])
      i++
      if (para.length === 1 && startsBlock(pc)) break
    }
    blocks.push({ id: bid++, type: "paragraph", html: inline(para.join("\n")) })
  }
  var hitLimit = blocks.length === MAX_BLOCKS
  if (blocks.length === 0) blocks.push({ id: 0, type: "paragraph", html: esc(source) })
  return { blocks: blocks, sections: sections(blocks), truncated: truncated || hitLimit }
}

function closingFence(line, len) {
  var t = trimWs(line)
  return t.length >= len && /^`*$/.test(t)
}

function tableHeader(line, sep) {
  var headers = tableCells(line), rules = tableCells(sep)
  if (!headers || !rules || headers.length !== rules.length) return null
  for (var k = 0; k < rules.length; ++k) {
    var rule = rules[k].replace(/^:+|:+$/g, "")
    if (rule.length < 3 || !/^-+$/.test(rule)) return null
  }
  return headers
}

function tableCells(line) {
  var text = trimWs(line)
  if (text.indexOf("|") < 0) return null
  var cells = [], cell = "", escaped = false, codeTicks = 0, pending = 0
  for (var k = 0; k < text.length; ++k) {
    var ch = text.charAt(k)
    if (escaped) {
      if (ch !== "|" && ch !== "\\") cell += "\\"
      cell += ch
      escaped = false
    } else if (ch === "`") {
      pending++
      cell += ch
    } else {
      if (pending > 0) {
        if (codeTicks === 0) codeTicks = pending
        else if (codeTicks === pending) codeTicks = 0
        pending = 0
      }
      if (ch === "\\") escaped = true
      else if (ch === "|" && codeTicks === 0) { cells.push(trimWs(cell)); cell = "" }
      else cell += ch
    }
  }
  if (escaped) cell += "\\"
  cells.push(trimWs(cell))
  if (text.charAt(0) === "|") cells.shift()
  if (text.charAt(text.length - 1) === "|" && cells[cells.length - 1] === "") cells.pop()
  return cells.length ? cells : null
}

function heading(line) {
  var level = /^#*/.exec(line)[0].length
  if (level < 1 || level > 3 || line.charAt(level) !== " ") return null
  return { level: level, text: line.substring(level + 1) }
}

function unorderedItem(line) {
  if (line.length <= 2) return null
  var p = line.substring(0, 2)
  return p === "- " || p === "* " || p === "+ " ? line.substring(2) : null
}

function orderedItem(line) {
  var d = line.indexOf(".")
  if (d <= 0 || d + 1 >= line.length || line.charAt(d + 1) !== " " || !/^\d+$/.test(line.substring(0, d))) return null
  return line.substring(d + 2)
}

function startsBlock(line) {
  return line.indexOf("```") === 0 || line.charAt(0) === ">" || heading(line) !== null
      || unorderedItem(line) !== null || orderedItem(line) !== null || line === "---" || line === "***" || line === "___"
}

// A section starts at each heading; text before the first heading is a section with no heading.
function sections(blocks) {
  var out = []
  for (var k = 0; k < blocks.length; ++k) {
    var b = blocks[k]
    if (b.type === "heading") out.push({ id: b.id, heading: b, blocks: [] })
    else if (out.length === 0) out.push({ id: b.id, heading: null, blocks: [b] })
    else out[out.length - 1].blocks.push(b)
  }
  for (var s = 0; s < out.length; ++s) {
    out[s].collapsible = !!out[s].heading && out[s].heading.level > 1
    out[s].icon = sectionIcon(out[s])
  }
  return out
}

// history.md 2.2: the heading icon by heading text, else by the blocks the section holds.
function sectionIcon(sec) {
  if (sec.heading) {
    var t = plainText(sec.heading.html).trim().toLowerCase()
    if (t === "goal" || t.indexOf("goal ") === 0 || t.indexOf("goal:") === 0) return "clipboard"
    if (t.indexOf("repository") === 0) return "folder"
    if (t.indexOf("inputs") === 0) return "shippingbox"
    if (t.indexOf("rules") === 0 || t.indexOf("hard rules") === 0) return "warnTriangle"
    if (t.indexOf("steps") === 0) return "listNumber"
  }
  var has = function (type) { for (var k = 0; k < sec.blocks.length; ++k) if (sec.blocks[k].type === type) return true; return false }
  if (has("table")) return "tablecells"
  if (has("ol")) return "listNumber"
  if (has("ul")) return "listBullet"
  return "docText"
}

function plainText(html) {
  return html.replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&amp;/g, "&")
}

// Inline Markdown only (bold, italic, strikethrough, code spans, links; images show their alt text).
// Bare URLs stay text. Whitespace and typed line breaks are kept by the white-space: pre-wrap wrapper.
function inline(text) { return inl(text) }

function isWs(c) { return c === "" || c === undefined || /\s/.test(c) }
function isAlnum(c) { return !!c && /[A-Za-z0-9]/.test(c) }

function inl(s) {
  var out = "", i = 0, n = s.length
  while (i < n) {
    var ch = s.charAt(i)
    if (ch === "\\" && i + 1 < n && /[!-\/:-@\[-`{-~]/.test(s.charAt(i + 1))) { out += esc(s.charAt(i + 1)); i += 2; continue }
    if (ch === "`") {
      var run = /^`+/.exec(s.substring(i))[0].length
      var close = findTicks(s, i + run, run)
      if (close >= 0) {
        var code = s.substring(i + run, close)
        if (code.length > 2 && code.charAt(0) === " " && code.charAt(code.length - 1) === " " && code.trim() !== "") code = code.slice(1, -1)
        out += "<code>" + esc(code) + "</code>"   // ChatText's style sheet sets the family
        i = close + run
        continue
      }
      out += esc(s.substr(i, run)); i += run; continue
    }
    if (ch === "!" && s.charAt(i + 1) === "[") {
      var im = link(s, i + 1)
      if (im) { out += inl(im.text); i = im.end; continue }
    }
    if (ch === "[") {
      var ln = link(s, i)
      if (ln) { out += "<a href=\"" + esc(ln.url) + "\">" + inl(ln.text) + "</a>"; i = ln.end; continue }
    }
    if (ch === "*" || ch === "_" || ch === "~") {
      var em = emphasis(s, i, ch)
      if (em) { out += em.html; i = em.end; continue }
    }
    out += esc(ch)
    i++
  }
  return out
}

function findTicks(s, from, run) {
  var j = from
  while (j < s.length) {
    var k = s.indexOf("`", j)
    if (k < 0) return -1
    var r = /^`+/.exec(s.substring(k))[0].length
    if (r === run) return k
    j = k + r
  }
  return -1
}

function link(s, i) {
  var depth = 0, j = i
  for (; j < s.length; ++j) {
    var c = s.charAt(j)
    if (c === "\\") { j++; continue }
    if (c === "[") depth++
    else if (c === "]" && --depth === 0) break
  }
  if (j >= s.length || s.charAt(j + 1) !== "(") return null
  var p = 0, k = j + 1
  for (; k < s.length; ++k) {
    var d = s.charAt(k)
    if (d === "(") p++
    else if (d === ")" && --p === 0) break
  }
  if (k >= s.length) return null
  var url = s.substring(j + 2, k).trim().replace(/\s+"[^"]*"$/, "").replace(/^<|>$/g, "")
  if (/\s/.test(url)) return null
  return { text: s.substring(i + 1, j), url: url, end: k + 1 }
}

function emphasis(s, i, ch) {
  var run = 0
  while (s.charAt(i + run) === ch) run++
  if (ch === "~" && run > 2) return null
  var size = ch === "~" ? run : Math.min(run, 2)
  var before = s.charAt(i - 1), after = s.charAt(i + size)
  if (isWs(after)) return null
  if (ch === "_" && isAlnum(before)) return null
  var delim = s.substr(i, size)
  var from = i + size + 1
  while (true) {
    var j = s.indexOf(delim, from)
    if (j < 0) return null
    var prevOk = !isWs(s.charAt(j - 1))
    var nextOk = ch !== "_" || !isAlnum(s.charAt(j + size))
    var exact = s.charAt(j + size) !== ch || size === 2 || ch === "~"
    if (prevOk && nextOk && exact) {
      var inner = inl(s.substring(i + size, j))
      var tag = ch === "~" ? "s" : (size === 2 ? "b" : "i")
      return { html: "<" + tag + ">" + inner + "</" + tag + ">", end: j + size }
    }
    from = j + 1
  }
}

// Line count of a code text: line feeds + 1 (ChatCodeBlock.lineCount).
function lineCount(text) { var n = 1; for (var k = 0; k < text.length; ++k) if (text.charCodeAt(k) === 10) n++; return n }

// "59M", "48K", "1.2K" (Foundation compactName, en-US).
function compact(n) {
  var units = ["", "K", "M", "B", "T"], k = 0, v = n
  while (Math.abs(v) >= 1000 && k < units.length - 1) { v /= 1000; k++ }
  if (k === 0) return String(n)
  var s = v < 10 ? (Math.round(v * 10) / 10).toString() : String(Math.round(v))
  return s + units[k]
}

// Copy export (ChatTranscriptExport.text): "[Role | ISO time]\nraw text", joined by a blank line.
var ROLE_NAMES = { "user": "Prompt", "assistant": "Response", "tool": "Tool", "other": "Other" }
function exportText(messages) {
  return messages.map(function (m) {
    var t = m.timestamp ? new Date(m.timestamp).toISOString() : "Unknown time"
    return "[" + ROLE_NAMES[m.role] + " | " + t + "]\n" + m.text
  }).join("\n\n")
}

// Self-check of the parser rules that are easy to break (run by the history capture script).
function selfCheck() {
  var fails = []
  function eq(name, a, b) { if (JSON.stringify(a) !== JSON.stringify(b)) fails.push(name + ": " + JSON.stringify(a) + " != " + JSON.stringify(b)) }
  var p = parse("user", "# Goal\n\nKeep **raw Markdown**.\n\n## Inputs\n\nInput | Location\n--- | ---\nSource | `/a|b`\n\n1. one\n2. two\n\n````md\n```swift\nx\n```\n````\n#### four")
  eq("types", p.blocks.map(function (b) { return b.type }), ["heading", "paragraph", "heading", "table", "ol", "code", "paragraph"])
  eq("sections", p.sections.length, 2)
  eq("collapsible", [p.sections[0].collapsible, p.sections[1].collapsible], [false, true])
  eq("icon", [p.sections[0].icon, p.sections[1].icon], ["clipboard", "shippingbox"])
  eq("nested fence", p.blocks[5].preview, "```swift\nx\n```")
  eq("cells", tableCells("| a \\| b | `c|d` |"), ["a | b", "`c|d`"])
  eq("tool", parse("tool", "# not a heading\n  kept").blocks[0].preview, "# not a heading\n  kept")
  eq("bold", inline("Keep **raw** _it_ ~~s~~ `c` [l](https://x.y) ![alt](i.png) snake_case_name"),
     "Keep <b>raw</b> <i>it</i> <s>s</s> <code>c</code> <a href=\"https://x.y\">l</a> alt snake_case_name")
  var long = []; for (var k = 0; k < 700; ++k) long.push("line " + k)
  var lc = parse("assistant", "```\n" + long.join("\n") + "\n```").blocks[0]
  eq("long code", [lc.preview.split("\n").length, lineCount(lc.expanded)], [600, 700])
  eq("export", exportText([{ role: "user", text: "# Goal\n\nKeep **raw Markdown**.", timestamp: null }]),
     "[Prompt | Unknown time]\n# Goal\n\nKeep **raw Markdown**.")
  eq("compact", [compact(59000000), compact(48000), compact(1200), compact(950)], ["59M", "48K", "1.2K", "950"])
  return fails
}
