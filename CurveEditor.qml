import QtQuick
import qs.Commons
import "Model.js" as Model

// A draggable temperature/duty-cycle curve.
//
// Points are [celsius, percent] pairs. Dragging a handle edits a local draft;
// `curveEdited` only fires when the drag ends, so a drag costs one daemon
// round-trip instead of one per frame.
//
// Curves are kept non-decreasing, matching the daemon: dragging a handle below
// the one to its left clamps instead of dipping, because a fan that slows down
// as the machine heats up is never what the user meant.
Item {
  id: root

  property QtObject bar: null
  property color foreground: bar ? bar.foreground : Color.foreground
  property color accent: Color.accent

  // The authoritative curve, normally bound to what the daemon reports.
  property var curve: [[30, 30], [80, 100]]
  property int minTemp: 20
  property int maxTemp: 100

  // Edits go into a local draft rather than overwriting `curve`, which would
  // sever the binding and leave the editor blind to anything the daemon does
  // afterwards. The draft wins while dragging and for a short settle window
  // after, then the daemon's own version takes over again — so if it normalises
  // the shape differently, the correction is visible instead of hidden.
  property var draft: null
  property bool holding: false
  readonly property var effectiveCurve: draft !== null ? draft : curve

  // The live reading, drawn as a marker so the curve can be tuned against what
  // the machine is actually doing right now.
  property real currentTemp: NaN
  property real currentPercent: NaN

  property bool editable: true
  property int selectedIndex: -1
  property bool dragging: false

  // Named `curveEdited` rather than `changed` so it cannot be mistaken for the
  // auto-generated property-change handlers QML puts on every property.
  signal curveEdited(var curve)
  signal pointSelected(int index)

  implicitHeight: Style.space(150)

  readonly property real padLeft: Style.space(26)
  readonly property real padRight: Style.space(8)
  readonly property real padTop: Style.space(8)
  readonly property real padBottom: Style.space(18)
  readonly property real plotWidth: Math.max(1, width - padLeft - padRight)
  readonly property real plotHeight: Math.max(1, height - padTop - padBottom)
  readonly property real tempSpan: Math.max(1, maxTemp - minTemp)

  function plotX(temp) { return padLeft + ((temp - minTemp) / tempSpan) * plotWidth }
  function plotY(percent) { return padTop + (1 - Math.max(0, Math.min(100, percent)) / 100) * plotHeight }
  function tempAt(x) { return minTemp + ((x - padLeft) / plotWidth) * tempSpan }
  function percentAt(y) { return (1 - (y - padTop) / plotHeight) * 100 }

  function points() { return Model.normalizeCurve(root.effectiveCurve) }

  // Publish an edit: hold the local shape briefly so the round-trip through the
  // daemon and the next status poll cannot make the curve jump backwards.
  function commit() {
    root.holding = true
    settle.restart()
    root.curveEdited(root.draft !== null ? root.draft : root.curve)
  }

  Timer {
    id: settle
    interval: 1500
    repeat: false
    onTriggered: {
      root.holding = false
      root.draft = null
      canvas.requestPaint()
    }
  }

  function nearestIndex(x, y, radius) {
    var list = points()
    var best = -1
    var bestDistance = radius * radius
    for (var i = 0; i < list.length; i++) {
      var dx = plotX(list[i][0]) - x
      var dy = plotY(list[i][1]) - y
      var distance = dx * dx + dy * dy
      if (distance <= bestDistance) {
        bestDistance = distance
        best = i
      }
    }
    return best
  }

  // Keep every handle strictly between its neighbours, so the curve stays a
  // function of temperature no matter how far a drag is pushed.
  function movePoint(index, temp, percent) {
    var list = points()
    if (index < 0 || index >= list.length) return
    var lowerBound = index > 0 ? list[index - 1][0] + 1 : root.minTemp
    var upperBound = index < list.length - 1 ? list[index + 1][0] - 1 : root.maxTemp
    if (upperBound < lowerBound) upperBound = lowerBound

    list[index] = [
      Math.round(Math.max(lowerBound, Math.min(upperBound, temp))),
      Model.clampPercent(percent)
    ]
    root.draft = list
    canvas.requestPaint()
  }

  function addPoint(temp, percent) {
    if (!root.editable) return
    var list = points()
    if (list.length >= 8) return
    list.push([Math.round(Math.max(root.minTemp, Math.min(root.maxTemp, temp))),
               Model.clampPercent(percent)])
    root.draft = Model.normalizeCurve(list)
    canvas.requestPaint()
    commit()
  }

  function removePoint(index) {
    if (!root.editable) return
    var list = points()
    if (list.length <= 2 || index < 0 || index >= list.length) return
    list.splice(index, 1)
    root.draft = list
    root.selectedIndex = -1
    canvas.requestPaint()
    commit()
  }

  // Keyboard editing. h/l walks the handles; +/- raises and lowers the selected
  // one; [/] slides it along the temperature axis.
  function selectNext(delta) {
    var list = points()
    if (!list.length) return
    var next = root.selectedIndex < 0 ? (delta > 0 ? 0 : list.length - 1) : root.selectedIndex + delta
    root.selectedIndex = Math.max(0, Math.min(list.length - 1, next))
    root.pointSelected(root.selectedIndex)
    canvas.requestPaint()
  }

  function nudgeSelected(deltaPercent, deltaTemp) {
    if (!root.editable || root.selectedIndex < 0) return
    var list = points()
    var point = list[root.selectedIndex]
    if (!point) return
    movePoint(root.selectedIndex, point[0] + (deltaTemp || 0), point[1] + (deltaPercent || 0))
    commit()
  }

  // A fresh reading from the daemon retires the local draft, unless the user is
  // mid-drag or the settle window is still open.
  onCurveChanged: {
    if (!root.dragging && !root.holding) root.draft = null
    canvas.requestPaint()
  }
  onDraftChanged: canvas.requestPaint()
  onCurrentTempChanged: canvas.requestPaint()
  onCurrentPercentChanged: canvas.requestPaint()
  onSelectedIndexChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    renderStrategy: Canvas.Immediate

    onPaint: {
      var ctx = getContext("2d")
      if (!ctx) return
      ctx.reset()
      ctx.clearRect(0, 0, width, height)

      var fg = root.foreground
      var line = Qt.rgba(fg.r, fg.g, fg.b, 0.11)
      var strong = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.96)
      var fill = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.13)

      // --- grid -------------------------------------------------------
      ctx.lineWidth = 1
      ctx.strokeStyle = line
      for (var percent = 0; percent <= 100; percent += 25) {
        var y = Math.round(root.plotY(percent)) + 0.5
        ctx.beginPath()
        ctx.moveTo(root.padLeft, y)
        ctx.lineTo(root.padLeft + root.plotWidth, y)
        ctx.stroke()
      }
      for (var temp = root.minTemp; temp <= root.maxTemp; temp += 20) {
        var x = Math.round(root.plotX(temp)) + 0.5
        ctx.beginPath()
        ctx.moveTo(x, root.padTop)
        ctx.lineTo(x, root.padTop + root.plotHeight)
        ctx.stroke()
      }

      var list = root.points()
      if (list.length < 2) return

      // --- area under the curve, clamped flat past the end points -----
      ctx.beginPath()
      ctx.moveTo(root.plotX(root.minTemp), root.plotY(list[0][1]))
      for (var i = 0; i < list.length; i++)
        ctx.lineTo(root.plotX(list[i][0]), root.plotY(list[i][1]))
      ctx.lineTo(root.plotX(root.maxTemp), root.plotY(list[list.length - 1][1]))
      ctx.lineTo(root.plotX(root.maxTemp), root.plotY(0))
      ctx.lineTo(root.plotX(root.minTemp), root.plotY(0))
      ctx.closePath()
      ctx.fillStyle = fill
      ctx.fill()

      // --- the curve itself -------------------------------------------
      ctx.beginPath()
      ctx.moveTo(root.plotX(root.minTemp), root.plotY(list[0][1]))
      for (var j = 0; j < list.length; j++)
        ctx.lineTo(root.plotX(list[j][0]), root.plotY(list[j][1]))
      ctx.lineTo(root.plotX(root.maxTemp), root.plotY(list[list.length - 1][1]))
      ctx.lineWidth = Math.max(1.5, Style.space(2))
      ctx.strokeStyle = strong
      ctx.stroke()

      // --- where the machine is sitting right now ---------------------
      if (isFinite(root.currentTemp)) {
        var markerX = root.plotX(Math.max(root.minTemp, Math.min(root.maxTemp, root.currentTemp)))
        ctx.save()
        ctx.beginPath()
        ctx.setLineDash([Style.space(3), Style.space(3)])
        ctx.lineWidth = 1
        ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.46)
        ctx.moveTo(markerX, root.padTop)
        ctx.lineTo(markerX, root.padTop + root.plotHeight)
        ctx.stroke()
        ctx.restore()

        if (isFinite(root.currentPercent)) {
          ctx.beginPath()
          ctx.arc(markerX, root.plotY(root.currentPercent), Math.max(3, Style.space(4)), 0, Math.PI * 2)
          ctx.fillStyle = fg
          ctx.fill()
        }
      }

      // --- handles ----------------------------------------------------
      var handle = Math.max(3.5, Style.space(4.5))
      for (var k = 0; k < list.length; k++) {
        var hx = root.plotX(list[k][0])
        var hy = root.plotY(list[k][1])
        var isSelected = k === root.selectedIndex
        ctx.beginPath()
        ctx.arc(hx, hy, isSelected ? handle + Style.space(2) : handle, 0, Math.PI * 2)
        ctx.fillStyle = isSelected ? fg : strong
        ctx.fill()
        if (isSelected) {
          ctx.beginPath()
          ctx.arc(hx, hy, handle + Style.space(4), 0, Math.PI * 2)
          ctx.lineWidth = 1
          ctx.strokeStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.85)
          ctx.stroke()
        }
      }
    }
  }

  // --- axis labels ----------------------------------------------------
  Repeater {
    model: [0, 50, 100]
    Text {
      required property var modelData
      text: modelData + "%"
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.52)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      x: Style.space(2)
      y: root.plotY(modelData) - implicitHeight / 2
    }
  }

  Repeater {
    model: [root.minTemp, Math.round((root.minTemp + root.maxTemp) / 2), root.maxTemp]
    Text {
      required property var modelData
      text: modelData + "°"
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.52)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      x: Math.min(root.width - implicitWidth, Math.max(0, root.plotX(modelData) - implicitWidth / 2))
      y: root.padTop + root.plotHeight + Style.space(3)
    }
  }

  // Live readout of whichever handle is being dragged, pinned to the top-right
  // so it never sits under the cursor.
  Text {
    visible: root.dragging && root.selectedIndex >= 0
    text: {
      var list = root.points()
      var point = list[root.selectedIndex]
      return point ? Math.round(point[0]) + "° → " + Math.round(point[1]) + "%" : ""
    }
    color: root.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    anchors.right: parent.right
    anchors.rightMargin: Style.space(4)
    anchors.top: parent.top
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.editable
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: root.dragging || root.nearestIndex(mouseX, mouseY, Style.space(14)) >= 0
      ? Qt.PointingHandCursor : Qt.ArrowCursor

    property int dragIndex: -1

    onPressed: function (event) {
      var index = root.nearestIndex(event.x, event.y, Style.space(14))
      if (event.button === Qt.RightButton) {
        if (index >= 0) root.removePoint(index)
        return
      }
      if (index < 0) return
      dragIndex = index
      root.selectedIndex = index
      root.dragging = true
      root.pointSelected(index)
    }

    onPositionChanged: function (event) {
      if (!root.dragging || dragIndex < 0) return
      // movePoint clamps between the neighbouring handles, so the index stays
      // valid no matter how fast or how far the drag goes.
      root.movePoint(dragIndex, root.tempAt(event.x), root.percentAt(event.y))
    }

    onReleased: function () {
      if (!root.dragging) return
      root.dragging = false
      dragIndex = -1
      root.commit()
    }

    onDoubleClicked: function (event) {
      if (event.button !== Qt.LeftButton) return
      if (root.nearestIndex(event.x, event.y, Style.space(14)) >= 0) return
      root.addPoint(root.tempAt(event.x), root.percentAt(event.y))
    }
  }
}
