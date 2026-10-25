//
//  ContentView.swift
//  MyApp
//
//  Created by Clive Talbutt on 23/10/2026.
//


import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var vm = ShootViewModel()

    @State private var exportMessage: String?
    @State private var isShowingHelp = false
    @State private var isShowingSettings = false
    @State private var isShowingRoster = false
    @State private var serverSettings = ClayShootsSettings()

    /// Keyboard focus sits on the score table so the Y and X keys score the
    /// current target without a text field swallowing them.
    @FocusState private var isScoreTableFocused: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// True on iPhone-sized screens in either orientation. Fonts, spacing and the
    /// toolbar are reduced so the controls do not crowd out the score table.
    private var isCompact: Bool {
        horizontalSizeClass == .compact || verticalSizeClass == .compact
    }

    /// True on an iPhone held upright, where the width is too narrow for the
    /// header and add-shooter sections to fit on one line. In landscape the
    /// screen is wide but short, so those sections go back to a single row.
    private var isNarrow: Bool {
        horizontalSizeClass == .compact && verticalSizeClass != .compact
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: isCompact ? 8 : 16) {
                headerCard

                if vm.isAddingShooter {
                    addShooterBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ScoreTableView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.secondary, in: .rect(cornerRadius: 16))
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isScoreTableFocused)
                    // Y scores a hit and X a miss on the current target. Both
                    // upper and lower case are accepted.
                    .onKeyPress(characters: CharacterSet(charactersIn: "yYxX"), phases: .down) { press in
                        switch press.characters.lowercased() {
                        case "y":
                            vm.recordHit()
                        case "x":
                            vm.recordMiss()
                        default:
                            return .ignored
                        }
                        return .handled
                    }
                    // Tapping anywhere on the table brings keyboard focus back to
                    // it after typing in the shoot name or a shooter's name.
                    .simultaneousGesture(TapGesture().onEnded { isScoreTableFocused = true })

                if vm.isComplete {
                    podiumView
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                statusBar

                if vm.isManualMode, !vm.shooters.isEmpty, !vm.isAddingShooter, !vm.isComplete {
                    manualButtons
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !vm.isManualMode, !vm.shooters.isEmpty, !vm.isAddingShooter, !vm.isComplete {
                    listeningPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, isCompact ? 12 : 20)
            .padding(.vertical, isCompact ? 8 : 20)
            .animation(.snappy, value: vm.isAddingShooter)
            .animation(.snappy, value: vm.isComplete)
            .animation(.snappy, value: vm.isManualMode)
            .animation(.snappy, value: vm.shooters.isEmpty)
            .onAppear {
                isScoreTableFocused = true
                // A new shoot starts at "Who is shooting?"; a resumed one shows its shooters and scores.
                if vm.shooters.isEmpty { isShowingRoster = true }
                // Listening is always on: start as soon as the app is showing.
                vm.resumeListening()
            }
            // Once names have been entered, hand focus back so scoring keys work.
            .task(id: liveSignature) { await syncLive() }
            .task { await followRoster() }
            .onChange(of: vm.isAddingShooter) { _, isAdding in
                if !isAdding { isScoreTableFocused = true }
            }
            // Release the microphone whenever the app leaves the foreground so
            // Siri, dictation and other apps are never left without it, and take
            // it back as soon as the app returns.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    vm.saveSnapshot()
                    vm.stopListeningForBackground()
                case .active:
                    vm.resumeListening()
                default:
                    break
                }
            }
            .onChange(of: vm.snapshotSignature) { _, _ in vm.saveSnapshot() }
            #if os(macOS)
            .frame(minWidth: 900, minHeight: 500)
            #endif
            .background(backgroundGradient.ignoresSafeArea())
            // On iPhone the header card already shows the editable shoot name, so
            // the navigation bar is left without a title to save vertical space.
            .navigationTitle(isCompact ? "" : vm.title)
            .toolbarTitleDisplayMode(isCompact ? .inline : .automatic)
            .toolbar {
                if isCompact {
                    compactControlPanel
                } else {
                    controlPanel
                }
            }
            // On iPhone the help button lives inside the overflow menu, where a
            // popover has nothing to anchor to, so the help is shown as a sheet.
            .sheet(isPresented: isShowingCompactHelp) {
                VoiceCommandsHelpView()
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $isShowingRoster) {
            RosterView(vm: vm, settings: serverSettings)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $isShowingSettings) {
            SendToServerView(settings: serverSettings, vm: vm)
                .presentationDetents([.medium, .large])
        }
    }

    /// The help sheet binding, which only ever reads true on compact screens so
    /// that the Mac popover and the iPhone sheet never show at the same time.
    private var isShowingCompactHelp: Binding<Bool> {
        Binding(
            get: { isCompact && isShowingHelp },
            set: { isShowingHelp = $0 }
        )
    }

    // MARK: - Control panel

    /// The Mac toolbar holds every control: adding shooters, listening, exporting
    /// and a dropdown for the number of stands in the shoot.
    @ToolbarContentBuilder
    private var controlPanel: some ToolbarContent {
        ToolbarItemGroup {
            rosterButton
            addShootersButton
            modeButton
            listenButton
            serverSettingsButton
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            Menu {
                standsPicker
            } label: {
                Label("^[\(vm.numberOfStands) Stand](inflect: true)", systemImage: "square.grid.3x3")
                    .labelStyle(.titleAndIcon)
            }
            .help("Choose how many stands are in the shoot")
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            Button {
                isShowingHelp.toggle()
            } label: {
                Label("Voice Commands", systemImage: "questionmark.circle")
            }
            .help("Show the voice commands you can say")
            .popover(isPresented: $isShowingHelp, arrowEdge: .bottom) {
                VoiceCommandsHelpView()
            }
        }
    }

    /// The iPhone toolbar keeps the two buttons used during a shoot visible and
    /// shows the rest as icon buttons, so nothing is squeezed off.
    @ToolbarContentBuilder
    private var compactControlPanel: some ToolbarContent {
        // The shoot name and date sit on the same line as the buttons, so no
        // separate header is needed above the score table.
        ToolbarItem(placement: .navigation) {
            shootNameAndDate
                .frame(width: isNarrow ? 190 : 280, alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItemGroup {
            rosterButton
            addShootersButton
            modeButton
            serverSettingsButton
            Menu {
                standsPicker
            } label: {
                Label("Stands: \(vm.numberOfStands)", systemImage: "square.grid.3x3")
            }
            Button {
                isShowingHelp = true
            } label: {
                Label("Voice Commands", systemImage: "questionmark.circle")
            }
        }
    }

    private var modeButton: some View {
        Button {
            vm.isManualMode.toggle()
        } label: {
            Label(vm.isManualMode ? "Manual" : "Voice",
                  systemImage: vm.isManualMode ? "hand.tap.fill" : "waveform")
        }
        .help(vm.isManualMode ? "Manual scoring: hold the green or red button. Tap for voice" : "Voice scoring. Tap for manual buttons")
    }

    /// Voice mode's counterpart to the HIT/MISS buttons: a large microphone that pulses as sounds are heard.
    private var listeningPanel: some View {
        Button {
            vm.resumeListening()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: vm.isListening ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: isCompact ? 44 : 56))
                    .symbolEffect(.bounce, value: vm.heardWordCount)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(vm.isHearingSpeech ? 1.15 : 1)
                Text(vm.isListening ? (vm.isHearingSpeech ? "Hearing you…" : "Listening") : "Not listening. Tap to retry")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: isCompact ? 90 : 120)
            .background(micTint.gradient, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: vm.isHearingSpeech)
        .accessibilityLabel(vm.isListening ? "Listening for scores" : "Not listening. Tap to retry")
    }

    /// Large hold-to-score buttons shown at the bottom in manual mode.
    private var manualButtons: some View {
        HStack(spacing: 12) {
            HoldScoreButton(title: "HIT", color: .green, systemImage: "checkmark") { vm.recordHit() }
            HoldScoreButton(title: "MISS", color: .red, systemImage: "xmark") { vm.recordMiss() }
        }
        .frame(height: isCompact ? 90 : 120)
    }

    /// Keeps the shoot in step with membership changes made on the website.
    private func followRoster() async {
        while !Task.isCancelled {
            if scenePhase == .active, let client = serverSettings.client,
               let roster = try? await client.fetchRoster() {
                vm.syncRoster(roster)
                RosterCache.store(roster)
            }
            try? await Task.sleep(for: .seconds(8))
        }
    }

    private var rosterButton: some View {
        Button {
            isShowingRoster = true
        } label: {
            Label("Membership", systemImage: "person.3.fill")
        }
        .help("Choose who is shooting from the club's registered shooters")
        .disabled(vm.isComplete)
    }

    private var addShootersButton: some View {
        Button {
            vm.startAddingShooter()
        } label: {
            Label("Add Shooters", systemImage: "person.badge.plus")
        }
        .help("Add shooters by saying their names")
        .disabled(vm.isAddingShooter || vm.isComplete || vm.isFull)
    }

    /// Shows that the app is always listening. The microphone bounces every time
    /// words are heard and lights up while someone is speaking. If listening has
    /// stopped because of a problem, tapping it tries again straight away.
    private var listenButton: some View {
        Button {
            vm.resumeListening()
        } label: {
            Label(vm.isListening ? "Listening" : "Not Listening",
                  systemImage: vm.isListening ? "mic.fill" : "mic.slash.fill")
                .symbolEffect(.bounce, value: vm.heardWordCount)
                .contentTransition(.symbolEffect(.replace))
        }
        .help(vm.isListening ? "Listening for spoken scores and commands" : "Listening has stopped. Tap to try again")
        .buttonStyle(.glassProminent)
        .tint(micTint)
        .animation(.easeOut(duration: 0.2), value: vm.isHearingSpeech)
    }

    /// Green while words are being heard, the accent colour while idle but
    /// listening, and grey when listening has stopped.
    private var micTint: Color {
        if vm.isHearingSpeech { return .green }
        return vm.isListening ? .accentColor : .gray
    }

    private var serverSettingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Label("Server Settings", systemImage: "gearshape")
        }
    }

    /// Changes whenever anything that is uploaded changes, so the task below
    /// restarts (and so debounces) on every score, name or setting change.
    private var liveSignature: String {
        guard serverSettings.client != nil, vm.hasAnyScore,
              let upload = vm.makeUpload(externalId: vm.shootSessionId),
              let data = try? JSONEncoder().encode(upload) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Sends the current scoresheet to the server shortly after the last change,
    /// and retries if the connection fails. The server replaces the earlier
    /// version of the same shoot, and emails and posts only once it is complete.
    private func syncLive() async {
        guard !liveSignature.isEmpty else {
            exportMessage = serverSettings.client == nil ? "Live upload is off: add the server in Server Settings." : nil
            return
        }
        guard let client = serverSettings.client, let upload = vm.makeUpload(externalId: vm.shootSessionId) else { return }
        try? await Task.sleep(for: .seconds(2))
        var delay = 10
        while !Task.isCancelled {
            do {
                _ = try await client.send(upload)
                exportMessage = "Live: \(upload.complete ? "shoot complete and" : "scores") synced at \(Date.now.formatted(date: .omitted, time: .shortened))"
                return
            } catch ClayShootsError.invalidKey {
                exportMessage = "Live upload stopped: the API key was rejected."
                return
            } catch ClayShootsError.subscriptionRequired {
                exportMessage = "Live upload stopped: the account needs a subscription."
                return
            } catch ClayShootsError.validation(let details) {
                exportMessage = "Live upload rejected: " + details.joined(separator: ", ")
                return
            } catch {
                if Task.isCancelled { return }
                exportMessage = "Live upload failed, retrying…"
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
            }
        }
    }

    private var standsPicker: some View {
        Picker("Number of stands", selection: $vm.numberOfStands) {
            ForEach(ShootViewModel.standOptions, id: \.self) { count in
                Text("\(count)").tag(count)
            }
        }
    }

    // MARK: - Header

    /// The shoot name (edited in place) and today's date. On iPhone these live in
    /// the toolbar beside the buttons instead, so nothing is shown here.
    @ViewBuilder
    private var headerCard: some View {
        if !isCompact {
            shootNameAndDate
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    private var shootNameAndDate: some View {
        VStack(alignment: .leading, spacing: isCompact ? 0 : 4) {
            TextField("Shoot name", text: $vm.shootName)
                .textFieldStyle(.plain)
                .font(isCompact ? .headline : .largeTitle.bold())
                .help("Click to edit the shoot name")

            TextField("Venue", text: $vm.venue)
                .textFieldStyle(.plain)
                .font(isCompact ? .caption : .subheadline)
                .foregroundStyle(.secondary)

            DatePicker("Date", selection: $vm.shootStart, displayedComponents: [.date])
                .labelsHidden()
                .font(isCompact ? .caption2 : .subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Add shooters

    /// Shown while names are being collected: live transcript, an editable pending
    /// name and buttons to add it or finish. On an upright iPhone the prompt goes
    /// on one line and the name field and buttons on the next.
    private var addShooterBar: some View {
        Group {
            if isNarrow {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        addShooterMicIcon
                        addShooterPrompt
                            .font(.subheadline)
                        Spacer()
                        addShooterCount
                    }

                    HStack(spacing: 10) {
                        pendingNameField
                        addPendingButton
                        finishAddingButton
                    }
                }
            } else {
                HStack(spacing: 12) {
                    addShooterMicIcon
                    addShooterPrompt
                    pendingNameField
                        .frame(width: 240)
                    addPendingButton
                    finishAddingButton
                    Spacer()
                    addShooterCount
                }
            }
        }
        .padding(isCompact ? 10 : 14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private var addShooterMicIcon: some View {
        Image(systemName: "mic.fill")
            .foregroundStyle(vm.isHearingSpeech ? .green : .red)
            .symbolEffect(.pulse, isActive: vm.isListening)
            .symbolEffect(.bounce, value: vm.heardWordCount)
            .animation(.easeOut(duration: 0.2), value: vm.isHearingSpeech)
    }

    private var addShooterPrompt: some View {
        Text("Say each name, pausing between them…")
            .foregroundStyle(.secondary)
    }

    private var pendingNameField: some View {
        TextField("Shooter name", text: $vm.pendingShooterName)
            .textFieldStyle(.roundedBorder)
            .onSubmit { vm.confirmPendingShooter() }
    }

    private var addPendingButton: some View {
        Button("Add") {
            vm.confirmPendingShooter()
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.pendingShooterName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var finishAddingButton: some View {
        Button("Finish") {
            vm.finishAddingShooters()
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)
    }

    private var addShooterCount: some View {
        Text("\(vm.shooters.count) of \(ShootViewModel.maxShooters)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    // MARK: - Results

    private var podiumView: some View {
        VStack(spacing: 10) {
            Text("Final Results")
                .font(isCompact ? .headline : .title3.weight(.semibold))

            HStack(spacing: isCompact ? 12 : 40) {
                ForEach(vm.podium, id: \.shooter.id) { entry in
                    VStack(spacing: 2) {
                        Text(Placing.medal(entry.place) ?? "")
                            .font(.system(size: isCompact ? 28 : 40))
                        Text(Placing.ordinal(entry.place))
                            .font(.headline)
                        Text(entry.shooter.name.capitalized)
                            .lineLimit(isCompact ? 1 : nil)
                            .minimumScaleFactor(isCompact ? 0.8 : 1)
                        Text("\(entry.shooter.grandTotal)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // Share the width evenly on iPhone so three places always fit.
                    .frame(maxWidth: isCompact ? .infinity : nil)
                }
            }
        }
        .padding(.vertical, isCompact ? 10 : 16)
        .padding(.horizontal, isCompact ? 16 : 32)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 16))
    }

    // MARK: - Status

    /// The latest words heard and any error or export message, so the user can see
    /// what the recogniser understood.
    @ViewBuilder
    private var statusBar: some View {
        VStack(spacing: 4) {
            if !vm.transcript.isEmpty {
                Text("Heard: \(vm.transcript)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let error = vm.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if let exportMessage {
                Text(exportMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.08), Color.clear],
            startPoint: .top,
            endPoint: .center
        )
        .background(.background)
    }
}

#Preview {
    ContentView()
}
