import QtQuick

// A one-line Txt for user text that can mix scripts. A fallback font with a tall ascent (Noto Sans Arabic or
// Hebrew) pushes the whole fixed-height line down onto the next row; move it back to the Inter baseline.
Txt {
  id: t
  readonly property bool mixed: /[֐-ࣿיִ-﷿ﹰ-﻿]/.test(text)
  readonly property real drop: mixed ? baselineOffset - ((lineHeight - fm.height) / 2 + fm.ascent) : 0
  FontMetrics { id: fm; font: t.font }
  transform: Translate { y: -Math.round(t.drop) }
}
