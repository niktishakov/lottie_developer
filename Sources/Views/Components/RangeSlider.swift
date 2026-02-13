import SwiftUI

struct RangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    let range: ClosedRange<Double>

    @State private var isDraggingLow = false
    @State private var isDraggingHigh = false

    private let thumbSize: CGFloat = 22
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - thumbSize
            let span = range.upperBound - range.lowerBound

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbSize / 2)

                // Active range track
                let lowX = ((low - range.lowerBound) / span) * width
                let highX = ((high - range.lowerBound) / span) * width

                Capsule()
                    .fill(Color.indigo)
                    .frame(width: max(0, highX - lowX), height: trackHeight)
                    .offset(x: lowX + thumbSize / 2)

                // Low thumb
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: lowX)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDraggingLow = true
                                let fraction = max(0, min(value.location.x / width, 1))
                                let newVal = range.lowerBound + fraction * span
                                low = min(newVal, high - 0.01)
                            }
                            .onEnded { _ in isDraggingLow = false }
                    )

                // High thumb
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: highX)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDraggingHigh = true
                                let fraction = max(0, min(value.location.x / width, 1))
                                let newVal = range.lowerBound + fraction * span
                                high = max(newVal, low + 0.01)
                            }
                            .onEnded { _ in isDraggingHigh = false }
                    )
            }
        }
        .frame(height: thumbSize)
    }
}
