// goty — see CLAUDE.md for the working principles.
import AppKit

// MARK: - Lucide glyph (tty7's icon set)

/// Renders the lucide icons tty7 uses (24-unit viewBox, stroke-width 2,
/// round caps/joins, no fill) as vector strokes in `draw(_:)` — AppKit
/// rasterizes at the live backing density, exactly like an SF Symbol;
/// no cached bitmaps, no scale state (the CLAUDE.md icon rule).
final class LucideIconView: NSView {
    enum Glyph {
        case folder
        case folderOpen
        case file

        /// Verbatim lucide `d` attributes (lucide-folder, lucide-folder-open,
        /// lucide-file); one string per subpath.
        var pathData: [String] {
            switch self {
            case .folder:
                return ["M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"]
            case .folderOpen:
                return ["m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"]
            case .file:
                return ["M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z",
                        "M14 2v4a2 2 0 0 0 2 2h4"]
            }
        }
    }

    let glyph: Glyph
    var tint: NSColor
    private let pointSize: CGFloat

    init(_ glyph: Glyph, pointSize: CGFloat, tint: NSColor) {
        self.glyph = glyph
        self.tint = tint
        self.pointSize = pointSize
        super.init(frame: NSRect(x: 0, y: 0, width: pointSize, height: pointSize))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let scale = min(bounds.width, bounds.height) / 24.0
        guard scale > 0 else { return }
        let path = NSBezierPath()
        for d in glyph.pathData {
            path.append(LucidePathParser.bezierPath(from: d))
        }
        var transform = AffineTransform()
        transform.translate(
            x: (bounds.width - 24.0 * scale) / 2,
            y: (bounds.height - 24.0 * scale) / 2 + 24.0 * scale)
        transform.scale(x: scale, y: -scale)
        path.transform(using: transform)
        tint.setStroke()
        path.lineWidth = 2.0 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

/// Minimal SVG path parser for the lucide grammar actually in use:
/// M/m L/l H/h V/v A/a (circular arcs only — every lucide arc here has
/// rx == ry) and Z/z, with implicit command repetition.
enum LucidePathParser {
    static func bezierPath(from d: String) -> NSBezierPath {
        let path = NSBezierPath()
        var x: CGFloat = 0, y: CGFloat = 0          // current point
        var sx: CGFloat = 0, sy: CGFloat = 0        // subpath start
        var command: Character = " "

        var i = d.startIndex
        func nextNumber() -> CGFloat? {
            // Skip separators.
            while i < d.endIndex, d[i] == " " || d[i] == "," { i = d.index(after: i) }
            guard i < d.endIndex else { return nil }
            let start = i
            if d[i] == "-" || d[i] == "+" { i = d.index(after: i) }
            var sawDigit = false, sawDot = false
            while i < d.endIndex {
                let c = d[i]
                if c.isNumber {
                    sawDigit = true
                    i = d.index(after: i)
                } else if c == "." && !sawDot {
                    sawDot = true
                    i = d.index(after: i)
                } else {
                    break
                }
            }
            guard sawDigit, i > start, let v = Double(d[start..<i]) else { return nil }
            return CGFloat(v)
        }
        func nextFlag() -> Int? {
            while i < d.endIndex, d[i] == " " || d[i] == "," { i = d.index(after: i) }
            guard i < d.endIndex, d[i] == "0" || d[i] == "1" else { return nil }
            defer { i = d.index(after: i) }
            return d[i].wholeNumberValue
        }

        while true {
            // Skip separators; a letter starts a new command, otherwise the
            // previous one repeats with another coordinate group.
            while i < d.endIndex, d[i] == " " || d[i] == "," { i = d.index(after: i) }
            if i < d.endIndex, d[i].isLetter {
                command = d[i]
                i = d.index(after: i)
            } else if command == " " {
                break
            }
            let relative = command.isLowercase
            let upper = Character(command.uppercased())
            switch upper {
            case "M", "L":
                guard let nx = nextNumber(), let ny = nextNumber() else { return path }
                let px = relative ? x + nx : nx
                let py = relative ? y + ny : ny
                if upper == "M" {
                    path.move(to: NSPoint(x: px, y: py))
                    sx = px; sy = py
                    // Moveto demotes to lineto for any further pairs.
                    command = relative ? "l" : "L"
                } else {
                    path.line(to: NSPoint(x: px, y: py))
                }
                x = px; y = py
            case "H":
                guard let nx = nextNumber() else { return path }
                x = relative ? x + nx : nx
                path.line(to: NSPoint(x: x, y: y))
            case "V":
                guard let ny = nextNumber() else { return path }
                y = relative ? y + ny : ny
                path.line(to: NSPoint(x: x, y: y))
            case "A":
                guard let rx = nextNumber(), let ry = nextNumber(),
                      let _ = nextNumber(),                    // x-axis-rotation (0 here)
                      let largeArc = nextFlag(), let sweep = nextFlag(),
                      let nx = nextNumber(), let ny = nextNumber() else { return path }
                let px = relative ? x + nx : nx
                let py = relative ? y + ny : ny
                appendArc(to: path, from: NSPoint(x: x, y: y),
                          to: NSPoint(x: px, y: py), radius: max(rx, ry),
                          largeArc: largeArc == 1, sweep: sweep == 1)
                x = px; y = py
            case "Z":
                path.close()
                x = sx; y = sy
            default:
                return path
            }
            if i >= d.endIndex { break }
        }
        return path
    }

    /// SVG circular arc (endpoint parameterization) → cubic beziers.
    ///
    /// Everything is computed algebraically in the path's own coordinate
    /// space (SVG's y-down grid): the W3C F.6.5 center formula, then
    /// per-quadrant beziers built from the arc's tangent vectors — no
    /// handedness assumption survives from the math textbook.
    private static func appendArc(to path: NSBezierPath, from: NSPoint,
                                  to: NSPoint, radius: CGFloat,
                                  largeArc: Bool, sweep: Bool) {
        let (x1, y1) = (from.x, from.y)
        let (x2, y2) = (to.x, to.y)
        // Degenerate per spec: radius 0 or coincident points = straight line.
        if radius <= 0 || (x1 == x2 && y1 == y2) {
            path.line(to: to)
            return
        }
        var r = radius
        let dx2 = (x1 - x2) / 2, dy2 = (y1 - y2) / 2
        var lambda = dx2 * dx2 + dy2 * dy2
        // F.6.5.1 — if the radius cannot span the chord, grow it to the
        // half-chord (the lucide set never needs this, but stay spec-true).
        if lambda > r.squared() {
            r = lambda.squareRoot()
            lambda = r.squared()
        }
        let sign: CGFloat = largeArc != sweep ? 1 : -1
        let coef = sign * ((r.squared() - lambda) / lambda).squareRoot()
        let cx = coef * dy2 + (x1 + x2) / 2
        let cy = -coef * dx2 + (y1 + y2) / 2

        // Signed angular travel in raw coordinates: SVG's positive-angle
        // direction (+x toward +y) IS increasing raw atan2, so sweep=1
        // travels positive.
        let theta1 = atan2(y1 - cy, x1 - cx)
        let theta2 = atan2(y2 - cy, x2 - cx)
        var travel = theta2 - theta1
        let direction: CGFloat = sweep ? 1 : -1
        while travel * direction < 0 { travel += direction * 2 * .pi }
        while abs(travel) > .pi, travel * direction > 0 { travel -= direction * 2 * .pi }
        if largeArc && abs(travel) < .pi { travel += direction * 2 * .pi }

        let segs = max(1, Int((abs(travel) / (.pi / 2)).rounded(.up)))
        let delta = travel / CGFloat(segs)
        let k = 4 / 3 * tan(abs(delta) / 4) * r * (delta > 0 ? 1 : -1)
        var theta = theta1
        var px = x1, py = y1
        for _ in 0..<segs {
            // Tangent of a raw-space circle at theta: (-sin, cos) for
            // positive travel; the k sign flips it for negative.
            let c1x = px + k * -sin(theta)
            let c1y = py + k * cos(theta)
            theta += delta
            let ex = cx + r * cos(theta)
            let ey = cy + r * sin(theta)
            let c2x = ex - k * -sin(theta)
            let c2y = ey - k * cos(theta)
            path.curve(to: NSPoint(x: ex, y: ey),
                       controlPoint1: NSPoint(x: c1x, y: c1y),
                       controlPoint2: NSPoint(x: c2x, y: c2y))
            px = ex; py = ey
        }
    }
}

private extension CGFloat {
    func squared() -> CGFloat { self * self }
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}


