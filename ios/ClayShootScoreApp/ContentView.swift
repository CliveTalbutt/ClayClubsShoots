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
    @State private var isConfirmingComplete = false
    @State private var isConfirmingNewShoot = false
    @State private var isShowingSettings = false
    @State private var isShowingRoster = false
    /// True only when the roster opened by itself at startup; one the user opened stays until they leave it.
    @State private var rosterOpenedAutomatically = false
    /// A shoot another device has started, offered on the home screen while this device has none.
    @State private var availableShoot: RemoteShoot?
    @State private var pastShoots: [PastShoot] = []
    @State private var selectedPastShoot: PastShoot?
    @State private var serverSettings = ClayShootsSettings()
    @State private var lastLocalEdit = Date.distantPast

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

                if vm.shooters.isEmpty, !vm.isAddingShooter {
                    homeView
                        .transition(.opacity)
                } else {
                    scoreTable
                }

                if vm.isFinished {
                    podiumView
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                statusBar

                if vm.isFinished {
                    newShootButton
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if vm.isManualMode, !vm.shooters.isEmpty, !vm.isAddingShooter {
                    manualButtons
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, isCompact ? 12 : 20)
            .padding(.vertical, isCompact ? 8 : 20)
            .animation(.snappy, value: vm.isAddingShooter)
            .animation(.snappy, value: vm.isFinished)
            .animation(.snappy, value: vm.isManualMode)
            .animation(.snappy, value: vm.shooters.isEmpty)
            .overlay(alignment: .center) {
                if let summary = vm.standSummary {
                    // A timed card goes away on a tap anywhere; the tap is swallowed here so it
                    // never reaches the Hit/Miss buttons or the table underneath.
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { if summary.possible != nil { vm.standSummary = nil } else { vm.dismissStandSummary() } }
                    standSummaryCard(summary)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .task(id: summary.id) {
                            try? await Task.sleep(for: .seconds(summary.possible != nil ? 2 : ShootViewModel.summaryDuration))
                            guard !Task.isCancelled, vm.standSummary?.id == summary.id else { return }
                            if summary.possible != nil { vm.standSummary = nil } else { vm.dismissStandSummary() }
                        }
                }
            }
            .animation(.snappy, value: vm.standSummary)
            .onAppear {
                serverSettings.importPendingConfig()
                isScoreTableFocused = true
                vm.setVoiceAllowed(onScoreScreen)
                // A new shoot starts at "Who is shooting?"; a resumed one shows its shooters and scores.
                // If the club already has a shoot running, go straight to it instead.
                Task { await openCurrentShootOrRoster() }
                // Listening is always on: start as soon as the app is showing.
                vm.resumeListening()
            }
            // Once names have been entered, hand focus back so scoring keys work.
            .task(id: liveSignature) {
                lastLocalEdit = .now
                await syncLive()
            }
            .task { await followRoster() }
            .task(id: "\(serverSettings.serverURL)|\(serverSettings.apiKey)|\(scenePhase == .active)") { await followCurrentShoot() }
            .task { await flushOutbox() }
            .onChange(of: onScoreScreen) { _, onScreen in vm.setVoiceAllowed(onScreen) }
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
                    serverSettings.importPendingConfig()
                    vm.resumeListening()
                    Task { await flushOutbox() }
                default:
                    break
                }
            }
            .onChange(of: vm.isFinished) { _, finished in
                if finished { vm.announceFinalResults() }
            }
            .onChange(of: vm.snapshotSignature) { _, _ in
                vm.saveSnapshot()
                vm.evaluateStandCompletion()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    vm.evaluateStandCompletion()
                }
            }
            #if os(macOS)
            .frame(minWidth: 900, minHeight: 500)
            #endif
            .background(backgroundGradient.ignoresSafeArea())
            // On iPhone the header card already shows the editable shoot name, so
            // the navigation bar is left without a title to save vertical space.
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .confirmationDialog("Start a new shoot?", isPresented: $isConfirmingNewShoot, titleVisibility: .visible) {
                if !vm.shooters.isEmpty {
                    Button("Submit results, then new shoot") { completeShoot(); vm.startNewShoot(); showRosterSoon() }
                }
                Button(vm.shooters.isEmpty ? "New shoot" : "Discard this shoot and start new", role: vm.shooters.isEmpty ? nil : .destructive) {
                    vm.startNewShoot()
                    showRosterSoon()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(vm.shooters.isEmpty ? "Choose who is shooting." : "Submitting counts any unscored targets as misses. Discarding clears the scoresheet; anything already synced stays on the server as an unfinished shoot.")
            }
            .confirmationDialog("Complete this shoot?", isPresented: $isConfirmingComplete, titleVisibility: .visible) {
                Button("Complete and submit results") { completeShoot() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Any targets not yet scored count as misses. The results are sent to the server and a new shoot is started.")
            }
            .toolbar {
                compactControlPanel
            }
            // On iPhone the help button lives inside the overflow menu, where a
            // popover has nothing to anchor to, so the help is shown as a sheet.
            .sheet(isPresented: isShowingCompactHelp) {
                VoiceCommandsHelpView()
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $selectedPastShoot) { shoot in
            PastShootView(shoot: shoot, settings: serverSettings)
        }
        .sheet(isPresented: $isShowingRoster, onDismiss: { rosterOpenedAutomatically = false }) {
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
        // Its own item, so it stays visible on the bar instead of folding into the "…" menu.
        if !vm.isManualMode {
            ToolbarItem(placement: .topBarTrailing) {
                listenButton
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarItemGroup {
            rosterButton
            addShootersButton
            startShootButton
            modeButton
            listenButton
            announcementsMenu
            serverSettingsButton
        }

        ToolbarSpacer(.fixed)

        ToolbarItem { newShootToolbarButton.help("Start a new shoot") }

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
            startShootButton
            modeButton
            announcementsMenu
            serverSettingsButton
            Button {
                isShowingHelp = true
            } label: {
                Label("Voice Commands", systemImage: "questionmark.circle")
            }
            newShootToolbarButton
            completeShootButton
        }
    }

    /// Waits for the confirmation dialog to finish dismissing before presenting the sheet.
    private func showRosterSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            rosterOpenedAutomatically = false
            isShowingRoster = true
        }
    }

    private var newShootToolbarButton: some View {
        Button {
            isConfirmingNewShoot = true
        } label: {
            Label("New Shoot", systemImage: "plus.circle")
        }
    }

    private var completeShootButton: some View {
        Button {
            isConfirmingComplete = true
        } label: {
            Label("Complete Shoot", systemImage: "flag.checkered")
        }
        .disabled(vm.shooters.isEmpty)
    }

    /// Closes the shoot as if every target had been scored (unscored targets count as
    /// misses), queues the final results for the server and leaves the final results on screen,
    /// with scoring locked, until New Shoot is pressed.
    private func completeShoot() {
        vm.finishShoot()
        queueFinalResults()
        exportMessage = "Shoot completed: submitting results…"
    }

    private func queueFinalResults() {
        guard let upload = vm.makeUpload(externalId: vm.shootSessionId, forceComplete: true),
              let body = try? JSONEncoder().encode(upload) else { return }
        UploadOutbox.save(id: upload.externalId, body: body)
        Task { await flushOutbox() }
    }

    /// Shown once every shooter has finished: makes sure the final results are queued,
    /// clears the sheet and opens "Who is shooting?" for the next shoot.
    /// Voice recognition only runs on the scoresheet, not on the home screen or any sheet over it.
    private var onScoreScreen: Bool {
        (!vm.shooters.isEmpty || vm.isAddingShooter)
            && !isShowingRoster && !isShowingSettings && selectedPastShoot == nil
    }

    private var scoreTable: some View {
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
    }

    /// Shown when there is no shoot on the scoresheet, for example after a shoot is finished.
    private var homeView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "scope")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text(vm.venue.isEmpty ? "Clay Shoots" : vm.venue)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Ready for the next shoot")
                .foregroundStyle(.secondary)
            if let shoot = availableShoot {
                Text("A shoot is in progress: \(shoot.name)")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button {
                    joinAvailableShoot()
                } label: {
                    Label("Join Current Shoot", systemImage: "person.2.fill")
                        .font(.headline)
                        .frame(maxWidth: 360)
                        .frame(height: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button {
                    rosterOpenedAutomatically = false
                    isShowingRoster = true
                } label: {
                    Label("New Shoot", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: 360)
                        .frame(height: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            Menu {
                if pastShoots.isEmpty {
                    Text("No previous shoots yet")
                }
                ForEach(pastShoots) { shoot in
                    Button(shoot.title) { selectedPastShoot = shoot }
                }
            } label: {
                Label("Previous shoots", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: 360)
            }
            .buttonStyle(.bordered)
            .task { await loadPastShoots() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }

    private var newShootButton: some View {
        Button {
            queueFinalResults()
            vm.startNewShoot()
            rosterOpenedAutomatically = false
            isShowingRoster = true
        } label: {
            Label("New Shoot", systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: isCompact ? 60 : 80)
        }
        .buttonStyle(.borderedProminent)
    }

    private var modeButton: some View {
        Button {
            vm.isManualMode.toggle()
        } label: {
            Label(vm.isManualMode ? "Voice" : "Manual",
                  systemImage: vm.isManualMode ? "waveform" : "hand.tap.fill")
        }
        .help(vm.isManualMode ? "Manual scoring is on. Tap to switch to voice" : "Voice scoring is on. Tap to switch to manual buttons")
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
            rosterOpenedAutomatically = false
            isShowingRoster = true
        } label: {
            Label("Membership", systemImage: "person.3.fill")
        }
        .help("Choose who is shooting from the club's registered shooters")
        .disabled(vm.isComplete || vm.isStarted)
    }

    private var addShootersButton: some View {
        Button {
            vm.startAddingShooter()
        } label: {
            Label("Add Shooters", systemImage: "person.badge.plus")
        }
        .help("Add shooters by saying their names")
        .disabled(vm.isAddingShooter || vm.isComplete || vm.isFull || vm.isStarted)
    }

    /// Shown once shooters are chosen and until the shoot begins; after it nothing about the shooters changes.
    @ViewBuilder private var startShootButton: some View {
        if !vm.isStarted, !vm.shooters.isEmpty, !vm.hasMinimumShooters {
            Label("Add at least \(ShootViewModel.minimumShooters) shooters to start (\(vm.shooters.count) so far)",
                  systemImage: "person.2.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        if !vm.isStarted, !vm.shooters.isEmpty {
            Button {
                Task { await vm.beginShoot(client: serverSettings.client) }
            } label: {
                Label("Start Shoot", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(!vm.hasMinimumShooters)
        }
    }

    /// Shows that the app is always listening. The microphone bounces every time
    /// words are heard and lights up while someone is speaking. If listening has
    /// stopped because of a problem, tapping it tries again straight away.
    /// Spoken feedback style and the "Possible" call, changeable at any time during the shoot.
    private var announcementsMenu: some View {
        Menu {
            Picker("Spoken feedback", selection: $vm.feedbackStyle) {
                ForEach(ShootViewModel.FeedbackStyle.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Announce “Possible” score", isOn: $vm.announcePossibleScore)
        } label: {
            Label("Announcements", systemImage: "speaker.wave.2")
        }
        .help("Spoken feedback and the Possible score call")
    }

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
        .labelStyle(.iconOnly)
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
        guard serverSettings.client != nil, vm.isStarted,
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
            if serverSettings.client != nil, UploadOutbox.count > 0 { await flushOutbox() }
            return
        }
        guard let upload = vm.makeUpload(externalId: vm.shootSessionId),
              let body = try? JSONEncoder().encode(upload) else { return }
        UploadOutbox.save(id: upload.externalId, body: body)
        try? await Task.sleep(for: .milliseconds(100))
        await flushOutbox()
    }

    /// Keeps this device on the club's current shoot: loads it at startup and every few seconds
    /// brings in the stands other devices have scored. If the shoot was finished elsewhere this
    /// device starts afresh, and a blank scoresheet picks up the shoot another device started.
    private func followCurrentShoot() async {
        while !Task.isCancelled {
            if scenePhase == .active, let client = serverSettings.client {
                await refreshCurrentShoot(client)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func loadPastShoots() async {
        guard let client = serverSettings.client, let list = try? await client.shootHistory() else { return }
        pastShoots = list
    }

    /// At launch: if another device has a shoot running, the home screen offers to join it;
    /// otherwise a blank device starts at the roster.
    private func openCurrentShootOrRoster() async {
        if let client = serverSettings.client,
           let reply = try? await client.currentShoot(externalId: vm.shootSessionId),
           let current = reply.current {
            if !vm.isStarted { availableShoot = current }
            let unsent = UploadOutbox.pending.contains { $0.id == vm.shootSessionId }
            if vm.isStarted, current.externalId != vm.shootSessionId, !unsent {
                vm.adoptRemote(current)
                exportMessage = "Joined the club's current shoot: \(current.name)."
            }
        } else if vm.shooters.isEmpty {
            rosterOpenedAutomatically = true
            isShowingRoster = true
        }
    }

    private func joinAvailableShoot() {
        guard let shoot = availableShoot else { return }
        isShowingRoster = false
        vm.isAddingShooter = false
        vm.adoptRemote(shoot)
        availableShoot = nil
        exportMessage = "Joined the club's current shoot: \(shoot.name)."
    }

    private func refreshCurrentShoot(_ client: ClayShootsClient) async {
        guard let reply = try? await client.currentShoot(externalId: vm.shootSessionId), !Task.isCancelled else { return }
        // Only unsent changes to the shoot on screen hold the device back; a stale entry for some
        // other shoot must never stop it joining the club's current one.
        let unsent = UploadOutbox.pending.contains { $0.id == vm.shootSessionId }
        // A roster opened with nothing chosen yet gives way to a shoot another device has started.
        // Once any device has started a shoot, this one stops setting up and shows it.
        availableShoot = vm.isStarted ? nil : reply.current
        if availableShoot != nil {
            isShowingRoster = false
            vm.isAddingShooter = false
        }
        // Another device completed this shoot: show the final results here too, locked.
        if let mine = reply.requested, mine.complete, !vm.isFinished, !unsent, vm.isStarted {
            vm.finishShoot()
        }
        // The server has lost the shoot being scored here (e.g. it was deleted): send it again.
        if vm.isStarted, !vm.isFinished, reply.requested == nil, !unsent,
           let upload = vm.makeUpload(externalId: vm.shootSessionId),
           let body = try? JSONEncoder().encode(upload) {
            UploadOutbox.save(id: upload.externalId, body: body)
            await flushOutbox()
            return
        }
        guard let current = reply.current else { return }
        if current.externalId == vm.shootSessionId, vm.isStarted {
            let idle = Date.now.timeIntervalSince(lastLocalEdit) > 3
            vm.mergeRemote(current, includeOwned: !unsent && idle)
        } else if vm.isStarted, !unsent, current.externalId != vm.shootSessionId {
            // The club has one current shoot (the newest active one) and every started device shows it.
            vm.adoptRemote(current)
            exportMessage = "Joined the club's current shoot: \(current.name)."
        }
    }

    /// Sends everything waiting in the outbox, retrying until the server
    /// answers. Each entry is the latest full scoresheet for a shoot, so a
    /// later change simply replaces an unsent one and nothing is lost.
    private func flushOutbox() async {
        var delay = 2
        while !Task.isCancelled, let client = serverSettings.client, UploadOutbox.count > 0 {
            var failed = false
            for item in UploadOutbox.pending {
                if Task.isCancelled { return }
                do {
                    _ = try await client.send(body: item.body)
                    UploadOutbox.clear(id: item.id, ifBody: item.body)
                    exportMessage = "Live: synced at \(Date.now.formatted(.dateTime.hour().minute().second()))"
                } catch ClayShootsError.invalidKey {
                    exportMessage = "Live upload stopped: the API key was rejected. Scores are kept on this phone."
                    return
                } catch ClayShootsError.subscriptionRequired {
                    exportMessage = "Live upload stopped: the account needs a subscription. Scores are kept on this phone."
                    return
                } catch ClayShootsError.validation(let details) {
                    exportMessage = "Live upload rejected: " + details.joined(separator: ", ")
                    UploadOutbox.clear(id: item.id, ifBody: item.body)
                } catch {
                    if Task.isCancelled { return }
                    failed = true
                    exportMessage = "Server unreachable: \(UploadOutbox.count) update(s) saved on this phone, retrying…"
                    break
                }
            }
            if !failed { return }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 6)
        }
    }

    /// Part of setting up a shoot; it starts at the number used last time and is fixed once the shoot starts.
    private var standsSetupMenu: some View {
        Picker("Stands", selection: $vm.numberOfStands) {
            ForEach(ShootViewModel.standOptions, id: \.self) { count in
                Text("\(count)").tag(count)
            }
        }
        .pickerStyle(.menu)
        .disabled(vm.isStarted)
    }

    // MARK: - Header

    /// The shoot name (edited in place) and today's date. On iPhone these live in
    /// the toolbar beside the buttons instead, so nothing is shown here.
    @ViewBuilder
    private var headerCard: some View {
        EmptyView()
    }

    private var shootNameAndDate: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Shoot name", text: $vm.shootName)
                .textFieldStyle(.plain)
                .font(.headline)
                .help("Click to edit the shoot name")

            DatePicker("Date", selection: $vm.shootStart, displayedComponents: [.date])
                .labelsHidden()
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func standSummaryCard(_ summary: ShootViewModel.StandSummary) -> some View {
        VStack(spacing: 6) {
            Text("\(summary.shooter) — Stand \(summary.stand)")
                .font(.headline)
            if let possible = summary.possible {
                Text("Possible \(possible)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                Text("if the final pair is hit (\(summary.score) so far)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
            Text("\(summary.score) / \(summary.total)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.green)
            if !summary.next.isEmpty {
                Text(summary.next)
                    .font(.title3.weight(.semibold))
            }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green, lineWidth: 1))
        .shadow(radius: 12)
        .onTapGesture { if summary.possible != nil { vm.standSummary = nil } else { vm.dismissStandSummary() } }
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
                        standsSetupMenu
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
                    standsSetupMenu
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
        Button("Start Shoot") {
            if vm.shooters.isEmpty { vm.finishAddingShooters() } else { Task { await vm.beginShoot(client: serverSettings.client) } }
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .disabled(!vm.shooters.isEmpty && !vm.hasMinimumShooters)
        .keyboardShortcut(.cancelAction)
    }

    private var addShooterCount: some View {
        Text(vm.hasMinimumShooters
             ? "\(vm.shooters.count) of \(ShootViewModel.maxShooters)"
             : "\(vm.shooters.count) of \(ShootViewModel.maxShooters) · min \(ShootViewModel.minimumShooters)")
            .font(.footnote)
            .foregroundStyle(vm.hasMinimumShooters ? Color.secondary : Color.orange)
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
                        Text(vm.totalText(entry.shooter))
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
                SyncStatusLabel(text: exportMessage)
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


/// The sync status line. On each change it lights up in the same yellow as the score flash and then
/// fades smoothly back to its normal grey, as a single highlight.
private struct SyncStatusLabel: View {
    let text: String
    @State private var lit = false

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(lit ? Color.yellow : Color.secondary)
            .onChange(of: text) { _, _ in
                lit = true
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.easeOut(duration: 0.9)) { lit = false }
                }
            }
    }
}
