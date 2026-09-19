import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// omacool — every fan and temperature sensor the kernel exposes, in one panel.
//
// The bar glyph carries the hottest sensor. The panel adds presets, a row per
// fan with its own mode and duty cycle, and a draggable curve editor.
//
// Reads come straight from sysfs through `bin/omacool status --json`, so the
// panel is useful even with no daemon installed; writes are refused with an
// explanation instead of failing silently.
Panel {
  id: root
  moduleName: "io.github.giovesch.omacool"
  ipcTarget: "omacool"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the status/preset methods below.
  manageIpc: false

  // ---------------------------------------------------------------- state

  property var status: null
  property string lastError: ""
  property string expandedFan: ""
  property real wheelAccumulator: 0

  // The bundled CLI, not whatever `omacool` happens to be on PATH: the panel
  // and the reader it parses must always be the same version.
  readonly property string tool: Qt.resolvedUrl("bin/omacool").toString().replace(/^file:\/\//, "")
  readonly property string installScript: Qt.resolvedUrl("install.sh").toString().replace(/^file:\/\//, "")
  property bool installing: false

  readonly property var temps: status && status.temps ? status.temps : []
  readonly property var fans: status && status.fans ? status.fans : []
  readonly property var presets: status && status.presets ? status.presets : []
  readonly property var hottest: status && status.hottest ? status.hottest : null
  readonly property bool daemonRunning: status ? status.daemon === true : false
  readonly property string activePreset: status ? String(status.preset || "") : ""
  readonly property real criticalTemp: status && status.criticalTemp ? Number(status.criticalTemp) : 90
  readonly property real hottestValue: hottest ? Number(hottest.value) : NaN
  readonly property bool alarming: isFinite(hottestValue) && hottestValue >= criticalTemp
  readonly property int controllableCount: status ? Number(status.controllable || 0) : 0

  // Duty cycles the user is dragging right now, keyed by fan id. The daemon is
  // only told when the drag ends, so the slider stays smooth and the sysfs
  // round-trip does not yank the knob back mid-gesture.
  property var draftPercents: ({})

  // The curve editor belonging to the expanded fan, if any. Inline components
  // get their own id scope, so the keyboard handlers up here cannot reach the
  // Loader directly — the row hands its editor over instead.
  property var activeCurveEditor: null

  function draftPercent(fan) {
    if (!fan) return 0
    var draft = root.draftPercents[fan.id]
    if (draft !== undefined) return draft
    if (fan.mode === "manual" && fan.target !== undefined && fan.target !== null) return fan.target
    return fan.percent === null || fan.percent === undefined ? 0 : fan.percent
  }

  function setDraftPercent(id, value) {
    var next = {}
    for (var key in root.draftPercents) next[key] = root.draftPercents[key]
    next[id] = Model.clampPercent(value)
    root.draftPercents = next
  }

  function clearDraftPercent(id) {
    var next = {}
    for (var key in root.draftPercents)
      if (key !== id) next[key] = root.draftPercents[key]
    root.draftPercents = next
  }

  // ------------------------------------------------------------- cursor
  // Sections, top to bottom:
  //   "presets" — one horizontal row of preset chips
  //   "fans"    — one row per fan; Enter expands the row's controls
  //   "curve"   — the expanded fan's curve editor, when it is in curve mode
  //   "temps"   — read-only sensor list, skipped by the cursor when empty
  property string focusSection: "presets"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property var expandedFanObject: Model.findFan(root.fans, root.expandedFan)
  readonly property bool curveVisible: expandedFanObject !== null
    && expandedFanObject.writable === true
    && expandedFanObject.mode === "curve"

  readonly property var visibleSections: {
    var list = ["presets"]
    if (fans.length > 0) list.push("fans")
    if (curveVisible) list.push("curve")
    if (temps.length > 0) list.push("temps")
    return list
  }

  function sectionCount(section) {
    if (section === "presets") return presets.length
    if (section === "fans") return fans.length
    if (section === "temps") return temps.length
    return 0
  }

  function sectionIsSingleRow(section) {
    return section === "presets" || section === "curve"
  }

  function sectionFirstIndex(section) {
    return section === "curve" ? -1 : 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  function moveCursorH(delta) {
    if (focusSection === "presets") {
      var next = selectedIndex + delta
      selectedIndex = Math.max(0, Math.min(presets.length - 1, next))
      return
    }
    if (focusSection === "curve") {
      if (root.activeCurveEditor) root.activeCurveEditor.selectNext(delta)
      return
    }
    if (focusSection === "fans") {
      // h/l trims a manual fan without reaching for the slider. Curve and auto
      // fans are left alone: nudging them would silently pin them to manual.
      var fan = fans[selectedIndex]
      if (!fan || !fan.writable || fan.mode !== "manual") return
      root.nudgeFan(fan, delta * 5)
    }
  }

  function activateCursor() {
    if (focusSection === "presets" && selectedIndex >= 0 && selectedIndex < presets.length) {
      root.applyPreset(presets[selectedIndex].id)
      return
    }
    if (focusSection === "fans" && selectedIndex >= 0 && selectedIndex < fans.length) {
      var fan = fans[selectedIndex]
      if (!fan) return
      root.expandedFan = root.expandedFan === fan.id ? "" : fan.id
    }
  }

  function handleTextKey(text) {
    var editor = root.activeCurveEditor
    if (focusSection === "curve" && editor) {
      if (text === "+" || text === "=") { editor.nudgeSelected(5, 0); return }
      if (text === "-" || text === "_") { editor.nudgeSelected(-5, 0); return }
      if (text === "]") { editor.nudgeSelected(0, 2); return }
      if (text === "[") { editor.nudgeSelected(0, -2); return }
    }
    // a/m/c switch the highlighted fan's mode without opening its row.
    var fan = focusSection === "fans" ? fans[selectedIndex] : root.expandedFanObject
    if (!fan || !fan.writable) return
    if (text === "a") root.setFanMode(fan.id, "auto")
    else if (text === "m") root.setFanMode(fan.id, "manual")
    else if (text === "c") root.setFanMode(fan.id, "curve")
    else if (text === "r") root.resetFan(fan.id)
  }

  function clampCursor() {
    var sections = visibleSections
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (sectionIsSingleRow(focusSection)) {
      if (focusSection === "curve") selectedIndex = -1
      else selectedIndex = Math.max(0, Math.min(sectionCount(focusSection) - 1, selectedIndex))
      return
    }
    var count = sectionCount(focusSection)
    if (count === 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    selectedIndex = Math.max(0, Math.min(count - 1, selectedIndex))
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var point = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = point.y
    var bottom = top + (item.height || 0)
    var margin = Style.space(6)
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = bottom + margin - flick.height
  }

  // ------------------------------------------------------------- commands

  // One control process at a time, with a queue behind it: a preset click while
  // a curve write is still in flight must not be dropped.
  property var commandQueue: []

  function runControl(args) {
    if (controlProc.running) {
      var queued = root.commandQueue.slice()
      queued.push(args)
      root.commandQueue = queued
      return
    }
    controlProc.command = [root.tool].concat(args)
    controlProc.running = true
  }

  function applyPreset(name) {
    if (!name) return
    runControl(["preset", String(name)])
  }

  function setFanPercent(id, percent) {
    if (!id) return
    runControl(["set", String(id), String(Model.clampPercent(percent))])
  }

  function setFanMode(id, mode) {
    if (!id) return
    if (mode === "curve") root.expandedFan = id
    runControl(["mode", String(id), String(mode)])
  }

  function setFanCurve(id, curve, sensor) {
    if (!id) return
    var args = ["curve", String(id), Model.curveToArg(curve)]
    if (sensor) args = args.concat(["--sensor", String(sensor)])
    runControl(args)
  }

  function resetFan(id) {
    if (!id) return
    clearDraftPercent(id)
    runControl(["reset", String(id)])
  }

  function nudgeFan(fan, delta) {
    if (!fan || !fan.writable) return
    var next = Model.clampPercent(root.draftPercent(fan) + delta)
    setDraftPercent(fan.id, next)
    setFanPercent(fan.id, next)
  }

  function installService() {
    if (installProc.running) return
    root.lastError = ""
    root.installing = true
    installProc.command = ["pkexec", root.installScript]
    installProc.running = true
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  // ------------------------------------------------------------------ ipc

  function statusIpc() {
    return JSON.stringify({
      preset: root.activePreset,
      daemon: root.daemonRunning,
      hottest: root.hottest,
      fans: root.fans
    })
  }

  IpcHandler {
    target: "omacool"

    function state(): string { return root.statusIpc() }
    function preset(name: string): string { root.applyPreset(name); return name }
    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
  }

  // --------------------------------------------------------------- wiring

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (!opened) return
    refresh()
    focusSection = "presets"
    selectedIndex = Math.max(0, presetIndex(root.activePreset))
    cursorActive = false
  }

  onVisibleSectionsChanged: clampCursor()
  onFansChanged: clampCursor()
  onTempsChanged: clampCursor()

  function presetIndex(id) {
    for (var i = 0; i < presets.length; i++)
      if (presets[i].id === id) return i
    return 0
  }

  // Poll fast enough to feel live while the panel is open, slowly enough in the
  // background that the bar glyph stays current without spawning a process a
  // second for no one to look at.
  Timer {
    interval: root.opened ? 2000 : 8000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProc
    command: [root.tool, "status", "--json", "--compact"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStatus(text)
        if (parsed) {
          root.status = parsed
          root.lastError = ""
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message) root.lastError = message.split("\n")[0]
      }
    }
  }

  Process {
    id: controlProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // The CLI answers in JSON on stdout for both success and refusal, so a
        // missing daemon surfaces as a readable line instead of silence.
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          root.lastError = parsed && parsed.ok === false ? String(parsed.error || "failed") : ""
        } catch (error) {
          root.lastError = raw.split("\n")[0]
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.commandQueue.length > 0) {
        var queued = root.commandQueue.slice()
        var next = queued.shift()
        root.commandQueue = queued
        controlProc.command = [root.tool].concat(next)
        controlProc.running = true
        return
      }
      root.draftPercents = ({})
      root.refresh()
    }
  }

  Process {
    id: installProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message && !root.daemonRunning) {
          root.lastError = message.indexOf("pkexec") !== -1
            ? "pkexec not available — run sudo ./install.sh from terminal"
            : message.split("\n")[0]
        }
      }
    }
    onRunningChanged: {
      if (running) return
      root.installing = false
      root.refresh()
    }
  }

  // ------------------------------------------------------------ bar glyph

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.alarming
    text: {
      // "󰈐" is nf-md-fan; the number beside it is the hottest sensor, which is
      // the one thing worth a permanent slot in the bar.
      var glyph = "󰈐"
      if (!isFinite(root.hottestValue)) return glyph
      return glyph + " " + Math.round(root.hottestValue) + "°"
    }
    tooltipText: {
      if (!root.status) return "omacool"
      var parts = ["omacool · " + root.activePreset]
      if (root.hottest) parts.push(root.hottest.label + " " + Model.formatTemp(root.hottestValue))
      if (!root.daemonRunning) parts.push("daemon stopped")
      return parts.join("\n")
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
    onWheelMoved: function (delta) {
      // Scrolling the bar item walks the preset list, so the common case never
      // needs the panel at all.
      if (root.presets.length === 0) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      var index = root.presetIndex(root.activePreset) + wheel.steps
      index = Math.max(0, Math.min(root.presets.length - 1, index))
      root.applyPreset(root.presets[index].id)
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (text) { root.handleTextKey(text) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }
        Binding {
          target: scrollArea.contentItem
          property: "boundsBehavior"
          value: Flickable.StopAtBounds
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "󰈐"
              color: root.alarming ? root.bar.urgent : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: heroTemp.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Cooling"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: {
                  if (!root.status) return "READING SENSORS…"
                  if (root.temps.length === 0) return "NO SENSORS FOUND"
                  var name = Model.thermalName(root.hottestValue, root.criticalTemp)
                  return (name + " · " + (root.hottest ? root.hottest.label : "")).toUpperCase()
                }
                color: root.alarming ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Text {
              id: heroTemp
              textFormat: Text.PlainText
              text: Model.formatTemp(root.hottestValue)
              color: root.alarming ? root.bar.urgent : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // ---------- Daemon / error notice ----------
          CursorSurface {
            width: parent.width
            visible: root.status !== null && (!root.daemonRunning || root.lastError !== "")
            implicitHeight: noticeLayout.implicitHeight + Style.spacing.xl
            foreground: root.bar.urgent
            fill: Style.hoverFillFor(root.bar.urgent, root.bar.urgent)
            bordered: true

            Column {
              id: noticeLayout
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.lastError !== ""
                  ? root.lastError
                  : "Fan control is read-only: the omacool daemon is not running."
                color: root.bar.urgent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Button {
                visible: !root.daemonRunning
                text: root.installing ? "Enabling fan service..." : "Enable Fan Control"
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.md
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                enabled: !root.installing
                onClicked: root.installService()
              }
            }
          }

          // ---------- Presets ----------
          PanelSeparator {
            visible: root.presets.length > 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.presets.length > 0

            Item {
              width: parent.width
              implicitHeight: Math.max(presetHeader.implicitHeight, presetHint.implicitHeight)

              PanelSectionHeader {
                id: presetHeader
                text: "PRESET"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: presetHint
                textFormat: Text.PlainText
                text: root.controllableCount === 1
                  ? "1 controllable fan"
                  : root.controllableCount + " controllable fans"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: presetRow
              width: parent.width
              columns: Math.max(1, root.presets.length)
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.presets.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.presets

                PresetPill {
                  required property var modelData
                  required property int index

                  preset: modelData
                  presetIndex: index
                  width: presetRow.cellWidth
                }
              }
            }
          }

          // ---------- Fans ----------
          PanelSeparator {
            visible: root.fans.length > 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.fans.length > 0

            PanelSectionHeader {
              text: "FANS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.fans

              FanRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                fan: modelData
                rowIndex: index
              }
            }
          }

          Text {
            width: parent.width
            visible: root.status !== null && root.fans.length === 0
            textFormat: Text.PlainText
            text: "No fans found. Load your board's sensor modules first — on most desktops that is  sudo sensors-detect  followed by a reboot."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---------- Temperatures ----------
          PanelSeparator {
            visible: root.temps.length > 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.temps.length > 0

            PanelSectionHeader {
              text: "TEMPERATURES"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.temps

              TempRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                temp: modelData
                rowIndex: index
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component PresetPill: Button {
    id: pill
    required property var preset
    required property int presetIndex

    text: preset.label || preset.id
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    tooltipText: preset.mode === "auto"
      ? "Hand every fan back to the firmware"
      : (preset.mode === "manual"
         ? "Pin every fan at " + preset.percent + "%"
         : "Follow the " + (preset.label || preset.id) + " curve")

    selected: root.activePreset === preset.id
    hasCursor: root.cursorActive && root.focusSection === "presets" && root.selectedIndex === pill.presetIndex

    onClicked: root.applyPreset(preset.id)
    onHovered: function (isHovered) {
      if (!isHovered) return
      root.cursorActive = true
      root.focusSection = "presets"
      root.selectedIndex = pill.presetIndex
    }
  }

  component ModePill: Button {
    id: modePill
    required property string mode
    required property string modeLabel
    required property string fanId
    required property string activeMode

    text: modeLabel
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    selected: modePill.mode !== "reset" && modePill.activeMode === modePill.mode

    onClicked: {
      if (modePill.mode === "reset") root.resetFan(modePill.fanId)
      else root.setFanMode(modePill.fanId, modePill.mode)
    }
  }

  component FanRow: Column {
    id: fanRow
    required property var fan
    required property int rowIndex

    property bool sensorPickerOpen: false
    onExpandedChanged: if (!expanded) sensorPickerOpen = false

    readonly property bool expanded: root.expandedFan === fanRow.fan.id
    readonly property bool controllable: fanRow.fan.writable === true

    spacing: Style.space(6)

    CursorSurface {
      id: fanSurface
      width: fanRow.width
      hasCursor: root.cursorActive && root.focusSection === "fans" && root.selectedIndex === fanRow.rowIndex
      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(fanSurface)
      current: fanRow.expanded
      foreground: root.bar.foreground
      fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
      currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
      implicitHeight: fanInner.implicitHeight + Style.spacing.xl
      opacity: fanRow.controllable ? 1.0 : 0.55

      Item {
        id: fanInner
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        implicitHeight: Math.max(fanGlyph.implicitHeight, fanLabels.implicitHeight, fanPercent.implicitHeight)

        Text {
          id: fanGlyph
          text: "󰈐"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          id: fanLabels
          anchors.left: fanGlyph.right
          anchors.leftMargin: Style.space(8)
          anchors.right: fanPercent.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            textFormat: Text.PlainText
            text: Model.fanLabel(fanRow.fan)
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: Model.fanSubtitle(fanRow.fan)
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
          }
        }

        Text {
          id: fanPercent
          textFormat: Text.PlainText
          text: fanRow.fan.percent === null || fanRow.fan.percent === undefined
            ? "--" : fanRow.fan.percent + "%"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: fanRow.controllable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onContainsMouseChanged: if (containsMouse) {
          root.cursorActive = true
          root.focusSection = "fans"
          root.selectedIndex = fanRow.rowIndex
        }
        onClicked: if (fanRow.controllable)
          root.expandedFan = fanRow.expanded ? "" : fanRow.fan.id
      }
    }

    // ---------- expanded controls ----------
    Column {
      width: fanRow.width
      visible: fanRow.expanded && fanRow.controllable
      spacing: Style.space(8)
      leftPadding: Style.space(28)

      Grid {
        id: modeRow
        width: parent.width - parent.leftPadding
        columns: 4
        spacing: Style.spacing.xs

        readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

        ModePill {
          fanId: fanRow.fan.id
          activeMode: fanRow.fan.mode
          mode: "auto"
          modeLabel: "Auto"
          width: modeRow.cellWidth
          tooltipText: "Let the firmware drive this fan"
        }
        ModePill {
          fanId: fanRow.fan.id
          activeMode: fanRow.fan.mode
          mode: "manual"
          modeLabel: "Manual"
          width: modeRow.cellWidth
          tooltipText: "Hold a fixed duty cycle"
        }
        ModePill {
          fanId: fanRow.fan.id
          activeMode: fanRow.fan.mode
          mode: "curve"
          modeLabel: "Curve"
          width: modeRow.cellWidth
          tooltipText: "Follow a temperature curve"
        }
        ModePill {
          fanId: fanRow.fan.id
          activeMode: fanRow.fan.mode
          mode: "reset"
          modeLabel: "Reset"
          width: modeRow.cellWidth
          tooltipText: "Drop this fan's override and follow the preset again"
        }
      }

      // Manual duty cycle
      Column {
        width: parent.width - parent.leftPadding
        visible: fanRow.fan.mode === "manual"
        spacing: Style.space(4)

        Item {
          width: parent.width
          implicitHeight: Math.max(manualHeader.implicitHeight, manualValue.implicitHeight)

          PanelSectionHeader {
            id: manualHeader
            text: "DUTY CYCLE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: manualValue
            textFormat: Text.PlainText
            text: Math.round(manualSlider.dragging ? manualSlider.liveValue : root.draftPercent(fanRow.fan)) + "%"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSlider {
          id: manualSlider
          bar: root.bar
          width: parent.width
          minimum: 0
          maximum: 100
          step: 1
          integer: true
          value: root.draftPercent(fanRow.fan)
          onMoved: function (v) { root.setDraftPercent(fanRow.fan.id, v) }
          onReleased: function (v) { root.setFanPercent(fanRow.fan.id, v) }
        }
      }

      // Curve editor
      Column {
        width: parent.width - parent.leftPadding
        visible: fanRow.fan.mode === "curve"
        spacing: Style.space(4)

        Item {
          width: parent.width
          implicitHeight: Math.max(curveHeader.implicitHeight, curveHint.implicitHeight)

          PanelSectionHeader {
            id: curveHeader
            text: "CURVE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: curveHint
            textFormat: Text.PlainText
            text: "drag · double-click adds · right-click removes"
            color: Qt.darker(root.bar.foreground, 1.55)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Loader {
          id: curveLoader
          width: parent.width
          height: Style.space(150)
          active: fanRow.expanded && fanRow.fan.mode === "curve"

          // Only one fan is ever expanded, so the last editor to load is the one
          // the panel's keyboard handlers should drive.
          onLoaded: root.activeCurveEditor = item
          onActiveChanged: if (!active) root.activeCurveEditor = null

          sourceComponent: Component {
            CurveEditor {
              bar: root.bar
              foreground: root.bar.foreground
              accent: root.bar.urgent
              curve: fanRow.fan.curve || []
              currentTemp: {
                var sensor = !fanRow.fan.sensor || fanRow.fan.sensor === "auto"
                  ? root.hottest
                  : Model.findTemp(root.temps, fanRow.fan.sensor)
                return sensor ? Number(sensor.value) : NaN
              }
              currentPercent: fanRow.fan.percent === null || fanRow.fan.percent === undefined
                ? NaN : Number(fanRow.fan.percent)
              onCurveEdited: function (points) {
                root.setFanCurve(fanRow.fan.id, points, null)
              }
              onPointSelected: function (index) {
                root.cursorActive = true
                root.focusSection = "curve"
                root.selectedIndex = -1
              }
            }
          }
        }

        // Inline Sensor Selector: fixes double scroll & popup clipping completely
        Column {
          id: sensorSection
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(sensorHeader.implicitHeight, sensorToggle.implicitHeight)

            PanelSectionHeader {
              id: sensorHeader
              text: "SENSOR"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            CursorSurface {
              id: sensorToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              implicitHeight: sensorToggleInner.implicitHeight + Style.spacing.sm
              implicitWidth: sensorToggleInner.implicitWidth + Style.spacing.md
              foreground: root.bar.foreground
              fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
              bordered: true
              cursorShape: Qt.PointingHandCursor

              Row {
                id: sensorToggleInner
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: {
                    var s = fanRow.fan.sensor || "auto"
                    if (s === "auto") {
                      var hTemp = root.hottest ? Model.formatTemp(root.hottest.value) : "--"
                      return "🔥 Hottest (" + hTemp + ")"
                    }
                    var found = Model.findTemp(root.temps, s)
                    return found ? (found.label + " (" + Model.formatTemp(found.value) + ")") : s
                  }
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  text: fanRow.sensorPickerOpen ? "󰅃" : "󰅀"
                  color: Qt.darker(root.bar.foreground, 1.3)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: fanRow.sensorPickerOpen = !fanRow.sensorPickerOpen
              }
            }
          }

          // Expandable Sensor Options List (inline - no popup, no nested scrollbar)
          Column {
            width: parent.width
            visible: fanRow.sensorPickerOpen
            spacing: Style.space(3)

            Repeater {
              model: Model.sensorOptions(root.temps)

              CursorSurface {
                id: sensorOptionItem
                required property var modelData
                required property int index

                readonly property bool isSelected: (fanRow.fan.sensor || "auto") === modelData.value
                readonly property var tempObj: modelData.value === "auto" ? root.hottest : Model.findTemp(root.temps, modelData.value)

                width: parent.width
                implicitHeight: sensorOptInner.implicitHeight + Style.spacing.md
                foreground: root.bar.foreground
                fill: isSelected
                  ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                  : Style.hoverFillFor(root.bar.foreground, Color.accent)
                current: isSelected
                bordered: true
                cursorShape: Qt.PointingHandCursor

                Item {
                  id: sensorOptInner
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  implicitHeight: Math.max(sensorOptName.implicitHeight, sensorOptVal.implicitHeight)

                  Row {
                    id: sensorOptName
                    anchors.left: parent.left
                    anchors.right: sensorOptVal.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    Text {
                      text: isSelected ? "✓" : (modelData.value === "auto" ? "🔥" : "󰍛")
                      color: isSelected ? Color.accent : root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: isSelected
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.label
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: isSelected
                      elide: Text.ElideRight
                      width: parent.parent.width - Style.space(70)
                    }
                  }

                  Text {
                    id: sensorOptVal
                    textFormat: Text.PlainText
                    text: tempObj ? Model.formatTemp(tempObj.value) : "--"
                    color: isSelected ? Color.accent : (tempObj && tempObj.value >= root.criticalTemp ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4))
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.setFanCurve(fanRow.fan.id, fanRow.fan.curve || [], modelData.value)
                    fanRow.sensorPickerOpen = false
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component TempRow: Item {
    id: tempRow
    required property var temp
    required property int rowIndex

    implicitHeight: tempLabel.implicitHeight + Style.spacing.lg

    Text {
      id: tempLabel
      textFormat: Text.PlainText
      text: tempRow.temp.label
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.right: tempMeter.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    // A bare bar rather than a full slider: temperatures are read-only, and a
    // knob would invite dragging them.
    Rectangle {
      id: tempMeter
      width: Style.space(70)
      height: Math.max(3, Style.space(4))
      radius: height / 2
      color: Style.selectedFillFor(root.bar.foreground, Color.accent)
      anchors.right: tempValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter

      readonly property real tempVal: Number(tempRow.temp.value)
      readonly property color meterColor: {
        if (!isFinite(tempVal)) return root.bar.foreground
        if (tempVal >= root.criticalTemp) return root.bar.urgent
        if (tempVal >= root.criticalTemp - 15) return Color.warning || "#e0af68"
        return root.bar.foreground
      }

      Rectangle {
        width: parent.width * Model.thermalFraction(tempRow.temp.value, root.criticalTemp)
        height: parent.height
        radius: parent.radius
        color: tempMeter.meterColor
      }
    }

    Text {
      id: tempValue
      textFormat: Text.PlainText
      text: Model.formatTemp(tempRow.temp.value)
      color: {
        var v = Number(tempRow.temp.value)
        if (isFinite(v) && v >= root.criticalTemp) return root.bar.urgent
        if (isFinite(v) && v >= root.criticalTemp - 15) return Color.warning || "#e0af68"
        return root.bar.foreground
      }
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      width: Style.space(34)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
