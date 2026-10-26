//
//  SendToServerView.swift
//
//  Sheet for configuring the Clay Shoots server address and API key.
//

import SwiftUI

struct SendToServerView: View {
    @Bindable var settings: ClayShootsSettings
    @Bindable var vm: ShootViewModel

    @State private var status: String?
    @State private var statusIsError = false
    @State private var isBusy = false
    @State private var clubs: [ClayShootsClient.MemberClub] = []
    @State private var selectedClub: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://192.168.1.100:3000", text: $settings.serverURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    SecureField("API key", text: $settings.apiKey)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Server key fingerprint (self-signed servers)", text: $settings.pinnedFingerprint)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Toggle("Testing: trust self-signed certificate", isOn: $settings.trustSelfSigned)
                } header: {
                    Text("Clay Shoots server")
                } footer: {
                    Text("Only encrypted (https) connections are used. Create the key on the website's Dashboard under API key. If the server uses its own certificate, paste the fingerprint it prints when it starts: the app then trusts only that server and refuses any impostor. The testing switch skips that check so a self-signed server works with no fingerprint; the connection is still encrypted but the server is not verified, so turn it off for real use.")
                }

                Section {
                    TextField("Your email address", text: $settings.memberEmail)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        #endif
                    Button("Find my clubs") { Task { await findClubs() } }
                        .disabled(settings.lookupClient == nil || settings.memberEmail.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                    if !clubs.isEmpty {
                        Picker("Club", selection: $selectedClub) {
                            Text("Choose a club").tag(Int?.none)
                            ForEach(clubs) { club in Text(club.name).tag(Int?.some(club.id)) }
                        }
                        .onChange(of: selectedClub) { _, id in
                            if let id { Task { await connect(to: id) } }
                        }
                    }
                    if !settings.clubName.isEmpty {
                        LabeledContent("Connected to", value: settings.clubName)
                    }
                } header: {
                    Text("My clubs")
                } footer: {
                    Text("Testing only: clubs are found from your email address alone, so anyone who knows a member's email could do this. Choosing a club connects this phone to it automatically.")
                }

                Section {
                    Picker("Number of stands", selection: $vm.numberOfStands) {
                        ForEach(ShootViewModel.standOptions, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                } header: {
                    Text("Shoot setup")
                } footer: {
                    Text("1 to 25. Remembered for \(vm.shootName).")
                }

                Section {
                    Button("Test Connection") { Task { await test() } }
                        .disabled(settings.client == nil || isBusy)
                }

                if let status {
                    Section {
                        Text(status).foregroundStyle(statusIsError ? .red : .green)
                    }
                }
            }
            .navigationTitle("Server Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay { if isBusy { ProgressView() } }
        }
    }

    private func findClubs() async {
        guard let client = settings.lookupClient else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let email = settings.memberEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            clubs = try await client.lookupClubs(email: email)
            selectedClub = nil
            status = clubs.isEmpty ? "No clubs list that email as a current member." : nil
            statusIsError = true
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    private func connect(to id: Int) async {
        guard let client = settings.lookupClient else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let email = settings.memberEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await client.connectClub(email: email, id: id)
            settings.apiKey = result.apiKey
            settings.clubName = result.club
            status = "Connected to \(result.club)."
            statusIsError = false
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }

    private func test() async {
        guard let client = settings.client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let club = try await client.checkConnection()
            status = "Connected to \(club)."
            statusIsError = false
        } catch {
            status = error.localizedDescription
            statusIsError = true
        }
    }
}
