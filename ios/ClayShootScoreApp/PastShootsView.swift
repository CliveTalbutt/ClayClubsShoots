import SwiftUI

/// Results of one finished shoot, loaded from the server.
struct PastShootView: View {
    let shoot: PastShoot
    let settings: ClayShootsSettings
    @Environment(\.dismiss) private var dismiss
    @State private var results: PastShootResults?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let results {
                    List {
                        Section {
                            HStack {
                                Text("Place").frame(width: 70, alignment: .leading)
                                Text("Shooter")
                                Spacer()
                                Text(results.handicap ? "Net" : "Total")
                            }
                            .font(.footnote.bold())
                            .foregroundStyle(.secondary)
                            ForEach(results.shooters) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(Placing.medal(entry.place).map { "\($0) " } ?? "")
                                            + Text(Placing.ordinal(entry.place)).bold()
                                        Text(entry.name.capitalized).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                                        Text(results.handicap ? "\(Int(entry.net))" : "\(entry.total)")
                                            .bold().monospacedDigit()
                                    }
                                    Text(standLine(entry, results: results))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } footer: {
                            if let venue = results.venue, !venue.isEmpty { Text(venue) }
                        }
                    }
                } else if let message {
                    ContentUnavailableView("Could not load the results", systemImage: "wifi.exclamationmark", description: Text(message))
                } else {
                    ProgressView("Loading results…")
                }
            }
            .navigationTitle(shoot.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await load() }
    }

    private func standLine(_ entry: PastShootResults.Entry, results: PastShootResults) -> String {
        let stands = entry.scores.enumerated().map { "S\($0.offset + 1): \($0.element)" }.joined(separator: "  ")
        return results.handicap ? "\(stands)  (\(entry.total) − \(Int(entry.handicap)))" : stands
    }

    private func load() async {
        guard let client = settings.client else { message = "Add the server in Server Settings first."; return }
        do { results = try await client.pastShoot(id: shoot.id) }
        catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}
