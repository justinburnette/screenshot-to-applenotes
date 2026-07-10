// Usage: ocr <path-to-image>  (build: swiftc ocr.swift -O -o ocr)
import Foundation
import ImageIO
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("Error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    fail("missing image path.\nUsage: \(arguments.first ?? "ocr") <path-to-image>")
}

let path = arguments[1]
let fileURL = URL(fileURLWithPath: path)

guard FileManager.default.fileExists(atPath: fileURL.path) else {
    fail("file not found: \(path)")
}

guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fail("could not decode image: \(path)")
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

do {
    // VNImageRequestHandler.perform(_:) is synchronous for still images --
    // request.results is populated by the time this call returns.
    try handler.perform([request])
} catch {
    fail("OCR request failed: \(error.localizedDescription)")
}

struct Line {
    let text: String
    let box: CGRect
}

var lines: [Line] = (request.results ?? []).compactMap { observation in
    guard let text = observation.topCandidates(1).first?.string else { return nil }
    return Line(text: text, box: observation.boundingBox)
}

guard !lines.isEmpty else {
    print("")
    exit(0)
}

// Deliberately not re-sorted by position: Vision's own detection order
// already handles multi-region layouts (sidebar + editor + terminal, etc.)
// correctly, since it reasons about regions as a whole. A naive top-to-bottom
// coordinate sort interleaves unrelated side-by-side regions at the same
// height and scrambles reading order -- confirmed by testing against a
// multi-pane IDE screenshot.

// Some renderers (e.g. e-textbook readers with inline hyperlinked citations
// or glossary terms) draw a small icon glyph right after a linked span. That
// occasionally makes Vision split ONE visual line into 2-3 separate
// observations sitting on the same row (near-identical y, sequential x)
// instead of returning it as one -- confirmed against real screenshots via
// bounding-box dumps (e.g. "...Chapters 10" + "• and 11" both at y~0.18,
// the "•" being Vision's misread of the icon). Glue same-row fragments back
// into one line *before* paragraph reflow, using vertical overlap plus a
// horizontal gap capped well below a typical multi-pane column gutter, so
// side-by-side panes from the regression above are never merged this way.
func mergeSameRowFragments(_ lines: [Line]) -> [Line] {
    guard lines.count > 1 else { return lines }
    let medianHeight = lines.map { $0.box.height }.sorted()[lines.count / 2]
    let maxRowGap = min(0.04, max(0.02, 2.0 * medianHeight))
    // How far (vertically) to look when deciding whether "no wide line near
    // this row" applies -- scoped to nearby rows rather than the whole image,
    // so an unrelated wide line elsewhere on the page (a different paragraph,
    // or a maximized pane far from this one) can't disable the guard for a
    // genuine side-by-side split happening here.
    let localYRange = 5.0 * medianHeight

    var merged: [Line] = [lines[0]]
    for current in lines.dropFirst() {
        let previous = merged[merged.count - 1]
        let overlapY = max(0, min(previous.box.maxY, current.box.maxY) - max(previous.box.minY, current.box.minY))
        let yOverlapRatio = overlapY / min(previous.box.height, current.box.height)
        let xGap = current.box.minX - previous.box.maxX
        let unionWidth = max(previous.box.maxX, current.box.maxX) - min(previous.box.minX, current.box.minX)
        let rowMidY = (previous.box.midY + current.box.midY) / 2
        let localMaxWidth = lines
            .filter { abs($0.box.midY - rowMidY) <= localYRange }
            .map { $0.box.width }
            .max() ?? 0

        let sameRowSplit = yOverlapRatio >= 0.55
            && current.box.minX >= previous.box.minX - 0.005
            && current.box.maxX > previous.box.maxX
            && xGap >= -0.5 * medianHeight
            && xGap <= maxRowGap
            && !(localMaxWidth < 0.70 && unionWidth > localMaxWidth * 1.35)

        if sameRowSplit {
            // A lone bullet-like glyph at the start of a same-row fragment is
            // Vision misreading the icon itself, not real list content --
            // a real list bullet starts a whole line/paragraph, never a
            // mid-sentence continuation like this.
            var text = current.text
            for marker in ["\u{2022} ", "\u{00B7} ", "\u{2023} "] where text.hasPrefix(marker) {
                text.removeFirst(marker.count)
            }
            merged[merged.count - 1] = Line(text: previous.text + " " + text, box: previous.box.union(current.box))
        } else {
            merged.append(current)
        }
    }
    return merged
}

lines = mergeSameRowFragments(lines)

