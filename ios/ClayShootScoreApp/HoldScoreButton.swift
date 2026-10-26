import SwiftUI

/// A large button that scores the instant it is touched, with no hold delay.
/// It fires once per touch, however long the finger stays down.
struct HoldScoreButton: View {
    let title: String
    let color: Color
    let systemImage: String
    let action: () -> Void

    @State private var isPressing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(isPressing ? color.opacity(0.7) : color)
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.title)
                Text(title).font(.title2.bold())
            }
            .foregroundStyle(.white)
        }
        .scaleEffect(isPressing ? 0.96 : 1)
        .animation(.easeOut(duration: 0.1), value: isPressing)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressing else { return }
                    isPressing = true
                    action()
                }
                .onEnded { _ in isPressing = false }
        )
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
