//
//  VoiceCommandsHelpView.swift
//  ClayShootScoreApp
//
//  Created by Clive Talbutt on 23/10/2026.
//


import SwiftUI

/// One thing the user can say, with a short explanation of what it does.
struct VoiceCommand: Identifiable {
    let phrase: String
    let meaning: String
    var id: String { phrase }
}

/// A group of related voice commands shown under one heading.
struct VoiceCommandGroup: Identifiable {
    let title: String
    let systemImage: String
    let commands: [VoiceCommand]
    var id: String { title }
}

/// The reference card shown from the toolbar's help button, listing every
/// phrase the app understands while it is listening.
struct VoiceCommandsHelpView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// True on iPhone, where the card is shown as a sheet that must scroll and
    /// fill the screen width rather than being a fixed-size popover.
    private var isCompact: Bool { horizontalSizeClass == .compact }

    static let groups: [VoiceCommandGroup] = [
        VoiceCommandGroup(
            title: "Scoring",
            systemImage: "target",
            commands: [
                VoiceCommand(phrase: "hit", meaning: "Scores the next target as a hit."),
                VoiceCommand(phrase: "miss  /  lost", meaning: "Scores the next target as a miss."),
                VoiceCommand(phrase: "pair hit", meaning: "Scores the next two targets as hits."),
                VoiceCommand(phrase: "pair lost  /  lost pair", meaning: "Scores the next two targets as misses."),
            ]
        ),
        VoiceCommandGroup(
            title: "Choosing a shooter",
            systemImage: "person.crop.circle",
            commands: [
                VoiceCommand(phrase: "<name>", meaning: "Switches scoring to that shooter. Say either name, e.g. “John” or “John Taylor”."),
                VoiceCommand(phrase: "shooter <name>", meaning: "The same, with the word “shooter” in front."),
                VoiceCommand(phrase: "<name> hit", meaning: "Switches to that shooter and scores in one go."),
            ]
        ),
        VoiceCommandGroup(
            title: "Stands",
            systemImage: "square.grid.3x3",
            commands: [
                VoiceCommand(phrase: "stand 3", meaning: "Moves scoring to stand 3. Scoring moves on by itself once every shooter has shot the current stand."),
                VoiceCommand(phrase: "next stand", meaning: "Moves scoring to the following stand."),
                VoiceCommand(phrase: "stand 3 john hit", meaning: "Moves to stand 3, switches to John and scores in one go."),
            ]
        ),
        VoiceCommandGroup(
            title: "Clearing",
            systemImage: "eraser",
            commands: [
                VoiceCommand(phrase: "clear shooters", meaning: "Removes every shooter and starts again."),
                VoiceCommand(phrase: "clear shooter <name>", meaning: "Removes that shooter from the shoot."),
                VoiceCommand(phrase: "clear score <name>", meaning: "Wipes that shooter's scores on every stand."),
                VoiceCommand(phrase: "clear score <name> stand 3", meaning: "Wipes that shooter's scores on stand 3 only, and moves scoring there."),
                VoiceCommand(phrase: "clear score", meaning: "Wipes the current shooter's scores. Add “stand 3” for one stand."),
            ]
        ),
        VoiceCommandGroup(
            title: "Adding shooters",
            systemImage: "person.badge.plus",
            commands: [
                VoiceCommand(phrase: "<name>, pause, <name>…", meaning: "After pressing Add Shooters, say each name and pause between them. Press Finish when done."),
            ]
        ),
    ]

    @ViewBuilder
    var body: some View {
        if isCompact {
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            content
                .padding(20)
                .frame(width: 420, alignment: .leading)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Voice Commands", systemImage: "waveform")
                .font(.title3.weight(.semibold))

            Text("Press Start Listening, then say any of these. Words are matched by sound, so small mishearings are fine.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Label(group.title, systemImage: group.systemImage)
                        .font(.headline)

                    ForEach(group.commands) { command in
                        commandRow(command)
                    }
                }
            }

            Text("Clear commands are carried out about a second after you stop speaking, so pause briefly after saying one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The phrase beside its meaning on the Mac; stacked on iPhone, where the
    /// two columns would leave the meaning too narrow to read comfortably.
    @ViewBuilder
    private func commandRow(_ command: VoiceCommand) -> some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(command.phrase)”")
                    .font(.callout.weight(.medium))

                Text(command.meaning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("“\(command.phrase)”")
                    .font(.callout.weight(.medium))
                    .frame(width: 170, alignment: .leading)

                Text(command.meaning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    VoiceCommandsHelpView()
}