// Reflow wrapped lines into paragraphs. A line only continues the previous
// one when the previous line runs nearly the full observed column width
// (i.e. it wrapped at the margin, rather than ending by choice) and the gap
// between them is a normal single-line gap. That tells prose apart from
// short/standalone lines (headings, list items, UI labels), which are left
// on their own line either way.
let maxWidth = lines.map { $0.box.width }.max() ?? 0
let avgHeight = lines.map { $0.box.height }.reduce(0, +) / CGFloat(lines.count)
let wideEnoughToWrap = maxWidth * 0.85
let normalLineGap = avgHeight * 1.3

var paragraphs: [String] = [lines[0].text]
for i in 1..<lines.count {
    let previous = lines[i - 1]
    let current = lines[i]
    let gap = previous.box.origin.y - (current.box.origin.y + current.box.height)
    let continuesParagraph = previous.box.width >= wideEnoughToWrap && gap <= normalLineGap

    let last = paragraphs.removeLast()
    if continuesParagraph {
        if last.hasSuffix("-"), let beforeHyphen = last.dropLast().last, beforeHyphen.isLetter {
            paragraphs.append(String(last.dropLast()) + current.text)
        } else {
            paragraphs.append(last + " " + current.text)
        }
    } else {
        paragraphs.append(last)
        paragraphs.append(current.text)
    }
}

