import SwiftUI

/// Lists the club's registered shooters from the website with a checkbox each.
/// Ticked shooters are the people shooting. A new shooter needs a valid email
/// address and is uploaded to the club's roster as a guest.
struct RosterView: View {
    @Bindable var vm: ShootViewModel
    var settings: ClayShootsSettings
    @Environment(\.dismiss) private var dismiss

    @State private var roster: [RosterShooter] = RosterView.cached()
    @State private var ticked: Set<Int> = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var newName = ""
    @State private var newEmail = ""
    @State private var isAdding = false
    @State private var newIsMember = false
    @State private var newIsAdmin = false
    @State private var newSignedGuestBook = false

    private static let cacheKey = "rosterCache"

    private static func cached() -> [RosterShooter] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([RosterShooter].self, from: data)) ?? []
    }

    /// A basic well-formedness check: one @, something either side, and a dotted domain.
    static func isValidEmail(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(of: #"^[^@\s,;<>"]+@[^@\s,;<>"]+\.[^@\s,;<>"]{2,}$"#, options: .regularExpression) != nil
    }

    private var canAdd: Bool {
        !ClayShootsNameCleaner.clean(newName).isEmpty && (newEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? !newIsMember : Self.isValidEmail(newEmail)) && !isAdding
    }

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if ticked.count < ShootViewModel.minimumShooters {
                    Label("At least \(ShootViewModel.minimumShooters) shooters are needed to start a shoot (\(ticked.count) selected).",
                          systemImage: "person.2.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Section("Shoot setup") {
                    Picker("Number of stands", selection: $vm.numberOfStands) {
                        ForEach(ShootViewModel.standOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .disabled(vm.isStarted)
                    Toggle("Enthusiastic feedback", isOn: $vm.isEnthusiastic)
                    Toggle("Handicap shoot", isOn: $vm.isHandicapShoot)
                        .disabled(vm.isStarted)
                    if vm.isHandicapShoot {
                        Picker("Average taken over", selection: $vm.handicapPeriod) {
                            ForEach(HandicapPeriod.allCases) { Text($0.title).tag($0) }
                        }
                        .disabled(vm.isStarted)
                        Text("Each shooter's total starts at minus their average score per stand over the chosen period, times the number of stands.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Registered shooters") {
                    if roster.isEmpty {
                        Text(isLoading ? "Loading…" : "No registered shooters yet. Add one below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(roster) { entry in
                        Button {
                            if ticked.contains(entry.id) { ticked.remove(entry.id) } else { ticked.insert(entry.id) }
                        } label: {
                            HStack {
                                Image(systemName: ticked.contains(entry.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(ticked.contains(entry.id) ? Color.accentColor : .secondary)
                                Text(entry.name)
                                    .foregroundStyle(entry.isGuest ? .red : .green)
                                    .fontWeight(.semibold)
                                Spacer()
                                Image(systemName: entry.verified == true ? "checkmark.seal.fill" : "envelope.badge")
                                    .foregroundStyle(entry.verified == true ? .green : .secondary)
                                    .accessibilityLabel(entry.verified == true ? "Email verified" : "Email not verified")
                                if entry.isAdmin == true {
                                    Text("Admin")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                        .background(Color.blue, in: .capsule)
                                        .foregroundStyle(.white)
                                }
                                Text(entry.isGuest ? "Guest" : "Member")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(entry.isGuest ? Color.red : Color.green, in: .capsule)
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("New shooter") {
                    TextField("Name", text: $newName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    TextField(newIsMember ? "Email address" : "Email address (optional)", text: $newEmail)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                    Picker("Type", selection: $newIsMember) {
                        Text("Guest").tag(false)
                        Text("Member").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if newIsMember {
                        Toggle("Admin", isOn: $newIsAdmin)
                    } else {
                        Toggle("Has signed the guest book", isOn: $newSignedGuestBook)
                    }
                    if !newEmail.isEmpty, !Self.isValidEmail(newEmail) {
                        Text("Enter a valid email address.").font(.footnote).foregroundStyle(.red)
                    }
                    Button {
                        Task { await addNew() }
                    } label: {
                        Label("Add new shooter", systemImage: "person.badge.plus")
                    }
                    .disabled(!canAdd)
                }
            }
            .navigationTitle("Who is shooting?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Shoot") {
                        vm.applyRoster(roster.filter { ticked.contains($0.id) })
                        dismiss()
                        Task { await vm.beginShoot(client: settings.client) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(ticked.count < ShootViewModel.minimumShooters)
                }
            }
            .refreshable { await load() }
            .task {
                ticked = Set(roster.filter { entry in
                    vm.shooters.contains { $0.name.lowercased() == entry.name.lowercased() }
                }.map(\.id))
                await load()
                // Follow website changes while the list is open.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    await load()
                }
            }
        }
    }

    private func load() async {
        guard let client = settings.client else {
            message = "Add the server in Server Settings to load the membership."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            roster = try await client.fetchRoster()
            message = nil
            RosterCache.store(roster)
            // Keep ticks only for people who are still listed.
            ticked = ticked.intersection(Set(roster.map(\.id)))
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func addNew() async {
        guard let client = settings.client else {
            message = "Add the server in Server Settings first."
            return
        }
        isAdding = true
        defer { isAdding = false }
        do {
            let saved = try await client.addRosterShooter(
                name: ClayShootsNameCleaner.clean(newName),
                email: newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                isMember: newIsMember, isAdmin: newIsAdmin, signedGuestBook: newSignedGuestBook)
            if !roster.contains(where: { $0.id == saved.id }) {
                roster.append(saved)
                roster.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            ticked.insert(saved.id)
            newName = ""
            newEmail = ""
            newIsAdmin = false
            newSignedGuestBook = false
            message = nil
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

enum RosterCache {
    static let key = "rosterCache"
    static func store(_ roster: [RosterShooter]) {
        if let data = try? JSONEncoder().encode(roster) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum ClayShootsNameCleaner {
    static func clean(_ raw: String) -> String {
        ShootViewModel.cleanedName(raw).capitalized
    }
}
