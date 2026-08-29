# App Store listing copy (Mac)

The text that goes into App Store Connect for **md** on the Mac App Store,
kept next to the code it describes — the Mac counterpart of the Android
repo's `play/` folder. One file per field, plain text, paste as-is.

| File | App Store Connect field | Limit | Current |
| --- | --- | --- | --- |
| `promotional-text.txt` | Promotional Text | 170 | 160 |
| `description.txt` | Description | 4000 | 3981 |
| `keywords.txt` | Keywords | 100 | 99 |
| `whats-new.txt` | What's New in This Version | 4000 | 2732 |
| `review-notes.txt` | App Review Information ▸ Notes | 4000 | 3972 |

Promotional Text can be changed at any time without submitting a new build;
the Description and What's New ship with a version.

## No angle brackets

App Store Connect rejects `<` and `>` in these fields — it reads them as
markup and answers *"This field contains one or more invalid characters."*
So the private-notes bullet describes the syntax in words ("an HTML comment
… whose text begins with note:") instead of showing `<!-- note: … -->`.
Keep it that way, and don't paste Markdown or HTML samples into the store
copy.

Bullets (•), em dashes (—), curly quotes and the keyboard glyphs
(⌘ ⌃ ↑ ↓) are ordinary Unicode and are accepted — Apple's own listings use
them. If a field ever refuses them anyway, `description-plain-fallback.txt`
and `whats-new-plain-fallback.txt` carry the same copy in plain ASCII
("Command-1", "Control-Command-Up", hyphen bullets).

## Ground rules these texts follow

Every claim was checked against the shipping build — App Review's
"Accurate Metadata" guideline is what a listing gets rejected on, and the
listing must describe *this* version, not the roadmap.

- No references to other platforms (the iPhone / iPad and Android siblings
  are deliberately not mentioned), no competitor comparisons, no pricing,
  promotions or "free", no unverifiable superlatives, no rating requests.
- Third-party names (Markdown, LaTeX, KaTeX, Mermaid, Graphviz, PlantUML,
  EPUB) are used descriptively, and Apple's (Mac, macOS, Finder, iCloud
  Drive) without implying endorsement.
- Privacy claims match the code *and* `PRIVACY.md` — the policy the
  listing links to. Both say the same thing: nothing is collected, and the
  only network use is fetching an image a document itself points at.
  The Privacy Nutrition Label answer that matches this build is
  **Data Not Collected**, with no tracking.

## Wording that must not drift back

Three claims were corrected because the build contradicts the obvious
version of them:

- **Not** "no third-party dependencies" — the app bundles KaTeX, Mermaid,
  Graphviz and PlantUML. Only the Swift side is package-free.
- Private notes are hidden from the preview / PDF / print **only when the
  `<!-- note: … -->` comment is on its own line**; inline, it renders.
- Pagination is line-aware for *text*. A diagram taller than the page can
  still be split, so the copy does not promise otherwise.

## Keywords

Comma-separated, no spaces (spaces count against the 100). Singular forms
only — the App Store already matches plurals and combinations, so "note"
also serves "notes", and "markdown editor" is found from the two separate
words. Terms already in the app name or subtitle are wasted here, so drop
any that appear there. Never include another app's name or a trademark
(that is a 2.3.7 rejection); everything in `keywords.txt` is a generic
term for what the app does.

## Review notes

`review-notes.txt` answers, up front, the seven things App Review asked
for when 1.0 went on a Guideline 2.1 "information needed" hold: what the
app is for, how to reach every feature without an account, what the
network entitlement is really for, and why bundled JavaScript engines are
not downloaded code (2.5.2). It also states the Privacy Nutrition Label
answer that matches the build — Data Not Collected.

If App Review asks for a screen recording again, the walkthrough in §2 is
the script: it exercises every new 1.2 feature in about three minutes.

## If 1.1 never shipped on the Mac App Store

`whats-new.txt` covers 1.2 only. Should the store still be on 1.0, add the
1.1 headline as a first bullet:

    • Math, Mermaid and PlantUML now render in the preview, the printout
      and the PDF — drawn on your Mac, offline.
