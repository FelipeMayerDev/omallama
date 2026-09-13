import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Ollama in the bar. The widget owns no state of its own: everything shown is
// read back from the Ollama HTTP API (/api/tags, /api/ps), so the panel and
// `ollama` in a terminal can never disagree. The switch drives the systemd
// unit; polkit asks for the password when it needs to.
Panel {
  id: root
  moduleName: "io.github.felipemayerdev.omallama"
  ipcTarget: "io.github.felipemayerdev.omallama"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color panelText: Color.popups.text

  readonly property string localApi: "http://127.0.0.1:11434"

  // A remote server is remembered even while the widget is pointed at the
  // local one, so the two are one switch apart rather than a re-typed address.
  readonly property string remoteHost: {
    var h = String(root.setting("host", "")).trim().replace(/\/+$/, "")
    if (h === "") return ""
    return /^https?:\/\//.test(h) ? h : "http://" + h
  }

  readonly property bool useRemote: root.remoteHost !== "" && root.setting("remote", false) === true

  readonly property string api: root.useRemote ? root.remoteHost : root.localApi

  readonly property string hostLabel: root.api.replace(/^https?:\/\//, "")
  readonly property string remoteLabel: root.remoteHost.replace(/^https?:\/\//, "")

  // The address is user-entered and reaches a shell command line when a pull
  // runs in a terminal, so it is checked there against exactly what a URL for
  // this needs: scheme, host, optional port and path.
  readonly property bool safeHost:
    /^https?:\/\/[A-Za-z0-9._:\[\]-]+(\/[A-Za-z0-9._\/-]*)?$/.test(root.api)

  // "Local" is the server this machine's systemd unit owns; a remote address
  // that happens to name localhost is still someone else's to start.
  readonly property bool isLocal: !root.useRemote

  // Only a local server can be missing a local binary.
  readonly property bool needsInstall: root.isLocal && !root.installed

  property bool installed: true       // assume yes until `which` says otherwise
  property bool serverUp: false
  property bool busy: false
  property var models: []             // [{name, size, ctx}]
  property var loaded: null           // {name, ctx, max, vram}
  property string lastError: ""
  property string kind: ""            // user | system | stopped
  property string pulling: ""         // model name while an API pull is in flight
  property string pendingDelete: ""   // model name waiting on the confirm dialog

  readonly property string cli:
    Qt.resolvedUrl("bin/omallama").toString().replace(/^file:\/\//, "")

  // Share of the model's own maximum context that the loaded instance was
  // given. Ollama exposes the window it loaded, not tokens consumed, so this
  // is how much context is available, not how much is filled.
  readonly property int ctxPercent:
    (loaded && loaded.max > 0) ? Math.round(loaded.ctx * 100 / loaded.max) : 0

  readonly property string statusLine: {
    if (root.needsInstall) return "Ollama is not installed"
    if (root.lastError !== "") return root.lastError
    if (!root.serverUp) return root.isLocal ? "Server stopped" : "No answer from " + root.hostLabel
    if (root.pulling !== "") return "Pulling " + root.pulling + "…"
    if (!root.isLocal) return root.loaded ? root.loaded.name + " on " + root.hostLabel
                                          : root.hostLabel
    if (root.loaded) return root.loaded.name + " loaded"
    return root.kind === "system" ? "Server running (system service)" : "Server running"
  }

  function shortName(n) { return String(n || "").replace(/:latest$/, "") }

  function human(bytes) {
    var gb = Number(bytes) / 1e9
    if (!isFinite(gb) || gb <= 0) return ""
    return gb >= 10 ? gb.toFixed(0) + " GB" : gb.toFixed(1) + " GB"
  }

  function tokens(n) {
    n = Number(n) || 0
    return n >= 1000 ? Math.round(n / 1024) + "K" : String(n)
  }

  function get(path, onOk) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (xhr.status === 200) {
        try { onOk(JSON.parse(xhr.responseText)) } catch (e) { /* torn read; next tick */ }
      } else {
        // No answer at all means the server is down, which is a state, not an
        // error. Only a real HTTP failure gets reported.
        root.serverUp = false
        root.loaded = null
        root.models = []
        if (xhr.status !== 0) root.lastError = "Ollama replied " + xhr.status
      }
    }
    xhr.open("GET", root.api + path)
    xhr.send()
  }

  function refresh() {
    if (root.needsInstall) return
    if (root.isLocal && root.opened && !kindProc.running) kindProc.running = true
    root.get("/api/tags", function (d) {
      root.serverUp = true
      root.lastError = ""
      var out = (d.models || []).map(function (m) {
        return { name: m.name, size: m.size, ctx: (m.details && m.details.context_length) || 0 }
      })
      out.sort(function (a, b) { return b.size - a.size })
      root.models = out
      root.get("/api/ps", function (p) {
        var run = (p.models || [])[0]
        if (!run) { root.loaded = null; return }
        var max = 0
        for (var i = 0; i < root.models.length; i++)
          if (root.models[i].name === run.name) max = root.models[i].ctx
        root.loaded = {
          name: run.name,
          ctx: run.context_length || 0,
          max: max,
          vram: run.size_vram || 0
        }
      })
    })
  }

  // Pull where the model has to land. With a local CLI the download runs in a
  // terminal, where it can be watched and cancelled; without one — a remote
  // host on a machine that has no ollama binary — it goes over the API and the
  // panel says so until the model shows up in the list.
  function pull(name) {
    if (root.installed) {
      if (!root.safeHost) { root.lastError = "Address is not a URL"; return }
      root.close()
      var env = root.isLocal ? "" : "env OLLAMA_HOST=" + root.api + " "
      if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation " + env + "ollama pull " + name)
      return
    }
    root.pulling = name
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      root.pulling = ""
      if (xhr.status !== 200) root.lastError = "Could not pull " + name
      root.refresh()
    }
    xhr.open("POST", root.api + "/api/pull")
    xhr.setRequestHeader("Content-Type", "application/json")
    xhr.send(JSON.stringify({ model: name, stream: false }))
  }

  // Settings live in the bar config, which is also where the bar's own
  // settings pane writes them: one source of truth, two ways in.
  function writeSetting(changes) {
    var merged = ({})
    var current = root.settings || ({})
    for (var k in current) merged[k] = current[k]
    for (var c in changes) merged[c] = changes[c]
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, merged)
  }

  function remove(name) {
    if (!root.safeHost) { root.lastError = "Address is not a URL"; return }
    root.lastError = ""
    removal.command = [root.cli, "rm", root.api, name]
    removal.running = true
  }

  function control(verb) {
    root.busy = true
    root.lastError = ""
    unit.command = [root.cli, verb]
    unit.running = true
  }

  Process {
    id: which
    running: true
    command: ["sh", "-c", "command -v ollama"]
    onExited: function (code) { root.installed = (code === 0); root.refresh() }
  }

  Process {
    id: kindProc
    running: false
    command: [root.cli, "status"]
    stdout: StdioCollector { id: kindOut; waitForEnd: true
      onStreamFinished: root.kind = String(text || "").trim() }
  }

  Process {
    id: removal
    running: false
    command: []
    onExited: function (code) {
      if (code !== 0) root.lastError = "Could not delete the model"
      root.refresh()
    }
  }

  Process {
    id: unit
    running: false
    command: []
    stderr: StdioCollector { id: unitErr; waitForEnd: true }
    onExited: function (code) {
      root.busy = false
      if (code !== 0) root.lastError = String(unitErr.text || "").split("\n")[0] || "systemctl failed"
      settle.restart()
    }
  }

  // `systemctl start` returns before the server is listening.
  Timer { id: settle; interval: 800; repeat: true; triggeredOnStart: true
    property int ticks: 0
    onTriggered: { root.refresh(); if (++ticks > 6) { ticks = 0; stop() } }
    onRunningChanged: if (running) ticks = 0
  }

  Timer {
    running: !root.needsInstall
    interval: root.opened ? 2000 : 15000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.serverUp

    // Wrapped: a Loader resizes whatever it loads to its own size, and the
    // mark has to keep the size it asks for.
    iconComponent: Component {
      Item {
        OllamaIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: button.active && button.useActiveColor ? button.activeColor : button.foreground
          // Off is not absent: the dimmed mark says the plugin is there and
          // the server is not.
          opacity: root.serverUp ? 1.0 : 0.55
        }
      }
    }
    activeColor: root.loaded ? Color.accent : Color.popups.text
    tooltipText: root.statusLine + "\nClick for Ollama"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(col.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      // Deleting is the one thing here that cannot be undone with a click, so
      // it goes through the same dialog the rest of Omarchy uses.
      ConfirmDialog {
        anchors.fill: parent
        z: 10
        opened: root.pendingDelete !== ""
        message: "Delete " + root.shortName(root.pendingDelete) + "?"
        confirmText: "Delete"
        foreground: root.panelText
        background: Color.popups.background
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onConfirmed: { root.remove(root.pendingDelete); root.pendingDelete = "" }
        onCanceled: root.pendingDelete = ""
      }

      Column {
        id: col
        width: parent.width
        spacing: Style.spacing.controlGap

        PanelSectionHeader {
          text: root.statusLine
          foreground: root.panelText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        // Nothing below this line makes sense without the binary, so when it
        // is missing the panel says so and stops.
        Text {
          visible: root.needsInstall
          width: col.width
          text: "Install it with `sudo pacman -S ollama` (or ollama-cuda / ollama-rocm for GPU), or point this widget at another machine in the bar settings."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.panelText
          opacity: 0.75
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Item {
          visible: !root.needsInstall
          width: col.width
          height: Style.spacing.controlHeight

          OllamaIcon {
            id: srvIcon
            iconSize: Math.round(Style.font.icon * 0.9)
            color: root.serverUp ? Color.accent : root.panelText
            opacity: root.serverUp ? 1.0 : 0.7
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: root.isLocal ? "Ollama server" : root.hostLabel
            textFormat: Text.PlainText
            color: root.panelText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            anchors.left: srvIcon.right
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
          }

          // A remote server is someone else's to start; all this end can do is
          // say whether it answers.
          Text {
            visible: !root.isLocal
            text: root.serverUp ? "reachable" : "no answer"
            textFormat: Text.PlainText
            color: root.serverUp ? Color.accent : root.panelText
            opacity: root.serverUp ? 1.0 : 0.7
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }

          ToggleSwitch {
            visible: root.isLocal
            checked: root.serverUp
            busy: root.busy
            foreground: root.panelText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.control(root.serverUp ? "stop" : "start")
          }
        }

        // Which of the two servers the widget is talking to. Shown only once a
        // remote one is configured — with nothing to switch to, a switch is
        // just a control that does nothing.
        Item {
          visible: root.remoteHost !== ""
          width: col.width
          height: Style.spacing.controlHeight

          Text {
            id: targetLabel
            text: "Use " + root.remoteLabel
            textFormat: Text.PlainText
            elide: Text.ElideRight
            width: parent.width - targetSwitch.width - Style.space(12)
            color: root.panelText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          ToggleSwitch {
            id: targetSwitch
            checked: root.useRemote
            foreground: root.panelText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: {
              root.writeSetting({ "remote": !root.useRemote })
              // The address changed under the poll; do not leave the old
              // server's models on screen while the new one answers.
              root.models = []
              root.loaded = null
              root.lastError = ""
              root.refresh()
            }
          }
        }

        // Address editor, folded away until asked for: most people set this
        // once and never look at it again.
        Column {
          id: config
          visible: configOpen
          width: col.width
          spacing: Style.space(6)

          property bool configOpen: false

          Text {
            width: config.width
            text: "Address of an Ollama server on another machine."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.panelText
            opacity: 0.7
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            width: config.width
            spacing: Style.spacing.sm

            TextField {
              id: hostField
              width: config.width - saveHost.implicitWidth - Style.spacing.sm
              text: root.remoteHost
              placeholderText: "192.168.1.10:11434"
              foreground: root.panelText
              onAccepted: saveHost.save()
            }

            PanelActionButton {
              id: saveHost
              iconText: "󰄬"
              tooltipText: "Save the address"
              foreground: root.panelText
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: save()

              // Clearing the field forgets the remote and falls back to local,
              // which is the only way out that leaves no dead address behind.
              function save() {
                var h = hostField.text.trim()
                if (h !== "" && !/^(https?:\/\/)?[A-Za-z0-9._:\[\]-]+(\/[A-Za-z0-9._\/-]*)?$/.test(h)) {
                  root.lastError = "Address is not a URL"
                  return
                }
                root.writeSetting({ "host": h, "remote": h !== "" })
                root.models = []
                root.loaded = null
                root.lastError = ""
                config.configOpen = false
                root.refresh()
              }
            }
          }
        }

        PanelSeparator { visible: !root.needsInstall; width: col.width; foreground: root.panelText }

        // Loaded model and its context window.
        PanelSectionHeader {
          visible: root.loaded !== null
          text: "In use"
          foreground: root.panelText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Column {
          visible: root.loaded !== null
          width: col.width
          spacing: Style.space(4)

          Item {
            width: parent.width
            height: ctxLabel.implicitHeight

            Text {
              text: root.loaded ? root.shortName(root.loaded.name) : ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              width: parent.width * 0.55
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: parent.left
            }

            Text {
              id: ctxLabel
              text: root.loaded
                ? root.tokens(root.loaded.ctx) + " / " + root.tokens(root.loaded.max) + " ctx · " + root.ctxPercent + "%"
                : ""
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignRight
              width: parent.width * 0.43
              color: root.panelText
              opacity: 0.75
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.right: parent.right
            }
          }

          Rectangle {
            width: parent.width
            height: Math.max(2, Style.space(3))
            radius: height / 2
            color: root.panelText
            opacity: 0.2

            Rectangle {
              width: parent.width * Math.max(0, Math.min(100, root.ctxPercent)) / 100
              height: parent.height
              radius: parent.radius
              color: Color.accent
              opacity: 1.0
            }
          }
        }

        PanelSeparator { visible: root.loaded !== null; width: col.width; foreground: root.panelText }

        PanelSectionHeader {
          visible: root.serverUp
          text: root.models.length > 0 ? "Models (" + root.models.length + ")" : "No models yet"
          foreground: root.panelText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        // An empty list under the packaged unit is not an empty disk: that
        // server runs as the `ollama` user and cannot see ~/.ollama.
        Text {
          visible: root.serverUp && root.models.length === 0 && root.isLocal && root.kind === "system"
          width: col.width
          text: "The packaged ollama.service runs as the ollama user and keeps models in /var/lib/ollama. Switch off and on again to run Ollama as you, with everything in ~/.ollama."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.panelText
          opacity: 0.7
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Repeater {
          model: root.models.slice(0, 6)

          Item {
            id: row
            required property var modelData
            width: col.width
            height: Style.spacing.controlHeight

            readonly property bool hovered: rowHover.containsMouse || trash.containsMouse

            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
            }

            Text {
              width: parent.width * 0.62
              text: root.shortName(row.modelData.name)
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: (root.loaded && root.loaded.name === row.modelData.name) ? Color.accent : root.panelText
              opacity: 0.9
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            // The size gives way to the bin on hover: one slot, so the row
            // never reflows under the pointer.
            Text {
              visible: !row.hovered
              width: parent.width * 0.34
              text: root.human(row.modelData.size)
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignRight
              color: root.panelText
              opacity: 0.6
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: trashIcon
              visible: row.hovered
              text: "󰩹"
              textFormat: Text.PlainText
              color: trash.containsMouse ? Color.urgent : root.panelText
              opacity: trash.containsMouse ? 1.0 : 0.7
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                id: trash
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Gigabytes take minutes to get back, so the click asks first.
                onClicked: root.pendingDelete = row.modelData.name
              }
            }
          }
        }

        Text {
          visible: root.serverUp && root.models.length > 6
          width: col.width
          text: "+ " + (root.models.length - 6) + " more"
          textFormat: Text.PlainText
          color: root.panelText
          opacity: 0.5
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator { visible: root.serverUp; width: col.width; foreground: root.panelText }

        // Pull runs in a floating terminal: a download with a progress bar
        // belongs where it can be watched and cancelled, not behind a spinner.
        //
        // The row itself survives an unreachable server, because the gear that
        // fixes a wrong address lives in it.
        Row {
          visible: !root.needsInstall
          width: col.width
          spacing: Style.spacing.sm

          TextField {
            id: pullField
            visible: root.serverUp
            width: col.width - pullButton.implicitWidth - gearButton.implicitWidth - 2 * Style.spacing.sm
            placeholderText: "add model, e.g. llama3.2:3b"
            foreground: root.panelText
            onAccepted: pullButton.pull()
          }

          PanelActionButton {
            id: gearButton
            iconText: "󰒓"
            tooltipText: root.remoteHost === "" ? "Point at a remote server" : "Change the address"
            foreground: root.panelText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: {
              config.configOpen = !config.configOpen
              if (config.configOpen) hostField.forceActiveFocus()
            }
          }

          PanelActionButton {
            id: pullButton
            iconText: "󰇚"
            tooltipText: "Pull the model"
            foreground: root.panelText
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: pull()

            function pull() {
              // Model names are letters, digits and : . _ - / only. Anything
              // else is not a model name and never reaches the shell.
              var name = pullField.text.trim()
              if (name === "" || !/^[A-Za-z0-9._:\/-]+$/.test(name)) {
                root.lastError = "Not a model name"
                return
              }
              pullField.text = ""
              root.pull(name)
            }
          }
        }
      }
    }
  }
}
