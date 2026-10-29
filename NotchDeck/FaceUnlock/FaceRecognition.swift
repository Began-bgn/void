import CoreML
import Vision

/// FaceNet (Inception-ResNet v1, VGGFace2 weights) via Core ML: 160x160 face crop in, 512-d
/// L2-normalised embedding out. Converted by `scripts/convert-facenet.py`; licences there.
final class CoreMLFaceRecognizer: FaceRecognizer, @unchecked Sendable {
    private let model: VNCoreMLModel // VNCoreMLModel is safe to share; requests are per call

    /// Margin around Vision's face box, as a fraction of its size (facenet-pytorch crops loosely).
    // ponytail: crop is not roll-aligned; align eyes first if head tilt hurts the scores.
    static let margin: CGFloat = 0.2

    init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try VNCoreMLModel(for: FaceNet(configuration: config).model)
    }

    func embedding(of frame: FaceCaptureService.Frame, face: FaceSample) throws -> [Float] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        request.regionOfInterest = Self.crop(face.box)
        try VNImageRequestHandler(cvPixelBuffer: frame.pixels, orientation: .up).perform([request])
        guard let array = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue else {
            throw CocoaError(.featureUnsupported)
        }
        return (0..<array.count).map { array[$0].floatValue }
    }

    /// Square crop around the face with margin, clamped to the image (normalised coordinates).
    static func crop(_ box: CGRect) -> CGRect {
        let side = max(box.width, box.height) * (1 + margin)
        let square = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        return square.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// Decides whether embeddings from one scan belong to the enrolled user.
struct FaceMatcher {
    // ponytail: default from FaceNet/VGGFace2 norms (same person ~0.7+, others <0.5); calibrate
    // per user with the enrolment window's score readout. Settings slider in step 6.
    var threshold: Float = 0.7
    /// Embeddings from the scan that must each be checked; the median score decides.
    var minimumFrames = 2

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return dot / max((na * nb).squareRoot(), .ulpOfOne)
    }

    /// Mean of the 3 best template similarities: one lucky template can't carry a match.
    static func score(_ embedding: [Float], templates: [[Float]]) -> Float {
        let best = templates.map { cosine(embedding, $0) }.sorted(by: >).prefix(3)
        return best.isEmpty ? -1 : best.reduce(0, +) / Float(best.count)
    }

    func matches(_ scan: [[Float]], templates: [[Float]]) -> Bool {
        guard scan.count >= minimumFrames, !templates.isEmpty else { return false }
        let scores = scan.map { Self.score($0, templates: templates) }.sorted()
        return scores[scores.count / 2] >= threshold
    }
}
