import SwiftUI

/// A vertical EQ band slider matching the design (accent fill + round thumb).
struct BandSliderView: View {
    @Binding var band: Band
    var onEdit: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.0f", band.gain))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)

            GeometryReader { geo in
                let range = Band.gainRange
                let span = range.upperBound - range.lowerBound
                let h = geo.size.height
                let frac = (band.gain - range.lowerBound) / span
                let thumbY = h * (1 - frac)

                ZStack(alignment: .bottom) {
                    Capsule().fill(Theme.trackInactive).frame(width: 4)
                    Capsule().fill(Theme.accent).frame(width: 4, height: max(0, h * frac))
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                        .position(x: geo.size.width / 2, y: thumbY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let f = max(0, min(1, 1 - value.location.y / h))
                            band.gain = (range.lowerBound + f * span).rounded()
                            onEdit()
                        }
                )
            }
            .frame(maxWidth: .infinity)

            Text(band.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
