import CoreImage
import Foundation
import Observation

/// Face ID-style enrolment: a few frames looking straight, then one frame per direction while the
/// user moves their head in a slow circle. Pure, so it can be tested.
struct EnrolmentPlan: Equatable {
    /// Directions around the circle, each filled by one frame. 12 + 3 centre = 15 templates.
    var sectors = 12
    var centreFrames = 3
    /// Head is "straight" within this (radians), and "turned" beyond `minTurn`.
    var straight = 0.12
    var minTurn = 0.18
    /// Screen x of the head direction is `yaw * yawSign`: Vision yaw grows when the user turns to
    /// their left, which is screen left in the mirrored preview.
    var yawSign = -1.0
    /// Screen y is `pitch * pitchSign`: Vision pitch grows when the user tilts their head down
    /// (measured in enrolment on the MacBook camera).
    var pitchSign = -1.0

    private(set) var centre = 0
    private(set) var filled: Set<Int> = []

    var isComplete: Bool { centre >= centreFrames && filled.count == sectors }
    var progress: Double { Double(min(centre, centreFrames) + filled.count) / Double(centreFrames + sectors) }
    var instruction: String {
        if centre < centreFrames { return "Look straight at the camera" }
        return isComplete ? "Done" : "Slowly move your head in a circle"
    }

    /// Head direction on screen: x right, y up, radians.
    func direction(_ face: FaceSample) -> (x: Double, y: Double) {
        (face.yaw * yawSign, face.pitch * pitchSign)
    }

    /// Sector (0 = screen right, counter-clockwise) for a turned head, nil if near straight.
    func sector(_ face: FaceSample) -> Int? {
        let d = direction(face)
        guard (d.x * d.x + d.y * d.y).squareRoot() >= minTurn else { return nil }
        var angle = atan2(d.y, d.x)
        if angle < 0 { angle += 2 * .pi }
        return Int(angle / (2 * .pi) * Double(sectors)) % sectors
    }

    /// Records the frame if it adds something: a straight frame while centre frames are needed,
    /// or the first frame in an empty sector after that. True means keep its embedding.
    mutating func offer(_ face: FaceSample) -> Bool {
        if centre < centreFrames {
            guard abs(face.yaw) < straight, abs(face.pitch) < straight else { return false }
            centre += 1
            return true
        }
        guard let s = sector(face), !filled.contains(s) else { return false }
        filled.insert(s)
        return true
    }
}

/// Runs the camera, keeps frames that pass the gate and add to the plan, and saves their
/// embeddings. Shows a live preview while enrolling; frames are never stored.
@MainActor @Observable
final class EnrolmentSession {
    private(set) var plan = EnrolmentPlan()
    private(set) var hint = "Look straight at the camera"
    /// Mirrored camera image for the enrolment circle. Memory only.
    private(set) var preview: CGImage?
    /// Current head direction for the ring highlight, nil without a usable face.
    private(set) var headDirection: (x: Double, y: Double)?
    private(set) var finished = false
    private(set) var error: String?

    @ObservationIgnored private let recognizer: any FaceRecognizer
    @ObservationIgnored private let store: TemplateStore
    @ObservationIgnored private let camera = FaceCaptureService()
    @ObservationIgnored private var task: Task<Void, Never>?
    private nonisolated static let context = CIContext()

    init(recognizer: any FaceRecognizer, store: TemplateStore = TemplateStore()) {
        self.recognizer = recognizer
        self.store = store
    }

    func start() {
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        task?.cancel()
        camera.stop()
        preview = nil
    }

    private struct Analysis: @unchecked Sendable {
        var verdict: FaceGate.Verdict
        var image: CGImage?
    }

    private func run() async {
        defer { camera.stop(); preview = nil }
        var templates: [[Float]] = []
        let gate = FaceGate()
        let recognizer = self.recognizer
        do {
            for await frame in try await camera.start() {
                guard !Task.isCancelled else { return }
                let analysis = await Task.detached {
                    let mirrored = CIImage(cvPixelBuffer: frame.pixels).oriented(.upMirrored)
                    return Analysis(verdict: gate.check((try? FaceDetector.detect(frame)) ?? []),
                                    image: Self.context.createCGImage(mirrored, from: mirrored.extent))
                }.value
                preview = analysis.image
                guard case .ok(let face) = analysis.verdict else {
                    headDirection = nil
                    hint = Self.hint(for: analysis.verdict)
                    continue
                }
                headDirection = plan.direction(face)
                var next = plan
                guard next.offer(face) else { hint = plan.instruction; continue }
                guard let embedding = await Task.detached(operation: { try? recognizer.embedding(of: frame, face: face) }).value else { continue }
                plan = next
                templates.append(embedding)
                hint = plan.instruction
                if plan.isComplete { break }
            }
            guard plan.isComplete else { return }
            try store.save(templates)
            finished = true
        } catch {
            self.error = String(describing: error)
        }
    }

    private static func hint(for verdict: FaceGate.Verdict) -> String {
        switch verdict {
        case .ok: ""
        case .noFace: "Position your face in the circle"
        case .multipleFaces: "Only one face, please"
        case .tooSmall: "Move closer"
        case .offCentre: "Centre your face in the circle"
        case .lowQuality: "More light, please"
        }
    }
}
