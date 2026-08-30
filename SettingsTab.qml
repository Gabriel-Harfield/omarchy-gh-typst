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
  required property string journalDir

  signal autosaveEnabledSet(bool enabled)
  signal autosaveMinutesSet(int minutes)
  signal journalDirSet(string dir)

  // journalDirField.text can't just be `text: root.journalDir` — the same
  // established trap as pathBarField/notesField elsewhere in this
  // codebase: a TextField's declarative binding is destroyed the instant
  // the user types into it. Seeded once at creation, then imperatively
  // re-synced only when journalDir actually changes from outside (the
  // settings.json load completing shortly after this component exists,
  // in practice) — never fights the user's own typing.
  onJournalDirChanged: {
    if (!journalDirField || journalDirField.text === root.journalDir) return
    journalDirField.text = root.journalDir
  }

  // --- Typst Universe template picker -------------------------------------
  //
  // Gabriel's ask, 2026-08-30: a couple of Typst Universe templates as
  // clickable thumbnails, kept here (Paramètres) rather than in the
  // editor toolbar since this is a one-off "start a new document from a
  // template" action, not something reached for every session. Data-
  // driven off a plain list so adding a third template later is a one-
  // line change, not new QML structure.
  //
  // insertCommand === "" (Simple Research Poster's own "command" is
  // actually `typst init @preview/...` — a shell command, not valid
  // Typst source) means no insert action at all for that card, per
  // Gabriel's own explicit choice: image/title click opens the link,
  // full stop.
  readonly property var typstTemplates: [
    {
      name: "Diatypst",
      thumbnail: "assets/diatypst.png",
      link: "https://typst.app/universe/package/diatypst/",
      insertCommand: "#import \"@preview/diatypst:0.9.3\": *\n#show: slides.with(\n  title: \"Diatypst\", // Required\n  subtitle: \"easy slides in typst\",\n  date: \"01.07.2024\",\n  authors: (\"John Doe\"),\n)\n"
    },
    {
      name: "Simple Research Poster",
      thumbnail: "assets/simple-research-poster.png",
      link: "https://typst.app/universe/package/simple-research-poster",
      insertCommand: ""
    }
  ]

  signal typstUniverseOpenRequested()
  signal templateLinkOpenRequested(string url)
  signal templateInsertRequested(string command)

  ScrollView {
    id: settingsScroll
    anchors.fill: parent
    anchors.margins: Style.space(6)
    clip: true
    ScrollBar.vertical.policy: ScrollBar.AsNeeded

  Column {
    width: settingsScroll.availableWidth
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

    PanelSeparator { foreground: root.foreground; width: parent.width }

    Text {
      text: "Typst Universe"
      color: root.foreground
      font.family: root.uiFont
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Button {
      iconText: ""
      text: "Parcourir Typst Universe"
      bordered: true
      foreground: root.foreground
      accent: root.accentColor
      onClicked: root.typstUniverseOpenRequested()
    }

    Row {
      spacing: Style.space(20)

      Repeater {
        model: root.typstTemplates

        Column {
          id: templateCard
          required property var modelData
          spacing: Style.space(6)
          width: Style.space(220)

          Rectangle {
            width: parent.width
            height: width * 0.75
            color: Qt.darker(root.foreground, 8)
            radius: Style.cornerRadius
            border.color: root.faint
            border.width: 1
            clip: true

            Image {
              anchors.fill: parent
              source: templateCard.modelData.thumbnail
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.templateLinkOpenRequested(templateCard.modelData.link)
            }
          }

          Text {
            width: parent.width
            text: templateCard.modelData.name
            color: root.foreground
            font.family: root.uiFont
            font.pixelSize: Style.font.body
            font.bold: true
            wrapMode: Text.Wrap

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.templateLinkOpenRequested(templateCard.modelData.link)
            }
          }

          // Simple Research Poster's own "command" is actually
          // `typst init @preview/...` (a shell command, not valid Typst
          // source) — no insert action for it at all, per Gabriel's own
          // explicit choice: image/title click opens the link, nothing
          // pasted into the editor.
          Button {
            visible: templateCard.modelData.insertCommand !== ""
            width: parent.width
            leftAlign: true
            iconText: ""
            text: "Nouveau document"
            bordered: true
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.templateInsertRequested(templateCard.modelData.insertCommand)
          }
        }
      }
    }

    PanelSeparator { foreground: root.foreground; width: parent.width }

    Text {
      text: "Journal"
      color: root.foreground
      font.family: root.uiFont
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Text {
      width: Math.min(parent.width, Style.space(520))
      textFormat: Text.PlainText
      text: "Dossier contenant vos entrées de journal, un fichier YYYY_MM_DD.md par jour (convention Logseq — le même fichier reste lisible et modifiable par les deux applications). Laissez vide pour désactiver l'onglet Journal."
      color: root.dim
      font.family: root.uiFont
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
    }

    Row {
      spacing: Style.space(8)

      TextField {
        id: journalDirField
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(Style.space(460), settingsScroll.availableWidth - Style.space(180))
        placeholderText: "/chemin/vers/le/dossier/journals"
        Component.onCompleted: text = root.journalDir
        onAccepted: root.journalDirSet(text.trim())
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        iconText: ""
        text: "Utiliser ce dossier"
        bordered: true
        foreground: root.foreground
        accent: root.accentColor
        onClicked: root.journalDirSet(journalDirField.text.trim())
      }
    }
  }
  }
}
