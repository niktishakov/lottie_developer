import Foundation

@Observable
final class PlaybackState {
    var isPlaying: Bool = true
    var speed: Double = 1.0
    var loopEnabled: Bool = true
    var currentProgress: Double = 0.0
    var fromProgress: Double = 0.0
    var toProgress: Double = 1.0

    static let speeds: [Double] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0]
}
