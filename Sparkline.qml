import QtQuick
import qs.Commons as Commons

// Lightweight line chart for a stock's closing prices. The painting happens on
// a Canvas child so the names of our own properties can never collide with
// Qt's final Item properties (notably `baseline`, which is an anchor line).
Item {
  id: root

  property var values: []
  property real baselineValue: NaN
  property color lineColor: Commons.Color.accent
  property color baselineColor: Qt.rgba(Commons.Color.foreground.r,
                                        Commons.Color.foreground.g,
                                        Commons.Color.foreground.b, 0.28)
  property bool filled: true
  property bool showBaseline: true

  function rgba(color, alpha) {
    var a = alpha === undefined ? color.a : alpha
    return "rgba(" + Math.round(color.r * 255) + ","
      + Math.round(color.g * 255) + ","
      + Math.round(color.b * 255) + "," + a + ")"
  }

  function numericSeries() {
    var out = []
    for (var i = 0; i < values.length; i++) {
      var raw = values[i]
      if (raw === null || raw === undefined) continue
      var n = Number(raw)
      if (isFinite(n)) out.push(n)
    }
    return out
  }

  onValuesChanged: canvas.requestPaint()
  onBaselineValueChanged: canvas.requestPaint()
  onLineColorChanged: canvas.requestPaint()
  onBaselineColorChanged: canvas.requestPaint()
  onFilledChanged: canvas.requestPaint()
  onShowBaselineChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      if (!ctx) return
      ctx.clearRect(0, 0, width, height)

      var points = root.numericSeries()
      if (points.length === 0 || width < 2 || height < 2) return
      if (points.length === 1) points.push(points[0])

      var min = points[0]
      var max = points[0]
      for (var i = 1; i < points.length; i++) {
        if (points[i] < min) min = points[i]
        if (points[i] > max) max = points[i]
      }
      if (isFinite(root.baselineValue)) {
        if (root.baselineValue < min) min = root.baselineValue
        if (root.baselineValue > max) max = root.baselineValue
      }
      if (max - min < 0.000001) {
        max += 0.5
        min -= 0.5
      }

      var pad = Math.max(1, height * 0.08)
      var plotHeight = height - pad * 2
      var span = max - min

      function xAt(index) {
        return (index / (points.length - 1)) * width
      }
      function yAt(value) {
        return pad + ((max - value) / span) * plotHeight
      }

      if (root.filled) {
        ctx.beginPath()
        ctx.moveTo(0, height)
        for (var f = 0; f < points.length; f++) ctx.lineTo(xAt(f), yAt(points[f]))
        ctx.lineTo(width, height)
        ctx.closePath()
        var gradient = ctx.createLinearGradient(0, 0, 0, height)
        gradient.addColorStop(0, root.rgba(root.lineColor, 0.20))
        gradient.addColorStop(1, root.rgba(root.lineColor, 0))
        ctx.fillStyle = gradient
        ctx.fill()
      }

      if (root.showBaseline && isFinite(root.baselineValue)) {
        var baseY = yAt(root.baselineValue)
        ctx.beginPath()
        ctx.setLineDash([2, 3])
        ctx.moveTo(0, baseY)
        ctx.lineTo(width, baseY)
        ctx.strokeStyle = root.rgba(root.baselineColor)
        ctx.lineWidth = 1
        ctx.stroke()
        ctx.setLineDash([])
      }

      ctx.beginPath()
      for (var l = 0; l < points.length; l++) {
        if (l === 0) ctx.moveTo(xAt(l), yAt(points[l]))
        else ctx.lineTo(xAt(l), yAt(points[l]))
      }
      ctx.strokeStyle = root.rgba(root.lineColor)
      ctx.lineWidth = Math.max(1, height / 42)
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.stroke()
    }
  }
}
