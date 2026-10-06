// Writes the app icon styles as Icon Composer documents. Every style is a sheet with lines of text and a highlighted
// note, the way the app draws a draft: a filled band behind the text, nothing beside it.
// Run: swift docs/icon/make-variants.swift docs/icon/variants
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/icon/variants", isDirectory: true)

// The app's note colors (system colors, light appearance).
let palette: [(name: String, hex: String)] = [
    ("yellow", "#FFCC00"), ("green", "#34C759"), ("blue", "#007AFF"),
    ("pink", "#FF2D55"), ("purple", "#AF52DE"), ("orange", "#FF9500"),
]

struct Line { var y: Double; var width: Double; var note: String? }

struct Style {
    var name: String
    var fill: [String: Any]
    var lines: [Line]
    var plainInk: String
    var markedInk: String
    /// Drawn under everything, flat (a pattern on the sheet).
    var background: String? = nil
    /// Square pixels instead of rounded bars, not glass, so the edges stay crisp.
    var pixel = false
    /// A bar's height and its note band's, for styles with more lines than four.
    var lineHeight = 80.0
    var band = 144.0
}

let left = 236.0
let four: [Double] = [250, 410, 570, 730]
func page(_ note: String) -> [Line] {
    [Line(y: four[0], width: 580), Line(y: four[1], width: 440, note: note), Line(y: four[2], width: 600), Line(y: four[3], width: 360)]
}
let frost: [String: Any] = ["automatic-gradient": "srgb:0.93000,0.93000,0.94000,1.00000"]
let graphite: [String: Any] = ["automatic-gradient": "srgb:0.24000,0.24000,0.26000,1.00000"]

var styles: [Style] = []
for color in palette {
    styles.append(Style(name: "frost-\(color.name)", fill: frost, lines: page(color.hex), plainInk: "#A1A1A8", markedInk: "#2C2C30"))
    styles.append(Style(name: "graphite-\(color.name)", fill: graphite, lines: page(color.hex), plainInk: "#8E8E95", markedInk: "#1C1C1E"))
}

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double, _ fill: String) -> String {
    #"<rect x="\#(Int(x))" y="\#(Int(y))" width="\#(Int(w))" height="\#(Int(h))" rx="\#(Int(r))" fill="\#(fill)"/>"#
}

// Starburst: rays from behind the note, on violet, so the yellow band glows.
var rays = rect(0, 0, 1024, 1024, 0, "#5B3FD9")
let center = (x: 470.0, y: 450.0)
for index in 0..<24 where index % 2 == 0 {
    let a0 = Double(index) / 24 * 2 * .pi, a1 = Double(index + 1) / 24 * 2 * .pi
    let p0 = (center.x + 1600 * cos(a0), center.y + 1600 * sin(a0)), p1 = (center.x + 1600 * cos(a1), center.y + 1600 * sin(a1))
    let ray = "#7A5CF0"
    rays += #"<path d="M \#(Int(center.x)) \#(Int(center.y)) L \#(Int(p0.0)) \#(Int(p0.1)) L \#(Int(p1.0)) \#(Int(p1.1)) Z" fill="\#(ray)"/>"#
}
styles.append(Style(name: "fun-starburst", fill: ["solid": "srgb:0.36000,0.25000,0.85000,1.00000"], lines: page("#FFCC00"),
                    plainInk: "#E9E4FF", markedInk: "#2C2C30", background: rays))

// Blueprint: white lines on a drafting grid.
var grid = rect(0, 0, 1024, 1024, 0, "#1E4F9A")
for step in stride(from: 0.0, through: 1024, by: 64) {
    grid += rect(step, 0, 3, 1024, 0, "#3D6DB5") + rect(0, step, 1024, 3, 0, "#3D6DB5")
}
styles.append(Style(name: "fun-blueprint", fill: ["solid": "srgb:0.12000,0.31000,0.60000,1.00000"], lines: page("#FFCC00"),
                    plainInk: "#DCE8FA", markedInk: "#1C2A44", background: grid))

