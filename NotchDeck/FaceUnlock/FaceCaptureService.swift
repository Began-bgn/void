import AVFoundation

/// Built-in camera at 640x480, running only while a stream is being consumed. All session work
/// happens on one serial queue (a class, not an actor: the sample-buffer delegate must be an
/// NSObject). The system camera indicator is never touched.
final class FaceCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let pixels: CVPixelBuffer
        let time: Double
    }

    enum CaptureError: Error, Equatable {
        case notAuthorized, noCamera, configuration
    }

    private let queue = DispatchQueue(label: "com.notchdeck.faceunlock.camera")
    private var session: AVCaptureSession? // queue only
    private var continuation: AsyncStream<Frame>.Continuation? // queue only
    private var errorToken: NSObjectProtocol? // queue only

    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    /// Built-in only: an external or Continuity camera is refused.
    static var builtInCamera: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            .devices.first
    }

    /// Starts the camera. Frames arrive until `stop()`, an error, or the consumer stops iterating.
    /// Only the newest frame is buffered, so slow analysis never queues stale frames.
    func start() async throws -> AsyncStream<Frame> {
        guard Self.isAuthorized else { throw CaptureError.notAuthorized }
        guard let device = Self.builtInCamera else { throw CaptureError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        let (stream, cont) = AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(1))
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let session = AVCaptureSession()
                session.beginConfiguration()
                session.sessionPreset = .vga640x480
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    return done.resume(throwing: CaptureError.configuration)
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
                session.startRunning()
                self.session = session
                self.continuation = cont
                self.errorToken = NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in self?.stop() }
                done.resume()
            }
        }
        cont.onTermination = { [weak self] _ in self?.stop() }
        return stream
    }

    /// Idempotent. Called after every scan, on unlock, sleep, error and quit.
    func stop() {
        queue.async { [self] in
            if let errorToken { NotificationCenter.default.removeObserver(errorToken) }
            errorToken = nil
            session?.stopRunning()
            session = nil
            continuation?.finish()
            continuation = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        continuation?.yield(Frame(pixels: pixels, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds))
    }
}
