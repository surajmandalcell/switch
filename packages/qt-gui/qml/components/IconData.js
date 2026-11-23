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
  // Mac pop-up capture: two 7 x 4 px chevrons, 10 px overall at 12 pt, thin strokes
  "chevronUD": [{ d: "M3.4 6.2L8 1.7l4.6 4.5M3.4 9.8L8 14.3l4.6-4.5", w: 1.3 }],
  "check":    [{ d: "M3.4 8.6L6.6 11.8 12.7 4.4", w: 1.7 }],
  "chevronRight": [{ d: "M6 3.2L10.8 8 6 12.8", w: 1.6 }],
  "refresh":  [{ d: "M12.8 8A4.8 4.8 0 1 1 11.4 4.6M9 4.4L11.4 4.6 11.2 2.2", w: 1.4 }],
  "power":    [{ d: "M5.1 4.5A4.7 4.7 0 1 0 10.9 4.5M8 2v5", w: 1.4 }],
  "gear":     [{ d: gear(8, 8, 6.9, 5.4, 8), w: 1.2 }, { d: circle(8, 8, 2.1), w: 1.2 }],
  "eye":      [{ d: "M1.6 8C3 5.3 5.3 3.9 8 3.9s5 1.4 6.4 4.1C13 10.7 10.7 12.1 8 12.1S3 10.7 1.6 8Z", w: 1.2 }, { d: circle(8, 8, 2), w: 1.2 }],
  "eyeSlash": [{ d: "M1.6 8C3 5.3 5.3 3.9 8 3.9s5 1.4 6.4 4.1C13 10.7 10.7 12.1 8 12.1S3 10.7 1.6 8Z", w: 1.2 }, { d: circle(8, 8, 2), w: 1.2 }, { d: "M2.6 13.4L13.4 2.6", w: 1.3 }],
  "warnFill": [{ d: "M8 1.9L14.9 13.6H1.1Z", f: true }, { d: "M8 6.2v3.3", w: 1.5, c: "#B0000000" }, { d: circle(8, 11.5, 0.85), f: true, c: "#B0000000" }],
  "xmark":    [{ d: "M4 4L12 12M12 4L4 12", w: 1.5 }],
  "minus":    [{ d: "M3.5 8h9", w: 1.6 }],
  // line.3.horizontal.decrease.circle and its .fill (the lines cut out in white)
  "filterCircle":     [{ d: circle(8, 8, 6.4), w: 1.2 }, { d: "M5 6.1h6M6.1 8.1h3.8M7.2 10.1h1.6", w: 1.2 }],
  "filterCircleFill": [{ d: circle(8, 8, 7), f: true }, { d: "M5 6.1h6M6.1 8.1h3.8M7.2 10.1h1.6", w: 1.3, c: "#FFFFFF" }],
  // the x is a hole (odd-even fill), as in xmark.circle.fill
  "xmarkCircle": [{ d: circle(8, 8, 6.4) + "M9.66 5.28L10.72 6.34 9.06 8 10.72 9.66 9.66 10.72 8 9.06 6.34 10.72 5.28 9.66 6.94 8 5.28 6.34 6.34 5.28 8 6.94Z", f: true }],
  "folder":   [{ d: "M1.8 4.2q0-1 1-1h3.4l1.4 1.5h5.6q1 0 1 1v6.9q0 1-1 1H2.8q-1 0-1-1Z", w: 1.3 }],
  "database": [{ d: "M3 4a5 1.8 0 1 0 10 0a5 1.8 0 1 0 -10 0ZM3 4v8a5 1.8 0 0 0 10 0V4M3 8a5 1.8 0 0 0 10 0", w: 1.3 }],
  "copy":     [{ d: "M5.5 5.5h7v8h-7zM3.5 10.5v-8h7", w: 1.3 }],
  "info":     [{ d: circle(8, 8, 6), w: 1.2 }, { d: "M8 7.2v4", w: 1.4 }, { d: circle(8, 5, 0.85), f: true }],
  "grip":     [{ d: "M3 4.5h10M3 8h10M3 11.5h10", w: 1.4 }],
  "play":     [{ d: "M4.6 2.8v10.4q0 .8.7.4l8.2-4.9q.7-.5 0-.9L5.3 2.4q-.7-.4-.7.4z", f: true }],
  "arrowRight": [{ d: "M2.8 8h10M9 4l4 4-4 4", w: 1.5 }],
  "arrowUpRight": [{ d: "M4 12L12 4M6 4h6v6", w: 1.5 }],   // SF arrow.up.right (Settings > About links)
  // SF "play" (outline) and "doc.on.doc" (two dog-eared pages, the back one up and right)
  "playOutline": [{ d: "M4.6 3.1v9.8q0 .7.6.4l7.9-4.6q.6-.4 0-.8L5.2 2.7q-.6-.3-.6.4z", w: 1.2 }],
  "docOnDoc": [{ d: "M6.3 4.5V2.5q0-1 1-1h3.2l2.6 2.6v6q0 1-1 1h-1.3M10.5 1.6v2.6h2.5", w: 1.15 },
               { d: "M3.9 4.5h3.3l2.6 2.6v6.4q0 1-1 1H3.9q-1 0-1-1v-8q0-1 1-1zM7.2 4.6v2.6h2.5", w: 1.15 }],
  "checkCircle": [{ d: circle(8, 8, 6.2), w: 1.3 }, { d: "M5.2 8.2l2 2 3.7-4.3", w: 1.4 }],
  "checkCircleFill": [{ d: circle(8, 8, 6.8), f: true }, { d: "M5.2 8.2l2 2 3.7-4.3", w: 1.6, c: "#FFFFFF" }],

  // Sidebar glyphs: our own drawings, fitted to the Mac 17 pt captures' coverage (shapes, weights, offsets).
  "house":    [{ d: "M1.1 8.6L7.6 3.1 14.1 8.6", w: 1.25 },
               { d: "M11.6 3.6h1.9v3.4h-1.9zM2.4 9.3L7.6 4.9 12.9 9.3v5.2q0 .7-.7.7H3.1q-.7 0-.7-.7zM6.2 10.4h2.7v3.7H6.2z", f: true }],
  "people":   [{ d: circle(3.8, 6.6, 2.2) + "M-0.5 13.6c0-2.2 1.6-3.5 3.9-3.5 1 0 1.9.2 2.6.6-.9.8-1.4 1.9-1.5 3.3H0.1q-.6 0-.6-.4z", f: true },
               { d: circle(10.85, 6.2, 2.7) + "M5.9 13.6c0-2.6 2-4 4.95-4s4.95 1.4 4.95 4q0 .6-.6.6H6.5q-.6 0-.6-.6z", f: true }],
  "gearFill": [{ d: gear(8, 8, 6.1, 4.8, 8) + circle(8, 8, 2.1), f: true }],
  // wrench (open jaw top right, ring bottom left) crossed with a screwdriver (grip top left, tip bottom right)
  "tools":    [{ d: "M2.1 3.2L5.3 6.4", w: 2.8 }, { d: "M6.6 7.7L14.4 14.9", w: 1.5 },
               { d: "M14.79 3.93A2 2 0 1 1 12.97 2.11M11.4 5.5L4.1 12.6", w: 1.6 }, { d: circle(3.1, 13.6, 1.3), w: 1.1 }],
  "history":  [{ d: "M8 3.8c-3.6 0-6.5 2.2-6.5 5.1 0 1.4.7 2.6 1.8 3.5-.1.9-.5 1.5-1.1 2.1 1.2 0 2.2-.4 3-.9.9.3 1.7.4 2.8.4 3.6 0 6.5-2.3 6.5-5.1S11.6 3.8 8 3.8z"
                 + circle(5.2, 9.2, 0.9) + circle(8, 9.2, 0.9) + circle(10.8, 9.2, 0.9), f: true }],

  // Maintenance (maintenance.md 1.4): eraser, archivebox, trash, chevron.left (date picker month)
  "eraser":   [{ d: "M9.6 2.6l3.8 3.8-6.9 6.9H4.1L2.6 11.8q-.7-.7 0-1.4zM6.1 6.1l3.8 3.8M6.5 13.3h7", w: 1.3 }],
  "archivebox": [{ d: "M2.6 3h10.8q.6 0 .6.6v1.8q0 .6-.6.6H2.6q-.6 0-.6-.6V3.6q0-.6.6-.6zM3 6v6.6q0 1 1 1h8q1 0 1-1V6M6.4 8.6h3.2", w: 1.3 }],
  "trash":    [{ d: "M2.5 4h11M6 4V2.8h4V4M3.8 4l.7 9.2q.1.9 1 .9h5q.9 0 1-.9L12.2 4M6.6 6.5v5M9.4 6.5v5", w: 1.3 }],
  "chevronLeft": [{ d: "M10 3.2L5.2 8 10 12.8", w: 1.6 }],

  // History reader (history.md 1.4, 2.2)
  "chevronDown": [{ d: "M3.2 6L8 10.8 12.8 6", w: 1.6 }],
  "curlybraces": [{ d: "M6 2.4q-1.7 0-1.7 1.7v1.9q0 1.3-1.3 2 1.3.7 1.3 2v1.9q0 1.7 1.7 1.7M10 2.4q1.7 0 1.7 1.7v1.9q0 1.3 1.3 2-1.3.7-1.3 2v1.9q0 1.7-1.7 1.7", w: 1.3 }],
  "bubbleRight": [{ d: "M8 2.4c3.4 0 6 2.1 6 4.8 0 1.3-.6 2.5-1.6 3.3.1.9.5 1.6 1.1 2.2-1.2 0-2.2-.4-2.9-1-.8.3-1.7.4-2.6.4-3.4 0-6-2.1-6-4.9S4.6 2.4 8 2.4z", w: 1.3 }],
  "layers3d": [{ d: "M8 2.2l5.8 2.9L8 8 2.2 5.1z", w: 1.2 }, { d: "M2.2 8L8 10.9 13.8 8M2.2 10.9L8 13.8l5.8-2.9", w: 1.2 }],
  "clipboard": [{ d: "M5.6 2.9H4.4q-1 0-1 1v9.3q0 1 1 1h7.2q1 0 1-1V3.9q0-1-1-1h-1.2", w: 1.3 }, { d: "M5.9 1.8h4.2v2.3H5.9z", w: 1.2 }],
  "shippingbox": [{ d: "M8 1.8l5.7 2.7v7L8 14.2l-5.7-2.7v-7z", w: 1.2 }, { d: "M2.3 4.5L8 7.2l5.7-2.7M8 7.2v7M5.1 3.1l5.7 2.8", w: 1.1 }],
  "warnTriangle": [{ d: "M8 2.2L14.3 13.4H1.7Z", w: 1.3 }, { d: "M8 6.3v3.4", w: 1.4 }, { d: circle(8, 11.5, 0.8), f: true }],
  "listNumber": [{ d: "M6.6 4h7.6M6.6 8h7.6M6.6 12h7.6", w: 1.3 }, { d: "M2.6 2.9l1-.6v3.4M2.5 7.1q.4-.6 1.1-.6.9 0 .9.8c0 .8-2 1.5-2 2.4h2M2.6 10.9h1.8l-1 1.1q1.1 0 1.1.9t-1.1.9q-.6 0-.9-.4", w: 0.9 }],
  "listBullet": [{ d: "M6.6 4h7.6M6.6 8h7.6M6.6 12h7.6", w: 1.3 }, { d: circle(3.2, 4, 1) + circle(3.2, 8, 1) + circle(3.2, 12, 1), f: true }],
  "docText": [{ d: "M4 1.9h5.2l3 3v8.2q0 1-1 1H4q-1 0-1-1v-10.2q0-1 1-1zM9 2v3h3", w: 1.2 }, { d: "M5.4 8h5.2M5.4 10.4h5.2", w: 1.1 }],
  "tablecells": [{ d: "M2.8 2.8h10.4q1 0 1 1v8.4q0 1-1 1H2.8q-1 0-1-1V3.8q0-1 1-1z", w: 1.2 }, { d: "M1.8 6.3h12.4M1.8 9.7h12.4M6.2 2.8v10.4", w: 1.1 }],

  // traffic light glyphs (hover)
  "tlClose": [{ d: "M4.2 4.2L9.8 9.8M9.8 4.2L4.2 9.8", w: 1.3 }],
  "tlMin":   [{ d: "M3.6 7h6.8", w: 1.4 }],
  "tlZoom":  [{ d: "M4.2 4.2h4.4L4.2 8.6zM9.8 9.8H5.4L9.8 5.4z", f: true }],

  // provider marks (stand-ins for the brand artwork)
  "markClaude": [{ d: "M8 1.8v12.4M2.6 4.9l10.8 6.2M2.6 11.1l10.8-6.2", w: 2.1 }],
  "markCodex":  [{ d: "M8 2.4l5 2.9v5.4L8 13.6l-5-2.9V5.3z", w: 1.5 }, { d: "M8 5.4v5.2M3.4 8h9.2", w: 1.3 }],
  "markDroid":  [{ d: "M8 2.4v11.2M3.2 5.2l9.6 5.6M3.2 10.8l9.6-5.6", w: 1.7 }, { d: circle(8, 8, 2), f: true }]
}
