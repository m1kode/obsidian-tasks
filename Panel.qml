import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Open tasks from an Obsidian vault, read straight off the markdown.
//
// The vault is the only state this widget has. Nothing is cached, so a task
// added on a phone appears as soon as the next scan lands, and a task ticked
// here is a rewritten line on disk that sync carries back out. Every read and
// write goes through bin/obsidian-tasks; this file only decides what to show.
Panel {
  id: root
  moduleName: "m1kode.obsidian-tasks"
  ipcTarget: "m1kode.obsidian-tasks"

  readonly property string glyphBar: String.fromCodePoint(0xF0135)
  readonly property string glyphOpen: String.fromCodePoint(0xF0131)
  readonly property string glyphDone: String.fromCodePoint(0xF0132)
  readonly property string glyphCog: String.fromCodePoint(0xF0493)

  readonly property string home: Quickshell.env("HOME") || ""
  // The configured path, if any. Resolution lives in the helper: an explicit
  // setting wins, otherwise Obsidian's own vault registry is asked.
  readonly property string vaultHint: String(setting("vaultPath", ""))
  property string vaultPath: ""
  property string vaultSource: "none"
  property bool vaultExists: false
  // No explicit setting yet. Whatever was detected is a suggestion until the
  // user confirms it, not a decision made on their behalf.
  readonly property bool vaultUnconfigured: root.vaultHint === ""
  // Revealed by the gear once a vault is set; before that the field is the
  // whole point and stands on its own.
  property bool settingsOpen: false
  readonly property bool vaultRowVisible: root.vaultUnconfigured || root.settingsOpen
  // Detection only ever supplies a suggested value for the field. Nothing is
  // read or written until that path has been saved, so the widget never acts
  // on a folder the user hasn't agreed to.
  readonly property bool vaultActive: !root.vaultUnconfigured && root.vaultExists
  readonly property string displayVault: vaultPath === "" ? "" : vaultPath.replace(root.home, "~")
  // Empty without a vault, rather than a relative path left dangling off the
  // filesystem root: the bad value shouldn't be constructible in the first place.
  readonly property string inboxPath: root.vaultActive
    ? vaultPath + "/" + String(setting("inboxFile", "Inbox.md"))
    : ""
  readonly property string countMode: String(setting("countMode", "all"))
  readonly property int refreshIntervalSec: Math.max(10, Number(setting("refreshIntervalSec", 60)))
  // Shipped beside the QML so the plugin stays one directory to install or remove.
  readonly property string helper: Qt.resolvedUrl("bin/obsidian-tasks").toString().replace("file://", "")

  property var tasks: []
  property bool everScanned: false
  // Tasks ticked within the fade window: written to disk already, still drawn
  // so the tick is visible and still reversible.
  property var justDone: []
  property string editingRaw: ""
  property int cursor: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string today: isoDate(new Date())

  readonly property var openTasks: (tasks || []).filter(function (t) { return t.open })
  readonly property var dueTasks: openTasks.filter(function (t) { return t.due !== "" && t.due <= root.today })
  readonly property int badgeCount: countMode === "due" ? dueTasks.length : openTasks.length

  // Dated tasks first and in date order, because those are the ones with a
  // deadline attached; undated ones keep their priority order behind them.
  readonly property var rows: openTasks.concat(justDone).sort(function (a, b) {
    var ad = a.due === "" ? "9999-99-99" : a.due
    var bd = b.due === "" ? "9999-99-99" : b.due
    if (ad !== bd) return ad < bd ? -1 : 1
    if (a.priority !== b.priority) return a.priority - b.priority
    return a.label.localeCompare(b.label)
  })

  readonly property string summary: {
    if (root.vaultUnconfigured) return "No vault set"
    if (!root.vaultExists) return "Vault not found"
    if (!everScanned) return "Reading vault…"
    if (openTasks.length === 0) return "Nothing open"
    var line = openTasks.length + (openTasks.length === 1 ? " open task" : " open tasks")
    return dueTasks.length > 0 ? line + " · " + dueTasks.length + " due" : line
  }

  function expand(path) {
    return path.indexOf("~") === 0 ? root.home + path.substring(1) : path
  }

  function isoDate(d) {
    return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2)
  }

  // Relative wording only within a day either side; past that a bare date says
  // more than counting days out loud does.
  function dueLabel(due) {
    if (due === "") return ""
    if (due < root.today) return "overdue"
    if (due === root.today) return "today"
    var t = new Date()
    t.setDate(t.getDate() + 1)
    return due === isoDate(t) ? "tomorrow" : due
  }

  function refresh() {
    if (!root.vaultActive) {
      root.tasks = []
      root.everScanned = true
      return
    }
    if (!scanProc.running) scanProc.running = true
  }

  function resolveVault() {
    if (vaultProc.running) return
    vaultProc.ranWith = root.vaultHint
    vaultProc.command = [root.helper, "vault", root.vaultHint]
    vaultProc.running = true
  }

  function chooseVault(input) {
    var path = root.expand(String(input || "").replace(/^file:\/\//, "").trim())
    if (path === "") return
    root.settingsOpen = false
    // Written through `omarchy bar set` rather than by editing shell.json here,
    // so the setting lands the same way it would if typed by hand.
    setVaultProc.command = ["omarchy", "bar", "set", root.moduleName, "vaultPath", path]
    setVaultProc.running = true
  }

  function completeTask(task) {
    if (!task || editProc.running) return
    // The exact line, not its number: sync can rewrite the file between the
    // scan that drew this row and the click that ticks it, and the helper
    // would rather do nothing than tick whatever moved into that position.
    editProc.mode = "complete"
    editProc.subject = task
    editProc.command = [root.helper, "complete", root.vaultPath, task.file, task.raw]
    editProc.running = true
  }

  // Keep the ticked row on screen, checked and struck through, until the sweep
  // retires it. `doneRaw` is the line as it now reads on disk, which is what an
  // undo has to address.
  function markJustDone(task, doneRaw) {
    var entry = {}
    for (var key in task) entry[key] = task[key]
    entry.doneRaw = doneRaw
    entry.retireAt = Date.now() + 1800
    root.justDone = root.justDone.concat([entry])
  }

  function undoTask(entry) {
    if (!entry || editProc.running) return
    root.justDone = root.justDone.filter(function (e) { return e.doneRaw !== entry.doneRaw })
    editProc.mode = "uncomplete"
    editProc.subject = null
    editProc.command = [root.helper, "uncomplete", entry.file, entry.doneRaw]
    editProc.running = true
  }

  function beginEdit(task) {
    if (!task || task.doneRaw !== undefined) return
    root.editingRaw = task.raw
  }

  // Leaving edit mode has to outlive the keystroke that ended it. Clearing
  // editingRaw synchronously unblocks the key catcher while that same Enter or
  // Escape is still propagating, and the catcher then reads it as "tick this
  // task" or "close the panel". Let the event finish first.
  function endEdit() {
    Qt.callLater(function () { root.editingRaw = "" })
  }

  function cancelEdit() {
    endEdit()
  }

  function renameTask(task, text) {
    endEdit()
    if (!task || editProc.running) return
    if (String(text).trim() === "" || String(text).trim() === task.label) return
    editProc.mode = "rename"
    editProc.subject = null
    editProc.command = [root.helper, "rename", root.vaultPath, task.file, task.raw, String(text)]
    editProc.running = true
  }

  function addTask(text) {
    if (!root.vaultActive || editProc.running || String(text).trim() === "") return
    editProc.mode = "add"
    editProc.subject = null
    editProc.command = [root.helper, "add", root.vaultPath, root.inboxPath, String(text)]
    editProc.running = true
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    cursorActive = true
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + delta))
  }

  onOpenedChanged: {
    if (opened) {
      cursor = 0
      cursorActive = false
      editingRaw = ""
      justDone = []
      settingsOpen = false
      refresh()
    }
  }

  onRowsChanged: if (cursor >= rows.length) cursor = Math.max(0, rows.length - 1)

  Process {
    id: vaultProc
    // The hint this run was started with. The bar injects settings after the
    // component is built, so the first resolve necessarily runs against an
    // empty one; without this the answer to a question nobody asked would win.
    property string ranWith: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var found = JSON.parse(String(text || "{}"))
          root.vaultPath = String(found.path || "")
          root.vaultSource = String(found.source || "none")
          root.vaultExists = found.exists === true
        } catch (e) {
          console.warn("m1kode.obsidian-tasks: could not resolve vault", e)
          root.vaultExists = false
        }
        if (vaultProc.ranWith !== root.vaultHint) Qt.callLater(root.resolveVault)
        else root.refresh()
      }
    }
  }

  Process {
    id: setVaultProc
    onExited: root.resolveVault()
  }

  onVaultHintChanged: root.resolveVault()
  Component.onCompleted: root.resolveVault()

  Process {
    id: scanProc
    command: [root.helper, "scan", root.vaultPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "[]"))
          root.tasks = Array.isArray(parsed) ? parsed : []
        } catch (e) {
          console.warn("m1kode.obsidian-tasks: could not parse scan output", e)
          root.tasks = []
        }
        root.everScanned = true
      }
    }
  }

  // Every edit is followed by a rescan rather than a local mutation, so what
  // the popup shows is always what is actually on disk.
  Process {
    id: editProc
    property string mode: ""
    property var subject: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var line = String(text || "").trim()
        if (editProc.mode === "complete" && line !== "" && editProc.subject)
          root.markJustDone(editProc.subject, line)
        editProc.subject = null
      }
    }
    onExited: root.refresh()
  }

  // Retires faded rows a beat after they were ticked. One sweeper rather than a
  // timer per row, so a burst of ticking cannot pile up timers.
  Timer {
    interval: 300
    running: root.justDone.length > 0
    repeat: true
    onTriggered: {
      var now = Date.now()
      var live = root.justDone.filter(function (e) { return e.retireAt > now })
      if (live.length !== root.justDone.length) root.justDone = live
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyphBar
    // Lit or dim, and nothing else. `active` would paint the button in the
    // theme's urgent colour, which every stock dark theme defines darker than
    // its foreground -- so the state meant to stand out rendered dimmer than
    // the ordinary one, and on a monochrome theme it read as switched off.
    // What is due is said in the tooltip and shown in the popup instead.
    dimmed: root.badgeCount === 0
    tooltipText: root.summary
    onPressed: function (code) {
      if (code === Qt.RightButton) root.refresh()
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: addField.activeFocus || root.editingRaw !== ""
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) root.moveCursor(dy > 0 ? 1 : -1)
      }
      onActivateRequested: {
        if (!root.cursorActive) return
        var task = root.rows[root.cursor]
        if (!task) return
        if (task.doneRaw !== undefined) root.undoTask(task)
        else root.completeTask(task)
      }
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      // hjkl drive the cursor, so capture lives behind "a" rather than
      // swallowing every letter the moment the panel opens.
      onTextKey: function (t) {
        if (t === "a" || t === "A") { if (root.vaultActive) addField.forceActiveFocus() }
        else if (t === "r" || t === "R") root.refresh()
        else if (t === "e" || t === "E") {
          if (root.cursorActive) root.beginEdit(root.rows[root.cursor])
        }
      }

      Flickable {
        id: flick
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
          width: flick.width
          spacing: Style.space(8)

          // Hero: icon · title over status, laid out like the audio panel so
          // the two read as the same kind of popup.
          Item {
            id: hero
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight,
              Math.max(heroLabels.implicitHeight, gearButton.implicitHeight))

            Text {
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.glyphBar
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.openTasks.length === 0 ? 0.5 : 1.0
            }

            PanelActionButton {
              id: gearButton
              visible: !root.vaultUnconfigured
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.glyphCog
              tooltipText: root.settingsOpen ? "Hide vault path" : "Change vault"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.settingsOpen = !root.settingsOpen
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: gearButton.visible ? gearButton.width + Style.space(12) : 0
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: "Tasks"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.summary.toUpperCase()
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // Shown until a vault is set explicitly, pre-filled with whatever
          // Obsidian reported. Confirming is one keystroke; correcting it is
          // obvious. The alternative — silently adopting a folder and never
          // saying which — is how you end up staring at the wrong vault.
          Column {
            width: parent.width
            visible: root.vaultRowVisible
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: !root.vaultUnconfigured
                ? "Vault — Enter to change it."
                : (root.vaultPath === ""
                   ? "Where do your notes live?"
                   : "Found Obsidian's vault. Enter to use it.")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Typed rather than browsed on purpose: a native folder dialog
            // pulls GTK3 and gvfs into the shell process, where a synchronous
            // gvfs call aborts and takes the whole bar down with it.
            TextField {
              id: vaultField
              width: parent.width
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              placeholderText: "Path to your vault, e.g. ~/Notes"
              onAccepted: root.chooseVault(text)
              Component.onCompleted: text = root.displayVault
              Connections {
                target: root
                function onDisplayVaultChanged() {
                  if (!vaultField.activeFocus) vaultField.text = root.displayVault
                }
                // Closing without saving discards the edit, so reopening offers
                // the suggestion again rather than yesterday's abandoned typing.
                function onOpenedChanged() {
                  if (root.opened) vaultField.text = root.displayVault
                }
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: root.foreground
            }
          }

          Repeater {
            model: root.rows

            Item {
              id: row
              required property var modelData
              required property int index

              width: column.width
              implicitHeight: Math.max(rowLabel.implicitHeight, Style.space(24))

              // A row carrying doneRaw was ticked a moment ago: still on screen
              // so the tick is visible, and still clickable so it can be undone.
              readonly property bool done: modelData.doneRaw !== undefined
              readonly property bool editing: root.editingRaw === modelData.raw
              readonly property bool overdue: !done && modelData.due !== "" && modelData.due < root.today
              readonly property bool hot: boxMouse.containsMouse || labelMouse.containsMouse
                || (root.cursorActive && root.cursor === index)

              Behavior on opacity { NumberAnimation { duration: 260 } }
              opacity: done ? 0.45 : 1.0

              Rectangle {
                anchors.fill: parent
                anchors.leftMargin: -Style.space(6)
                anchors.rightMargin: -Style.space(6)
                radius: Style.cornerRadius
                color: row.hot ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent"
              }

              // The box is the only thing that ticks a task off, so clicking
              // the words can mean editing them instead.
              Text {
                id: box
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: row.done ? root.glyphDone : root.glyphOpen
                color: row.done ? root.accent : (boxMouse.containsMouse ? root.accent : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body

                MouseArea {
                  id: boxMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: { root.cursorActive = true; root.cursor = row.index }
                  onClicked: row.done ? root.undoTask(row.modelData) : root.completeTask(row.modelData)
                }
              }

              Text {
                id: rowLabel
                visible: !row.editing
                anchors.left: box.right
                anchors.leftMargin: Style.space(8)
                anchors.right: dueBadge.visible ? dueBadge.left : parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.strikeout: row.done
                elide: Text.ElideRight
                wrapMode: Text.NoWrap

                MouseArea {
                  id: labelMouse
                  anchors.fill: parent
                  enabled: !row.done
                  hoverEnabled: true
                  cursorShape: Qt.IBeamCursor
                  onEntered: { root.cursorActive = true; root.cursor = row.index }
                  onClicked: root.beginEdit(row.modelData)
                }
              }

              TextField {
                id: rowEdit
                visible: row.editing
                anchors.left: box.right
                anchors.leftMargin: Style.space(4)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.foreground
                accent: root.accent
                verticalPadding: 2
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onVisibleChanged: if (visible) { text = row.modelData.label; selectAll(); forceActiveFocus() }
                onAccepted: root.renameTask(row.modelData, text)
                Keys.onEscapePressed: root.cancelEdit()
                // Clicking away is a cancel, not a silent save: a half-typed
                // edit losing focus should not rewrite the vault.
                onActiveFocusChanged: if (!activeFocus && row.editing) root.cancelEdit()
              }

              Text {
                id: dueBadge
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !row.editing && row.modelData.due !== ""
                text: root.dueLabel(row.modelData.due)
                color: row.overdue ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            width: parent.width
            visible: !root.vaultUnconfigured && root.everScanned && root.rows.length === 0
            text: root.vaultExists
              ? "No open tasks in " + root.displayVault
              : "Vault not found at " + root.displayVault
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            width: parent.width
            visible: root.vaultActive
          }

          TextField {
            id: addField
            visible: root.vaultActive
            width: parent.width
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            placeholderText: "Add a task — try \"pay rent friday\""
            onAccepted: {
              root.addTask(text)
              text = ""
            }
            Keys.onEscapePressed: {
              text = ""
              keyCatcher.forceActiveFocus()
            }
          }
        }
      }
    }
  }
}
