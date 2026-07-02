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

// Strip in-text citations like "(Perosa, 1996)" or "(Shields et al., 1994, p.
// 121)" so Notes' text-to-speech reads cleanly. Requires a comma directly
// before the year with only letters/names in between (no digits) so dates
// like "(Aug 14 / 15, 2026)" are correctly left alone -- a bare "capitalized
// word + year" check was tried first and false-matched exactly that case.
// \n is excluded from the body so a match can never span a paragraph break.
func stripCitations(_ text: String) -> String {
    let citationPattern = #"\([A-Z][a-zA-Z.&,\s-]{0,80}?,\s*(?:19|20)\d{2}[a-z]?(?:[^()\n]{0,120})?\)"#
    guard let regex = try? NSRegularExpression(pattern: citationPattern) else { return text }
    let fullRange = NSRange(text.startIndex..., in: text)
    var result = regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")

    // A removed citation can leave "word  and" (double space) or "word ."
    // (space stranded before punctuation) -- tidy both up.
    result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    result = result.replacingOccurrences(of: #"[ \t]+([.,;:!?])"#, with: "$1", options: .regularExpression)
    return result
}

print(stripCitations(paragraphs.joined(separator: "\n\n")))
