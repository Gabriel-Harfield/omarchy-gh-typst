import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "lib/CodeReview.js" as CodeReview
import "lib/Diff.js" as Diff

// Isolated component: the "Révision" tab — merges the former separate
// "Claude" and "Antidote" tabs into one, Gabriel's explicit UX request
// 2026-08-29 ("je pense que c'est la meilleure manière de corriger le
// texte" about Antidote, wanting both review paths in one place). Two
// sections, Antidote first (his preferred path) then Claude.
//
// Claude section redesigned as select-then-launch rather than three
// immediate-trigger buttons (Gabriel's own choice when asked, given the
// added model/effort/mode/consignes controls needed somewhere to live):
// pick a category (code/orthographe/syntaxe — selection only, doesn't
// run anything), which reveals that category's own options (syntaxe's
// mode picker + a one-line explanation of the selected mode), then a
// single "Lancer" button actually starts the review. Model/effort
// dropdowns and the free-text "consignes supplémentaires" box apply to
// whichever category gets launched.
Item {
  id: root

  // --- Antidote -----------------------------------------------------------
  required property bool antidoteSending
  required property string antidoteSendError
  required property bool antidoteHasPreview
  required property string antidotePreviewText
  required property bool antidoteFetching
  required property string antidoteFetchError

  // --- Claude ---------------------------------------------------------
  required property bool reviewing
  required property string reviewKind // "" | "code" | "orthographe" | "syntaxe"
  required property bool hasResult
  required property string reviewLog
  required property string reviewError
  required property string reviewOriginalText
  required property string reviewCorrectedText
  required property int reviewElapsedMs
  required property int reviewOutputTokens
  required property string claudeModel
  required property string claudeEffort

  required property bool docEmpty
  required property color foreground
  required property color dim
  required property color faint
  required property color accentColor
  required property color urgentColor
  required property string uiFont

  signal sendRequested()
  signal fetchRequested()
  signal antidoteApplyRequested()

  signal reviewRequested(string kind, string mode, string extraInstructions)
  signal applyRequested(string finalText)
  signal cancelRequested()
  signal claudeModelSet(string model)
  signal claudeEffortSet(string effort)

  // Selection-only state (which category's options are showing) — not
  // the same thing as reviewKind, which is Panel.qml's record of
  // whichever review actually ran/is running. Changing this while a
  // review is in flight is harmless, it's just local UI state.
  property string selectedKind: "code"
  property string syntaxeMode: "strict"
  property string extraInstructions: ""
  // False when the last result's diff hit its time budget and fell back
  // to an unhighlighted render (see lib/Diff.js's own comment) — a real,
  // observed failure mode on a large document with many scattered
  // changes, not a hypothetical one.
  property bool diffHighlighted: true

  readonly property var modeLabels: ({ strict: "Strict", permissif: "Permissif", creatif: "Créatif" })
  readonly property var modeExplanations: ({
    strict: "Aucun changement dans la tournure des phrases — uniquement les fautes grammaticales évidentes (accords, conjugaisons, structure fautive).",
    permissif: "La tournure peut changer si nécessaire pour corriger une construction fautive ou clarifier un sens ambigu — jamais par simple préférence.",
    creatif: "Reformulations autorisées, y compris de phrases déjà correctes, si Claude juge qu'une autre tournure sert mieux le texte."
  })
  readonly property var kindLabels: ({ code: "code", orthographe: "orthographe", syntaxe: "syntaxe" })

  readonly property var modelOptions: [
    { value: "", label: "Par défaut" },
    { value: "sonnet", label: "Sonnet" },
    { value: "opus", label: "Opus" },
    { value: "haiku", label: "Haiku" },
    { value: "fable", label: "Fable" }
  ]
  readonly property var effortOptions: [
    { value: "", label: "Par défaut" },
    { value: "low", label: "Faible" },
    { value: "medium", label: "Moyen" },
    { value: "high", label: "Élevé" },
    { value: "xhigh", label: "Très élevé" },
    { value: "max", label: "Maximal" }
  ]

  function formatElapsed(ms) {
    var totalSeconds = Math.floor(ms / 1000)
    var mm = Math.floor(totalSeconds / 60)
    var ss = totalSeconds % 60
    return mm + ":" + (ss < 10 ? "0" : "") + ss
  }

  // Same U+2028/2029-normalization the main editor needs (see
  // EditorTab.qml's own comment) — TextEdit.getText() on a RichText
  // document returns those, not "\n", for a <br/>-induced line break.
  function normalize(t) {
    return String(t).replace(/[\u2028\u2029]/g, "\n")
  }

  // (Re)builds correctionEdit's content from the latest review result.
  // Called once per new result, never again afterward — this is
  // deliberately a static render, not a live recolor-on-edit loop like
  // the main editor's: that loop is exactly what caused this codebase's
  // "ghost lines" saga, and there's no need to pay that risk here since
  // the highlight only ever needs to reflect the diff at the moment the
  // result arrived, not track further live edits.
  function _loadCorrection() {
    var built = Diff.buildCorrectionHtml(root.reviewOriginalText, root.reviewCorrectedText, String(root.urgentColor))
    correctionEdit.text = built.html
    root.diffHighlighted = built.highlighted
  }

  onReviewCorrectedTextChanged: if (root.hasResult) root._loadCorrection()
  onHasResultChanged: if (root.hasResult) root._loadCorrection()

  ScrollView {
    id: revisionScroll
    anchors.fill: parent
    clip: true
    ScrollBar.vertical.policy: ScrollBar.AsNeeded

    Column {
      width: revisionScroll.availableWidth - Style.space(12)
      x: Style.space(6)
      topPadding: Style.space(6)
      bottomPadding: Style.space(12)
      spacing: Style.space(22)

      // ============================================== section 1: Antidote
      Column {
        width: parent.width
        spacing: Style.space(10)

        Text {
          text: "Antidote"
          color: root.foreground
          font.family: root.uiFont
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Pas d'intégration officielle possible sans compte pro API — à la place : envoie tout le document (copié dans le presse-papier) et ouvre le correcteur Antidote dans le navigateur. Corrige normalement là-bas, sélectionne tout (Ctrl+A, Ctrl+C), puis reviens ici récupérer le résultat."
          color: root.dim
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        Row {
          spacing: Style.space(8)

          Button {
            iconText: "\uf0ea"
            text: root.antidoteSending ? "Envoi…" : "Envoyer vers Antidote"
            enabled: !root.antidoteSending && !root.docEmpty
            bordered: true
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.sendRequested()
          }

          Button {
            iconText: "\uf019"
            text: root.antidoteFetching ? "Lecture du presse-papier…" : "Récupérer la correction"
            enabled: !root.antidoteFetching
            bordered: true
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.fetchRequested()
          }
        }

        Text {
          visible: root.antidoteSendError !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.antidoteSendError
          color: root.urgentColor
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        Text {
          visible: root.antidoteFetchError !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.antidoteFetchError
          color: root.urgentColor
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        Column {
          visible: root.antidoteHasPreview
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "Contenu récupéré du presse-papier — vérifie avant d'appliquer"
            color: root.foreground
            font.family: root.uiFont
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          ScrollView {
            id: antidotePreviewScroll
            width: parent.width
            height: 220
            clip: true
            ScrollBar.vertical.policy: ScrollBar.AsNeeded

            Text {
              width: antidotePreviewScroll.availableWidth
              textFormat: Text.PlainText
              text: root.antidotePreviewText
              color: root.foreground
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }

          Button {
            iconText: "\uf00c"
            text: "Remplacer le document par ce texte"
            bordered: true
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.antidoteApplyRequested()
          }
        }
      }

      PanelSeparator { foreground: root.faint; width: parent.width }

      // ================================================ section 2: Claude
      Column {
        width: parent.width
        spacing: Style.space(10)

        Text {
          text: "Claude"
          color: root.foreground
          font.family: root.uiFont
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "Trois vérifications séparées, une à la fois : le code (syntaxe Typst), l'orthographe lexicale (fautes de frappe, homonymes, accents) ou la syntaxe grammaticale de la prose (accords, construction des phrases). Choisis une catégorie, ajuste les options si besoin, puis lance — journal des changements et comparaison éditable, sans rien modifier tant que tu n'appliques pas."
          color: root.dim
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        Row {
          spacing: Style.space(8)

          Button {
            iconText: "\uf121"
            text: "Code"
            selected: root.selectedKind === "code"
            bordered: true
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.selectedKind = "code"
          }
          Button {
            iconText: "\uf031"
            text: "Orthographe"
            selected: root.selectedKind === "orthographe"
            bordered: true
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.selectedKind = "orthographe"
          }
          Button {
            iconText: "\uf0e8"
            text: "Syntaxe"
            selected: root.selectedKind === "syntaxe"
            bordered: true
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.selectedKind = "syntaxe"
          }
        }

        Column {
          visible: root.selectedKind === "syntaxe"
          width: parent.width
          spacing: Style.space(6)

          Row {
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Mode :"
              color: root.faint
              font.family: root.uiFont
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: CodeReview.SYNTAXE_MODES
              Button {
                required property string modelData
                text: root.modeLabels[modelData] || modelData
                selected: root.syntaxeMode === modelData
                foreground: root.foreground
                accent: root.accentColor
                onClicked: root.syntaxeMode = modelData
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.modeExplanations[root.syntaxeMode] || ""
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }
        }

        Row {
          spacing: Style.space(16)

          Dropdown {
            label: "Modèle"
            value: root.claudeModel
            options: root.modelOptions
            foreground: root.foreground
            accent: root.accentColor
            onChanged: function(v) { root.claudeModelSet(v) }
          }

          Dropdown {
            label: "Effort"
            value: root.claudeEffort
            options: root.effortOptions
            foreground: root.foreground
            accent: root.accentColor
            onChanged: function(v) { root.claudeEffortSet(v) }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            text: "Consignes supplémentaires (optionnel)"
            color: root.faint
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
          }

          Rectangle {
            width: parent.width
            height: 70
            color: "transparent"
            border.color: root.faint
            border.width: 1
            radius: Style.cornerRadius

            TextArea {
              id: extraInstructionsField
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: root.extraInstructions
              placeholderText: "Ex. : ignore les guillemets typographiques…"
              wrapMode: TextEdit.Wrap
              color: root.foreground
              font.family: root.uiFont
              font.pixelSize: Style.font.bodySmall
              background: null
              onTextChanged: root.extraInstructions = text
            }
          }
        }

        Button {
          iconText: "\uf04b"
          text: root.reviewing ? "Analyse en cours…" : "Lancer la vérification"
          enabled: !root.reviewing && !root.docEmpty
          bordered: true
          foreground: root.foreground
          accent: root.accentColor
          onClicked: root.reviewRequested(root.selectedKind, root.selectedKind === "syntaxe" ? root.syntaxeMode : "", root.extraInstructions)
        }

        Row {
          visible: root.reviewing
          spacing: Style.space(14)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "⏱ " + root.formatElapsed(root.reviewElapsedMs)
              + (root.reviewOutputTokens > 0 ? ("  ·  ~" + root.reviewOutputTokens + " tokens générés") : "")
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            iconText: "\uf00d"
            text: "Annuler"
            bordered: true
            foreground: root.foreground
            accent: root.urgentColor
            onClicked: root.cancelRequested()
          }
        }

        Text {
          visible: root.reviewError !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.reviewError
          color: root.urgentColor
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        Column {
          visible: root.hasResult
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: "Journal des corrections proposées — " + (root.kindLabels[root.reviewKind] || root.reviewKind)
              + (root.reviewKind === "syntaxe" ? (" (" + (root.modeLabels[root.syntaxeMode] || root.syntaxeMode) + ")") : "")
            color: root.foreground
            font.family: root.uiFont
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          ScrollView {
            id: reviewLogScroll
            width: parent.width
            height: 180
            clip: true
            ScrollBar.vertical.policy: ScrollBar.AsNeeded

            Text {
              width: reviewLogScroll.availableWidth
              textFormat: Text.PlainText
              text: root.reviewLog
              color: root.foreground
              font.family: "monospace"
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }

          Text {
            text: "Comparaison — modifie la colonne de droite si besoin (une proposition non modifiée est validée telle quelle) :"
            color: root.dim
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            width: parent.width
          }

          Text {
            visible: !root.diffHighlighted
            text: "⚠ Trop de différences pour les surligner mot à mot sur ce document — la proposition ci-dessous n'est pas colorée, vérifie-la directement."
            color: root.urgentColor
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            width: parent.width
          }

          Row {
            width: parent.width
            height: 280
            spacing: Style.space(10)

            Column {
              width: (parent.width - parent.spacing) / 2
              height: parent.height
              spacing: Style.space(4)

              Text {
                text: "Texte original"
                color: root.faint
                font.family: root.uiFont
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                width: parent.width
                height: parent.height - Style.space(20)
                color: "transparent"
                border.color: root.faint
                border.width: 1
                radius: Style.cornerRadius
                clip: true

                ScrollView {
                  id: originalTextScroll
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  clip: true
                  ScrollBar.vertical.policy: ScrollBar.AsNeeded

                  Text {
                    width: originalTextScroll.availableWidth
                    textFormat: Text.PlainText
                    text: root.reviewOriginalText
                    color: root.foreground
                    font.family: "monospace"
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                  }
                }
              }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              height: parent.height
              spacing: Style.space(4)

              Text {
                text: "Proposition (modifiable)"
                color: root.faint
                font.family: root.uiFont
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                width: parent.width
                height: parent.height - Style.space(20)
                color: "transparent"
                border.color: root.accentColor
                border.width: 1
                radius: Style.cornerRadius
                clip: true

                ScrollView {
                  id: correctionScroll
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  clip: true
                  ScrollBar.vertical.policy: ScrollBar.AsNeeded

                  TextEdit {
                    id: correctionEdit
                    width: correctionScroll.availableWidth
                    textFormat: TextEdit.RichText
                    color: root.foreground
                    selectionColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.35)
                    font.family: "monospace"
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    persistentSelection: true
                    cursorVisible: true
                    readOnly: false
                  }
                }
              }
            }
          }

          Button {
            iconText: "\uf00c"
            text: "Appliquer les corrections retenues au document"
            bordered: true
            foreground: root.foreground
            accent: root.accentColor
            onClicked: root.applyRequested(root.normalize(correctionEdit.getText(0, correctionEdit.length)))
          }
        }
      }
    }
  }
}
