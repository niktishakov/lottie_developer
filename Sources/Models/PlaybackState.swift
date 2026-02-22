import SwiftUI

@Observable
final class PlaybackState {
    var isPlaying: Bool = true
    var speed: Double = 1.0
    var loopEnabled: Bool = true
    var currentProgress: Double = 0.0
    var fromProgress: Double = 0.0
    var toProgress: Double = 1.0
    var selectedHullColor: Color = PlaybackState.defaultHullColor
    var selectedWingColor: Color = PlaybackState.defaultWingColor
    var selectedExhaustColor: Color = PlaybackState.defaultExhaustColor

    static let speeds: [Double] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0]
    static let defaultHullColor = Color(red: 0.95, green: 0.95, blue: 0.95)
    static let defaultWingColor = Color(red: 0.89, green: 0.92, blue: 0.98)
    static let defaultExhaustColor = Color(red: 0.95, green: 0.56, blue: 0.21)
}
