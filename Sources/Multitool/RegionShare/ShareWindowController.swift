import AppKit
import CoreMedia
import CoreVideo
import Combine

/// Invisible (alpha=0) window kept on-screen so external capture apps
/// (Teams, Zoom, Meet, …) can list it as a shareable window. Frames are
/// assigned to a CALayer via IOSurface — that goes through the WindowServer's
/// standard compositing path, which is the most compatible route for
/// third-party screen-capture pipelines.
final class ShareWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var contentLayer: CALayer?
    private var cancellable: AnyCancellable?
    private var lastBuffer: CMSampleBuffer?
    var onClose: (() -> Void)?

    static let titleSentinel = "Multitool — Region"

    func show(region: CGRect, frames: AnyPublisher<CMSampleBuffer, Never>) {
        let size = NSSize(width: max(region.width, 200), height: max(region.height, 150))

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = Self.titleSentinel
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.hidesOnDeactivate = false
        // Push it behind every regular window so it never flashes during
        // Mission Control or Cmd-Tab. It stays in the WindowServer's list
        // (capturable) but is visually inert.
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = .resizeAspect
        layer.frame = container.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.layer = layer
        contentLayer = layer

        w.contentView = container
        w.orderFront(nil)
        window = w

        cancellable = frames.sink { [weak self] buffer in
            self?.update(with: buffer)
        }
    }

    private func update(with buffer: CMSampleBuffer) {
        // Retain the latest buffer so the IOSurface stays alive for as long
        // as the layer holds a reference to it.
        lastBuffer = buffer
        guard let layer = contentLayer,
              let pixelBuffer = CMSampleBufferGetImageBuffer(buffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surface
        CATransaction.commit()
    }

    func close() {
        cancellable = nil
        lastBuffer = nil
        window?.delegate = nil
        window?.close()
        window = nil
        contentLayer = nil
    }

    func windowWillClose(_ notification: Notification) {
        cancellable = nil
        lastBuffer = nil
        window = nil
        contentLayer = nil
        onClose?()
    }
}
