import SwiftUI
import UIKit

/// A large button that scores only after it has been held down for `holdTime`,
/// so accidental brushes do not record anything. A fill shows the progress.
struct HoldScoreButton: View {
    let title: String
    let color: Color
    let systemImage: String
    var holdTime: Double = 0.3
    let action: () -> Void

    @State private var isPressing = false
    @State private var fired = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(color.opacity(0.35))
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 20)
                    .fill(color)
                    .frame(width: isPressing ? geo.size.width : 0)
                    .animation(isPressing ? .linear(duration: holdTime) : .easeOut(duration: 0.15), value: isPressing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.title)
                Text(title).font(.title2.bold())
                Text("hold").font(.caption).opacity(0.8)
            }
            .foregroundStyle(.white)
        }
        .scaleEffect(fired ? 0.96 : 1)
        .animation(.easeOut(duration: 0.15), value: fired)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onLongPressGesture(minimumDuration: holdTime, maximumDistance: 60, perform: {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            fired = true
            action()
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                fired = false
            }
        }, onPressingChanged: { pressing in
            isPressing = pressing
        })
        .accessibilityLabel("\(title), hold to score")
        .accessibilityAddTraits(.isButton)
    }
}
