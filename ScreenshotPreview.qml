import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Effects
import qs.Commons

// Shottr-style capture preview.
//
// omarchy-screenshot-jpeg summons this panel with the capture path and the
// cursor position, and it drops a small card next to the pointer: the shot,
// a drag strip, a close button, and an icon row (Edit / Copy / Save / OCR /
// Pin) whose shortcuts show on hover. Pin promotes the shot to a frameless
// always-on-top window that can be dragged and scroll-zoomed, matching
// Shottr's pinning.
//
// Everything with a side effect goes through actions.sh; this file only
// decides what to show and where.
Item {
  id: root

  // Handed over by the shell's panel loader when this plugin is mounted.
  property var manifest: null
  property var shell: null

  // Settings live on this plugin's entry in ~/.config/omarchy/shell.json:
  //
  //   { "plugins": [ { "id": "<this plugin's id>", "dismissAfter": 8000 } ] }
  //
  // Read off the shell config rather than a `settings` property, because the
  // panel loader does not inject one -- that is a bar-widget mechanism.
  readonly property var settings: {
    var cfg = root.shell ? root.shell.shellConfig : null
    var list = (cfg && Array.isArray(cfg.plugins)) ? cfg.plugins : []
    var id = root.manifest ? String(root.manifest.id || "") : ""
    if (id === "") return ({})
    for (var i = 0; i < list.length; i++)
      if (list[i] && String(list[i].id) === id) return list[i]
    return ({})
  }

  function setting(key, fallback) {
    var n = Number(root.settings[key])
    return (isFinite(n) && n >= 0) ? Math.round(n) : fallback
  }

  readonly property int dismissAfter: Math.max(0, root.setting("dismissAfter", 6000))  // 0 keeps it up
  readonly property int cardWidth: Math.max(120, root.setting("cardWidth", 340))       // logical px
  readonly property int maxImageHeight: Math.max(80, root.setting("maxImageHeight", 240))
  readonly property int pinMaxWidth: Math.max(120, root.setting("pinMaxWidth", 520))

  // This file's own directory, so nothing has to know which id the plugin was
  // installed under -- the marketplace id, a personal clone, and a hand-drop
  // into an arbitrary folder all resolve the same way.
  readonly property string pluginDir:
    decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string helper: root.pluginDir + "/actions.sh"

  property string path: ""
  property bool opened: false
  property real previewX: 0
  property real previewY: 0
  property string monitorName: ""
  property real monitorWidth: 0
  property real monitorHeight: 0
  // Cleared and re-set per summon so re-capturing the same path re-reads
  // from disk rather than serving the cached pixmap.
  property string imageSource: ""

  // ---- card metrics -------------------------------------------------
  //
  // `pad` is the single knob: it is the gap from the shot to every card
  // edge, and the card's radius is the shot's radius plus that gap, so the
  // outer corner stays concentric with the image inside it. Change `pad`
  // and the whole card re-proportions.
  readonly property int pad: Style.space(10)
  readonly property int shotRadius: Style.space(8)
  readonly property int cardRadius: root.shotRadius + root.pad
  // Square, and never below the 40px floor a pointer target needs -- the
  // spacing scale can only make it bigger.
  readonly property int buttonSize: Math.max(40, Style.space(34))
  readonly property int dotSize: Style.space(3)
  // The drag strip is sized by the close button, the tallest thing in it --
  // never by the dots. Sized to the dots it came out 28px tall, which wedged
  // the button against the card's top edge, and a corner's curve wants more
  // clearance than a straight edge, not less.
  readonly property int closeSize: Style.space(20)
  readonly property int chromePad: Style.space(7)

  // Image edges need a hairline to sit on, and it has to be pure black or
  // pure white: a tinted neutral picks up the surface under it and reads as
  // dirt along the edge.
  readonly property bool darkTheme: Color.background.hslLightness < 0.5
  readonly property color imageOutline: root.darkTheme
    ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.10)

  readonly property int enterMs: 180
  readonly property int exitMs: 120

  // Hover hint. `hintText` drives the fade; `hintLabel` keeps the last
  // non-empty string so the pill doesn't collapse to nothing while it
  // fades out.
  property string hintText: ""
  property string hintLabel: ""
  onHintTextChanged: if (root.hintText !== "") root.hintLabel = root.hintText

  // True from the moment the card is dismissed until its exit animation
  // has run; the surface has to outlive `opened` for that to be visible.
  property bool closing: false

  property var pins: []
  property int pinSerial: 0
  // Diagnostic: incremented by every wheel event that reaches a pin, from
  // either delivery path. Read it with `omarchy-shell screenshot-preview probe`.
  property int wheelSeen: 0
  // Serial of the pin under the pointer, 0 for none. Pins never take the
  // keyboard, so a keybind has to ask which one is hovered.
  property int hoveredPin: 0

  // Bare keys, not Super combinations: Hyprland grabs its binds before a
  // focused surface sees the key, and SUPER+C/O/P/S are all taken. The card
  // holds the keyboard while it is up, so a single letter is unambiguous.
  readonly property var actions: [
    { "icon": "󰏫", "label": "Edit", "shortcut": "Enter", "action": "edit" },
    { "icon": "󰆏", "label": "Copy", "shortcut": "C", "action": "copy" },
    { "icon": "󰆓", "label": "Save", "shortcut": "S", "action": "save" },
    { "icon": "󰴑", "label": "OCR", "shortcut": "O", "action": "ocr" },
    { "icon": "󰐃", "label": "Pin", "shortcut": "P", "action": "pin" }
  ]

  function screenFor(name) {
    var list = Quickshell.screens
    for (var i = 0; i < list.length; i++)
      if (list[i].name === name) return list[i]
    return list.length > 0 ? list[0] : null
  }

  // Lifecycle hooks invoked by omarchy-shell summon/hide.
  function open(payloadJson) {
    var p = {}
    try { p = JSON.parse(payloadJson || "{}") || {} } catch (e) { p = {} }
    if (!p.path) return

    root.path = String(p.path)
    root.monitorName = String(p.monitor || "")
    root.monitorWidth = Number(p.monitorWidth || 0)
    root.monitorHeight = Number(p.monitorHeight || 0)
    // Sit just off the pointer so the card never lands under it.
    root.previewX = Number(p.x || 0) + 14
    root.previewY = Number(p.y || 0) + 14
    root.imageSource = ""
    Qt.callLater(function () { root.imageSource = "file://" + root.path })
    root.hintText = ""
    closeTimer.stop()
    root.closing = false
    root.opened = true
    root.place()
    root.restartDismiss()
    Qt.callLater(root.clampPreview)
  }

  function close() {
    dismissTimer.stop()
    if (!root.opened) return
    root.hintText = ""
    root.opened = false
    root.closing = true
    closeTimer.restart()
  }

  // Dragging the card writes card.x directly, which breaks the binding to
  // previewX for good -- so position is pushed, never bound.
  function place() {
    card.x = root.previewX
    card.y = root.previewY
  }

  // Keep the card on screen when the pointer is near an edge.
  //
  // Measured against the monitor size from the payload, never against the
  // surface: a layer-shell window reports an interim size until the
  // compositor configures it, and clamping to that lands the card in the
  // middle of nowhere.
  function clampPreview() {
    var w = root.monitorWidth > 0 ? root.monitorWidth : previewWindow.width
    var h = root.monitorHeight > 0 ? root.monitorHeight : previewWindow.height
    var maxX = w - card.width - 8
    var maxY = h - card.height - 8
    if (maxX <= 0 || maxY <= 0) return
    root.previewX = Math.max(8, Math.min(root.previewX, maxX))
    root.previewY = Math.max(8, Math.min(root.previewY, maxY))
    root.place()
  }

  function run(action) {
    Quickshell.execDetached([root.helper, action, root.path])
  }

  function trigger(action) {
    if (action === "pin") root.pin()
    else { root.run(action); root.close() }
  }

  function pin() {
    var next = root.pins.slice()
    next.push({
      "serial": ++root.pinSerial,
      "path": root.path,
      "x": root.previewX,
      "y": root.previewY,
      "monitor": root.monitorName
    })
    root.pins = next
    root.close()
  }

  function unpin(serial) {
    if (root.hoveredPin === serial) root.hoveredPin = 0
    root.pins = root.pins.filter(function (p) { return p.serial !== serial })
  }

  // Pin windows listen for these; serial 0 means every pin.
  signal zoomRequested(int serial, real factor)
  signal editRequested(int serial)

  IpcHandler {
    target: "screenshot-preview"
    function show(payloadJson: string): string { root.open(payloadJson); return "ok" }
    function close(): string { root.close(); return "ok" }
    // Pin without going through the card, for keybinds and for testing.
    function pin(payloadJson: string): string {
      var p = {}
      try { p = JSON.parse(payloadJson || "{}") || {} } catch (e) { return "bad payload" }
      if (!p.path) return "no path"
      var next = root.pins.slice()
      next.push({
        "serial": ++root.pinSerial,
        "path": String(p.path),
        "x": Number(p.x || 80), "y": Number(p.y || 80),
        "monitor": String(p.monitor || root.monitorName)
      })
      root.pins = next
      return "ok"
    }
    function unpinAll(): string { root.pins = []; return "ok" }
    // Closes the pin under the pointer. Returns "none" when there is none, so
    // a keybind can fall through to its normal action.
    function closeHovered(): string {
      if (root.hoveredPin === 0) return "none"
      root.unpin(root.hoveredPin)
      return "closed"
    }
    // Same path the hover toolbar takes: opens the editor and retires the pin.
    function editPin(serial: string): string {
      root.editRequested(Number(serial) || 0)
      return "ok"
    }
    // Same path the scroll wheel takes: serial 0 zooms every pin.
    function zoom(serial: string, factor: string): string {
      var f = Number(factor)
      if (!(f > 0)) return "bad factor"
      root.zoomRequested(Number(serial) || 0, f)
      return "ok"
    }
    function state(): string { return root.opened ? "open" : "closed" }
    function ping(): string { return "ok" }
    // Layer-shell windows fail silently when geometry or screen lookup goes
    // wrong -- this reports what the window actually resolved to.
    function probe(): string {
      var names = []
      for (var i = 0; i < Quickshell.screens.length; i++) names.push(Quickshell.screens[i].name)
      return JSON.stringify({
        opened: root.opened, path: root.path, imageSource: root.imageSource,
        screens: names, wantScreen: root.monitorName,
        matched: previewWindow.screen ? previewWindow.screen.name : null,
        visible: previewWindow.visible,
        surfaceW: previewWindow.width, surfaceH: previewWindow.height,
        cardW: card.width, cardH: card.height,
        cardRadius: card.radius, shotRadius: root.shotRadius,
        x: card.x, y: card.y, pins: root.pins.length,
        cornerRadius: Style.cornerRadius, wheelSeen: root.wheelSeen,
        hovered: cardHover.hovered, hasFocus: card.activeFocus
      })
    }
  }

  Timer {
    id: dismissTimer
    interval: root.dismissAfter
    onTriggered: root.close()
  }

  // Keeps the surface alive just long enough for the exit animation.
  Timer {
    id: closeTimer
    interval: root.exitMs
    onTriggered: root.closing = false
  }

  function restartDismiss() {
    if (root.opened && root.dismissAfter > 0) dismissTimer.restart()
  }

  // The surface stays put and the card moves inside it. Repositioning a
  // layer-shell window under a drag fights the compositor: every commit
  // shifts the pointer's surface-local coordinates, the next event
  // double-counts the delta, and the window wobbles. A fullscreen surface
  // masked to the card gets the same visuals with none of that -- and the
  // mask keeps clicks elsewhere passing through to the desktop.
  PanelWindow {
    id: previewWindow
    visible: (root.opened || root.closing) && root.path !== ""
    screen: root.screenFor(root.monitorName)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region { item: card }

    WlrLayershell.namespace: "omarchy-screenshot-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    // Keyboard only while the pointer is over the card. Holding it for the
    // whole 6s steals keystrokes from whatever the user is typing into --
    // observed for real: a stray `p` meant for an editor pinned a capture
    // instead. The card appears under the pointer, so the shortcuts still
    // work immediately; moving the mouse away hands the keyboard straight
    // back and leaves the buttons clickable.
    WlrLayershell.keyboardFocus: root.opened && cardHover.hovered
      ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // Soft shadow under the card. MultiEffect has to own the item it draws,
    // so it renders a stand-in rectangle rather than the card itself, which
    // has to stay live for input. Declared first so it sits underneath, and
    // it copies the card's entrance so both move as one object.
    Rectangle {
      id: cardShade
      anchors.fill: card
      radius: card.radius
      color: card.color
      visible: false
    }

    MultiEffect {
      source: cardShade
      anchors.fill: card
      opacity: card.opacity
      scale: card.scale
      transformOrigin: card.transformOrigin
      autoPaddingEnabled: true
      shadowEnabled: true
      shadowColor: Qt.rgba(0, 0, 0, 0.45)
      shadowBlur: 0.8
      shadowVerticalOffset: Style.space(6)
      shadowScale: 1.0
    }

    Rectangle {
      id: card
      // Position is pushed by root.place(), never bound: the drag writes
      // straight to x/y and would break a binding on the first move.
      width: root.cardWidth + root.pad * 2
      height: chrome.height + shotFrame.height + root.pad + buttonRow.height + root.pad
      // Concentric with the shot: the image's radius plus the padding
      // around it. Any other value leaves the outer corner visibly tighter
      // or looser than the inner one.
      radius: root.cardRadius
      color: Color.background
      // The shadow carries the separation now, so the outline is only here
      // to keep the edge crisp against a same-toned wallpaper.
      border.width: Math.max(1, Style.space(1))
      border.color: Util.alpha(Color.foreground, 0.12)
      antialiasing: true
      focus: true

      // Grows out of its top-left, which is where the pointer is, and
      // leaves smaller and quicker than it arrived -- an exit should be
      // quieter than an entrance.
      transformOrigin: Item.TopLeft
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.97
      Behavior on opacity {
        NumberAnimation {
          duration: root.opened ? root.enterMs : root.exitMs
          easing.type: Easing.OutCubic
        }
      }
      Behavior on scale {
        NumberAnimation {
          duration: root.opened ? root.enterMs : root.exitMs
          easing.type: Easing.OutCubic
        }
      }

      HoverHandler {
        id: cardHover
        onHoveredChanged: hovered ? dismissTimer.stop() : root.restartDismiss()
      }

      // The whole card drags, not just the dot strip: grabbing the screenshot
      // itself is the obvious way to move a small floating panel. Declared
      // before the chrome and buttons so those later siblings sit on top and
      // keep their own clicks.
      //
      // A press that never crosses the drag threshold is still a click, so
      // pressing on the shot and releasing without moving opens the editor --
      // dragging from it does not.
      MouseArea {
        id: cardDrag
        anchors.fill: parent
        drag.target: card
        drag.minimumX: 0
        drag.minimumY: 0
        drag.maximumX: previewWindow.width - card.width
        drag.maximumY: previewWindow.height - card.height
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

        property bool dragged: false
        property bool pressedOnShot: false

        onPressed: function (mouse) {
          dismissTimer.stop()
          cardDrag.dragged = false
          var p = shotFrame.mapFromItem(cardDrag, mouse.x, mouse.y)
          cardDrag.pressedOnShot = shotFrame.contains(Qt.point(p.x, p.y))
        }
        onPositionChanged: if (drag.active) cardDrag.dragged = true
        onReleased: {
          // Keep the summon position in step, so a re-summon and any pin
          // taken from here start where the card was left.
          root.previewX = card.x
          root.previewY = card.y
          if (!cardDrag.dragged && cardDrag.pressedOnShot) root.trigger("edit")
          else root.restartDismiss()
        }
      }

      Keys.onPressed: function (event) {
        // Modifiers are deliberately not checked: the bare key is what the
        // card advertises, and a stray modifier should not swallow the action.
        switch (event.key) {
        case Qt.Key_Escape:                       root.close(); break
        case Qt.Key_Return: case Qt.Key_Enter:    root.trigger("edit"); break
        case Qt.Key_C:                            root.trigger("copy"); break
        case Qt.Key_S:                            root.trigger("save"); break
        case Qt.Key_O:                            root.trigger("ocr"); break
        case Qt.Key_P:                            root.trigger("pin"); break
        default: return
        }
        event.accepted = true
      }

      // ---- drag strip + close ----
      //
      // Tall enough to clear the close button on both sides, with the dots
      // centred in whatever that leaves.
      Item {
        id: chrome
        width: parent.width
        height: root.closeSize + root.chromePad * 2
        anchors.top: parent.top

        Row {
          id: dots
          anchors.centerIn: parent
          spacing: root.dotSize
          Repeater {
            model: 4
            Rectangle {
              width: root.dotSize; height: width; radius: width / 2
              antialiasing: true
              color: Util.alpha(Color.foreground, cardDrag.pressed ? 0.8 : 0.35)
              Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
          }
        }

        // Round, not a rounded square: at this size a square chip in the
        // corner runs into the card's own curve.
        Rectangle {
          id: closeButton
          width: root.closeSize
          height: width
          radius: width / 2
          antialiasing: true
          // Same inset from the top and the right, so the glyph reads as
          // sitting in the corner rather than pushed into one edge of it.
          anchors.verticalCenter: parent.verticalCenter
          anchors.right: parent.right
          anchors.rightMargin: root.chromePad
          color: closeArea.pressed
            ? Util.alpha(Color.foreground, 0.18)
            : (closeArea.containsMouse ? Util.alpha(Color.foreground, 0.10) : "transparent")
          scale: closeArea.pressed ? 0.96 : 1
          Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutCubic } }
          Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

          Text {
            anchors.centerIn: parent
            text: "󰅖"
            font.family: Style.font.family
            font.pixelSize: Style.font.iconSmall
            color: closeArea.containsMouse ? Color.foreground : Util.alpha(Color.foreground, 0.5)
            Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutCubic } }
          }

          // Grown to a full pointer target; the visible chip stays small so
          // it doesn't crowd the drag strip.
          MouseArea {
            id: closeArea
            anchors.fill: parent
            anchors.margins: -(40 - closeButton.width) / 2
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: { root.hintText = "Discard  ·  Esc"; dismissTimer.stop() }
            onExited: { root.hintText = ""; root.restartDismiss() }
            onClicked: root.close()
          }
        }
      }

      // ---- the shot ----
      //
      // ClippingRectangle, not `clip: true`: Qt's clip is a plain rectangle
      // and ignores the radius, which is what left the image square-cornered
      // inside a rounded frame.
      ClippingRectangle {
        id: shotFrame
        anchors.top: chrome.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        // Height comes from the natural aspect ratio, never from the
        // Image's painted size: the Image fills this frame, so that would
        // be a binding loop.
        readonly property real imageRatio: shot.implicitWidth > 0
          ? shot.implicitHeight / shot.implicitWidth : 0.625
        width: root.cardWidth
        height: Math.max(Style.space(60), Math.min(root.cardWidth * imageRatio, root.maxImageHeight))
        color: Util.alpha(Color.foreground, 0.06)
        radius: root.shotRadius
        border.width: 1
        border.color: root.imageOutline

        Image {
          id: shot
          anchors.fill: parent
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: false
          // Screenshots arrive at monitor resolution and land in a 340px
          // frame; without mipmaps that downscale crawls with aliasing.
          mipmap: true
          source: root.imageSource
          // The file loads a frame or two after the card is up, so fade it
          // in rather than letting it snap into the empty frame.
          opacity: status === Image.Ready ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
          onStatusChanged: if (status === Image.Ready) Qt.callLater(root.clampPreview)
        }
      }

      // ---- action row ----
      //
      // Cells split the shot's width evenly and the whole cell is clickable,
      // but the chip that lights up inside each one is square -- a chip
      // stretched to the cell reads as a bar, not a button.
      Row {
        id: buttonRow
        anchors.top: shotFrame.bottom
        anchors.topMargin: root.pad
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.cardWidth
        height: root.buttonSize
        spacing: 0

        Repeater {
          model: root.actions
          Item {
            id: cell
            required property var modelData
            required property int index
            width: Math.round(root.cardWidth / root.actions.length)
            height: root.buttonSize

            Rectangle {
              id: chip
              anchors.centerIn: parent
              width: root.buttonSize
              height: root.buttonSize
              // Same radius as the shot: both sit one pad inside the card,
              // so both are concentric with its corner.
              radius: root.shotRadius
              antialiasing: true
              color: btn.pressed
                ? Util.alpha(Color.foreground, 0.18)
                : (btn.containsMouse ? Util.alpha(Color.foreground, 0.10) : "transparent")
              scale: btn.pressed ? 0.96 : 1
              // The row arrives a beat after the card and one icon at a
              // time, so the card reads as assembling rather than pasting.
              opacity: root.opened ? 1 : 0

              Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutCubic } }
              Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
              Behavior on opacity {
                SequentialAnimation {
                  PauseAnimation { duration: root.opened ? 60 + cell.index * 30 : 0 }
                  NumberAnimation {
                    duration: root.opened ? 160 : 90
                    easing.type: Easing.OutCubic
                  }
                }
              }

              Text {
                anchors.centerIn: parent
                text: cell.modelData.icon
                font.family: Style.font.family
                font.pixelSize: Style.font.icon
                color: btn.containsMouse ? Color.foreground : Util.alpha(Color.foreground, 0.75)
                Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutCubic } }
              }
            }

            MouseArea {
              id: btn
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: { root.hintText = cell.modelData.label + "  ·  " + cell.modelData.shortcut; dismissTimer.stop() }
              onExited: if (root.hintText.indexOf(cell.modelData.label) === 0) root.hintText = ""
              onClicked: root.trigger(cell.modelData.action)
            }
          }
        }
      }

      // ---- hover hint ----
      //
      // Sits over the shot so the card keeps a fixed height, which means it
      // needs its own shadow to lift off the image underneath.
      //
      // The pill is the MultiEffect's source, not a stand-in rectangle
      // copying its geometry: the pill changes width with every label, and
      // a stand-in re-rendered a frame behind put a second, stale pill on
      // screen each time the pointer crossed to another button.
      Rectangle {
        id: hintPill
        anchors.bottom: buttonRow.top
        anchors.bottomMargin: Style.space(6)
        anchors.horizontalCenter: parent.horizontalCenter
        width: hint.implicitWidth + Style.space(18)
        height: hint.implicitHeight + Style.space(10)
        radius: height / 2
        antialiasing: true
        color: Color.tooltip.background
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha(Color.foreground, 0.12)
        visible: false

        Text {
          id: hint
          anchors.centerIn: parent
          text: root.hintLabel
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Color.tooltip.text
        }
      }

      MultiEffect {
        source: hintPill
        // Anchored, not four geometry bindings: anchors settle in the same
        // pass the source resizes in.
        anchors.fill: hintPill
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: Qt.rgba(0, 0, 0, 0.35)
        shadowBlur: 0.6
        shadowVerticalOffset: Style.space(3)
        shadowScale: 1.0
        // Faded rather than toggled, and the text it was showing is held
        // until the fade finishes so the pill doesn't shrink as it leaves.
        opacity: root.hintText !== "" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      }
    }
  }

  // ---- pinned shots ----
  Variants {
    model: root.pins

    // Same shape as the preview: a fullscreen surface masked to the pin, so
    // dragging and zooming move an item inside a window that never moves.
    PanelWindow {
      id: pinWindow
      required property var modelData

      // Live geometry belongs to the window, not the model, so dragging and
      // zooming never have to write back through the pins array.
      property real zoom: 1
      readonly property real baseWidth: pinImage.implicitWidth > 0
        ? Math.min(pinImage.implicitWidth, root.pinMaxWidth) : 320
      readonly property real ratio: pinImage.implicitWidth > 0
        ? pinImage.implicitHeight / pinImage.implicitWidth : 0.625

      visible: true
      screen: root.screenFor(modelData.monitor)
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      anchors { top: true; bottom: true; left: true; right: true }
      mask: Region { item: pinFrame }

      WlrLayershell.namespace: "omarchy-screenshot-pin"
      WlrLayershell.layer: WlrLayer.Overlay
      // A pin is a passive reference; it must never take the keyboard.
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // A pin and the editor are two views of one capture, so opening the
      // editor retires the pin. Path and serial are read before unpinning:
      // that destroys this delegate, taking modelData with it.
      function editAndClose() {
        var path = pinWindow.modelData.path
        var serial = pinWindow.modelData.serial
        Quickshell.execDetached([root.helper, "edit", path])
        root.unpin(serial)
      }

      // Scaling by notches rather than by direction keeps high-resolution
      // wheels and touchpads -- which emit many small deltas -- from zooming
      // in huge jumps.
      function applyWheel(deltaY) {
        root.wheelSeen++
        var notches = deltaY / 120
        if (notches === 0) return
        pinWindow.applyZoom(Math.pow(1.1, Math.max(-4, Math.min(4, notches))))
      }

      // Zoom about the centre so the pin grows in place instead of crawling
      // toward a corner, then keep it inside the screen.
      function applyZoom(factor) {
        var previous = pinWindow.zoom
        pinWindow.zoom = Math.max(0.15, Math.min(4, previous * factor))
        var grew = pinWindow.zoom - previous
        pinFrame.x = Math.max(0, Math.min(
          pinFrame.x - (grew * pinWindow.baseWidth) / 2,
          pinWindow.width - pinFrame.width))
        pinFrame.y = Math.max(0, Math.min(
          pinFrame.y - (grew * pinWindow.baseWidth * pinWindow.ratio) / 2,
          pinWindow.height - pinFrame.height))
      }

      Item {
        id: pinFrame
        x: modelData.x
        y: modelData.y
        width: Math.round(pinWindow.baseWidth * pinWindow.zoom)
        height: Math.round(pinWindow.baseWidth * pinWindow.ratio * pinWindow.zoom)

        HoverHandler {
          id: pinHover
          onHoveredChanged: {
            if (hovered) root.hoveredPin = pinWindow.modelData.serial
            else if (root.hoveredPin === pinWindow.modelData.serial) root.hoveredPin = 0
          }
        }

        // Rounding tracks Hyprland's decoration:rounding through
        // Style.cornerRadius -- the same knob the Display panel sets, so a
        // pin rounds like every other window on the desktop.
        ClippingRectangle {
          id: pinClip
          anchors.fill: parent
          radius: Style.cornerRadius
          color: "transparent"
          // Drawn by the MultiEffect below, which adds the shadow.
          visible: false

          Image {
            id: pinImage
            anchors.fill: parent
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            source: "file://" + modelData.path
          }
        }

        // A pin floats over arbitrary windows, so it needs a shadow to read
        // as a separate object rather than as part of whatever is behind it.
        MultiEffect {
          anchors.fill: pinClip
          source: pinClip
          autoPaddingEnabled: true
          shadowEnabled: true
          shadowColor: Qt.rgba(0, 0, 0, 0.55)
          shadowBlur: 0.9
          shadowVerticalOffset: Style.space(5)
          shadowScale: 1.0
        }

        // Hover outline, on top of the image.
        Rectangle {
          anchors.fill: parent
          color: "transparent"
          radius: pinClip.radius
          border.width: pinHover.hovered ? Math.max(1, Style.space(1)) : 0
          border.color: Util.alpha(Color.foreground, 0.5)
        }

        MouseArea {
          id: pinDrag
          anchors.fill: parent
          cursorShape: Qt.SizeAllCursor
          drag.target: pinFrame
          drag.minimumX: 0
          drag.minimumY: 0
          drag.maximumX: pinWindow.width - pinFrame.width
          drag.maximumY: pinWindow.height - pinFrame.height
          onDoubleClicked: pinWindow.editAndClose()

          // Wheel lives on the MouseArea, not on a handler: this area covers
          // the whole pin, and every wheel-driven widget in the omarchy shell
          // (WidgetButton, Tray, PanelSlider, the media widget) does the same.
          // Accepting here stops the fallback handler below from zooming twice.
          onWheel: function (wheel) {
            pinWindow.applyWheel(wheel.angleDelta.y)
            wheel.accepted = true
          }
        }

        // Fallback delivery path. No acceptedModifiers on purpose: it demands
        // an *exact* modifier match, so naming any modifier (even alongside
        // Qt.NoModifier, which is 0 and contributes nothing) stops a plain
        // scroll from matching at all.
        WheelHandler {
          onWheel: function (event) {
            pinWindow.applyWheel(event.angleDelta.y)
            event.accepted = true
          }
        }

        Connections {
          target: root
          function onZoomRequested(serial, factor) {
            if (serial === 0 || serial === pinWindow.modelData.serial)
              pinWindow.applyZoom(factor)
          }
          function onEditRequested(serial) {
            if (serial === 0 || serial === pinWindow.modelData.serial)
              pinWindow.editAndClose()
          }
        }

        Row {
          visible: pinHover.hovered
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: Style.space(4)
          spacing: Style.space(2)

          Repeater {
            model: [
              { "icon": "󰆏", "action": "copy" },
              { "icon": "󰏫", "action": "edit" },
              { "icon": "󰅖", "action": "close" }
            ]
            Rectangle {
              required property var modelData
              width: Style.space(22); height: width
              radius: Style.space(4)
              color: Util.alpha(Color.background, pinBtn.containsMouse ? 0.95 : 0.75)

              Text {
                anchors.centerIn: parent
                text: modelData.icon
                font.family: Style.font.family
                font.pixelSize: Style.font.iconSmall
                color: Color.foreground
              }

              MouseArea {
                id: pinBtn
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (modelData.action === "close") root.unpin(pinWindow.modelData.serial)
                  else if (modelData.action === "edit") pinWindow.editAndClose()
                  else Quickshell.execDetached([root.helper, modelData.action, pinWindow.modelData.path])
                }
              }
            }
          }
        }
      }
    }
  }
}
