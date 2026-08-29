import SwiftUI

/// Minimal but complete SVG path-data → SwiftUI Path renderer.
/// Supports M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z, absolute and relative,
/// with implicit command repetition — enough for real brand marks.
/// Coordinates are interpreted in the given viewBox and scaled to `rect`.
struct SVGShape: Shape {
    let pathData: String
    let viewBox: CGSize

    func path(in rect: CGRect) -> Path {
        let raw = SVGPathParser.parse(pathData)
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let dx = rect.minX + (rect.width - viewBox.width * scale) / 2
        let dy = rect.minY + (rect.height - viewBox.height * scale) / 2
        let transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
        return raw.applying(transform)
    }
}

private enum SVGPathParser {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var scanner = TokenScanner(data)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "

        while let command = scanner.nextCommand(previous: lastCommand) {
            lastCommand = command
            let relative = command.isLowercase
            switch command.uppercased().first! {
            case "M":
                let p = scanner.point(relativeTo: relative ? current : .zero)
                current = p; start = p
                path.move(to: p)
                lastControl = nil
                // Subsequent implicit pairs are line-tos.
                while scanner.hasNumber {
                    let lp = scanner.point(relativeTo: relative ? current : .zero)
                    path.addLine(to: lp); current = lp
                }
            case "L":
                while scanner.hasNumber {
                    let p = scanner.point(relativeTo: relative ? current : .zero)
                    path.addLine(to: p); current = p
                }
                lastControl = nil
            case "H":
                while scanner.hasNumber {
                    let x = scanner.number() + (relative ? current.x : 0)
                    current.x = x; path.addLine(to: current)
                }
                lastControl = nil
            case "V":
                while scanner.hasNumber {
                    let y = scanner.number() + (relative ? current.y : 0)
                    current.y = y; path.addLine(to: current)
                }
                lastControl = nil
            case "C":
                while scanner.hasNumber {
                    let base = relative ? current : .zero
                    let c1 = scanner.point(relativeTo: base)
                    let c2 = scanner.point(relativeTo: base)
                    let end = scanner.point(relativeTo: base)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2; current = end
                }
            case "S":
                while scanner.hasNumber {
                    let base = relative ? current : .zero
                    let c1 = reflected(lastControl, about: current, command: lastCommand, isCubic: true)
                    let c2 = scanner.point(relativeTo: base)
                    let end = scanner.point(relativeTo: base)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastControl = c2; current = end
                }
            case "Q":
                while scanner.hasNumber {
                    let base = relative ? current : .zero
                    let c = scanner.point(relativeTo: base)
                    let end = scanner.point(relativeTo: base)
                    path.addQuadCurve(to: end, control: c)
                    lastControl = c; current = end
                }
            case "T":
                while scanner.hasNumber {
                    let base = relative ? current : .zero
                    let c = reflected(lastControl, about: current, command: lastCommand, isCubic: false)
                    let end = scanner.point(relativeTo: base)
                    path.addQuadCurve(to: end, control: c)
                    lastControl = c; current = end
                }
            case "A":
                while scanner.hasNumber {
                    let rx = scanner.number(), ry = scanner.number()
                    let rotation = scanner.number()
                    let largeArc = scanner.flag(), sweep = scanner.flag()
                    let end = scanner.point(relativeTo: relative ? current : .zero)
                    addArc(to: &path, from: current, to: end, rx: rx, ry: ry,
                           rotationDeg: rotation, largeArc: largeArc, sweep: sweep)
                    current = end
                }
                lastControl = nil
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
            default:
                break
            }
        }
        return path
    }

    private static func reflected(_ control: CGPoint?, about point: CGPoint,
                                  command: Character, isCubic: Bool) -> CGPoint {
        let smoothPrev: Set<Character> = isCubic ? ["c", "C", "s", "S"] : ["q", "Q", "t", "T"]
        guard let control, smoothPrev.contains(command) else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// Endpoint-parameterized elliptical arc → cubic bezier segments.
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDeg: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotationDeg * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        var lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s; lambda = 1 }
        let sign: CGFloat = largeArc != sweep ? 1 : -1
        let num = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = sign * sqrt(den == 0 ? 0 : num / den)
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = Int(ceil(abs(delta) / (.pi / 2)))
        let segAngle = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(segAngle / 4)
        var angleStart = theta1
        for _ in 0 ..< segments {
            let a1 = angleStart, a2 = angleStart + segAngle
            func point(_ a: CGFloat) -> CGPoint {
                let x = cosPhi * rx * cos(a) - sinPhi * ry * sin(a) + cx
                let y = sinPhi * rx * cos(a) + cosPhi * ry * sin(a) + cy
                return CGPoint(x: x, y: y)
            }
            func deriv(_ a: CGFloat) -> CGPoint {
                let x = -cosPhi * rx * sin(a) - sinPhi * ry * cos(a)
                let y = -sinPhi * rx * sin(a) + cosPhi * ry * cos(a)
                return CGPoint(x: x, y: y)
            }
            let p2 = point(a2)
            let d1 = deriv(a1), d2 = deriv(a2)
            let c1 = CGPoint(x: point(a1).x + t * d1.x, y: point(a1).y + t * d1.y)
            let c2 = CGPoint(x: p2.x - t * d2.x, y: p2.y - t * d2.y)
            path.addCurve(to: p2, control1: c1, control2: c2)
            angleStart = a2
        }
    }
}

/// Tokenizer for SVG path data.
private struct TokenScanner {
    private let chars: [Character]
    private var index = 0

    init(_ string: String) { chars = Array(string) }

    private mutating func skipSeparators() {
        while index < chars.count, chars[index] == " " || chars[index] == "," || chars[index] == "\n" || chars[index] == "\t" || chars[index] == "\r" {
            index += 1
        }
    }

    mutating func nextCommand(previous: Character) -> Character? {
        skipSeparators()
        guard index < chars.count else { return nil }
        let c = chars[index]
        if c.isLetter { index += 1; return c }
        // Implicit repeat of the previous command.
        return previous == " " ? nil : previous
    }

    var hasNumber: Bool {
        var i = index
        while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
        guard i < chars.count else { return false }
        let c = chars[i]
        return c.isNumber || c == "-" || c == "+" || c == "."
    }

    mutating func number() -> CGFloat {
        skipSeparators()
        var s = ""
        var seenDot = false, seenExp = false
        if index < chars.count, chars[index] == "-" || chars[index] == "+" { s.append(chars[index]); index += 1 }
        while index < chars.count {
            let c = chars[index]
            if c.isNumber { s.append(c); index += 1 }
            else if c == ".", !seenDot, !seenExp { seenDot = true; s.append(c); index += 1 }
            else if c == "e" || c == "E", !seenExp {
                seenExp = true; s.append(c); index += 1
                if index < chars.count, chars[index] == "-" || chars[index] == "+" { s.append(chars[index]); index += 1 }
            } else { break }
        }
        return CGFloat(Double(s) ?? 0)
    }

    /// Arc flags are single digits, possibly not separated.
    mutating func flag() -> Bool {
        skipSeparators()
        guard index < chars.count else { return false }
        let c = chars[index]; index += 1
        return c == "1"
    }

    mutating func point(relativeTo base: CGPoint) -> CGPoint {
        let x = number() + base.x
        let y = number() + base.y
        return CGPoint(x: x, y: y)
    }
}
