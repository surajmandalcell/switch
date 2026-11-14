.pragma library

// Demo data for --demo and the captures: the Mac reference set (ConversationsCheck.swift:107-191), 1,098
// threads and a 530-message thread with a Markdown prompt, plus a richer response, a long tool output, and
// a long title. Answers history.list and history.detail with the helper's wire shapes.

var PROMPT = [
  "# Goal",
  "",
  "Keep the desktop reader clear and compact. Preserve every conversation and verify the working app.",
  "",
  "## Repository",
  "",
  "`/Projects/Reader`",
  "",
  "The source and the installed app use the same revision.",
  "",
  "## Inputs",
  "",
  "Input | Location",
  "--- | ---",
  "Source folder | `/Projects/Reader/source/`",
  "Work folder | `/Projects/Reader/build/` (tools, packages, and test output)",
  "Environment | Swift, the macOS SDK, and the existing build cache",
  "Fixtures | Synthetic conversations with no account credentials",
  "Version | Current source revision",
  "",
  "## Rules",
  "",
  "- Keep the window, sidebar, and toolbar in their current positions.",
  "- Preserve both search fields, the filters, and the reading place.",
  "- Verify the reader in Light and Dark appearance.",
  "",
  "## Steps",
  "",
  "1. Inspect the current reader, then compare the measured body frames with the reference.",
  "2. Run the native checks with synthetic conversations.",
  "",
  "```swift",
  "let reader = HistoryPage(model: model)",
  "let messages = conversation.messages",
  "```"
].join("\n")

var RICH = [
  "The reader now keeps its place. Three changes:",
  "",
  "- The thread list loads **100 rows** at a time and grows near the end.",
  "- Each search waits *120 ms* and drops a stale result.",
  "- A long path such as `/Projects/Reader/build/intermediates/very/deep/folder/structure/that/never/ends/output.log` wraps.",
  "",
  "> The transcript files stay as they are. The reader never writes to them.",
  "",
  "Key | Value",
  "--- | ---",
  "Rows built | 100, then +100",
  "Search delay | 120 ms",
  "",
  "See [the port spec](https://example.com/history) for the rest.",
  "",
  "Check | Result | Note",
  "--- | --- | ---",
  "Rows | 44 pt | Every source and model length",
  "Wheel | Pass | Pixel and line steps scroll the chat and the list from every point",
  "Path | Wraps | `/Projects/Reader/build/intermediates/very/deep/folder/output.log`",
  "",
  "مرحبا، هذه رسالة من اليمين إلى اليسار. שלום, זו הודעה מימין לשמאל.",
  "",
  "```js",
  "function unit(width) { return Math.max(0, width - 48) / 548 }",
  "```"
].join("\n")

var TITLES = ["# Goal: finish the desktop reader and verify its history", "Review the conversation search",
  "Check the message sections and input table", "Keep the reader's scroll position", "Verify the native controls"]

var threads = []
var messages = {}

function build() {
  if (threads.length) return
  var now = Date.now()
  var first = []
  for (var i = 0; i < 530; ++i) {
    var role, text
    if (i === 0) { role = "user"; text = PROMPT }
    else if (i === 1) { role = "assistant"; text = RICH }
    else if (i === 3) {
      role = "tool"
      var out = ["Shell command", "swift test --filter ConversationsCheck"]
      for (var k = 0; k < 720; ++k) out.push("[" + (k + 1) + "/720] Test Case 'ConversationsCheck.check" + k + "' passed (0." + (k % 9) + "12 seconds)")
      text = out.join("\n")
    }
    else if (i % 3 === 0) { role = "tool"; text = "Check " + i + ": passed" }
    else if (i === 2) { role = "other"; text = "Planning the reader checks: list, detail, search, and scroll restore." }
    else { role = "assistant"; text = "Response " + i + ": the content stays readable." }
    first.push({ id: "reference-0#" + i, role: role, text: text, timestamp: new Date(now + (i - 530) * 10000).toISOString(),
                 model: i === 0 ? null : "gpt-6.1-sol" })
  }
  for (var t = 0; t < 1098; ++t) {
    var id = "reference-" + t
    var title = t === 2 ? "Explain why the very long conversation title in this row keeps one line and ends with an ellipsis when the card is narrow"
                        : TITLES[t % TITLES.length]
    threads.push({ id: id, threadID: id, title: title, preview: "A synthetic conversation for the History reader.",
                   workingDirectory: "/Projects/Reader", updatedAt: new Date(now - t * 180000).toISOString(),
                   archived: t === 5, messageCount: t === 0 ? first.length : 2, fileByteCount: t === 0 ? PROMPT.length : 200,
                   source: "/Synthetic/" + id + ".jsonl", totalTokens: t === 0 ? 59000000 : 1200,
                   appSource: t === 0 ? "exec" : (t === 4 ? "vscode" : "subagent"),
                   model: t === 2 ? "gpt-6.1-sol-extended-context-preview-2026-11" : (t % 3 === 0 ? "gpt-6.1-sol" : "gpt-6-luna") })
    messages[id] = t === 0 ? first : [
      { id: id + "#0", role: "user", text: "Review this conversation.", timestamp: new Date(now).toISOString(), model: null },
      { id: id + "#1", role: "assistant", text: "The conversation is ready.", timestamp: new Date(now).toISOString(), model: "gpt-6-luna" }]
  }
}

function terms(q) { return q.toLowerCase().split(/\s+/).filter(function (s) { return s !== "" }) }
function matches(text, ts) { var l = text.toLowerCase(); for (var k = 0; k < ts.length; ++k) if (l.indexOf(ts[k]) < 0) return false; return true }

function list(p) {
  build()
  var ts = terms(p.query || "")
  var hit = threads.filter(function (t) { return matches(t.title + "\n" + t.preview + "\n" + t.workingDirectory + "\n" + t.threadID, ts) })
  return { threads: hit.slice(0, p.limit || 100), total: threads.length, matching: hit.length, skippedFiles: 2, unreadableRecords: 1 }
}

// the helper's `roles` mask (rpc.md history.detail): 1 prompts, 2 responses, 4 tools, 8 other
var BIT = { user: 1, assistant: 2, tool: 4, other: 8 }
function detail(p) {
  build()
  var thread = null
  for (var k = 0; k < threads.length; ++k) if (threads[k].id === p.id) thread = threads[k]
  if (!thread) return null
  var mask = p.roles || 15, ts = terms(p.query || "")
  var hit = messages[p.id].filter(function (m) { return (mask & BIT[m.role]) && matches(m.text, ts) })
  var off = p.offset || 0, lim = p.limit || 100
  return { thread: thread, messages: hit.slice(off, off + lim), omitted: 0, matching: hit.length,
           nextOffset: off + lim < hit.length ? off + lim : null }
}
