//
//  ScoreTableView.swift
//  MyApp
//
//  Created by Clive Talbutt on 23/10/2026.
//


import SwiftUI

/// Shows every shooter as a row, with all stands laid out side by side across the
/// available width. Each stand shows its 10 targets followed by the stand total,
/// and the row ends with the shooter's grand total and, once the shoot is
/// complete, their finishing place.
struct ScoreTableView: View {
    var vm: ShootViewModel

    private let nameWidth: CGFloat = 120
    private let standTotalWidth: CGFloat = 36
    private let grandTotalWidth: CGFloat = 56
    private let placeWidth: CGFloat = 72
    private let standCount = ShootViewModel.numberOfStands
    private let targetCount = ShootViewModel.targetsPerStand

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                headerRow

                if vm.shooters.isEmpty {
                    Text("No shooters yet. Press Add Shooter and say the shooter's name.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(vm.shooters.indices, id: \.self) { shooterIndex in
                        shooterRow(shooterIndex)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Shooter")
                .font(.headline)
                .frame(width: nameWidth, alignment: .leading)

            ForEach(0..<standCount, id: \.self) { stand in
                HStack(spacing: 4) {
                    Text("Stand \(stand + 1)")
                        .font(.headline)
                        .foregroundStyle(stand == vm.currentStand && !vm.isComplete ? Color.accentColor : .primary)
                        .frame(maxWidth: .infinity)

                    Text("Tot")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: standTotalWidth)
                }
            }

            Text("Total")
                .font(.headline)
                .frame(width: grandTotalWidth)

            if vm.isComplete {
                Text("Place")
                    .font(.headline)
                    .frame(width: placeWidth)
            }
        }
    }

    // MARK: - Rows

    private func shooterRow(_ shooterIndex: Int) -> some View {
        let shooter = vm.shooters[shooterIndex]
        let isCurrentShooter = shooterIndex == vm.currentShooterIndex && !vm.isComplete

        return HStack(spacing: 8) {
            // Clicking a name also makes that shooter current.
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .opacity(isCurrentShooter ? 1 : 0)
                Text(shooter.name.capitalized)
                    .fontWeight(isCurrentShooter ? .bold : .regular)
                    .foregroundStyle(isCurrentShooter ? Color.accentColor : .primary)
            }
            .frame(width: nameWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                vm.selectShooter(at: shooterIndex)
            }

            ForEach(0..<standCount, id: \.self) { stand in
                standCells(shooterIndex: shooterIndex, stand: stand)
            }

            Text("\(shooter.grandTotal)")
                .bold()
                .frame(width: grandTotalWidth)

            if vm.isComplete {
                placeLabel(for: shooter)
                    .frame(width: placeWidth)
            }
        }
        .padding(.vertical, 4)
        .background(isCurrentShooter ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The 10 target cells and stand total for one shooter on one stand.
    private func standCells(shooterIndex: Int, stand: Int) -> some View {
        let shooter = vm.shooters[shooterIndex]
        let standScores = shooter.scores.indices.contains(stand) ? shooter.scores[stand] : []
        let isCurrentStand = stand == vm.currentStand && !vm.isComplete

        return HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<targetCount, id: \.self) { target in
                    let score = target < standScores.count ? standScores[target] : -1
                    Text(score == -1 ? "-" : "\(score)")
                        .font(.callout.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(cellColor(for: score))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleScore(shooterIndex: shooterIndex, stand: stand, target: target, current: score)
                        }
                }
            }
            .padding(2)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isCurrentStand ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
            )

            Text("\(shooter.standTotal(stand))")
                .font(.callout.monospacedDigit())
                .bold()
                .frame(width: standTotalWidth)
        }
    }

    /// Medal and ordinal for a shooter's finishing place, e.g. "🥇 1st".
    @ViewBuilder
    private func placeLabel(for shooter: Shooter) -> some View {
        if let place = vm.placing(for: shooter) {
            HStack(spacing: 4) {
                if let medal = Placing.medal(place) {
                    Text(medal)
                }
                Text(Placing.ordinal(place))
                    .bold()
            }
        } else {
            Text("")
        }
    }

    // MARK: - Helpers

    private func cellColor(for score: Int) -> Color {
        switch score {
        case 1, 2: return Color.green.opacity(0.25)
        case 0: return Color.red.opacity(0.2)
        default: return Color.gray.opacity(0.15)
        }
    }

    /// Tapping a cell cycles it between hit and miss so scores can be corrected by hand.
    private func toggleScore(shooterIndex: Int, stand: Int, target: Int, current: Int) {
        guard vm.shooters.indices.contains(shooterIndex),
              vm.shooters[shooterIndex].scores.indices.contains(stand),
              vm.shooters[shooterIndex].scores[stand].indices.contains(target) else { return }
        vm.shooters[shooterIndex].scores[stand][target] = current == 1 ? 0 : 1
    }
}

#Preview("Completed shoot") {
    let vm = ShootViewModel()
    for (index, name) in ["john taylor", "joe black", "clive"].enumerated() {
        vm.addShooter(named: name)
        for stand in vm.shooters[index].scores.indices {
            for target in vm.shooters[index].scores[stand].indices {
                vm.shooters[index].scores[stand][target] = (stand + target + index) % 4 == 0 ? 0 : 1
            }
        }
    }
    return ScoreTableView(vm: vm)
        .frame(width: 1200)
}
