import SwiftUI
import QuickLookThumbnailing
import AppKit

struct ThumbnailView: View {
    let url: URL
    let size: CGSize
    var contentMode: ContentMode = .fit

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .onAppear { generate() }
    }

    private func generate() {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2.0,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async { thumbnail = rep.nsImage }
        }
    }
}
