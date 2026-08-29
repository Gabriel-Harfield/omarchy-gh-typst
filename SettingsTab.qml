import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Isolated component: the "Paramètres" tab. Currently just the
// auto-save interval — a durable preference (lives in its own
// settings.json, not the per-document session.json), not a document
// property, so it belongs here rather than on the editor toolbar.
Item {
  id: root

  required property bool autosaveEnabled
  required property int autosaveMinutes
  required property color foreground
  required property color dim
  required property color faint
  required property color accentColor
  required property string uiFont

  signal autosaveEnabledSet(bool enabled)
  signal autosaveMinutesSet(int minutes)

  Column {
    anchors.fill: parent
    anchors.margins: Style.space(6)
    spacing: Style.space(18)

    Text {
      text: "Paramètres"
      color: root.foreground
      font.family: root.uiFont
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Toggle {
      width: Math.min(parent.width, Style.space(420))
      label: "Sauvegarde automatique"
      description: "Enregistre le document sur disque à intervalle régulier s'il a un chemin. Un document jamais enregistré reste protégé par la session, indépendamment de ce réglage."
      checked: root.autosaveEnabled
      foreground: root.foreground
      accent: root.accentColor
      fontFamily: root.uiFont
      onClicked: root.autosaveEnabledSet(!root.autosaveEnabled)
    }

    Row {
      spacing: Style.space(14)
      opacity: root.autosaveEnabled ? 1.0 : 0.5

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Intervalle :"
        color: root.foreground
        font.family: root.uiFont
        font.pixelSize: Style.font.body
      }

      Button {
        text: "−"
        bordered: true
        foreground: root.foreground
        accent: root.accentColor
        enabled: root.autosaveEnabled && root.autosaveMinutes > 1
        onClicked: root.autosaveMinutesSet(root.autosaveMinutes - 1)
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.autosaveMinutes + " min"
        color: root.foreground
        font.family: root.uiFont
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Button {
        text: "+"
        bordered: true
        foreground: root.foreground
        accent: root.accentColor
        enabled: root.autosaveEnabled && root.autosaveMinutes < 60
        onClicked: root.autosaveMinutesSet(root.autosaveMinutes + 1)
      }
    }
  }
}
