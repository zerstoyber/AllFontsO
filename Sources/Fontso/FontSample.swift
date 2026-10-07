import FontsoCore
import SwiftUI

struct FamilySample: View {
    let face: FontFace
    let text: String
    let size: CGFloat
    var expands = false
    @State private var image: CGImage?

    var body: some View {
        Group {
            if expands {
                sampleBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                sampleBody
                    .frame(maxWidth: .infinity, minHeight: size * 1.4, maxHeight: size * 1.9, alignment: .leading)
            }
        }
    }

    private var sampleBody: some View {
        Group {
            if let image {
                sampleImage(image)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: size * 1.4)
            }
        }
        .task(id: "\(face.identity)|\(drawnText)|\(Int(size))|\(expands)") {
            let path = face.filePath
            let index = face.faceIndex
            let sample = drawnText
            let point = size
            let rendered = await Task.detached(priority: .utility) {
                SampleLineCache.image(path: path, index: index, text: sample, size: point)
            }.value
            if !Task.isCancelled {
                image = rendered
            }
        }
    }

    private var drawnText: String {
        guard !expands else { return text }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? " " : trimmed
    }

    @ViewBuilder
    private func sampleImage(_ image: CGImage) -> some View {
        let picture = Image(decorative: image, scale: 2)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .foregroundStyle(.primary)
        if expands {
            picture
                .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            picture
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: size * 1.9, alignment: .leading)
        }
    }
}

enum SampleLineCache {
    private final class Box: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2500
        return cache
    }()

    static func image(path: String, index: Int, text: String, size: CGFloat) -> CGImage? {
        let key = "\(path)\n\(index)\n\(text)\n\(Int(size))" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        guard let rendered = SpecimenRenderer.line(filePath: path, faceIndex: index, text: text, pointSize: size) else {
            return nil
        }
        cache.setObject(Box(rendered), forKey: key)
        return rendered
    }
}
