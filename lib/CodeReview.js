// Builds the prompts for GH Typst's Claude-powered review tools in the
// "Claude" tab — three deliberately separate categories, never folded
// together (Gabriel's explicit instruction, 2026-08-29):
//   - code: Typst syntax only, never prose.
//   - orthographe: a strict lexical spellchecker only — typos, homophone
//     confusions (ses/ces, a/à, tout/tous...), doubled/missing
//     consonants, accents. Always strict, no mode: Gabriel's own words,
//     "il s'agit d'un spellchecker au sens premier du terme" — never
//     touches sentence structure, that's syntaxe's job.
//   - syntaxe: grammatical sentence-structure review, distinct from
//     orthographe and gated by SYNTAXE_MODES (strict/permissif/creatif,
//     same three-tier vocabulary as [[omaslide-plugin]]'s own
//     CONTENT_MODES) — how much latitude Claude has to rephrase.
// Originally Claude's tab was code-only, prose reserved for Antidote —
// but Antidote has no non-pro API and its round trip (see
// [[ghtypst-plugin]] memory / Panel.qml's Antidote-tab comment) is
// manual, so these prose tools are a quick in-app alternative Gabriel
// asked for on top of that, not a replacement for it.
//
// Contract, all three tools: Claude reads a snapshot of the current
// buffer, writes the corrected file to outPath and a plain-text bullet
// log of what it changed (and why) to logPath. File-based results, not
// parsed free text (same reasoning as OmaSlide's single-slide flow: a
// real file is a reliable contract; parsing free-form chat text back
// into structured data is not). The UI applies the correction only after
// the user reviews it (log + the two-column diff) — this never silently
// overwrites the live buffer.

var SYNTAXE_MODES = ["strict", "permissif", "creatif"]

function buildCodeReviewPrompt(srcPath, outPath, logPath, extraInstructions) {
  var lines = []
  lines.push("Tu es un correcteur de CODE Typst, pas de prose.")
  lines.push("Lis le fichier source Typst à ce chemin exact : " + srcPath)
  lines.push("")
  lines.push("Ta seule tâche : trouver et corriger les erreurs de CODE Typst — parenthèses/crochets/accolades non fermés, appels de fonction malformés, arguments manquants ou du mauvais type, références à des variables ou fonctions non définies quand la correction est évidente et sûre.")
  lines.push("Ne touche JAMAIS au texte en prose : ni l'orthographe, ni le style, ni la formulation, ni le contenu rédactionnel. Si une ligne de texte brut n'a aucun problème de code, laisse-la caractère pour caractère identique.")
  lines.push("Si le fichier ne contient aucune erreur de code, écris quand même le fichier de sortie (identique à l'original) et un journal indiquant qu'aucune correction n'était nécessaire.")
  lines.push("")
  lines.push("Écris le résultat dans EXACTEMENT ces deux fichiers, rien d'autre :")
  lines.push("1. " + outPath + " — le contenu Typst complet et corrigé (le fichier entier, pas un extrait, pas de balises de code autour).")
  lines.push("2. " + logPath + " — une liste à puces en texte brut de chaque correction apportée (une ligne par correction : numéro de ligne approximatif, ce qui a été changé, pourquoi). Une seule ligne \"Aucune correction nécessaire.\" si rien n'a été changé.")
  lines.push("")
  lines.push("Ne crée et ne modifie aucun autre fichier. N'écris rien sur la sortie standard au-delà de ce qui est nécessaire au bon déroulement de la tâche.")
  _appendExtraInstructions(lines, extraInstructions)
  return lines.join("\n")
}

// Appended identically by all three builders, right at the end — a free
// text box in the Révision tab (Gabriel's explicit ask, 2026-08-29) for
// one-off instructions ("ignore les guillemets typographiques", etc.)
// that don't warrant a whole new mode/category. Kept last and clearly
// delimited so it reads as a supplement to the fixed rules above, never
// a replacement for them.
function _appendExtraInstructions(lines, extraInstructions) {
  var extra = (extraInstructions || "").trim()
  if (extra === "") return
  lines.push("")
  lines.push("Consignes supplémentaires données par l'utilisateur pour cette vérification précise (viennent en complément des règles ci-dessus, ne les contredisent pas) :")
  lines.push(extra)
}

