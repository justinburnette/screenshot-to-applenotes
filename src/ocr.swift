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
//       none of these signals and is correctly left alone.
func stripCitations(_ text: String) -> String {
    let citePrefix = #"(?:(?:e\.g\.|i\.e\.)\s*,\s*)?"#
    let authorNameBody = #"[\p{L}\p{M}.&,\s'’-]{0,80}?"#
    let year = #"(?:19|20)\d{2}[a-z]?"#
    let shortYear = #"(?:19|20)?\d{2}[a-z]?"#
    let iconJunk = #"(?:[|•·●▪■□◦°]{1,3}|[A-Z]{1,2})"#
    let strongAuthorSignal = #"(?:&|\bet\s+al\.)"#
    let noNearClose = #"(?![^()\n]{0,80}\))"#

    let authorFirstPattern = #"\(\#(citePrefix)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)(?:[^()\n]{0,120})?\)"#
    let narrativePattern = #"\((?:19|20)\d{2}[a-z]?(?:\s*/\s*(?:19|20)?\d{2}[a-z]?)*(?:\s*,\s*(?:(?:19|20)\d{2}[a-z]?(?:\s*/\s*(?:19|20)?\d{2}[a-z]?)*|p{1,2}\.\s*\d+(?:\s*[-–]\s*\d+)?))*[^()\n]{0,4}\)"#
    let pageOnlyPattern = #"\(p{1,2}\.\s*\d+(?:\s*[-–]\s*\d+)?\)"#
    let yearCluster = #"\#(year)(?:\s*/\s*\#(shortYear))*"#
    let authorFirstSegment = #"\#(citePrefix)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)(?:\s*,\s*p{1,2}\.\s*\d+(?:\s*[-–]\s*\d+)?)?(?:[^();\n]{0,4})?"#
    let compoundSemicolonPattern = #"\(\s*\#(yearCluster)(?:[^();\n]{0,4})?(?:\s*;\s*\#(authorFirstSegment)){1,4}\s*\)"#
    let missingParenEndOfText = #"\(\#(citePrefix)[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)(?:\s+\#(iconJunk))?(?=[ \t]*(?:\n|\z))"#
    let missingParenMidSentenceA = #"\(\#(citePrefix)[\p{Lu}\p{Lt}]\#(authorNameBody)\#(strongAuthorSignal)[\p{L}\p{M}.\s'’-]{0,40}?,\s*\#(year)(?:\s+\#(iconJunk))?\#(noNearClose)(?=\s+[\p{Lu}\p{Lt}])"#
    let missingParenMidSentenceB = #"\((?:e\.g\.|i\.e\.)\s*,\s*[\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)(?:\s+\#(iconJunk))?\#(noNearClose)(?=\s+[\p{Lu}\p{Lt}])"#
    let missingParenMidSentenceC = #"\([\p{Lu}\p{Lt}]\#(authorNameBody),\s*\#(year)\s+\#(iconJunk)\#(noNearClose)(?=\s+[\p{Lu}\p{Lt}])"#

    var result = text
    let patterns = [
        compoundSemicolonPattern,
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
