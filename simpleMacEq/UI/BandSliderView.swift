import SwiftUI

// ponytail: unified slider — was two near-identical views (BandSliderView + MiniBandSlider)
struct BandSliderView: View {
    @Binding var gain: Double
    let label: String
    var compact: Bool = false
    var onEdit: () -> Void = {}

    var body: some View {
        VStack(spacing: compact ? 4 : 6) {
            if !compact {
                Text(String(format: "%+.0f", gain))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }

            GeometryReader { geo in
                let range = Band.gainRange
                let span = range.upperBound - range.lowerBound
                let h = geo.size.height
                let frac = (gain - range.lowerBound) / span
                let thumbY = h * (1 - frac)
                let trackW: CGFloat = compact ? 3 : 4
                let thumbD: CGFloat = compact ? 10 : 13

                ZStack(alignment: .bottom) {
                    Capsule().fill(Theme.trackInactive).frame(width: trackW)
                    Capsule().fill(Theme.accent).frame(width: trackW, height: max(0, h * frac))
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: thumbD, height: thumbD)
                        .overlay(compact ? nil : Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: compact ? .clear : .black.opacity(0.2), radius: 1, y: 1)
                        .position(x: geo.size.width / 2, y: thumbY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let f = max(0, min(1, 1 - value.location.y / h))
                            gain = (range.lowerBound + f * span).rounded()
                            onEdit()
                        }
                )
            }
            .frame(maxWidth: .infinity)

            Text(label)
                .font(.system(size: compact ? 8 : 9, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