function buildOrthographeReviewPrompt(srcPath, outPath, logPath, extraInstructions) {
  var lines = []
  lines.push("Tu es un correcteur ORTHOGRAPHIQUE français — un simple spellchecker, pas un correcteur de style ni un correcteur de code.")
  lines.push("Lis le fichier source Typst à ce chemin exact : " + srcPath)
  lines.push("")
  lines.push("Ta seule tâche : corriger les fautes d'orthographe LEXICALE dans le texte en PROSE française (le contenu rédactionnel destiné à être lu, pas le code) — et rien d'autre :")
  lines.push("- fautes de frappe (lettres manquantes, inversées, en trop)")
  lines.push("- confusions d'homonymes grammaticaux (ses/ces, a/à, tout/tous/toute/toutes, ou/où, et/est, son/sont, etc.)")
  lines.push("- consonnes doublées manquantes ou en trop")
  lines.push("- accents manquants, en trop ou mal placés")
  lines.push("Ceci provient souvent d'un texte extrait d'une capture d'écran (OCR) : les fautes typiques de ce genre de source (accent oublié, caractère mal reconnu) sont exactement ce qu'il faut chasser.")
  lines.push("")
  lines.push("Ne touche JAMAIS : à la tournure des phrases, à la syntaxe grammaticale, au style, au choix des mots, à la ponctuation au-delà d'une faute d'orthographe évidente — cela relève d'un autre outil, pas de toi. Ne touche JAMAIS au code Typst : ni les marqueurs #commande, ni les crochets/parenthèses/accolades, ni les noms de variables ou fonctions, ni les chemins de fichiers, ni la syntaxe de mise en forme. Si une ligne est entièrement du code, laisse-la caractère pour caractère identique.")
  lines.push("Si le fichier ne contient aucune faute d'orthographe lexicale, écris quand même le fichier de sortie (identique à l'original) et un journal indiquant qu'aucune correction n'était nécessaire.")
  lines.push("")
  lines.push("Écris le résultat dans EXACTEMENT ces deux fichiers, rien d'autre :")
  lines.push("1. " + outPath + " — le contenu Typst complet et corrigé (le fichier entier, pas un extrait, pas de balises de code autour).")
  lines.push("2. " + logPath + " — une liste à puces en texte brut de chaque correction apportée (une ligne par correction : numéro de ligne approximatif, ce qui a été changé, pourquoi). Une seule ligne \"Aucune correction nécessaire.\" si rien n'a été changé.")
  lines.push("")
  lines.push("Ne crée et ne modifie aucun autre fichier. N'écris rien sur la sortie standard au-delà de ce qui est nécessaire au bon déroulement de la tâche.")
  _appendExtraInstructions(lines, extraInstructions)
  return lines.join("\n")
}

