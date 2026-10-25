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
///
/// The table scrolls in both directions when it is wider or taller than the
/// window. Whenever a shooter is selected (by voice, by clicking their name or by
/// the scoring moving on) their row is scrolled vertically into view, leaving the
/// horizontal position alone so the stands being viewed stay put.
struct ScoreTableView: View {
    var vm: ShootViewModel

    @State private var scrollPosition = ScrollPosition()
    /// The shooter whose email address is being edited, and the text typed so far.
    @State private var emailEditID: Shooter.ID?
    @State private var emailDraft = ""
    /// The part of the table content currently on screen, in content coordinates.
    @State private var visibleRect = CGRect.zero
    /// Where each shooter's row sits within the table content.
    @State private var standFrames: [Int: CGRect] = [:]
    @State private var rowFrames: [Shooter.ID: CGRect] = [:]
    /// A shooter whose row should be scrolled to as soon as it has been laid out.
    @State private var pendingScrollID: Shooter.ID?

    private static let tableSpace = "scoreTable"

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// True on iPhone-sized screens, where the name column, header text and
    /// padding are trimmed so more of the first stand fits on screen.
    private var isCompact: Bool {
        horizontalSizeClass == .compact || verticalSizeClass == .compact
    }

    private var nameWidth: CGFloat { isCompact ? 100 : 120 }
    private var tablePadding: CGFloat { isCompact ? 10 : 16 }
    private var headerFont: Font { isCompact ? .caption.weight(.semibold) : .subheadline.weight(.semibold) }
    private let targetCellWidth: CGFloat = 14
    private let targetCellHeight: CGFloat = 18
    private let targetCellSpacing: CGFloat = 1
    private let standTotalWidth: CGFloat = 22
    private let grandTotalWidth: CGFloat = 44
    private let placeWidth: CGFloat = 72
    private let targetCount = ShootViewModel.targetsPerStand

    /// Small fonts keep the tick, cross and totals in proportion with the narrow cells.
    private let cellFont: Font = .caption2
    private let totalFont: Font = .caption

    private var standCount: Int { vm.numberOfStands }

    /// Width of the bordered block of target cells for one stand, so the header
    /// lines up with the rows even though the table scrolls horizontally.
    private var standCellsWidth: CGFloat {
        CGFloat(targetCount) * targetCellWidth + CGFloat(targetCount - 1) * targetCellSpacing + 4
    }

