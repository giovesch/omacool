import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons
import "Model.js" as Model

// The panel's visual layer. Control and polling stay in Panel.qml; keeping this
// as a focused component makes the information architecture legible and lets
// the shell's native palette flow through every surface.
Item {
  id: dashboard

  required property var controller
  property QtObject bar: null
  readonly property real contentHeight: contentColumn.implicitHeight
  readonly property real cardRadius: Style.cornerRadius > 0 ? Style.space(10) : 0

  function presetLabel(id) {
    for (var i = 0; i < controller.presets.length; i++) {
      var preset = controller.presets[i]
      if (preset.id === id)
        return id === "performance" ? "Performance" : (preset.label || id)
    }
    return id || "—"
  }

  function ensureVisible(item) {
    if (!item || !panelScroll || !panelScroll.contentItem) return
    var flick = panelScroll.contentItem
    if (flick.contentY === undefined) return
    var point = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = point.y
    var bottom = top + (item.height || 0)
    var margin = Style.space(10)
    if (top < flick.contentY + margin)
      flick.contentY = Math.max(0, top - margin)
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = bottom + margin - flick.height
  }

  ScrollView {
    id: panelScroll
    anchors.fill: parent
    clip: true
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
    ScrollBar.vertical.policy: contentColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

    Binding {
      target: panelScroll.contentItem
      property: "interactive"
      value: contentColumn.implicitHeight > panelScroll.height
    }

    Binding {
      target: panelScroll.contentItem
      property: "boundsBehavior"
      value: Flickable.StopAtBounds
    }

    Column {
      id: contentColumn
      width: panelScroll.availableWidth
      spacing: Style.space(14)

      // The top card answers the two questions that matter first: how hot is
      // the machine, and who is currently in control of the fans?
      Rectangle {
        width: parent.width
        height: Style.space(112)
        radius: dashboard.cardRadius
        color: controller.softSurface
        border.width: 1
        border.color: Qt.rgba(controller.ink.r, controller.ink.g, controller.ink.b, 0.10)

        Column {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(16)
          anchors.top: parent.top
          anchors.topMargin: Style.space(14)
          spacing: Style.space(3)

          Text {
            text: "THERMAL CONTROL"
            color: controller.mutedInk
            font.family: bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.5
          }

          Row {
            spacing: Style.space(8)

            Text {
              id: heroTemperature
              text: Model.formatTemp(controller.hottestValue)
              color: controller.alarming ? controller.danger : controller.ink
              font.family: bar.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }

            Text {
              id: thermalWord
              text: Model.thermalName(controller.hottestValue, controller.criticalTemp)
              color: controller.alarming ? controller.danger : controller.mutedInk
              font.family: bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              anchors.verticalCenter: heroTemperature.verticalCenter
            }
          }

          Text {
            width: Math.max(Style.space(170), parent.parent.width * 0.55)
            text: controller.hottest ? controller.hottest.label : "Waiting for sensor data"
            color: controller.mutedInk
            font.family: bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Column {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(16)
          anchors.top: parent.top
          anchors.topMargin: Style.space(16)
          spacing: Style.space(9)

          StatusBadge {
            label: dashboard.presetLabel(controller.activePreset)
            icon: controller.presetIcon(controller.activePreset)
            active: true
          }

          StatusBadge {
            label: controller.daemonRunning ? "Service active" : "Read only"
            icon: controller.daemonRunning ? "●" : "○"
            active: controller.daemonRunning
          }
        }

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.leftMargin: Style.space(16)
          anchors.rightMargin: Style.space(16)
          anchors.bottomMargin: Style.space(11)
          height: Style.space(4)
          radius: height / 2
          color: controller.strongSurface

          Rectangle {
            width: parent.width * Model.thermalFraction(controller.hottestValue, controller.criticalTemp)
            height: parent.height
            radius: parent.radius
            color: controller.alarming ? controller.danger : controller.accent
          }
        }
      }

      Rectangle {
        width: parent.width
        height: Math.max(serviceMessage.implicitHeight + Style.space(22),
                         enableButton.visible ? enableButton.implicitHeight + Style.space(16) : 0)
        radius: dashboard.cardRadius
        visible: controller.status !== null && (!controller.daemonRunning || controller.lastError !== "")
        color: Qt.rgba(controller.danger.r, controller.danger.g, controller.danger.b, 0.10)
        border.width: 1
        border.color: Qt.rgba(controller.danger.r, controller.danger.g, controller.danger.b, 0.34)

        Text {
          id: serviceMessage
          anchors.left: parent.left
          anchors.right: enableButton.visible ? enableButton.left : parent.right
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: controller.lastError !== ""
            ? controller.lastError
            : "Fan control is off. Temperatures are still live."
          color: controller.danger
          font.family: bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Button {
          id: enableButton
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          visible: !controller.daemonRunning
          text: controller.installing ? "Enabling…" : "Enable"
          fontSize: Style.font.caption
          foreground: controller.ink
          fontFamily: bar.fontFamily
          horizontalPadding: Style.spacing.md
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          enabled: !controller.installing
          onClicked: controller.installService()
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(9)
        visible: controller.presets.length > 0

        SectionHeading {
          width: parent.width
          title: "Cooling profile"
          meta: "Applies to all fans"
        }

        Flow {
          id: profileFlow
          width: parent.width
          spacing: Style.space(7)

          Repeater {
            model: controller.presets

            PresetCard {
              required property var modelData
              required property int index
              width: index === controller.presets.length - 1 && controller.presets.length % 2 === 1
                ? profileFlow.width
                : (profileFlow.width - profileFlow.spacing) / 2
              preset: modelData
              presetIndex: index
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(9)
        visible: controller.fans.length > 0

        Item {
          width: parent.width
          height: Math.max(fanHeading.implicitHeight, newGroupButton.implicitHeight)

          SectionHeading {
            id: fanHeading
            anchors.left: parent.left
            anchors.right: newGroupButton.left
            anchors.rightMargin: Style.space(8)
            title: "Fans"
            meta: controller.controllableCount + " adjustable"
          }

          Button {
            id: newGroupButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: !controller.addingGroup
            text: "+ Zone"
            fontSize: Style.font.caption
            foreground: controller.ink
            fontFamily: bar.fontFamily
            horizontalPadding: Style.spacing.md
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            onClicked: {
              controller.addingGroup = true
              controller.newGroupName = ""
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(40)
          radius: dashboard.cardRadius
          visible: controller.addingGroup
          color: controller.softSurface
          border.width: 1
          border.color: Qt.rgba(controller.accent.r, controller.accent.g, controller.accent.b, 0.45)

          TextInput {
            id: groupNameInput
            anchors.left: parent.left
            anchors.right: addGroupButton.left
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            color: controller.ink
            font.family: bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: controller.newGroupName
            onTextChanged: controller.newGroupName = text
            onAccepted: controller.addCustomGroup(text)

            Text {
              anchors.fill: parent
              visible: groupNameInput.text.length === 0
              text: "Name this fan zone"
              color: controller.faintInk
              font: groupNameInput.font
              verticalAlignment: Text.AlignVCenter
            }
          }

          Button {
            id: addGroupButton
            anchors.right: cancelGroupButton.left
            anchors.rightMargin: Style.space(5)
            anchors.verticalCenter: parent.verticalCenter
            text: "Add"
            fontSize: Style.font.caption
            foreground: controller.ink
            fontFamily: bar.fontFamily
            horizontalPadding: Style.spacing.sm
            verticalPadding: Style.space(2)
            bordered: true
            onClicked: controller.addCustomGroup(groupNameInput.text)
          }

          Button {
            id: cancelGroupButton
            anchors.right: parent.right
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: "Cancel"
            fontSize: Style.font.caption
            foreground: controller.ink
            fontFamily: bar.fontFamily
            horizontalPadding: Style.spacing.sm
            verticalPadding: Style.space(2)
            bordered: true
            onClicked: {
              controller.addingGroup = false
              controller.newGroupName = ""
            }
          }
        }

        Repeater {
          model: Model.organizeFansByGroup(controller.fans, controller.groups)

          Column {
            id: zone
            required property var modelData
            width: contentColumn.width
            spacing: Style.space(5)

            Item {
              width: parent.width
              height: Style.space(24)

              Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(7)

                Text {
                  text: zone.modelData.icon
                  color: controller.accent
                  font.family: bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  text: zone.modelData.name.toUpperCase()
                  color: controller.mutedInk
                  font.family: bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.1
                }

                Text {
                  text: zone.modelData.fans.length
                  color: controller.faintInk
                  font.family: bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !zone.modelData.builtin
                text: "Remove zone"
                color: controller.danger
                font.family: bar.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(5)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: controller.removeCustomGroup(zone.modelData.id)
                }
              }
            }

            Text {
              width: parent.width
              visible: zone.modelData.fans.length === 0
              text: "No fans assigned"
              color: controller.faintInk
              font.family: bar.fontFamily
              font.pixelSize: Style.font.caption
              font.italic: true
              leftPadding: Style.space(10)
            }

            Repeater {
              model: zone.modelData.fans

              FanCard {
                required property var modelData
                width: contentColumn.width
                fan: modelData
                rowIndex: Model.findFanIndex(controller.fans, modelData.id)
              }
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: emptyFanText.implicitHeight + Style.space(26)
        radius: dashboard.cardRadius
        visible: controller.status !== null && controller.fans.length === 0
        color: controller.softSurface

        Text {
          id: emptyFanText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: Style.space(13)
          anchors.verticalCenter: parent.verticalCenter
          text: "No fan channels were found. Load your board's sensor module, then reopen this panel."
          color: controller.mutedInk
          font.family: bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(9)
        visible: controller.temps.length > 0

        SectionHeading {
          width: parent.width
          title: "Sensors"
          meta: controller.temps.length + " live"
        }

        Grid {
          id: sensorGrid
          width: parent.width
          columns: 2
          spacing: Style.space(7)
          readonly property real cellWidth: (width - spacing) / 2

          Repeater {
            model: controller.temps

            SensorCard {
              required property var modelData
              required property int index
              width: sensorGrid.cellWidth
              temp: modelData
              rowIndex: index
            }
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(7)

        Rectangle {
          width: Style.space(6)
          height: width
          radius: width / 2
          color: controller.daemonRunning ? controller.accent : controller.faintInk
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: controller.daemonRunning ? "omacool is managing airflow" : "Monitoring only"
          color: controller.faintInk
          font.family: bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Item { width: parent.width; height: Style.space(5) }
    }
  }

  component StatusBadge: Rectangle {
    required property string label
    required property string icon
    property bool active: false

    width: badgeContent.implicitWidth + Style.space(16)
    height: badgeContent.implicitHeight + Style.space(8)
    radius: height / 2
    color: active ? controller.accentSurface : controller.softSurface

    Row {
      id: badgeContent
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        text: icon
        color: active ? controller.accent : controller.mutedInk
        font.family: bar.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        text: label
        color: controller.ink
        font.family: bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  component SectionHeading: Item {
    required property string title
    property string meta: ""

    implicitHeight: Math.max(sectionTitle.implicitHeight, sectionMeta.implicitHeight)

    Text {
      id: sectionTitle
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: title
      color: controller.ink
      font.family: bar.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Text {
      id: sectionMeta
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: meta
      color: controller.faintInk
      font.family: bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component PresetCard: CursorSurface {
    id: profile
    required property var preset
    required property int presetIndex

    implicitHeight: Style.space(64)
    foreground: controller.ink
    fill: Style.hoverFillFor(controller.ink, controller.accent)
    currentFill: controller.accentSurface
    current: controller.activePreset === preset.id
    hasCursor: controller.cursorActive
      && controller.focusSection === "presets"
      && controller.selectedIndex === presetIndex
    bordered: true

    Rectangle {
      id: profileIcon
      width: Style.space(34)
      height: width
      radius: Style.cornerRadius
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      color: profile.current ? Qt.rgba(controller.accent.r, controller.accent.g, controller.accent.b, 0.18) : controller.softSurface

      Text {
        anchors.centerIn: parent
        text: controller.presetIcon(profile.preset.id)
        color: profile.current ? controller.accent : controller.mutedInk
        font.family: bar.fontFamily
        font.pixelSize: Style.font.title
      }
    }

    Column {
      anchors.left: profileIcon.right
      anchors.leftMargin: Style.space(9)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(9)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: dashboard.presetLabel(profile.preset.id)
        color: controller.ink
        font.family: bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: profile.current
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: controller.presetBlurb(profile.preset)
        color: controller.mutedInk
        font.family: bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        controller.cursorActive = true
        controller.focusSection = "presets"
        controller.selectedIndex = profile.presetIndex
      }
      onClicked: controller.applyPreset(profile.preset.id)
    }
  }

  component ModeButton: Button {
    required property string mode
    required property string label
    required property string fanId
    required property string activeMode

    text: label
    fontSize: Style.font.caption
    foreground: controller.ink
    fontFamily: bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    selected: mode !== "reset" && activeMode === mode
    onClicked: mode === "reset"
      ? controller.resetFan(fanId)
      : controller.setFanMode(fanId, mode)
  }

  component FanCard: Column {
    id: fanCard
    required property var fan
    required property int rowIndex

    readonly property bool expanded: controller.expandedFan === fan.id
    readonly property bool controllable: fan.writable === true
    spacing: expanded ? Style.space(6) : 0

    CursorSurface {
      id: fanSurface
      width: fanCard.width
      implicitHeight: Style.space(68)
      foreground: controller.ink
      fill: Style.hoverFillFor(controller.ink, controller.accent)
      currentFill: controller.softSurface
      current: fanCard.expanded
      hasCursor: controller.cursorActive
        && controller.focusSection === "fans"
        && controller.selectedIndex === fanCard.rowIndex
      bordered: true
      opacity: fanCard.controllable ? 1 : 0.52
      onHasCursorChanged: if (hasCursor) dashboard.ensureVisible(fanSurface)

      Rectangle {
        id: fanIcon
        width: Style.space(38)
        height: width
        radius: width / 2
        anchors.left: parent.left
        anchors.leftMargin: Style.space(11)
        anchors.verticalCenter: parent.verticalCenter
        color: fanCard.expanded ? controller.accentSurface : controller.softSurface

        Text {
          anchors.centerIn: parent
          text: "󰈐"
          color: fanCard.expanded ? controller.accent : controller.mutedInk
          font.family: bar.fontFamily
          font.pixelSize: Style.font.title
          rotation: fanCard.fan.rpm > 0 ? 12 : 0
        }
      }

      Column {
        anchors.left: fanIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: fanReading.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: Model.fanLabel(fanCard.fan)
          color: controller.ink
          font.family: bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: Model.fanSubtitle(fanCard.fan)
          color: controller.mutedInk
          font.family: bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: fanReading
        anchors.right: parent.right
        anchors.rightMargin: Style.space(11)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(7)

        Text {
          text: fanCard.fan.percent === null || fanCard.fan.percent === undefined
            ? "—" : fanCard.fan.percent + "%"
          color: controller.ink
          font.family: bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          visible: fanCard.controllable
          text: fanCard.expanded ? "󰅃" : "󰅀"
          color: controller.faintInk
          font.family: bar.fontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        anchors.bottomMargin: Style.space(5)
        height: Style.space(2)
        radius: height / 2
        color: controller.strongSurface

        Rectangle {
          width: parent.width * Math.max(0, Math.min(100, Number(fanCard.fan.percent || 0))) / 100
          height: parent.height
          radius: parent.radius
          color: controller.accent
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: fanCard.controllable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onContainsMouseChanged: if (containsMouse) {
          controller.cursorActive = true
          controller.focusSection = "fans"
          controller.selectedIndex = fanCard.rowIndex
        }
        onClicked: if (fanCard.controllable)
          controller.expandedFan = fanCard.expanded ? "" : fanCard.fan.id
      }
    }

    Rectangle {
      width: fanCard.width
      height: visible ? tuningControls.implicitHeight + Style.space(24) : 0
      visible: fanCard.expanded && fanCard.controllable
      radius: dashboard.cardRadius
      color: controller.softSurface
      border.width: 1
      border.color: Qt.rgba(controller.ink.r, controller.ink.g, controller.ink.b, 0.08)

      Column {
        id: tuningControls
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(12)
        spacing: Style.space(12)

        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "CONTROL MODE"
            color: controller.faintInk
            font.family: bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.1
          }

          Grid {
            id: modeGrid
            width: parent.width
            columns: 4
            spacing: Style.space(5)
            readonly property real cellWidth: (width - spacing * 3) / 4

            ModeButton { width: modeGrid.cellWidth; fanId: fanCard.fan.id; activeMode: fanCard.fan.mode; mode: "auto"; label: "Auto" }
            ModeButton { width: modeGrid.cellWidth; fanId: fanCard.fan.id; activeMode: fanCard.fan.mode; mode: "manual"; label: "Fixed" }
            ModeButton { width: modeGrid.cellWidth; fanId: fanCard.fan.id; activeMode: fanCard.fan.mode; mode: "curve"; label: "Curve" }
            ModeButton { width: modeGrid.cellWidth; fanId: fanCard.fan.id; activeMode: fanCard.fan.mode; mode: "reset"; label: "Reset" }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "ZONE"
            color: controller.faintInk
            font.family: bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.1
          }

          Flow {
            width: parent.width
            spacing: Style.space(5)

            Repeater {
              model: Model.allGroupOptions(controller.groups)

              Button {
                required property var modelData
                text: modelData.name
                fontSize: Style.font.caption
                foreground: controller.ink
                fontFamily: bar.fontFamily
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                selected: (fanCard.fan.group || Model.detectFanGroup(fanCard.fan)) === modelData.id
                onClicked: controller.setFanGroup(fanCard.fan.id, modelData.id)
              }
            }
          }
        }

        Column {
          width: parent.width
          visible: fanCard.fan.mode === "manual"
          spacing: Style.space(7)

          Item {
            width: parent.width
            height: fixedLabel.implicitHeight

            Text {
              id: fixedLabel
              anchors.left: parent.left
              text: "FIXED SPEED"
              color: controller.faintInk
              font.family: bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
            }

            Text {
              anchors.right: parent.right
              text: Math.round(speedSlider.dragging ? speedSlider.liveValue : controller.draftPercent(fanCard.fan)) + "%"
              color: controller.accent
              font.family: bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }

          PanelSlider {
            id: speedSlider
            width: parent.width
            bar: dashboard.bar
            minimum: 0
            maximum: 100
            step: 1
            integer: true
            value: controller.draftPercent(fanCard.fan)
            onMoved: function(value) { controller.setDraftPercent(fanCard.fan.id, value) }
            onReleased: function(value) { controller.setFanPercent(fanCard.fan.id, value) }
          }
        }

        Column {
          width: parent.width
          visible: fanCard.fan.mode === "curve"
          spacing: Style.space(7)

          Item {
            width: parent.width
            height: curveLabel.implicitHeight

            Text {
              id: curveLabel
              anchors.left: parent.left
              text: "RESPONSE CURVE"
              color: controller.faintInk
              font.family: bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
            }

            Text {
              anchors.right: parent.right
              text: "Drag points · double-click to add"
              color: controller.faintInk
              font.family: bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Loader {
            id: graphLoader
            width: parent.width
            height: Style.space(168)
            active: fanCard.expanded && fanCard.fan.mode === "curve"
            onLoaded: controller.activeCurveEditor = item
            onActiveChanged: if (!active) controller.activeCurveEditor = null

            sourceComponent: Component {
              CurveEditor {
                bar: dashboard.bar
                foreground: controller.ink
                accent: controller.accent
                curve: fanCard.fan.curve || []
                currentTemp: {
                  var sensor = !fanCard.fan.sensor || fanCard.fan.sensor === "auto"
                    ? controller.hottest
                    : Model.findTemp(controller.temps, fanCard.fan.sensor)
                  return sensor ? Number(sensor.value) : NaN
                }
                currentPercent: fanCard.fan.percent === null || fanCard.fan.percent === undefined
                  ? NaN : Number(fanCard.fan.percent)
                onCurveEdited: function(points) {
                  controller.setFanCurve(fanCard.fan.id, points, null)
                }
                onPointSelected: function(index) {
                  controller.cursorActive = true
                  controller.focusSection = "curve"
                  controller.selectedIndex = -1
                }
              }
            }
          }

          Text {
            text: "TEMPERATURE SOURCE"
            color: controller.faintInk
            font.family: bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.1
          }

          Flow {
            width: parent.width
            spacing: Style.space(5)

            Repeater {
              model: Model.sensorOptions(controller.temps)

              Button {
                id: sensorChoice
                required property var modelData
                readonly property bool isCurrent: (fanCard.fan.sensor || "auto") === modelData.value
                readonly property var sensorObject: modelData.value === "auto"
                  ? controller.hottest
                  : Model.findTemp(controller.temps, modelData.value)
                text: modelData.value === "auto"
                  ? "Hottest"
                  : (sensorObject ? sensorObject.label : modelData.label)
                tooltipText: modelData.label
                fontSize: Style.font.caption
                foreground: controller.ink
                fontFamily: bar.fontFamily
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                selected: isCurrent
                onClicked: controller.setFanCurve(fanCard.fan.id, fanCard.fan.curve || [], modelData.value)
              }
            }
          }
        }
      }
    }
  }

  component SensorCard: CursorSurface {
    id: sensorCard
    required property var temp
    required property int rowIndex

    implicitHeight: Style.space(68)
    foreground: controller.ink
    fill: controller.softSurface
    currentFill: controller.softSurface
    current: true
    bordered: true
    hasCursor: controller.cursorActive
      && controller.focusSection === "temps"
      && controller.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) dashboard.ensureVisible(sensorCard)

    Column {
      anchors.left: parent.left
      anchors.right: sensorValue.left
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: sensorCard.temp.label
        color: controller.ink
        font.family: bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: sensorCard.temp.chipName || sensorCard.temp.chip || "Sensor"
        color: controller.faintInk
        font.family: bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      id: sensorValue
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: Model.formatTemp(sensorCard.temp.value)
      color: Number(sensorCard.temp.value) >= controller.criticalTemp
        ? controller.danger
        : controller.ink
      font.family: bar.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.bottomMargin: Style.space(6)
      height: Style.space(2)
      radius: height / 2
      color: controller.strongSurface

      Rectangle {
        width: parent.width * Model.thermalFraction(sensorCard.temp.value, controller.criticalTemp)
        height: parent.height
        radius: parent.radius
        color: Number(sensorCard.temp.value) >= controller.criticalTemp
          ? controller.danger
          : controller.accent
      }
    }
  }
}
