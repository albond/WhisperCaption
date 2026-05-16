import Foundation

/// Coarse load/health snapshot every `TranscriptionEngine` surfaces to the UI.
/// Lives in its own file so cloud engines (which also emit this state but
/// don't import WhisperKit) can be compiled and unit-tested without dragging
/// the WhisperKit dependency in.
enum WhisperLoadState: Sendable, Equatable {
    case idle
    case loading(progress: Double, message: String)
    case ready
    case failed(String)
}