function buildSyntaxeReviewPrompt(srcPath, outPath, logPath, mode, extraInstructions) {
  var m = SYNTAXE_MODES.indexOf(mode) !== -1 ? mode : "strict"
  var lines = []
  lines.push("Tu es un correcteur SYNTAXIQUE et GRAMMATICAL français — tu travailles sur la construction des phrases, pas sur l'orthographe lexicale (fautes de frappe, homonymes, accents : un autre outil s'en charge déjà, n'y touche pas) et pas sur le code.")
  lines.push("Lis le fichier source Typst à ce chemin exact : " + srcPath)
  lines.push("")
  lines.push("Ta seule tâche : corriger la syntaxe grammaticale du texte en PROSE française — accords (genre, nombre, participes passés), conjugaisons, construction des phrases, ponctuation liée à la structure de la phrase.")
  if (m === "strict") {
    lines.push("Mode STRICT : ne propose AUCUN changement dans la tournure des phrases. Corrige uniquement ce qui est grammaticalement incorrect (accord, conjugaison, structure fautive), en restant au plus près de la phrase d'origine — même nombre de mots, même ordre, dans la mesure du possible.")
  } else if (m === "permissif") {
    lines.push("Mode PERMISSIF : tu peux modifier la tournure d'une phrase si c'est nécessaire pour corriger une construction fautive ou clarifier un sens ambigu, mais ne reformule pas une phrase déjà correcte simplement parce qu'une autre tournure te semble meilleure.")
  } else {
    lines.push("Mode CRÉATIF : tu es autorisé à proposer des reformulations de phrases, y compris des phrases déjà grammaticalement correctes, si tu penses qu'une autre tournure sert mieux le texte. Reste fidèle au sens et au ton d'origine.")
  }
  lines.push("Ne touche JAMAIS aux fautes d'orthographe lexicale pures (frappe, homonymes, accents) si la phrase est par ailleurs grammaticalement correcte — laisse-les intactes, un autre outil s'en occupe. Ne touche JAMAIS au code Typst : ni les marqueurs #commande, ni les crochets/parenthèses/accolades, ni les noms de variables ou fonctions, ni les chemins de fichiers, ni la syntaxe de mise en forme. Si une ligne est entièrement du code, laisse-la caractère pour caractère identique.")
  lines.push("Si le fichier ne contient aucune faute syntaxique/grammaticale (compte tenu du mode ci-dessus), écris quand même le fichier de sortie (identique à l'original) et un journal indiquant qu'aucune correction n'était nécessaire.")
  lines.push("")
  lines.push("Écris le résultat dans EXACTEMENT ces deux fichiers, rien d'autre :")
  lines.push("1. " + outPath + " — le contenu Typst complet et corrigé (le fichier entier, pas un extrait, pas de balises de code autour).")
  lines.push("2. " + logPath + " — une liste à puces en texte brut de chaque correction apportée (une ligne par correction : numéro de ligne approximatif, ce qui a été changé, pourquoi). Une seule ligne \"Aucune correction nécessaire.\" si rien n'a été changé.")
  lines.push("")
  lines.push("Ne crée et ne modifie aucun autre fichier. N'écris rien sur la sortie standard au-delà de ce qui est nécessaire au bon déroulement de la tâche.")
  _appendExtraInstructions(lines, extraInstructions)
  return lines.join("\n")
}

// --output-format stream-json (requires --verbose) makes the CLI emit one
// JSON object per line as it works instead of only at the very end —
// Panel.qml's reviewProc parses this live to drive the tab's elapsed
// time/token-count indicator (Gabriel's explicit ask, 2026-08-29: a long
// review gave no sign of life at all before this).
// model/effort: "" means omit the flag entirely (claude -p's own
// default) — Gabriel's explicit choice, 2026-08-29, so this feature adds
// resource control without silently changing what every review already
// ran with by default before it existed.
function buildCommand(promptText, model, effort) {
  var cmd = ["claude", "-p", promptText, "--dangerously-skip-permissions", "--output-format", "stream-json", "--verbose"]
  if (model) cmd.push("--model", model)
  if (effort) cmd.push("--effort", effort)
  return cmd
}

// Parses one stream-json line into {outputTokens: number} for the
// running token-count indicator, or null if the line isn't an assistant
// message (system/init, tool results, the final result summary, etc. —
// none of those carry the per-turn usage this indicator sums). Never
// throws on a malformed/partial line — streamed stdout can in principle
// hand SplitParser a line mid-write.
function parseStreamEvent(line) {
  var obj
  try { obj = JSON.parse(line) } catch (e) { return null }
  if (!obj || typeof obj !== "object") return null
  if (obj.type === "assistant" && obj.message && obj.message.usage
    && typeof obj.message.usage.output_tokens === "number") {
    return { outputTokens: obj.message.usage.output_tokens }
  }
  return null
}
