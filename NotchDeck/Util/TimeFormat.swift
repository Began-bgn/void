import Foundation

/// `m:ss`. Negative, NaN or infinite input renders as `0:00`.
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// `-m:ss` left of `elapsed`.
func remainingTime(elapsed: Double, duration: Double) -> String {
    "-" + formatTime(max(0, duration - elapsed))
}
