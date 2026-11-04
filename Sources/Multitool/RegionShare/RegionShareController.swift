import AppKit
import ScreenCaptureKit
import CoreMedia
import Combine

@MainActor
final class RegionShareController: NSObject, ObservableObject {
    static let shared = RegionShareController()

    enum State: Equatable {
        case idle
        case selecting
        case starting
        case sharing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentRegion: CGRect?

    /// Multi-consumer frame stream. The share window subscribes (to assign
    /// IOSurfaces to its CALayer) and the popover preview subscribes (to
    /// enqueue into an AVSampleBufferDisplayLayer).
    let framePublisher = PassthroughSubject<CMSampleBuffer, Never>()

    private let selector = RegionSelector()
    private let shareWindow = ShareWindowController()
    private var stream: SCStream?
    private var streamOutput: StreamOutput?

    override init() {
        super.init()
        selector.onComplete = { [weak self] rect in
            guard let self = self else { return }
            Task { @MainActor in
                if let rect = rect {
                    await self.startStreaming(region: rect)
                } else {
                    self.state = .idle
                }
            }
        }
        shareWindow.onClose = { [weak self] in
            Task { @MainActor in await self?.stop() }
        }
    }

    var isActive: Bool {
        switch state {
        case .sharing, .starting: return true
        default: return false
        }
    }

    // MARK: - Public

    func startSelection() {
        guard state == .idle else { return }
        state = .selecting
        selector.show()
    }

    func cancelSelection() {
        guard state == .selecting else { return }
        selector.hide()
        state = .idle
    }

    func stop() async {
        if state == .selecting {
            selector.hide()
        }
        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        shareWindow.close()
        currentRegion = nil
        state = .idle
    }

    // MARK: - Streaming setup

    private func startStreaming(region: CGRect) async {
        state = .starting
        currentRegion = region

        // Show the (invisible) share window first so it's listed in
        // SCShareableContent on the next fetch and we can exclude it.
        shareWindow.show(region: region, frames: framePublisher.eraseToAnyPublisher())

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw NSError(domain: "RegionShare", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No display available"])
            }

            let bundleID = Bundle.main.bundleIdentifier
            let ourWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == bundleID
            }
            let filter = SCContentFilter(display: display, excludingWindows: ourWindows)

            let config = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            config.sourceRect = region
            config.width = Int(region.width * scale)
            config.height = Int(region.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 5
            config.showsCursor = true
            config.scalesToFit = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            let output = StreamOutput { [weak self] buffer in
                Task { @MainActor in self?.framePublisher.send(buffer) }
            }
            try stream.addStreamOutput(output, type: .screen,
                                       sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
            try await stream.startCapture()

            self.stream = stream
            self.streamOutput = output
            state = .sharing
        } catch {
            shareWindow.close()
            currentRegion = nil
            state = .error(error.localizedDescription)
        }
    }
}

extension RegionShareController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in
            self.shareWindow.close()
            self.stream = nil
            self.streamOutput = nil
            self.currentRegion = nil
            self.state = .error(msg)
        }
    }
}

private final class StreamOutput: NSObject, SCStreamOutput {
    let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let first = attachments.first,
           let statusRaw = first[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }
        handler(sampleBuffer)
    }
}
