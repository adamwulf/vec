#!/usr/bin/env swift
//
// E12 synthetic-image generator.
//
// Renders the E12 synthetic distinct-topic sample images with CoreText onto a
// white CGContext bitmap and writes each as a PNG via ImageIO. The rendered
// text is high-contrast black-on-white in a large, legible sans-serif so that
// Vision OCR reads it cleanly. Every string here is ASCII on purpose: it keeps
// OCR (and the frozen rubric criteria) robust and avoids accent-decoding edge
// cases.
//
// IMPORTANT — the COMMITTED PNG bytes under sample/synthetic/ are the frozen,
// authoritative inputs (their sha256 is pinned in sample/manifest.json). This
// generator documents exactly how they were produced and can re-render
// visually-equivalent images, but PNG bytes are NOT guaranteed bit-identical
// across macOS / font versions (font rasterization and the ImageIO PNG encoder
// can differ). So a re-run is a reproduction aid, NOT a bit-exact regeneration
// — the manifest hashes, not this script, define the sample.
//
// Usage:
//   swift generate-synthetic-images.swift <output-directory>
//
// It writes exactly the 12 synthetic images (11 rubric targets + 1 distractor).

import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct ImageSpec {
    let filename: String
    let title: String
    let body: [String]
}

// 11 distinct-topic rubric TARGETS + 1 unlabeled synthetic DISTRACTOR
// (knitting-gauge). Topics are deliberately unrelated to each other and to the
// four real targets (Jan-6 charges, operational transformation, fractional
// indexing, Minecraft) so retrieval is unambiguous — an easy-topic bias that
// the report calls out explicitly.
let specs: [ImageSpec] = [
    ImageSpec(filename: "sourdough-hydration.png",
              title: "Sourdough Bread Hydration",
              body: ["A country loaf uses 75 percent hydration.",
                     "Feed the starter, then bulk ferment for four hours.",
                     "The Tartine method folds the dough every 30 minutes."]),
    ImageSpec(filename: "titan-methane-lakes.png",
              title: "Titan, Moon of Saturn",
              body: ["Titan is the only moon with a thick atmosphere.",
                     "Liquid methane fills Kraken Mare near the north pole.",
                     "The Cassini-Huygens probe landed there in 2005."]),
    ImageSpec(filename: "espresso-extraction.png",
              title: "Espresso Extraction",
              body: ["Pull the shot at nine bars of pressure.",
                     "Use 18 grams in and target 36 grams out.",
                     "Uneven flow through the puck is called channeling."]),
    ImageSpec(filename: "roman-aqueduct.png",
              title: "Roman Aqueduct Engineering",
              body: ["The Pont du Gard carried water to Nimes.",
                     "Its average gradient is 34 centimeters per kilometer.",
                     "Gravity alone moves the water across the valley."]),
    ImageSpec(filename: "waggle-dance.png",
              title: "The Honeybee Waggle Dance",
              body: ["A forager encodes distance and direction.",
                     "The angle to vertical maps to the angle to the sun.",
                     "Karl von Frisch first decoded this dance."]),
    ImageSpec(filename: "lithium-battery-runaway.png",
              title: "Lithium-Ion Thermal Runaway",
              body: ["An NMC cathode can vent above 150 degrees Celsius.",
                     "A punctured separator causes an internal short.",
                     "Cooling and controlled venting slow the cascade."]),
    ImageSpec(filename: "coral-bleaching.png",
              title: "Coral Bleaching on the Reef",
              body: ["Water above 30 degrees stresses the coral.",
                     "The polyps expel their zooxanthellae algae.",
                     "Acropora colonies turn white and may starve."]),
    ImageSpec(filename: "tea-ceremony.png",
              title: "The Japanese Tea Ceremony",
              body: ["Matcha is whisked in a chawan bowl.",
                     "Sen no Rikyu shaped the wabi-sabi aesthetic.",
                     "Its principles are harmony, respect, purity, tranquility."]),
    ImageSpec(filename: "everest-death-zone.png",
              title: "Climbing Mount Everest",
              body: ["The death zone begins above 8000 meters.",
                     "Climbers pass the Hillary Step near the summit.",
                     "Tenzing Norgay reached the top in 1953."]),
    ImageSpec(filename: "fermat-last-theorem.png",
              title: "Fermat's Last Theorem",
              body: ["No positive integers solve a to the n plus b to the n",
                     "equals c to the n when n is greater than two.",
                     "Andrew Wiles proved it in 1994 using modular forms."]),
    ImageSpec(filename: "antikythera-mechanism.png",
              title: "The Antikythera Mechanism",
              body: ["A bronze gear train models the heavens.",
                     "It predicts eclipses and the Metonic cycle.",
                     "Divers found it in a Greek shipwreck in 1901."]),
    // Unlabeled synthetic distractor — no rubric query points here.
    ImageSpec(filename: "knitting-gauge.png",
              title: "Knitting Gauge Swatch",
              body: ["Stockinette gives 20 stitches per four inches.",
                     "Block the swatch before you measure it.",
                     "Change needle size to match the pattern gauge."]),
]

let width = 1024
let height = 768
let margin: CGFloat = 64
let titleSize: CGFloat = 46
let bodySize: CGFloat = 30

// CoreText's own foreground key (a CGColor). Setting it explicitly keeps the
// glyph color independent of any AppKit color bridging during CTFrameDraw.
let ctForeground = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

func attributed(for spec: ImageSpec) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let black = CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)

    let titleFont = NSFont(name: "HelveticaNeue-Bold", size: titleSize)
        ?? NSFont.boldSystemFont(ofSize: titleSize)
    let bodyFont = NSFont(name: "HelveticaNeue", size: bodySize)
        ?? NSFont.systemFont(ofSize: bodySize)

    let titlePara = NSMutableParagraphStyle()
    titlePara.paragraphSpacing = 26
    titlePara.lineBreakMode = .byWordWrapping
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont, ctForeground: black, .paragraphStyle: titlePara,
    ]
    result.append(NSAttributedString(string: spec.title + "\n\n", attributes: titleAttrs))

    let bodyPara = NSMutableParagraphStyle()
    bodyPara.paragraphSpacing = 12
    bodyPara.lineSpacing = 6
    bodyPara.lineBreakMode = .byWordWrapping
    let bodyAttrs: [NSAttributedString.Key: Any] = [
        .font: bodyFont, ctForeground: black, .paragraphStyle: bodyPara,
    ]
    result.append(NSAttributedString(string: spec.body.joined(separator: "\n"), attributes: bodyAttrs))
    return result
}

func render(_ spec: ImageSpec, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "gen", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot make CGContext"])
    }
    // Opaque white background.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let attr = attributed(for: spec)
    let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
    // CoreText fills lines from the TOP of the path rect downward, so no manual
    // flip is needed — the default y-up CGContext renders upright glyphs.
    let textRect = CGRect(x: margin, y: margin, width: CGFloat(width) - 2 * margin,
                          height: CGFloat(height) - 2 * margin)
    let path = CGPath(rect: textRect, transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, ctx)

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "gen", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot make CGImage"])
    }
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "gen", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot make PNG destination"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "gen", code: 4, userInfo: [NSLocalizedDescriptionKey: "cannot write PNG"])
    }
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-synthetic-images.swift <output-directory>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for spec in specs {
    let url = outDir.appendingPathComponent(spec.filename)
    try render(spec, to: url)
    print("wrote \(spec.filename)")
}
print("done: \(specs.count) synthetic images -> \(outDir.path)")
