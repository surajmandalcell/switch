.pragma library

// Vector redraws of the SF Symbols the slice uses, in a 16 x 16 box.
// A layer is { d: svg path, f: true for fill, w: stroke width, c: fixed color (else the icon color) }.

function circle(cx, cy, r) {
  return "M" + (cx - r) + " " + cy + "a" + r + " " + r + " 0 1 0 " + (2 * r) + " 0a" + r + " " + r + " 0 1 0 " + (-2 * r) + " 0Z"
}

function gear(cx, cy, ro, ri, n) {
  var pts = [], step = 2 * Math.PI / n
  for (var i = 0; i < n; ++i) {
    var a = i * step - Math.PI / 2
    var m = [[-0.23, ri], [-0.15, ro], [0.15, ro], [0.23, ri]]
    for (var j = 0; j < m.length; ++j)
      pts.push([cx + m[j][1] * Math.cos(a + m[j][0]), cy + m[j][1] * Math.sin(a + m[j][0])])
  }
  var d = ""
  for (var k = 0; k < pts.length; ++k) d += (k ? "L" : "M") + pts[k][0].toFixed(2) + " " + pts[k][1].toFixed(2)
  return d + "Z"
}

var icons = {
  "plus":     [{ d: "M8 3.2v9.6M3.2 8h9.6", w: 1.5 }],
  "ellipsis": [{ d: circle(3.4, 8, 1.2) + circle(8, 8, 1.2) + circle(12.6, 8, 1.2), f: true }],
  "search":   [{ d: circle(7, 7, 4.4) + "M10.3 10.3L13.7 13.7", w: 1.5 }],
  "chevronUD": [{ d: "M5 6.3L8 3.4l3 2.9M5 9.7l3 2.9 3-2.9", w: 1.5 }],
  "check":    [{ d: "M3.4 8.6L6.6 11.8 12.7 4.4", w: 1.7 }],
  "refresh":  [{ d: "M12.8 8A4.8 4.8 0 1 1 11.4 4.6M9 4.4L11.4 4.6 11.2 2.2", w: 1.4 }],
  "power":    [{ d: "M5.1 4.5A4.7 4.7 0 1 0 10.9 4.5M8 2v5", w: 1.4 }],
  "gear":     [{ d: gear(8, 8, 6.9, 5.4, 8), w: 1.2 }, { d: circle(8, 8, 2.1), w: 1.2 }],
  "eye":      [{ d: "M1.6 8C3 5.3 5.3 3.9 8 3.9s5 1.4 6.4 4.1C13 10.7 10.7 12.1 8 12.1S3 10.7 1.6 8Z", w: 1.2 }, { d: circle(8, 8, 2), w: 1.2 }],
  "eyeSlash": [{ d: "M1.6 8C3 5.3 5.3 3.9 8 3.9s5 1.4 6.4 4.1C13 10.7 10.7 12.1 8 12.1S3 10.7 1.6 8Z", w: 1.2 }, { d: circle(8, 8, 2), w: 1.2 }, { d: "M2.6 13.4L13.4 2.6", w: 1.3 }],
  "warnFill": [{ d: "M8 1.9L14.9 13.6H1.1Z", f: true }, { d: "M8 6.2v3.3", w: 1.5, c: "#B0000000" }, { d: circle(8, 11.5, 0.85), f: true, c: "#B0000000" }],
  "xmark":    [{ d: "M4 4L12 12M12 4L4 12", w: 1.5 }],
  "minus":    [{ d: "M3.5 8h9", w: 1.6 }],
  // the x is a hole (odd-even fill), as in xmark.circle.fill
  "xmarkCircle": [{ d: circle(8, 8, 6.4) + "M9.66 5.28L10.72 6.34 9.06 8 10.72 9.66 9.66 10.72 8 9.06 6.34 10.72 5.28 9.66 6.94 8 5.28 6.34 6.34 5.28 8 6.94Z", f: true }],
  "folder":   [{ d: "M1.8 4.2q0-1 1-1h3.4l1.4 1.5h5.6q1 0 1 1v6.9q0 1-1 1H2.8q-1 0-1-1Z", w: 1.3 }],
  "copy":     [{ d: "M5.5 5.5h7v8h-7zM3.5 10.5v-8h7", w: 1.3 }],

  "house":    [{ d: "M8 1.7L1.4 7.2l.9 1.1.9-.7v5.8q0 .9.9.9h2.5V10h2.8v4.3h2.5q.9 0 .9-.9V7.6l.9.7.9-1.1z", f: true }],
  "people":   [{ d: circle(6, 5.2, 2.6) + "M1.1 13.7c0-2.8 1.9-4.1 4.9-4.1s4.9 1.3 4.9 4.1q0 .6-.6.6H1.7q-.6 0-.6-.6z", f: true },
               { d: "M11.1 3.3a2.2 2.2 0 1 1-.9 4.2 3.5 3.5 0 0 0 .9-4.2zM11.6 9.7c2.2.1 3.4 1.3 3.4 3.5q0 .5-.5.5h-2.6c.1-1.5-.1-2.8-.9-4z", f: true }],
  "gearFill": [{ d: gear(8, 8, 6.1, 4.8, 8) + circle(8, 8, 2.1), f: true }],
  "tools":    [{ d: "M3.1 12.9L8.6 7.4", w: 2.5 }, { d: circle(10.6, 5.4, 2.7), w: 2.1 }, { d: "M12.9 12.9L9.5 9.5", w: 1.7 }, { d: "M6.3 6.3L3.9 3.9", w: 1.7 }],
  "history":  [{ d: "M8 1.8c-3.6 0-6.5 2.3-6.5 5.4 0 1.5.7 2.8 1.8 3.8-.1.9-.5 1.6-1.1 2.2 1.2 0 2.2-.4 3-1 .9.3 1.7.4 2.8.4 3.6 0 6.5-2.4 6.5-5.4S11.6 1.8 8 1.8z"
                 + circle(5, 7.2, 0.95) + circle(8, 7.2, 0.95) + circle(11, 7.2, 0.95), f: true }],

  // traffic light glyphs (hover)
  "tlClose": [{ d: "M4.2 4.2L9.8 9.8M9.8 4.2L4.2 9.8", w: 1.3 }],
  "tlMin":   [{ d: "M3.6 7h6.8", w: 1.4 }],
  "tlZoom":  [{ d: "M4.2 4.2h4.4L4.2 8.6zM9.8 9.8H5.4L9.8 5.4z", f: true }],

  // provider marks (stand-ins for the brand artwork)
  "markClaude": [{ d: "M8 1.8v12.4M2.6 4.9l10.8 6.2M2.6 11.1l10.8-6.2", w: 2.1 }],
  "markCodex":  [{ d: "M8 2.4l5 2.9v5.4L8 13.6l-5-2.9V5.3z", w: 1.5 }, { d: "M8 5.4v5.2M3.4 8h9.2", w: 1.3 }],
  "markDroid":  [{ d: "M8 2.4v11.2M3.2 5.2l9.6 5.6M3.2 10.8l9.6-5.6", w: 1.7 }, { d: circle(8, 8, 2), f: true }]
}