// Rainbow: every note color on one frost page.
styles.append(Style(name: "fun-rainbow", fill: frost,
                    lines: palette.enumerated().map { index, color in Line(y: 196 + Double(index) * 118, width: [560, 440, 600, 380, 520, 460][index], note: color.hex) },
                    plainInk: "#A1A1A8", markedInk: "#2C2C30", lineHeight: 56, band: 96))

// Pixel art: frost-yellow on a 16×16 grid.
styles.append(Style(name: "fun-pixel", fill: ["solid": "srgb:0.93000,0.93000,0.94000,1.00000"], lines: page("#FFCC00"),
                    plainInk: "#A1A1A8", markedInk: "#2C2C30", pixel: true))

func svg(_ body: String) -> String {
    #"<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">"# + body + "</svg>"
}

/// The pixel style's page: rows of 64-pt squares (cells 3…12 of 16), the note a three-row band.
func pixelLayers(_ style: Style) -> (text: String, notes: String) {
    let cell = 64.0
    func run(_ row: Int, _ from: Int, _ to: Int, _ fill: String) -> String {
        rect(Double(from) * cell, Double(row) * cell, Double(to - from + 1) * cell, cell, 0, fill)
    }
    let text = run(3, 3, 12, style.plainInk) + run(9, 3, 12, style.plainInk) + run(11, 3, 8, style.plainInk)
    let notes = rect(2 * cell, 5 * cell, 9 * cell, 3 * cell, 0, "#FFCC00") + run(6, 3, 9, style.markedInk)
    return (text, notes)
}

for style in styles {
    let doc = out.appendingPathComponent("\(style.name).icon", isDirectory: true)
    let assets = doc.appendingPathComponent("Assets", isDirectory: true)
    try? FileManager.default.removeItem(at: doc)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    var text = "", notes = ""
    if style.pixel {
        (text, notes) = pixelLayers(style)
    } else {
        for line in style.lines {
            guard let color = line.note else {
                text += rect(left, line.y, line.width, style.lineHeight, style.lineHeight / 2, style.plainInk)
                continue
            }
            // The band behind the line, then the line's text on top, as a draft looks in the app.
            notes += rect(left - 40, line.y - (style.band - style.lineHeight) / 2, line.width + 80, style.band, style.band * 0.28, color)
            notes += rect(left, line.y, line.width - 60, style.lineHeight, style.lineHeight / 2, style.markedInk)
        }
    }

    func group(_ names: [String], glass: Bool, shadow: String?) -> [String: Any] {
        var group: [String: Any] = ["layers": names.map { ["glass": glass, "image-name": "\($0).svg", "name": $0] }]
        if glass {
            group["translucency"] = ["enabled": true, "value": 0.4]
            group["specular"] = true
        }
        if let shadow { group["shadow"] = ["kind": shadow, "opacity": 0.5] }
        return group
    }
    let glass = !style.pixel
    var groups: [[String: Any]] = []
    if !notes.isEmpty {
        try svg(notes).write(to: assets.appendingPathComponent("notes.svg"), atomically: true, encoding: .utf8)
        groups.append(group(["notes"], glass: glass, shadow: glass ? "layer-color" : nil))
    }
    if !text.isEmpty {
        try svg(text).write(to: assets.appendingPathComponent("text.svg"), atomically: true, encoding: .utf8)
        groups.append(group(["text"], glass: glass, shadow: glass ? "neutral" : nil))
    }
    if let background = style.background {
        try svg(background).write(to: assets.appendingPathComponent("background.svg"), atomically: true, encoding: .utf8)
        groups.append(group(["background"], glass: false, shadow: nil))
    }
    let json: [String: Any] = ["fill": style.fill, "groups": groups, "supported-platforms": ["squares": ["macOS"]]]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: doc.appendingPathComponent("icon.json"))
    print(style.name)
}
