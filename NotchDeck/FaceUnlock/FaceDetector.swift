import Vision

/// One detected face, in Vision's normalised image coordinates (origin bottom-left, 0...1).
struct FaceSample: Equatable, Sendable {
    var box: CGRect
    /// Radians, Vision's convention. Measured on the MacBook camera: yaw > 0 when the user turns to
    /// their own left.
    var yaw: Double
    var roll: Double
    var pitch: Double
    /// `VNDetectFaceCaptureQualityRequest`, 0...1; nil if Vision returned none.
    var quality: Float?
    /// Eye contours for the blink check (step 4), normalised to the image.
    var leftEye: [CGPoint] = []
    var rightEye: [CGPoint] = []
}

/// Vision face detection + landmarks + capture quality, synchronously on the caller's thread.
enum FaceDetector {
    static func detect(_ frame: FaceCaptureService.Frame) throws -> [FaceSample] {
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixels, orientation: .up)
        // Revision 3 rectangles carry yaw, roll and pitch; the landmarks request leaves pitch nil.
        let rects = VNDetectFaceRectanglesRequest()
        rects.revision = VNDetectFaceRectanglesRequestRevision3
        try handler.perform([rects])
        let faces = rects.results ?? []
        guard !faces.isEmpty else { return [] }
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = faces
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = faces
        try handler.perform([landmarks])
        try? handler.perform([quality])
        let marked = landmarks.results ?? []
        let scored = quality.results ?? []
        return faces.enumerated().map { i, face in
            let lm = i < marked.count ? marked[i].landmarks : nil
            return FaceSample(
                box: face.boundingBox,
                yaw: face.yaw?.doubleValue ?? 0,
                roll: face.roll?.doubleValue ?? 0,
                pitch: face.pitch?.doubleValue ?? 0,
                quality: i < scored.count ? scored[i].faceCaptureQuality : nil,
                leftEye: points(lm?.leftEye, in: face.boundingBox),
                rightEye: points(lm?.rightEye, in: face.boundingBox))
        }
    }

    /// Landmark points are relative to the face box; convert to image coordinates.
    private static func points(_ region: VNFaceLandmarkRegion2D?, in box: CGRect) -> [CGPoint] {
        (region?.normalizedPoints ?? []).map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }
    }
}

/// Accepts a frame only with exactly one centred, large enough, good quality face.
struct FaceGate {
    enum Verdict: Equatable {
        case ok(FaceSample)
        case noFace, multipleFaces, tooSmall, offCentre, lowQuality
    }

    // ponytail: thresholds picked for a MacBook camera at arm's length; tune in step 4 calibration.
    var minWidth: CGFloat = 0.18
    var maxCentreOffset: CGFloat = 0.22
    var minQuality: Float = 0.3

    func check(_ faces: [FaceSample]) -> Verdict {
        guard let face = faces.first else { return .noFace }
        guard faces.count == 1 else { return .multipleFaces }
        guard face.box.width >= minWidth else { return .tooSmall }
        guard abs(face.box.midX - 0.5) <= maxCentreOffset, abs(face.box.midY - 0.5) <= maxCentreOffset else { return .offCentre }
        if let q = face.quality, q < minQuality { return .lowQuality }
        return .ok(face)
    }
}