// Strip in-text citations so Notes' text-to-speech reads cleanly.
// \n is excluded from all bodies so a match can never span a paragraph
// break.
//
// - citePrefix: optional "(e.g., " / "(i.e., " lead-in before an author
//   name. Only used in author-first-shaped patterns -- narrativePattern is
//   year-first, so allowing a prose prefix there would make it match plain
//   parenthetical asides instead of citations.
// - authorFirstPattern: "(Perosa, 1996)" / "(Shields et al., 1994, p. 121)"
//   / "(e.g., Nurmi, 1991)" / "(Galván, 2020)". Requires a comma directly
//   before the year with only letters/names in between (no digits) so
//   dates like "(Aug 14 / 15, 2026)" are correctly left alone -- a bare
//   "capitalized word + year" check was tried first and false-matched
//   exactly that case. Uses \p{L}/\p{M} (not a-z) so accented author names
//   (e.g. "Galván") match -- OCR'd non-ASCII letters can appear as either a
//   single precomposed codepoint or a base letter + combining accent mark,
//   and \p{M} covers the latter.
// - narrativePattern: "Erikson (1950/1963, 1968)" / "a "ground plan" (1968,
//   p. 92)" -- the author is already named in the running prose, so only
//   year(s)/page(s) are inside the parens. Requires a leading 19xx/20xx year
//   (so "(Aug 14 / 15, 2026)" still can't match) and caps trailing junk at 4
//   chars so it only absorbs stray OCR noise immediately before the ")"
//   (e.g. a misread hyperlink-icon glyph), not an actual word/phrase like
//   "(2026 release)".
// - pageOnlyPattern: "(p. 1011)" / "(pp. 10-12)" -- a follow-up reference to
//   an author/year already cited earlier in the same paragraph, so neither
//   appears again here. Requires the number to be the very last thing before
//   ")" (only an optional dash-range in between), so it can't accidentally
//   eat a longer parenthetical that merely starts with "p." for some other
//   reason.
// - compoundSemicolonPattern: "(2017; Steinberg & Icenogle, 2019)" -- a
//   narrative-style bare-year citation followed by one or more "; Author,
//   Year" continuations in the same parens (shorthand for citing the same
//   claim across multiple sources). Runs before the simpler patterns since
//   it must claim the whole span, closing paren included, or those patterns
//   would otherwise only strip the first segment and strand "; Author,
//   Year)" behind.
// - compoundListPattern: "(e.g., compare Shulman et al., 2016, to Romer et
//   al., 2017, or Do et al., 2020)" -- like compoundSemicolonPattern, but
//   the segments are author-first (not bare-year-led) and joined by "to"/
//   "or"/"and"/";" instead of only ";", with an optional leading "compare "
//   (seen alongside "e.g.,"). Each segment still requires its own capital
//   letter + ", year" shape, so a plain aside like "(roughly 2020, or
//   perhaps 2021)" can't match -- "perhaps" isn't capitalized and has no
//   ", year" of its own.
// - compoundSemicolonListPattern / missingCompoundSemicolonListPattern:
//   "(Bogaerts et al., 2021; Hatano et al., 2022a; Sznitman et al., 2019)"
//   -- unlike compoundSemicolonPattern, EVERY segment is author-first (no
//   bare-year lead segment). The OCR icon-glyph problem shows up here in
//   two ways: (1) trailing junk before a ";" (citationJunk, which now also
//   allows a lone lowercase "l" -- confirmed via bounding-box dump as a
//   real OCR misread of the icon glyph in this context) and (2) the ";"
//   itself sometimes getting swallowed entirely, leaving only whitespace +
//   a junk glyph between two segments (junkListSep) -- confirmed via
//   bounding-box dump showing "Stephen et al., 1992" and "Waterman, 1993a"
//   as two separate same-row OCR fragments with no ";" observation between
//   them at all. junkListSep still requires the next segment to start with
//   a capital letter, so it can't fire on ordinary prose. The missing-close
//   variant reuses noNearClose; no extra corroboration signal (et al./&) is
//   required beyond 2+ valid "Author, Year" segments, since that structure
//   is already distinctive enough on its own (unlike the single-citation
//   missing-paren patterns, which need it to rule out one-off false
//   positives like "(Smith, 2020 Corporation launched...)").
// - acronymCitationPattern: "(IPT; Klerman et al., 1984, see Chapter 11)"
//   -> "(IPT)". Unlike every other pattern, this one keeps part of its
//   match (the acronym) via a capture-group replacement template instead of
//   deleting outright -- the acronym is real reader content (it's the
//   short name the surrounding prose keeps referring back to), only the
//   citation trailing it should go. Runs as a separate first pass, before
//   the deletion patterns, so by the time compoundSemicolonListPattern
//   etc. run, "(IPT; Klerman et al., 1984...)" has already become "(IPT)"
//   and won't be touched again. acronymBody allows internal hyphens/digits
//   (e.g. "MB-EAT") since some program-name acronyms include them.
//   acronymCitationMissingParen mirrors this for the same OCR icon-glyph
//   paren-swallowing problem as the other missing-paren patterns, but the
//   continuation here is usually mid-sentence lowercase prose (e.g.
//   "(MB-EAT; Kristeller & Hallett, 1999 is a group treatment..."), not a
//   new capitalized sentence, so its lookahead also accepts a lowercase
//   word. Its trailing-junk allowance is limited to icon-glyph chars only
//   (no generic multi-char buffer like the real-close-paren variant) --
//   an early version used the same generic buffer and it silently ate part
//   of the following sentence before finding a lookahead match further in.
// - namePart: optional lowercase name-particle prefix ("van", "de la",
//   "von", etc.) before the required capital letter, so names like "van de
//   Bongardt" or "Mac Donald" aren't rejected for not starting with a
//   capital. Requires the particle to be one of a fixed, known list (not
//   just "any lowercase word") so ordinary prose like "the van drove away
//   (Smith, 2020)" can't have "van" misread as part of the citation.
// - citePrefix/compareCitePrefix also accept a "see " lead-in now (e.g.
//   "(see Piaget & Inhelder, 1951/1976)"), alongside "e.g."/"i.e.". A
//   trailing comma after these lead-ins is now optional (some are written
//   "see Author" with no comma at all), which also fixes "(see Figure
//   9.2)" being left alone since "Figure" isn't followed by ", year".
// - missingParenEndOfText's optional trailing icon-junk no longer requires
//   a space before it -- OCR sometimes glues the junk glyph directly onto
//   the year with no space at all (e.g. "(Skoog et al., 2016|" at a
//   paragraph break).
// - missingParenMidSentenceA/B/C and missingParenEndOfText: some OCR'd
//   citations never get a detected closing ")" at all -- the source PDF
//   viewer's inline hyperlink icon after the citation sometimes swallows the
//   ")" glyph entirely (confirmed via bounding-box dumps: text transitions
//   directly from the citation into the next sentence, or into end-of-text,
//   with no ")" observation ever present). Two shapes are handled:
//     - End of paragraph/string right after the citation: safe to strip
//       unconditionally (no more text follows, so nothing can be
//       mistakenly swallowed).
//     - Mid-sentence (next non-junk char is uppercase, i.e. what looks like
//       a new sentence starting): this alone is NOT safe, since a real,
//       complete parenthetical like "(Smith, 2020 Corporation launched a
//       new program)" would falsely qualify. Two guards are required
//       together: (1) noNearClose -- no real ")" appears within the next 80
//       non-paren characters, so a citation that actually does close later
//       in the same sentence/paragraph is left to the other patterns; (2) a
//       corroborating signal that this really is a citation, not prose --
//       either a multi-author marker ("&" / "et al.", branch A), an
//       "e.g./i.e." lead-in (branch B), or a stray OCR icon-glyph fragment
//       right after the year (branch C, e.g. the stray "L" the user
//       reported). A bare "(Smith, 2020 A longitudinal study found..." has
//       none of these signals and is correctly left alone. The "next thing
//       looks like a new sentence" lookahead requires 2+ letters (not a
//       lone capital) -- a single stray junk letter immediately followed by
//       a same-author continuation year, e.g. "(Brody et al., 2014 L,
//       2018", was previously misread as "L" starting a new sentence,
//       causing the pattern to stop short and strand ", 2018" behind
//       (caught via bounding-box verification against the real image,
//       where the citation continues onto a second, same-author year with
//       no closing paren ever detected -- handled by yearContinuation
//       below, allowing missingParenEndOfText to absorb any number of
//       repeated ", year" segments before reaching end of text).
func stripCitations(_ text: String) -> String {
    let citePrefix = #"(?:(?:e\.g\.|i\.e\.|see)\s*,?\s*)?"#
    let namePart = #"(?:(?:van|von|de|der|den|du|la|le|Mc|Mac)\s+)*"#
    let authorNameBody = #"[\p{L}\p{M}.&,\s'’-]{0,80}?"#
    let year = #"(?:19|20)\d{2}[a-z]?"#
    let shortYear = #"(?:19|20)?\d{2}[a-z]?"#
    let iconJunk = #"(?:[|•·●▪■□◦°]{1,3}|[A-Z]{1,2})"#
    let strongAuthorSignal = #"(?:&|\bet\s+al\.)"#
    let noNearClose = #"(?![^()\n]{0,80}\))"#

    let authorFirstPattern = #"\(\#(citePrefix)\#(namePart)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)(?:[^()\n]{0,120})?\)"#
    let narrativePattern = #"\((?:19|20)\d{2}[a-z]?(?:\s*/\s*(?:19|20)?\d{2}[a-z]?)*(?:\s*,\s*(?:(?:19|20)\d{2}[a-z]?(?:\s*/\s*(?:19|20)?\d{2}[a-z]?)*|p{1,2}\.\s*\d+(?:\s*[-–]\s*\d+)?))*[^()\n]{0,4}\)"#
    let pageOnlyPattern = #"\(p{1,2}\.\s*\d+(?:\s*[-–]\s*\d+)?\)"#
    let yearCluster = #"\#(year)(?:\s*/\s*\#(shortYear))*"#
    let authorFirstSegment = #"\#(citePrefix)\#(namePart)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)(?:\s*,\s*p{1,2}\.\s*\d+(?:\s*[-–]\s*\d+)?)?(?:[^();\n]{0,4})?"#
    let compoundSemicolonPattern = #"\(\s*\#(yearCluster)(?:[^();\n]{0,4})?(?:\s*;\s*\#(authorFirstSegment)){1,4}\s*\)"#
    let compareCitePrefix = #"(?:(?:e\.g\.|i\.e\.|see)\s*,?\s*)?(?:compare\s+)?"#
    let listSep = #"(?:;|,\s*(?:to|or|and))\s*"#
    let compoundListPattern = #"\(\s*\#(compareCitePrefix)\#(namePart)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)(?:\s*,\s*p{1,2}\.\s*\d+(?:\s*[-–]\s*\d+)?)?(?:[^();\n]{0,4})?(?:\s*\#(listSep)\#(compareCitePrefix)?\#(namePart)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)(?:\s*,\s*p{1,2}\.\s*\d+(?:\s*[-–]\s*\d+)?)?(?:[^();\n]{0,4})?){1,5}\s*\)"#
    let yearContinuation = #"(?:\s*\#(iconJunk)?\s*,\s*\#(year))*"#
    let missingParenEndOfText = #"\(\#(citePrefix)\#(namePart)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)\#(yearContinuation)(?:\s*\#(iconJunk))?(?=[ \t]*(?:\n|\z))"#
    let missingParenMidSentenceA = #"\(\#(citePrefix)\#(namePart)[\p{Lu}\p{Lt}]\#(authorNameBody)\#(strongAuthorSignal)[\p{L}\p{M}.\s'’-]{0,40}?,\s*\#(year)(?:\s+\#(iconJunk))?\#(noNearClose)(?=\s+[\p{Lu}\p{Lt}][\p{L}\p{M}])"#
    let missingParenMidSentenceB = #"\((?:e\.g\.|i\.e\.)\s*,\s*\#(namePart)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)(?:\s+\#(iconJunk))?\#(noNearClose)(?=\s+[\p{Lu}\p{Lt}][\p{L}\p{M}])"#
    let missingParenMidSentenceC = #"\(\#(namePart)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)\s+\#(iconJunk)\#(noNearClose)(?=\s+[\p{Lu}\p{Lt}][\p{L}\p{M}])"#
    let citationJunk = #"(?:[|•·●▪■□◦°]{1,3}|[A-Z]{1,2}|l)"#
    let authorFirstListSegment = #"\#(compareCitePrefix)\#(namePart)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)(?:\s*,\s*p{1,2}\.\s*\d+(?:\s*[-–]\s*\d+)?)?"#
    let semicolonAhead = #"(?=[^()\n]{0,240};)"#
    let semiListSep = #"\s*(?:\#(citationJunk)\s*){0,2};\s*"#
    let junkListSep = #"\s+\#(citationJunk)\s+(?=[\p{Lu}\p{Lt}])"#
    let flexListSep = #"(?:\#(semiListSep)|\#(junkListSep))"#
    let citationTailJunk = #"(?:\s+\#(citationJunk)){0,2}(?:[^();\n]{0,4})?"#
    let compoundSemicolonListPattern = #"\(\s*\#(semicolonAhead)\#(authorFirstListSegment)(?:\#(flexListSep)\#(authorFirstListSegment)){1,5}\#(citationTailJunk)\s*\)"#
    let missingCompoundSemicolonListPattern = #"\(\s*\#(semicolonAhead)\#(authorFirstListSegment)(?:\#(flexListSep)\#(authorFirstListSegment)){1,5}\#(citationTailJunk)\#(noNearClose)(?=\s+[\p{Lu}\p{Lt}][\p{L}\p{M}])"#
    // Same missing-close-paren list shape as above, but the paragraph ends
    // (or the screenshot's visible text is cut off) right after the last
    // segment instead of continuing into a new sentence -- confirmed via a
    // real image where a citation list is the very last thing OCR'd with
    // no ")" ever detected.
    let compoundSemicolonListEndOfText = #"\(\s*\#(semicolonAhead)\#(authorFirstListSegment)(?:\#(flexListSep)\#(authorFirstListSegment)){1,5}\#(citationTailJunk)(?=[ \t]*(?:\n|\z))"#
    let acronymBody = #"[A-Z][A-Z0-9-]{1,7}"#
    let acronymCitationPattern = #"\((\#(acronymBody)(?:\([^()\n]{1,40}\))?)\s*;\s*\#(authorFirstListSegment)(?:\#(flexListSep)\#(authorFirstListSegment)){0,5}(?:[^()\n]{0,80})?\)"#
    let acronymTailJunk = #"(?:\s*\#(citationJunk)){0,2}"#
    let acronymCitationMissingParen = #"\((\#(acronymBody))\s*;\s*\#(authorFirstListSegment)(?:\#(flexListSep)\#(authorFirstListSegment)){0,5}\#(acronymTailJunk)\#(noNearClose)(?=\s+[a-z]|\s+[\p{Lu}\p{Lt}][\p{L}\p{M}]|[ \t]*(?:\n|\z))"#

    // Acronym-preserving pass runs first and keeps the acronym via $1
    // instead of deleting the whole match, so by the time the deletion
    // patterns below run, "(IPT; Klerman et al., 1984)" is already "(IPT)"
    // and can't be touched again.
    var result = text
    for acronymPattern in [acronymCitationPattern, acronymCitationMissingParen] {
        if let acronymRegex = try? NSRegularExpression(pattern: acronymPattern) {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = acronymRegex.stringByReplacingMatches(in: result, range: fullRange, withTemplate: "($1)")
        }
    }

    let patterns = [
        compoundSemicolonListPattern,
        compoundListPattern,
        compoundSemicolonPattern,
        missingCompoundSemicolonListPattern,
        compoundSemicolonListEndOfText,
        missingParenMidSentenceA,
        missingParenMidSentenceB,
        missingParenMidSentenceC,
        missingParenEndOfText,
        authorFirstPattern,
        narrativePattern,
        pageOnlyPattern,
    ]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let fullRange = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: fullRange, withTemplate: "")
    }

    // A removed citation can leave "word  and" (double space) or "word ."
    // (space stranded before punctuation) -- tidy both up.
    result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    result = result.replacingOccurrences(of: #"[ \t]+([.,;:!?])"#, with: "$1", options: .regularExpression)
    return result
}

print(stripCitations(paragraphs.joined(separator: "\n\n")))
