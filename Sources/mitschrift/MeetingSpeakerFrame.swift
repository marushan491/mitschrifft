import CoreGraphics
import Foundation

enum MeetingSpeakerFrame {
    enum Style { case teams, slack }

    static func names(in image: CGImage, lines: [(text: String, box: CGRect)], style: Style) -> [String] {
        let scale = min(1, 1920 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        let viewport = CGRect(x: 0, y: 0, width: width, height: height)
        let normalizedViewport = CGRect(x: 0, y: 0, width: 1, height: 1)
        let labels: [(name: String, box: CGRect)] = lines.compactMap { line in
            guard !line.box.isEmpty,
                  normalizedViewport.contains(line.box),
                  let name = TeamsCaption.personName(line.text) else { return nil }
            return (name, CGRect(x: line.box.minX * viewport.width,
                                 y: (1 - line.box.maxY) * viewport.height,
                                 width: line.box.width * viewport.width,
                                 height: line.box.height * viewport.height))
        }
        guard !labels.isEmpty,
              var remaining = colorMask(image, width: width, height: height, style: style) else {
            return []
        }

        var names: [String] = []
        var matchedNames = Set<String>()
        for seed in remaining.indices where remaining[seed] {
            let outline = Outline(seed: seed, remaining: &remaining, width: width, height: height)
            let fullyVisible = viewport.insetBy(dx: 2, dy: 2).contains(outline.box)
            let shape: Shape
            switch style {
            case .teams: shape = outline.rectangle(stride: width, touchesEdge: !fullyVisible)
            case .slack: shape = outline.ring(stride: width)
            }
            guard shape != .unrelated else { continue }
            guard shape == .complete, fullyVisible else { return [] }

            let matches = labels.filter { matchesLabel($0.box, outline: outline.box, style: style) }
            guard matches.count == 1, let label = matches.first,
                  matchedNames.insert(label.name.lowercased()).inserted else { return [] }
            names.append(label.name)
        }
        return names
    }

    private static func matchesLabel(_ label: CGRect, outline: CGRect, style: Style) -> Bool {
        switch style {
        case .teams:
            return outline.insetBy(dx: 2, dy: 2).contains(label)
                && label.minX - outline.minX <= outline.width * 0.30
                && label.height <= outline.height * 0.22
                && outline.maxY - label.maxY <= min(outline.height * 0.30, label.height * 3)
        case .slack:
            guard label.height <= outline.height * 0.42 else { return false }
            let below = label.minY - outline.maxY
            let beside = label.minX - outline.maxX
            return (below >= 0 && below <= outline.height * 0.40
                    && abs(label.midX - outline.midX) <= outline.width * 0.22)
                || (beside >= 0 && beside <= outline.width * 0.40
                    && abs(label.midY - outline.midY) <= outline.height * 0.22)
        }
    }

    private static func colorMask(_ image: CGImage, width: Int, height: Int, style: Style) -> [Bool]? {
        let bytesPerRow = width * 4
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo),
              let data = context.data else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        return withExtendedLifetime(context) {
            var mask = [Bool](repeating: false, count: width * height)
            for index in mask.indices {
                let offset = index * 4
                guard pixels[offset + 3] >= 240 else { continue }
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                switch style {
                case .teams:
                    mask[index] = blue >= 145 && blue - red >= 24 && blue - green >= 36
                        && abs(red - green) <= 95
                case .slack:
                    mask[index] = green >= 135 && green - red >= 55 && green - blue >= -12 && blue <= 190
                }
            }
            return mask
        }
    }

    private enum Shape { case unrelated, ambiguous, complete }

    private struct Outline {
        let pixels: [Int]
        let box: CGRect

        init(seed: Int, remaining: inout [Bool], width: Int, height: Int) {
            var pixels = [seed]
            remaining[seed] = false
            var left = seed % width
            var right = left
            var top = seed / width
            var bottom = top
            var cursor = 0
            while cursor < pixels.count {
                let index = pixels[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
                for row in max(0, y - 1)...min(height - 1, y + 1) {
                    for column in max(0, x - 1)...min(width - 1, x + 1) {
                        let neighbor = row * width + column
                        guard remaining[neighbor] else { continue }
                        remaining[neighbor] = false
                        pixels.append(neighbor)
                    }
                }
            }
            self.pixels = pixels
            box = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }

        func rectangle(stride: Int, touchesEdge: Bool) -> Shape {
            guard box.width >= 76, box.height >= 54, box.width >= box.height * 0.55,
                  box.width <= box.height * 3.2 else { return .unrelated }
            let shortSide = min(box.width, box.height)
            let edgeBand = max(2, min(12, shortSide / 18))
            let cornerBand = shortSide * 0.16
            guard CGFloat(pixels.count) <= (box.width + box.height) * edgeBand * 3 else {
                return .unrelated
            }

            var sides = [UInt16](repeating: 0, count: 4)
            var nearPerimeter = 0
            for index in pixels {
                let x = CGFloat(index % stride) + 0.5 - box.minX
                let y = CGFloat(index / stride) + 0.5 - box.minY
                let dx = min(x, box.width - x)
                let dy = min(y, box.height - y)
                if min(dx, dy) <= edgeBand || (dx <= cornerBand && dy <= cornerBand) {
                    nearPerimeter += 1
                }
                if dy <= edgeBand, let bin = Self.edgeBin(x / box.width) {
                    sides[y < box.height / 2 ? 0 : 1] |= bin
                }
                if dx <= edgeBand, let bin = Self.edgeBin(y / box.height) {
                    sides[x < box.width / 2 ? 2 : 3] |= bin
                }
            }
            let perimeterShare = Double(nearPerimeter) / Double(pixels.count)
            let coveredBins = sides.map(\.nonzeroBitCount)
            let viableSides = coveredBins.filter { $0 >= 7 }.count
            guard perimeterShare >= 0.72, viableSides >= 3 || (touchesEdge && viableSides >= 2) else {
                return .unrelated
            }
            return perimeterShare >= 0.92 && coveredBins.allSatisfy { $0 >= 9 } ? .complete : .ambiguous
        }

        private static func edgeBin(_ position: CGFloat) -> UInt16? {
            guard position >= 0.15, position < 0.85 else { return nil }
            return 1 << min(9, Int((position - 0.15) / 0.07))
        }

        func ring(stride: Int) -> Shape {
            let diameter = min(box.width, box.height)
            let aspect = diameter / max(box.width, box.height)
            guard diameter >= 24, aspect >= 0.66,
                  CGFloat(pixels.count) < box.width * box.height * 0.50 else { return .unrelated }

            var sectors: UInt16 = 0
            var inBand = 0
            for index in pixels {
                let x = (CGFloat(index % stride) + 0.5 - box.midX) * 2 / box.width
                let y = (CGFloat(index / stride) + 0.5 - box.midY) * 2 / box.height
                let radiusSquared = x * x + y * y
                guard radiusSquared >= 0.72 * 0.72, radiusSquared <= 1.12 * 1.12 else { continue }
                inBand += 1
                let angle = atan2(Double(y), Double(x))
                let sector = min(15, Int((angle + .pi) * (8 / .pi)))
                sectors |= 1 << sector
            }
            let ringShare = Double(inBand) / Double(pixels.count)
            guard ringShare >= 0.76, sectors.nonzeroBitCount >= 11 else { return .unrelated }
            return aspect >= 0.90 && ringShare >= 0.93 && sectors.nonzeroBitCount == 16 ? .complete : .ambiguous
        }
    }
}