    var body: some View {
        scrollingTable
            .alert("Email address", isPresented: Binding(get: { emailEditID != nil }, set: { if !$0 { emailEditID = nil } })) {
                TextField("name@example.com", text: $emailDraft)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") {
                    if let id = emailEditID, let s = vm.shooters.first(where: { $0.id == id }) { vm.setEmail(emailDraft, for: s.name) }
                    emailEditID = nil
                }
                Button("Cancel", role: .cancel) { emailEditID = nil }
            } message: {
                Text("Their results are emailed to them after the shoot is uploaded. Leave blank to remove.")
            }
    }

    private var scrollingTable: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 6) {
                headerRow

                if vm.shooters.isEmpty {
                    Text("No shooters yet. Press Add Shooters and say the shooters' names.")
                        .foregroundStyle(.secondary)
                        // Match the visible width so the message wraps instead of
                        // running off the side of the horizontally scrolling table.
                        .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                            max(0, length - 2 * tablePadding)
                        }
                        .padding(.vertical, 24)
                } else {
                    ForEach(vm.shooters.indices, id: \.self) { shooterIndex in
                        let shooterID = vm.shooters[shooterIndex].id
                        shooterRow(shooterIndex)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Self.tableSpace))
                            } action: { frame in
                                rowFrames[shooterID] = frame
                                if pendingScrollID == shooterID {
                                    scrollToCurrentShooter()
                                }
                            }
                    }
                }
            }
            .padding(tablePadding)
            .coordinateSpace(.named(Self.tableSpace))
        }
        .scrollIndicators(.visible)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGRect.self) { geometry in
            CGRect(origin: geometry.contentOffset, size: geometry.containerSize)
        } action: { _, newValue in
            visibleRect = newValue
            if pendingScrollID != nil {
                scrollToCurrentShooter()
            }
        }
        .onChange(of: vm.selectionCount) { _, _ in
            scrollToCurrentShooter()
        }
        .onChange(of: vm.currentShooterIndex) { _, _ in
            scrollToCurrentShooter()
        }
        .onChange(of: vm.currentStand) { _, _ in
            scrollToCurrentShooter()
        }
    }

    /// Scrolls vertically by the smallest amount that brings the current shooter's
    /// row fully into view. The horizontal offset is kept exactly as it is. If the
    /// row has not been laid out yet (a shooter was just added) the scroll happens
    /// as soon as its frame is known.
    private func scrollToCurrentShooter() {
        guard let index = vm.currentShooterIndex, vm.shooters.indices.contains(index) else { return }
        let shooterID = vm.shooters[index].id
        guard let row = rowFrames[shooterID], visibleRect.height > 0 else {
            pendingScrollID = shooterID
            return
        }
        pendingScrollID = nil

        let margin: CGFloat = 8
        var targetY = visibleRect.minY
        if row.minY < visibleRect.minY {
            targetY = row.minY - margin
        } else if row.maxY > visibleRect.maxY {
            targetY = row.maxY + margin - visibleRect.height
        }

        // Also bring the current stand's columns into view horizontally.
        var targetX = visibleRect.minX
        if !vm.isComplete, let stand = standFrames[vm.currentStand] {
            if stand.width >= visibleRect.width || stand.minX < visibleRect.minX {
                targetX = stand.minX - margin
            } else if stand.maxX > visibleRect.maxX {
                targetX = stand.maxX + margin - visibleRect.width
            }
        }
        targetX = max(0, targetX)
        targetY = max(0, targetY)
        guard abs(targetX - visibleRect.minX) > 0.5 || abs(targetY - visibleRect.minY) > 0.5 else { return }

        withAnimation(.snappy) {
            scrollPosition.scrollTo(x: targetX, y: targetY)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("Shooter")
                .font(headerFont)
                .frame(width: nameWidth, alignment: .leading)

            ForEach(0..<standCount, id: \.self) { stand in
                HStack(spacing: 2) {
                    Text("Stand \(stand + 1)")
                        .font(headerFont)
                        .foregroundStyle(stand == vm.currentStand && !vm.isComplete ? Color.accentColor : .primary)
                        .frame(width: standCellsWidth)

                    // Blank space above the stand total column keeps the header aligned
                    // with the rows without labelling every stand total.
                    Color.clear
                        .frame(width: standTotalWidth, height: 1)
                }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.tableSpace))
                } action: { frame in
                    standFrames[stand] = frame
                    if stand == vm.currentStand { scrollToCurrentShooter() }
                }
            }

            Text("Total")
                .font(headerFont)
                .frame(width: grandTotalWidth)

            if vm.isComplete {
                Text("Place")
                    .font(headerFont)
                    .frame(width: placeWidth)
            }
        }
    }

    // MARK: - Rows

    private func shooterRow(_ shooterIndex: Int) -> some View {
        let shooter = vm.shooters[shooterIndex]
        let isCurrentShooter = shooterIndex == vm.currentShooterIndex && !vm.isComplete

        return HStack(spacing: 6) {
            // Clicking a name also makes that shooter current.
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .opacity(isCurrentShooter ? 1 : 0)
                Text(shooter.name.capitalized)
                    .font(.subheadline)
                    .fontWeight(isCurrentShooter ? .bold : .regular)
                    .foregroundStyle(isCurrentShooter ? Color.accentColor : (vm.kind(for: shooter.name).map { $0 == "member" ? Color.green : ($0 == "guest" ? Color.red : Color.gray) } ?? .primary))
                    .lineLimit(1)
                if vm.kind(for: shooter.name) == "guest" {
                    Text("G")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .background(.red, in: .capsule)
                        .foregroundStyle(.white)
                        .accessibilityLabel("Guest")
                }
                if vm.email(for: shooter.name) != nil {
                    Image(systemName: "envelope.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: nameWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                vm.selectShooter(at: shooterIndex)
            }
            .contextMenu {
                Button {
                    emailDraft = vm.email(for: shooter.name) ?? ""
                    emailEditID = shooter.id
                } label: {
                    Label("Email address…", systemImage: "envelope")
                }
            }

            ForEach(0..<standCount, id: \.self) { stand in
                standCells(shooterIndex: shooterIndex, stand: stand)
            }

            Text("\(shooter.grandTotal)")
                .font(.subheadline.monospacedDigit())
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

        return HStack(spacing: 2) {
            HStack(spacing: targetCellSpacing) {
                ForEach(0..<targetCount, id: \.self) { target in
                    let score = target < standScores.count ? standScores[target] : -1
                    cellSymbol(for: score)
                        .frame(width: targetCellWidth, height: targetCellHeight)
                        .background(cellColor(for: score))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
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
                .font(totalFont.monospacedDigit())
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

    /// A green tick for a hit, a red cross for a miss and a dash for a target
    /// that has not been shot yet.
    @ViewBuilder
    private func cellSymbol(for score: Int) -> some View {
        switch score {
        case let hit where hit > 0:
            Image(systemName: "checkmark")
                .font(cellFont.weight(.bold))
                .foregroundStyle(.green)
        case 0:
            Image(systemName: "xmark")
                .font(cellFont.weight(.bold))
                .foregroundStyle(.red)
        default:
            Text("-")
                .font(cellFont)
                .foregroundStyle(.secondary)
        }
    }

    private func cellColor(for score: Int) -> Color {
        switch score {
        case 1, 2: return Color.green.opacity(0.25)
        case 0: return Color.red.opacity(0.2)
        default: return Color.gray.opacity(0.15)
        }
    }

    /// Tapping a cell cycles it from not shot (-) to a hit (tick) to a miss
    /// (cross) and back to not shot, so scores can be corrected by hand.
    private func toggleScore(shooterIndex: Int, stand: Int, target: Int, current: Int) {
        guard vm.shooters.indices.contains(shooterIndex),
              vm.shooters[shooterIndex].scores.indices.contains(stand),
              vm.shooters[shooterIndex].scores[stand].indices.contains(target) else { return }
        let next: Int
        switch current {
        case 1: next = 0        // tick -> cross
        case 0: next = -1       // cross -> not shot
        default: next = 1       // not shot -> tick
        }
        guard !vm.isStandLocked(stand) else { return }
        vm.shooters[shooterIndex].scores[stand][target] = next
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
