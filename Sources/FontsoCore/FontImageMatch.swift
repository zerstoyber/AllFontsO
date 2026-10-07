import CoreGraphics
import Foundation
import Vision

public enum FontImageMatch {
    /// Compares the picture with one regular face per family and returns the closest letterforms.
    public static func match(image: CGImage, faces: [FontFace], note: String, limit: Int = 8) -> ResearchTurn {
        let sample = recognizedSample(in: image)
        guard let reference = grid(from: image) else {
            return ResearchTurn(text: emptyCopy(note), suggestions: [])
        }
        let representatives = representatives(in: faces)
        var scored: [(family: String, distance: Float)] = []
        scored.reserveCapacity(representatives.count)
        for face in representatives {
            guard let rendered = SpecimenRenderer.line(
                filePath: face.filePath,
                faceIndex: face.faceIndex,
                text: sample,
                pointSize: 64
            ), let candidate = grid(from: rendered) else { continue }
            scored.append((face.family, distance(reference, candidate)))
        }
        scored.sort { $0.distance < $1.distance }
        let names = uniqueFamilies(scored.map(\.family)).prefix(limit)
        let list = Array(names)
        guard !list.isEmpty else {
            return ResearchTurn(text: emptyCopy(note), suggestions: [])
        }
        let suggestions = list.map { ResearchSuggestion(family: $0, role: "", reason: "") }
        return ResearchTurn(text: summary(list, note: note, sample: sample), suggestions: suggestions)
    }

    private static func representatives(in faces: [FontFace]) -> [FontFace] {
        let grouped = Dictionary(grouping: faces, by: { $0.family.lowercased() })
        return grouped.values.compactMap { group in
            group.min { lhs, rhs in
                if lhs.isItalic != rhs.isItalic { return !lhs.isItalic }
                return abs(lhs.weightClass - 400) < abs(rhs.weightClass - 400)
            }
        }
    }

    private static func uniqueFamilies(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for name in names where seen.insert(name.lowercased()).inserted {
            ordered.append(name)
        }
        return ordered
    }

    private static func recognizedSample(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        let observations = request.results ?? []
        let best = observations.max { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
        }
        let raw = best?.topCandidates(1).first?.string ?? ""
        let cleaned = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .prefix(22)
        let sample = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return sample.count >= 2 ? sample : "Handgloves"
    }

    private static func summary(_ names: [String], note: String, sample: String) -> String {
        let list = sentence(names, german: ResearchLanguage.detect(note) == .german)
        if ResearchLanguage.detect(note) == .german {
            return "Am nächsten am Bild, gesetzt als „\(sample)“: \(list)."
        }
        return "Closest to the picture, set as “\(sample)”: \(list)."
    }

    private static func emptyCopy(_ note: String) -> String {
        if ResearchLanguage.detect(note) == .german {
            return "In dem Bild habe ich keine vergleichbare Schrift aus der Bibliothek gefunden."
        }
        return "I couldn't find a library font that matches that picture."
    }

    private static func sentence(_ names: [String], german: Bool) -> String {
        guard let last = names.last else { return "" }
        if names.count == 1 { return last }
        let head = names.dropLast().joined(separator: ", ")
        return german ? "\(head) und \(last)" : "\(head), and \(last)"
    }

    private static func distance(_ left: [Float], _ right: [Float]) -> Float {
        guard left.count == right.count, !left.isEmpty else { return 1 }
        var sum: Float = 0
        for index in 0..<left.count {
            sum += abs(left[index] - right[index])
        }
        return sum / Float(left.count)
    }

    /// Ink shape fitted into a fixed grid, so a photo and a rendered word can be compared.
    private static func grid(from image: CGImage, columns: Int = 96, rows: Int = 40) -> [Float]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, 480 / Double(max(width, height)))
        let pixelWidth = max(1, Int((Double(width) * scale).rounded()))
        let pixelHeight = max(1, Int((Double(height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        func luminance(_ index: Int) -> Float {
            let offset = index * 4
            let alpha = Float(pixels[offset + 3]) / 255
            if alpha < 0.08 { return -1 }
            let red = Float(pixels[offset]) / 255
            let green = Float(pixels[offset + 1]) / 255
            let blue = Float(pixels[offset + 2]) / 255
            return (0.2126 * red + 0.7152 * green + 0.0722 * blue)
        }

        var paperSamples: [Float] = []
        for index in [0, pixelWidth - 1, (pixelHeight - 1) * pixelWidth, pixelWidth * pixelHeight - 1] {
            let value = luminance(index)
            if value >= 0 { paperSamples.append(value) }
        }
        let paper = paperSamples.isEmpty ? Float(1) : paperSamples.reduce(0, +) / Float(paperSamples.count)
        let inkIsDark = paper > 0.5
        var mask = [Bool](repeating: false, count: pixelWidth * pixelHeight)
        var minX = pixelWidth
        var minY = pixelHeight
        var maxX = 0
        var maxY = 0
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let value = luminance(y * pixelWidth + x)
                let ink: Bool
                if value < 0 {
                    ink = false
                } else if inkIsDark {
                    ink = value < paper - 0.18
                } else {
                    ink = value > paper + 0.18
                }
                guard ink else { continue }
                mask[y * pixelWidth + x] = true
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let boxWidth = maxX - minX + 1
        let boxHeight = maxY - minY + 1
        var cells = [Float](repeating: 0, count: columns * rows)
        let fit = min(Float(columns) / Float(boxWidth), Float(rows) / Float(boxHeight))
        let originX = (Float(columns) - Float(boxWidth) * fit) / 2
        let originY = (Float(rows) - Float(boxHeight) * fit) / 2
        for row in 0..<rows {
            for column in 0..<columns {
                let sourceX = Int(((Float(column) + 0.5 - originX) / fit).rounded(.down))
                let sourceY = Int(((Float(row) + 0.5 - originY) / fit).rounded(.down))
                guard sourceX >= 0, sourceY >= 0, sourceX < boxWidth, sourceY < boxHeight else { continue }
                if mask[(minY + sourceY) * pixelWidth + (minX + sourceX)] {
                    cells[row * columns + column] = 1
                }
            }
        }
        return cells.contains(where: { $0 > 0 }) ? cells : nil
    }
}
