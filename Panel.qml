import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button (glyph of the service being counted, or a television when idle,
// plus today's total minutes) and a popup dashboard: a tab per service plus
// "All", today's time against the daily limit, what is being counted right
// now, a per-service breakdown and one row per day for the last week. All
// numbers come from the Tracker singleton.
Panel {
  id: root
  moduleName: "io.github.albertojnk.screen-time"
  ipcTarget: "io.github.albertojnk.screen-time"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool showMinutes: String(setting("showMinutesInBar", "On")).toLowerCase() !== "off"
  readonly property string idleGlyph: "󰔂"

  // One tracker for the whole shell: the bar instantiates this widget once
  // per screen, and a per-instance tracker would notify once per monitor.
  readonly property var tracker: Tracker

  function pushSettings() { Tracker.settings = root.settings || {} }
  onSettingsChanged: pushSettings()
  Component.onCompleted: pushSettings()

  // ---------------------------------------------------------------- tabs

  // "all" first, then every tracked service.
  readonly property var tabs: buildTabs(tracker.services, tracker.lang)
  function buildTabs(services, lang) {
    var out = [{ id: "all", name: tracker.t("all"), glyph: root.idleGlyph }]
    for (var i = 0; i < services.length; i++)
      out.push({ id: services[i].id, name: services[i].name, glyph: services[i].glyph })
    return out
  }

  readonly property string selectedId: tracker.selectedTab
  readonly property int tabIndex: {
    for (var i = 0; i < tabs.length; i++) if (tabs[i].id === selectedId) return i
    return 0
  }
  readonly property var tab: tabs.length > 0 ? tabs[tabIndex] : null
  readonly property string viewId: tab ? tab.id : "all"
  property bool cursorActive: false

  function selectTab(index) {
    if (tabs.length === 0) return
    var wrapped = ((index % tabs.length) + tabs.length) % tabs.length
    Tracker.selectedTab = tabs[wrapped].id
  }

  // Recomputed whenever the tracker ticks or settings change.
  property var view: tracker.summary(viewId)
  function refreshView() { view = tracker.summary(viewId) }
  onViewIdChanged: refreshView()
  Connections {
    target: tracker
    function onTracked() { root.refreshView() }
    function onSettingsChanged() { root.refreshView() }
    function onLoadedChanged() { root.refreshView() }
    function onTodayChanged() { root.refreshView() }
  }

  readonly property bool alarming: tracker.anyOverLimit
  readonly property bool viewAlarming: view && view.overLimit

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // ---------------------------------------------------------------- text

  readonly property var dayLocale: {
    var forced = String(tracker.languageSetting || "System").toLowerCase()
    if (forced === "pt") return Qt.locale("pt_BR")
    if (forced === "es") return Qt.locale("es_ES")
    if (forced === "en") return Qt.locale("en_US")
    return Qt.locale()
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    var name = root.dayLocale.dayName(parsed.getDay() === 0 ? 7 : parsed.getDay(), Locale.ShortFormat)
    name = String(name || "").replace(/\.$/, "")
    return name.charAt(0).toUpperCase() + name.slice(1)
  }

  function dayLabel(date, today) {
    return today ? tracker.t("today") : dayName(date)
  }

  function daySeconds(day) {
    if (!day) return 0
    return tracker.secondsFor(root.viewId, day.services || {})
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + String(parsed.getDate()).padStart(2, "0") + "/" + String(parsed.getMonth() + 1).padStart(2, "0")
    var text = label + " · " + tracker.formatMinutes(daySeconds(day))
    if (today && view && view.limitMin > 0) text += tracker.t("of_limit", { n: view.limitMin })
    // Per-service split for the "All" tab.
    if (root.viewId === "all") {
      var parts = []
      var services = tracker.services
      for (var i = 0; i < services.length; i++) {
        var s = Number((day.services || {})[services[i].id] || 0)
        if (s > 0) parts.push(services[i].name + " " + tracker.formatMinutes(s))
      }
      if (parts.length > 0) text += "\n" + parts.join(" · ")
    }
    return text
  }

  function statusText() {
    if (!tracker.loaded) return tracker.t("status_loading")
    if (!tracker.active) return tracker.t("status_idle")
    var name = tracker.serviceName(tracker.activeService)
    return tracker.t(tracker.reason === "listening" ? "status_listening" : "status_watching", { s: name })
  }

  function heroMeta() {
    var text = tracker.t("meta_today", { m: tracker.formatMinutes(view ? view.seconds : 0) })
    if (view && view.limitMin > 0) text += " · " + tracker.t("meta_limit", { n: view.limitMin })
    return text
  }

  function barLabel() {
    var glyph = tracker.active && tracker.serviceById(tracker.activeService)
      ? tracker.serviceById(tracker.activeService).glyph : root.idleGlyph
    if (!root.showMinutes || (bar && bar.vertical)) return glyph
    return glyph + " " + tracker.formatMinutes(tracker.todaySeconds)
  }

  function remainingText() {
    if (!view || view.limitMin <= 0) return tracker.t("no_limit")
    var left = view.limitSeconds - view.seconds
    if (left <= 0) return tracker.t("over_by", { m: tracker.formatMinutes(-left) })
    return tracker.t("left_until", { m: tracker.formatMinutes(left) })
  }

  readonly property real weekPeak: {
    var peak = 0
    var days = tracker.recentDays
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, daySeconds(days[i]))
    return Math.max(60, peak)
  }

  readonly property int weekSeconds: {
    var total = 0
    var days = tracker.recentDays
    for (var i = 0; i < days.length; i++) total += daySeconds(days[i])
    return total
  }

  // Rows for the per-service breakdown on the "All" tab, heaviest first.
  readonly property var serviceRows: {
    var rows = []
    var services = tracker.services
    var map = tracker.todayMap
    for (var i = 0; i < services.length; i++) {
      var s = tracker.summary(services[i].id)
      rows.push({ id: services[i].id, name: services[i].name, glyph: services[i].glyph, seconds: s.seconds, limitMin: s.limitMin, overLimit: s.overLimit })
    }
    rows.sort(function(a, b) { return b.seconds - a.seconds })
    var peak = rows.length > 0 ? Math.max(1, rows[0].seconds) : 1
    for (var j = 0; j < rows.length; j++) rows[j].share = rows[j].seconds / peak
    return rows
  }

  // ---------------------------------------------------------------- layout

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    Tracker.openCount = Math.max(0, Tracker.openCount + (opened ? 1 : -1))
    if (!opened) return
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    tracker.tick()
    refreshView()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // The bar creates one copy of this widget per monitor and only the first
  // copy's handler answers this target, so open/close/toggle here act on that
  // copy. To open the panel on the focused screen use the shell route:
  // `omarchy-shell shell summon io.github.albertojnk.screen-time '{}'`. Everything else
  // reads or writes the shared Tracker singleton, so any copy answers alike.
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function next(): string { root.selectTab(root.tabIndex + 1); return "ok" }
    function select(id: string): string { Tracker.selectedTab = String(id || "all"); return root.viewId }
    function today(): string { return JSON.stringify(tracker.todayMap) }
    function status(): string {
      return JSON.stringify({
        active: tracker.active,
        service: tracker.activeService,
        reason: tracker.reason,
        title: tracker.currentTitle,
        today: tracker.todayMap,
        todaySeconds: tracker.todaySeconds,
        recentDays: tracker.recentDays
      })
    }
    function reset(id: string): string { tracker.resetToday(id); return "ok" }
    function debug(): string { return JSON.stringify(tracker.debugSnapshot()) }
    function isOpen(): string { return String(Tracker.openCount) }
    // Which service a window title would be counted as, e.g.
    // `omarchy-shell io.github.albertojnk.screen-time probe "Netflix - Google Chrome"`.
    function probe(title: string): string {
      var svc = tracker.serviceForToplevel({ title: title, appId: "" })
      return svc ? svc.id : "none"
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barLabel()
    active: root.alarming || tracker.active
    activeColor: root.alarming ? root.urgent : root.foreground
    useActiveColor: root.alarming
    tooltipText: root.statusText() + " · " + tracker.t("meta_today", { m: tracker.formatMinutes(tracker.todaySeconds) })
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.selectTab(root.tabIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectTab(root.tabIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: tracker.tick()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") tracker.tick() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero ----------
          PanelHero {
            width: parent.width
            title: tracker.serviceName(root.viewId)
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.tab ? root.tab.glyph : root.idleGlyph
                color: root.viewAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Tab switch ----------
          Row {
            id: tabSwitch
            visible: root.tabs.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.tabs.length > 0
              ? (width - spacing * (root.tabs.length - 1)) / root.tabs.length
              : 0

            Repeater {
              model: root.tabs

              Button {
                required property var modelData
                required property int index

                width: tabSwitch.cellWidth
                text: modelData.glyph
                tooltipText: modelData.name
                selected: index === root.tabIndex
                hasCursor: root.cursorActive && index === root.tabIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.icon
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: {
                  root.cursorActive = true
                  root.selectTab(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }

          // ---------- Now ----------
          BorderSurface {
            width: parent.width
            implicitHeight: nowColumn.implicitHeight + Style.spacing.xl * 2
            color: tracker.active ? root.alpha(root.alarming ? root.urgent : root.foreground, 0.08) : root.alpha(root.foreground, 0.04)
            borderSpec: Border.flat(root.alpha(tracker.active ? (root.alarming ? root.urgent : root.foreground) : root.foreground, tracker.active ? 0.35 : 0.12), 1)
            radius: Style.cornerRadius

            Column {
              id: nowColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.statusText()
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: tracker.active
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                visible: text !== ""
                width: parent.width
                text: tracker.active ? tracker.currentTitle : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          // ---------- Today vs limit ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: tracker.t("section_today")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(todayLabel.implicitHeight, todayValue.implicitHeight)

              Text {
                id: todayLabel
                textFormat: Text.PlainText
                text: root.view && root.view.limitMin > 0 ? tracker.t("daily_limit") : tracker.t("time_today")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: todayValue
                textFormat: Text.PlainText
                text: root.view && root.view.limitMin > 0
                  ? tracker.formatMinutes(root.view.seconds) + " / " + root.view.limitMin + " min"
                  : tracker.formatMinutes(root.view ? root.view.seconds : 0)
                color: root.viewAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: root.view && root.view.limitMin > 0
              width: parent.width
              value: root.view ? root.view.ratio : -1
              alarming: root.viewAlarming || (root.view && root.view.nearLimit)
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.remainingText()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- Per-service breakdown (All tab) ----------
          PanelSeparator {
            visible: serviceSection.visible
            foreground: root.foreground
          }

          Column {
            id: serviceSection
            visible: root.viewId === "all" && root.serviceRows.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: tracker.t("section_services")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.serviceRows

              ServiceRow {
                required property var modelData
                width: serviceSection.width
                row: modelData
              }
            }
          }

          // ---------- Last 7 days ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            id: weekSection
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: tracker.t("section_week")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: tracker.recentDays

              DayRow {
                required property var modelData
                width: weekSection.width
                day: modelData
                seconds: root.daySeconds(modelData)
                ratio: root.daySeconds(modelData) / root.weekPeak
                today: String(modelData.date || "") === tracker.today
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              topPadding: Style.space(4)
              text: tracker.t("week_total", { t: tracker.formatMinutes(root.weekSeconds),
                                              a: tracker.formatMinutes(Math.round(root.weekSeconds / 7)) })
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            topPadding: Style.space(2)
            text: "omarchy bar set " + root.moduleName + " " + (root.viewId === "all" ? "dailyLimitMin" : "limit" + root.viewId.charAt(0).toUpperCase() + root.viewId.slice(1) + "Min") + " 90 --json"
            color: root.alpha(root.dim, 0.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // Rounded track showing how much of the daily limit is used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  // Service rows read as a table: the share bar fills the row behind the
  // label, scaled to the heaviest service. Click one to open its tab.
  component ServiceRow: Item {
    id: serviceRow
    property var row: null

    implicitHeight: serviceName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(serviceRow.row ? serviceRow.row.share : 0, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(serviceRow.row && serviceRow.row.overLimit ? root.urgent : root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: serviceName
      textFormat: Text.PlainText
      text: serviceRow.row ? serviceRow.row.glyph + "  " + serviceRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: serviceMinutes.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: serviceMinutes
      textFormat: Text.PlainText
      text: serviceRow.row
        ? tracker.formatMinutes(serviceRow.row.seconds) + (serviceRow.row.limitMin > 0 ? " / " + serviceRow.row.limitMin + "m" : "")
        : ""
      color: serviceRow.row && serviceRow.row.overLimit ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (serviceRow.row) { root.cursorActive = true; Tracker.selectedTab = serviceRow.row.id }
    }
  }

  // One row per day: label, bar, minutes. Today is bold in full foreground.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property int seconds: 0
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(44)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? (root.viewAlarming ? root.urgent : root.foreground) : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }

      // Limit marker on every day's track so the week reads against the goal.
      Rectangle {
        visible: root.view && root.view.limitSeconds > 0 && root.view.limitSeconds < root.weekPeak
        x: parent.width * root.clamp((root.view ? root.view.limitSeconds : 0) / root.weekPeak, 0, 1) - width / 2
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(1, Style.space(1))
        height: parent.height * 2.2
        color: root.alpha(root.urgent, 0.8)
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: tracker.formatMinutes(dayRow.seconds)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(56)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }
}
