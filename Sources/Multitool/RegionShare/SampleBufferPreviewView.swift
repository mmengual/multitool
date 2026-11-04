import SwiftUI
import AppKit
import AVFoundation
import Combine
import CoreMedia

/// SwiftUI-friendly preview that renders frames from a Combine publisher into
/// an AVSampleBufferDisplayLayer. Used inside the popover for the live region
/// preview; the share window uses a different rendering path (IOSurface
/// assignment to a plain CALayer) for capture-app compatibility.
struct SampleBufferPreviewView: NSViewRepresentable {
    let publisher: AnyPublisher<CMSampleBuffer, Never>

    func makeNSView(context: Context) -> PreviewNSView {
        PreviewNSView(publisher: publisher)
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}
}

final class PreviewNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var cancellable: AnyCancellable?

    init(publisher: AnyPublisher<CMSampleBuffer, Never>) {
        super.init(frame: .zero)
        wantsLayer = true
        let container = CALayer()
        container.backgroundColor = NSColor.black.cgColor
        layer = container

        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.addSublayer(displayLayer)

        cancellable = publisher.sink { [weak self] buffer in
            guard let self = self else { return }
            if self.displayLayer.status == .failed { self.displayLayer.flush() }
            if self.displayLayer.isReadyForMoreMediaData {
                self.displayLayer.enqueue(buffer)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
}
