//
//  ShootViewModel.swift
//  MyApp
//
//  Created by Clive Talbutt on 23/10/2026.
//


import Foundation
import Observation
import Speech
import AVFoundation
import AudioToolbox
import UIKit
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// What the microphone is currently being used for.
enum ListeningMode {
    /// Listening for "hit", "miss", "pair hit", "shooter <name>" and "clear …" commands.
    case scoring
    /// Listening for a list of new shooters' names after the Add Shooter button was pressed.
    case addingShooter
}

@Observable
class ShootViewModel {
    /// The number of stands a new shoot starts with.
    static let defaultNumberOfStands = 5
    /// The stand counts that can be chosen in the control panel.
    static let standOptions = Array(5...10)
    /// The number of targets shot on each stand.
    static let targetsPerStand = 10
    /// The most shooters a shoot can have.
    static let maxShooters = 20
    /// How long the speaker must pause between names before a name is added.
    static let nameGap: Duration = .milliseconds(1400)
    /// Name entry ends by itself after this long without any new speech.
    static let nameIdleLimit: Duration = .seconds(4)
    private var nameIdleTask: Task<Void, Never>?
    /// How long the speaker must pause after a "clear …" command before it is carried out.
    static let commandGap: Duration = .milliseconds(1200)
    /// How long newly heard scoring words are held so a phrase such as "pair hit"
    /// or "lost pair" arrives complete before it is scored.
    static let scoreGap: Duration = .milliseconds(500)
    /// How soon after a single score a lone "pair" still counts as the second half
    /// of that score ("hit … pair").
    static let pairFollowUpWindow: TimeInterval = 1.5

    private static let shootNameKey = "shootName"
    private static let numberOfStandsKey = "numberOfStands"
    private static let venueKey = "shootVenue"
    private static let startKey = "shootStart"
    private static let emailsKey = "shooterEmails"

    /// Email addresses by lowercased shooter name, remembered between shoots.
    private(set) var emails: [String: String] = (UserDefaults.standard.dictionary(forKey: "shooterEmails") as? [String: String]) ?? [:]

    /// "member" or "guest" by lowercased name, for shooters picked from the roster.
    var kinds: [String: String] = [:]

    func kind(for name: String) -> String? {
        kinds[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// Makes the shoot's shooters match the ticked roster entries. Anyone who has
    /// already scored stays, even if unticked, so no result is lost.
    func applyRoster(_ selected: [RosterShooter]) {
        let wanted = Set(selected.map { $0.name.lowercased() })
        for index in shooters.indices.reversed() {
            let shooter = shooters[index]
            let scored = shooter.scores.contains { $0.contains { $0 >= 0 } }
            if !wanted.contains(shooter.name.lowercased()), !scored, kinds[shooter.name.lowercased()] != nil {
                removeShooter(at: index)
            }
        }
        for entry in selected {
            kinds[entry.name.lowercased()] = entry.kind
            setEmail(entry.email, for: entry.name)
            if !shooters.contains(where: { $0.name.lowercased() == entry.name.lowercased() }) {
                addShooter(named: entry.name)
            }
        }
    }

    func email(for name: String) -> String? {
        let e = emails[name.trimmingCharacters(in: .whitespaces).lowercased()]
        return (e?.isEmpty ?? true) ? nil : e
    }

    /// Saves (or, when blank, removes) a shooter's email address.
    func setEmail(_ email: String, for name: String) {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { emails[key] = nil } else { emails[key] = value }
        UserDefaults.standard.set(emails, forKey: Self.emailsKey)
    }

    /// Rounds a date down to the previous half hour.
    static func halfHour(_ date: Date) -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        c.minute = (c.minute ?? 0) < 30 ? 0 : 30
        return cal.date(from: c) ?? date
    }

    /// When the shoot starts, to a 30 minute resolution. A saved value from an earlier
    /// day is replaced by the current half hour when the app starts.
    var shootStart: Date {
        didSet {
            let rounded = Self.halfHour(shootStart)
            if rounded != shootStart { shootStart = rounded; return }
            UserDefaults.standard.set(shootStart, forKey: Self.startKey)
        }
    }

    /// Where the shoot takes place; uploaded to the server with the results.
    var venue: String {
        didSet { UserDefaults.standard.set(venue, forKey: Self.venueKey) }
    }

    /// User-editable name of the shoot, shown in the heading alongside today's date.
    /// Saved to user defaults so it survives relaunching the app.
    var shootName: String {
        didSet { UserDefaults.standard.set(shootName, forKey: Self.shootNameKey) }
    }

    /// The number of stands in the shoot. Every shooter has this many rows of targets.
    /// Changing it keeps the scores already recorded on the stands that remain.
    /// Saved to user defaults so it survives relaunching the app.
    var numberOfStands: Int {
        didSet {
            guard numberOfStands != oldValue else { return }
            UserDefaults.standard.set(numberOfStands, forKey: Self.numberOfStandsKey)
            applyStandCount()
        }
    }

    init() {
        let saved = UserDefaults.standard.object(forKey: Self.startKey) as? Date
        shootStart = (saved.map { Calendar.current.isDateInToday($0) } ?? false) ? saved! : Self.halfHour(.now)
        venue = UserDefaults.standard.string(forKey: Self.venueKey) ?? "West Peckham Gun Club"
        shootName = UserDefaults.standard.string(forKey: Self.shootNameKey) ?? "West Peckham Shoot"
        let savedStands = UserDefaults.standard.integer(forKey: Self.numberOfStandsKey)
        numberOfStands = Self.standOptions.contains(savedStands) ? savedStands : Self.defaultNumberOfStands
        observeAudioEngineChanges()
        observeAppTermination()
    }

    /// The full heading, e.g. "West Peckham Shoot - 23 October 2026".
    var title: String {
        let today = shootStart.formatted(date: .long, time: .shortened)
        let name = shootName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? today : "\(name) - \(today)"
    }

    var shooters: [Shooter] = []

    /// Identifies this shoot on the server so every live upload replaces the previous one.
    /// A new one is made at launch and whenever the shoot is cleared and started again.
    private(set) var shootSessionId = UUID().uuidString
    var currentShooterIndex: Int? = nil
    var currentStand = 0
    var currentTarget = 0   // 0–9

    /// Goes up every time a shooter is chosen by name, click or command, even when
    /// they were already current. The score table watches this so the chosen
    /// shooter is always scrolled into view.
    private(set) var selectionCount = 0

    /// True while the audio engine is running and speech is being recognised.
    var isListening = false
    /// When true, scores come only from the on-screen Hit and Miss buttons and
    /// spoken scoring is ignored. Names are still taken by voice.
    var isManualMode: Bool = UserDefaults.standard.bool(forKey: "manualMode") {
        didSet {
            UserDefaults.standard.set(isManualMode, forKey: "manualMode")
            if isManualMode {
                cancelPendingScores()
                processedWordCount = latestWordCount
            }
        }
    }
    /// Whether the current (or last) listening session is for scoring or new names.
    private(set) var listeningMode: ListeningMode = .scoring
    /// The most recent transcription heard from the microphone, for on-screen feedback.
    var transcript = ""
    /// Goes up every time the recogniser hears new words, so the microphone
    /// symbol can bounce in time with speech.
    private(set) var heardWordCount = 0
    /// True for a moment after words are heard, so the microphone symbol can
    /// light up while someone is speaking.
    private(set) var isHearingSpeech = false
    private var hearingTask: Task<Void, Never>?
    /// How long after the last words the microphone stays lit.
    private static let hearingHold: Duration = .milliseconds(900)

    /// True while the app is in the background and must not use the microphone.
    private var isInBackground = false
    /// Tries listening again after a failure, so listening comes back by itself.
    private var retryTask: Task<Void, Never>?
    private static let retryDelay: Duration = .seconds(10)
    /// A human-readable description of the last failure, if any.
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                Self.logger.error("\(errorMessage, privacy: .public)")
            }
        }
    }

    /// Diagnostics for the microphone and recogniser, visible in the Xcode
    /// console and in Console.app under the "Speech" category.
    nonisolated static let logger = Logger(subsystem: "com.clivetalbutt.ClayShootScoreApp", category: "Speech")

    /// Where the user turns permissions back on, worded for the platform.
    #if os(macOS)
    private static let privacySettingsHint = "System Settings > Privacy & Security"
    #else
    private static let privacySettingsHint = "Settings > Privacy & Security"
    #endif

    /// True from pressing Add Shooter until Finish is pressed or the shoot is full.
    var isAddingShooter = false
    /// The name heard so far (since the last name was added). Editable by hand before confirming.
    var pendingShooterName = ""

    /// True when no more shooters can be added.
    var isFull: Bool { shooters.count >= Self.maxShooters }

    /// The recogniser for the device language, falling back to British then US
    /// English when the device language has no speech recognition support.
    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer()
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    /// Built fresh for every listening session. An engine that was running when
    /// the audio session was torn down can keep its old input format and then
    /// deliver nothing but silence, so it is never reused.
    private var audioEngine = AVAudioEngine()
    /// Carries microphone audio from the engine's tap to the current request.
    private let audioSink = RecognitionAudioSink()
    private var isTapInstalled = false
    /// True once the microphone has been rebuilt in response to silence, so the
    /// recovery is only attempted once per listening session.
    private var hasRetriedForSilence = false
    /// True while this app holds the shared audio session for recording.
    private var isAudioSessionActive = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isStartingSession = false
    /// Bumped whenever listening starts or stops, so a start that is still
    /// waiting on permissions can tell that Stop was pressed in the meantime.
    private var listeningGeneration = 0
    private var sessionStart = Date.distantPast
    /// True once the current recognition session has produced any words.
    private var sessionHeardSpeech = false
    /// Sessions in a row that failed quickly without hearing anything.
    private var quickFailures = 0
    /// A session that fails within this many seconds without hearing any speech
    /// counts as a quick failure; this many in a row means the recogniser is
    /// genuinely broken and the error is shown instead of silently retrying.
    private static let quickFailureWindow: TimeInterval = 5
    private static let quickFailureLimit = 3
    /// How long after starting to wait before warning that the microphone is silent.
    private static let silenceCheckDelay: Duration = .seconds(4)
    private var silenceCheckTask: Task<Void, Never>?

    // Tracks which part of the transcript has already been scored (or added as a
    // name), so the same words are not used again every time the recogniser updates.
    private var processedWordCount = 0
    // Total words in the latest transcript, so a manual Add can mark them as used.
    private var latestWordCount = 0

    // Adds the spoken name once the speaker has paused for a moment.
    private var nameCommitTask: Task<Void, Never>?

    // Scoring words heard but not yet acted on, waiting for the phrase to settle.
    private var pendingScoreWords: [String] = []
    private var scoreCommitTask: Task<Void, Never>?
    // The last single hit or miss scored, so a lone "pair" arriving just after it
    // can turn it into a pair.
    private var lastSingleScore: (value: Int, time: Date)?

    // A "clear …" command spans several words that arrive one at a time, so the
    // words from "clear" onwards are held back until the speaker pauses.
    private var pendingClearStart: Int?
    private var pendingClearPhrase: [String] = []
    private var clearCommitTask: Task<Void, Never>?

    // MARK: - Stands

    /// Resizes every shooter's score sheet to the current number of stands and keeps
    /// the scoring position within range.
    private func applyStandCount() {
        for index in shooters.indices {
            shooters[index].resize(numberOfStands: numberOfStands, targetsPerStand: Self.targetsPerStand)
        }
        // `currentStand == numberOfStands` means every stand has been shot, so it is
        // allowed to sit one past the last stand.
        currentStand = min(currentStand, numberOfStands)
        if let index = currentShooterIndex {
            selectShooter(at: index)
        }
    }

    // MARK: - Results

    /// True once every shooter has scored every target on every stand.
    var isComplete: Bool {
        !shooters.isEmpty && shooters.allSatisfy(\.isComplete)
    }

    /// Finishing position for each shooter, using competition ranking so that
    /// equal totals share a place. Empty until the shoot is complete.
    var placings: [Shooter.ID: Int] {
        guard isComplete else { return [:] }
        let ranked = shooters.sorted { $0.grandTotal > $1.grandTotal }
        var result: [Shooter.ID: Int] = [:]
        var lastTotal: Int?
        var lastPlace = 0
        for (index, shooter) in ranked.enumerated() {
            if shooter.grandTotal != lastTotal {
                lastPlace = index + 1
                lastTotal = shooter.grandTotal
            }
            result[shooter.id] = lastPlace
        }
        return result
    }

    func placing(for shooter: Shooter) -> Int? {
        placings[shooter.id]
    }

    /// The shooters finishing first, second and third, in order.
    var podium: [(place: Int, shooter: Shooter)] {
        let placings = placings
        return shooters
            .compactMap { shooter -> (place: Int, shooter: Shooter)? in
                guard let place = placings[shooter.id], place <= 3 else { return nil }
                return (place, shooter)
            }
            .sorted { lhs, rhs in
                lhs.place != rhs.place ? lhs.place < rhs.place : lhs.shooter.name < rhs.shooter.name
            }
    }

    /// Builds an Excel workbook of the current scores and placings.
    func makeWorkbookData() -> Data {
        ResultsExporter.makeWorkbook(
            title: title,
            shooters: shooters,
            placings: placings,
            numberOfStands: numberOfStands,
            targetsPerStand: Self.targetsPerStand
        )
    }

    /// A sensible default file name for the exported workbook.
    var exportFileName: String {
        let name = shootName.trimmingCharacters(in: .whitespaces)
        let date = shootStart.formatted(.iso8601.year().month().day())
        return (name.isEmpty ? "Shoot" : name) + " " + date
    }

    // MARK: - Shooters

    /// Starts listening for spoken names. Each name is added automatically after the
    /// speaker pauses for 1.4 seconds, and listening continues until Finish is
    /// pressed or the maximum number of shooters is reached.
    func startAddingShooter() {
        guard !isFull else { return }
        isAddingShooter = true
        pendingShooterName = ""
        restartNameIdleTimer()
        startListening(mode: .addingShooter)
    }

    /// Adds the pending name (spoken or typed) as a new shooter and keeps listening
    /// for the next one.
    private func restartNameIdleTimer() {
        nameIdleTask?.cancel()
        nameIdleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.nameIdleLimit)
            guard !Task.isCancelled, let self, self.isAddingShooter else { return }
            self.finishAddingShooters()
        }
    }

    func confirmPendingShooter() {
        nameCommitTask?.cancel()
        nameCommitTask = nil

        let name = pendingShooterName.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingShooterName = ""
        // Everything heard so far now belongs to a name that has been dealt with.
        processedWordCount = latestWordCount

        if !name.isEmpty {
            addShooter(named: name)
        }
        if isFull {
            finishAddingShooters()
        }
    }

    /// Adds any name still pending, then goes back to listening for scores.
    func finishAddingShooters() {
        nameIdleTask?.cancel()
        nameIdleTask = nil
        nameCommitTask?.cancel()
        nameCommitTask = nil

        let name = pendingShooterName.trimmingCharacters(in: .whitespacesAndNewlines)
        isAddingShooter = false
        pendingShooterName = ""

        if !name.isEmpty {
            addShooter(named: name)
        }
        // The microphone stays on; only the vocabulary changes back to scoring.
        startListening(mode: .scoring)
    }

    /// Keeps only what can be part of a person's name: letters, apostrophes and
    /// hyphens. Digits, symbols, scoring words ("hit", "miss", "pair") and filler
    /// words are dropped, so stray speech never becomes a shooter.
    static func cleanedName(_ raw: String) -> String {
        let ignored: Set<String> = namePrefixWords.union([
            "hit", "hits", "miss", "misses", "missed", "lost", "dead", "kill", "pair", "single",
            "clear", "stand", "next", "undo", "score", "shooter", "shooters", "and", "then", "the", "a", "um", "uh"
        ])
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "'-’"))
        let words = raw.split(whereSeparator: { $0.isWhitespace }).compactMap { word -> String? in
            let kept = String(String.UnicodeScalarView(word.unicodeScalars.filter { allowed.contains($0) }))
                .trimmingCharacters(in: CharacterSet(charactersIn: "'-’"))
            guard kept.rangeOfCharacter(from: .letters) != nil,
                  !ignored.contains(kept.lowercased()) else { return nil }
            return kept
        }
        return words.joined(separator: " ")
    }

    func addShooter(named name: String) {
        let name = Self.cleanedName(name)
        guard !name.isEmpty, !isFull else { return }
        shooters.append(
            Shooter(name: name.lowercased(),
                    numberOfStands: numberOfStands,
                    targetsPerStand: Self.targetsPerStand)
        )
        if currentShooterIndex == nil {
            currentShooterIndex = 0
        }
    }

    /// Removes one shooter and keeps scoring pointed at a sensible shooter.
    func removeShooter(at index: Int) {
        guard shooters.indices.contains(index) else { return }
        shooters.remove(at: index)
        guard !shooters.isEmpty else {
            removeAllShooters()
            return
        }
        if let current = currentShooterIndex {
            if current > index {
                // The current shooter moved up one row.
                selectShooter(at: current - 1)
            } else if current == index {
                // The current shooter was removed; carry on with whoever took their row.
                selectShooter(at: min(index, shooters.count - 1))
            }
        }
    }

    /// Removes every shooter and starts the shoot again from the first stand.
    func removeAllShooters() {
        shootSessionId = UUID().uuidString
        shooters.removeAll()
        currentShooterIndex = nil
        currentStand = 0
        currentTarget = 0
    }

    /// Wipes a shooter's scores, either on one stand or on every stand, and moves
    /// scoring to that shooter at the first cleared stand so it can be shot again.
    func clearScores(ofShooterAt index: Int, stand: Int? = nil) {
        guard shooters.indices.contains(index) else { return }
        if let stand {
            guard shooters[index].scores.indices.contains(stand) else {
                errorMessage = "There is no stand \(stand + 1) in this shoot."
                return
            }
            shooters[index].clearStand(stand)
            currentStand = stand
        } else {
            shooters[index].clearAllScores()
            currentStand = 0
        }
        selectShooter(at: index)
    }

    // MARK: - Listening

    /// Starts listening for scoring commands.
    func startListening() {
        startListening(mode: .scoring)
    }

    /// Makes sure the microphone is on, for when the app appears or comes back
    /// to the foreground. Does nothing if listening is already under way.
    func resumeListening() {
        isInBackground = false
        guard !isListening, !isStartingSession else { return }
        startListening(mode: isAddingShooter ? .addingShooter : .scoring)
    }

    private func startListening(mode: ListeningMode) {
        guard !isStartingSession, !isInBackground else { return }
        retryTask?.cancel()
        retryTask = nil
        // Scoring always has a current shooter; default to the first on the list.
        if mode == .scoring, currentShooterIndex == nil, !shooters.isEmpty {
            selectShooter(at: 0)
        }
        listeningMode = mode
        errorMessage = nil
        transcript = ""
        quickFailures = 0
        hasRetriedForSilence = false

        // The microphone is already live (for example when switching from scoring
        // to taking names), so only a fresh recognition session is needed.
        if isListening, let recognizer {
            beginRecognitionSession(with: recognizer)
            return
        }

        isStartingSession = true
        listeningGeneration += 1
        let generation = listeningGeneration

        Task {
            defer { isStartingSession = false }

            let speechAuthorized = await requestSpeechAuthorization()
            Self.logger.info("Speech authorization status: \(SFSpeechRecognizer.authorizationStatus().rawValue)")
            // Stop may have been pressed while the permission prompt was showing.
            guard generation == listeningGeneration else { return }
            guard speechAuthorized else {
                errorMessage = "Speech recognition permission was not granted. Enable it in \(Self.privacySettingsHint) > Speech Recognition."
                return
            }

            let micAuthorized = await requestMicrophoneAuthorization()
            guard generation == listeningGeneration else { return }
            guard micAuthorized else {
                errorMessage = "Microphone permission was not granted. Enable it in \(Self.privacySettingsHint) > Microphone."
                return
            }

            Self.logger.info("Recognizer locale=\(self.recognizer?.locale.identifier ?? "none", privacy: .public) available=\(self.recognizer?.isAvailable ?? false) onDevice=\(self.recognizer?.supportsOnDeviceRecognition ?? false)")
            guard let recognizer, recognizer.isAvailable else {
                #if targetEnvironment(simulator)
                // The Simulator has no Siri or Dictation service, so the recogniser
                // nearly always reports itself unavailable there.
                errorMessage = "Speech recognition is not available in the iOS Simulator. Run the app on an iPhone to use voice scoring."
                #else
                errorMessage = "Speech recognition is not available right now. Check that Siri or Dictation is enabled in Settings and that the device is online. Listening will retry shortly, or tap the microphone."
                scheduleListeningRetry()
                #endif
                return
            }

            do {
                try startAudioEngine()
            } catch {
                // Release anything that did get set up before the failure.
                stopAudioEngine()
                errorMessage = Self.describeMicrophoneFailure(error)
                scheduleListeningRetry()
                return
            }

            isListening = true
            beginRecognitionSession(with: recognizer)
            scheduleSilenceCheck()
        }
    }

    func stopListening() {
        // Abandons a start that is still waiting on permissions.
        listeningGeneration += 1
        silenceCheckTask?.cancel()
        silenceCheckTask = nil
        hearingTask?.cancel()
        hearingTask = nil
        isHearingSpeech = false
        endRecognitionSession()
        cancelPendingClear()
        cancelPendingScores()
        stopAudioEngine()
        isListening = false
    }

    /// Releases the microphone when the app leaves the foreground, so Siri,
    /// dictation and other apps can use it. Any name still being taken is added
    /// first. Listening starts again by itself when the app comes back.
    func stopListeningForBackground() {
        isInBackground = true
        retryTask?.cancel()
        retryTask = nil
        guard isListening || isStartingSession || isAddingShooter else { return }
        if isAddingShooter {
            finishAddingShooters()
        }
        stopListening()
        Self.logger.info("Listening stopped because the app left the foreground")
    }

    /// Tries to start listening again after a short wait, so a passing problem
    /// such as the recogniser being briefly unavailable heals itself.
    private func scheduleListeningRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.resumeListening()
        }
    }

    /// Records that the recogniser has just heard words, driving the microphone
    /// animation, and lets it go quiet again once speech stops.
    private func noteSpeechHeard() {
        heardWordCount += 1
        isHearingSpeech = true
        hearingTask?.cancel()
        hearingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hearingHold)
            guard !Task.isCancelled, let self else { return }
            self.isHearingSpeech = false
        }
    }

    /// Makes sure the microphone is released if the app is quit while listening.
    private func observeAppTermination() {
        #if os(macOS)
        let willTerminate = NSApplication.willTerminateNotification
        #else
        let willTerminate = UIApplication.willTerminateNotification
        #endif
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: willTerminate) {
                self?.stopListening()
            }
        }
    }

    // MARK: - Authorization

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
        #else
        // On iPhone the audio session records only silence unless this recording
        // permission in particular has been granted, so ask through it directly.
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            granted = true
        case .undetermined:
            granted = await AVAudioApplication.requestRecordPermission()
        default:
            granted = false
        }
        Self.logger.info("Record permission: \(AVAudioApplication.shared.recordPermission.rawValue) capture status: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        return granted
        #endif
    }

    // MARK: - Microphone

    /// Sets up the microphone and starts feeding its audio to `audioSink`. The
    /// engine then stays running for as long as the user is listening; only the
    /// recognition request changes from one session to the next, which avoids
    /// tearing down and rebuilding the audio session on iPhone every time the
    /// system ends a session.
    private func startAudioEngine() throws {
        // Start from a clean engine so no state from an earlier session, or from
        // a session the system pulled the microphone out from under, is carried
        // over. The old engine's tap is dropped with it.
        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        audioEngine = AVAudioEngine()
        audioSink.resetSoundDetection()

        #if !os(macOS)
        // On iPhone and iPad the microphone is only routed to the audio engine once
        // the shared audio session is set up for recording. Without this the input
        // node reports a 0 Hz format and no speech is ever heard.
        // The default mode keeps the system's input processing (gain control and
        // noise handling) on, which suits speech picked up outdoors.
        // No category options: the record category does not support mixing or
        // ducking options such as `.duckOthers`, and asking for one makes
        // `setCategory` throw (OSStatus -50) before the microphone ever starts.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        isAudioSessionActive = true
        if AVAudioApplication.shared.isInputMuted {
            Self.logger.error("Microphone input is muted; unmuting")
            try? AVAudioApplication.shared.setInputMuted(false)
        }
        let inputs = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
        let source = session.inputDataSource?.dataSourceName ?? "default"
        Self.logger.info("Audio session active: inputAvailable=\(session.isInputAvailable) inputs=[\(inputs, privacy: .public)] source=\(source, privacy: .public) gain=\(session.inputGain) muted=\(AVAudioApplication.shared.isInputMuted) sampleRate=\(session.sampleRate)")
        #endif

        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        Self.logger.info("Input node format: \(format.sampleRate) Hz, \(format.channelCount) channel(s)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NoMicrophoneError()
        }

        // Passing nil takes the node's own input format, which always matches the
        // hardware even if it changed since the format was read above.
        let sink = audioSink
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            sink.append(buffer)
        }
        isTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            node.removeTap(onBus: 0)
            isTapInstalled = false
            throw error
        }
        Self.logger.info("Audio engine started")
    }

    /// Warns the user if the microphone has delivered nothing but digital silence
    /// since listening began. iOS does that, rather than failing, when recording
    /// is not really permitted or the input is muted, so without this check the
    /// app would simply appear deaf.
    private func scheduleSilenceCheck() {
        silenceCheckTask?.cancel()
        silenceCheckTask = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceCheckDelay)
            guard !Task.isCancelled, let self, self.isListening, !self.audioSink.hasDetectedSound else { return }

            // A microphone that another app or an abandoned session is still
            // holding delivers silence until it is taken afresh, so rebuild the
            // whole audio path once before telling the user anything is wrong.
            if !self.hasRetriedForSilence {
                self.hasRetriedForSilence = true
                Self.logger.error("Only silence so far; rebuilding the microphone")
                self.restartMicrophoneAfterSilence()
                return
            }

            Self.logger.error("Still only silence after rebuilding the microphone")
            self.errorMessage = "The microphone is only picking up silence. Check that it works in another app such as Voice Memos, then tap the microphone to try again."
        }
    }

    /// Releases the microphone completely and takes it again, then starts a new
    /// recognition session on it.
    private func restartMicrophoneAfterSilence() {
        guard let recognizer else { return }
        endRecognitionSession()
        stopAudioEngine()
        do {
            try startAudioEngine()
        } catch {
            let failure = Self.describeMicrophoneFailure(error)
            stopListening()
            errorMessage = failure
            scheduleListeningRetry()
            return
        }
        beginRecognitionSession(with: recognizer)
        scheduleSilenceCheck()
    }

    private func stopAudioEngine() {
        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        #if !os(macOS)
        // Give the microphone back so other apps' audio and Siri can resume.
        // Only a session this app activated needs releasing.
        guard isAudioSessionActive else { return }
        isAudioSessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            Self.logger.info("Audio session released")
        } catch {
            Self.logger.error("Could not release the audio session: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    // MARK: - Recognition

    /// Starts a new recognition session on the running audio engine. A request
    /// can only be used once, and iOS ends a session after a pause or about a
    /// minute of speech, so this runs again every time a session finishes.
    private func beginRecognitionSession(with recognizer: SFSpeechRecognizer) {
        endRecognitionSession()
        cancelPendingClear()
        cancelPendingScores()
        processedWordCount = 0
        latestWordCount = 0
        sessionHeardSpeech = false
        sessionStart = .now

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Steer the recogniser towards the words it is about to hear. Without
        // this a word with no context, such as "pair" at the start of "pair
        // lost", is often heard as "pay", "paul" or "per".
        request.contextualStrings = contextualStrings(for: listeningMode)
        self.request = request
        audioSink.setRequest(request)
        Self.logger.info("Recognition session started (\(self.listeningMode == .scoring ? "scoring" : "names", privacy: .public))")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The recogniser calls back on a background queue; hop to the main actor
            // before touching any observable state.
            Task { @MainActor in
                guard let self, self.request === request else { return }
                if let error {
                    let nsError = error as NSError
                    Self.logger.error("Recognition error \(nsError.domain, privacy: .public) \(nsError.code): \(nsError.localizedDescription, privacy: .public)")
                }
                if let result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    Self.logger.debug("Heard \"\(text, privacy: .public)\" final=\(result.isFinal)")
                    if !text.isEmpty {
                        self.sessionHeardSpeech = true
                        if text != self.transcript {
                            self.noteSpeechHeard()
                        }
                    }
                    self.transcript = text
                    switch self.listeningMode {
                    case .scoring:
                        self.handleSpeech(text)
                    case .addingShooter:
                        self.handleNameSpeech(text, isFinal: result.isFinal)
                    }
                }
                // Either an error or a final result means this session is over and
                // the recogniser has stopped taking audio.
                if error != nil || result?.isFinal == true {
                    // Acting on the words above may already have stopped listening
                    // (for example once the shooter list is full).
                    guard self.isListening, self.request === request else { return }
                    self.recognitionSessionEnded(with: error, recognizer: recognizer)
                }
            }
        }
    }

    /// The vocabulary the recogniser should favour in each mode: the scoring
    /// commands, common two-word phrases and the shooters' names.
    private func contextualStrings(for mode: ListeningMode) -> [String] {
        switch mode {
        case .scoring:
            return Self.scoringVocabulary + shooters.map(\.name)
        case .addingShooter:
            return ["shooter"]
        }
    }

    private static let scoringVocabulary = [
        "hit", "miss", "missed", "lost", "pair",
        "pair hit", "pair lost", "pair missed", "hit pair", "lost pair", "missed pair",
        "shooter", "shooters", "clear", "score", "scores", "stand", "next stand"
    ]

    private func endRecognitionSession() {
        audioSink.setRequest(nil)
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
    }

    /// Decides what to do when the system ends a session: finish any words still
    /// waiting on a pause timer, then quietly start another session, unless the
    /// recogniser keeps failing straight away, in which case the error is shown.
    private func recognitionSessionEnded(with error: Error?, recognizer: SFSpeechRecognizer) {
        if let error {
            // A "no speech" timeout during a quiet spell between stands is normal
            // and arrives after a long wait. Genuine failures come back fast,
            // without any words, and keep doing so.
            let elapsed = Date.now.timeIntervalSince(sessionStart)
            let failedQuickly = elapsed < Self.quickFailureWindow && !sessionHeardSpeech
            quickFailures = failedQuickly ? quickFailures + 1 : 0
            if quickFailures >= Self.quickFailureLimit {
                errorMessage = Self.describe(error)
                stopListening()
                scheduleListeningRetry()
                return
            }
        } else {
            quickFailures = 0
        }

        flushPendingWork()
        // Flushing can add the last shooter and, once the list is full, stop listening.
        guard isListening else { return }
        // No silence check here: the microphone has not been touched, and a quiet
        // spell between stands is expected rather than a fault.
        beginRecognitionSession(with: recognizer)
    }

    // MARK: - Audio interruptions

    /// The engine stops itself when the audio route or format changes, such as
    /// headphones being connected, and when a phone call interrupts it. If the
    /// user is still listening, bring the microphone back up and start afresh.
    private func observeAudioEngineChanges() {
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
                self?.recoverAudioEngine()
            }
        }

        #if !os(macOS)
        Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: rawType) == .ended else { continue }
                self?.recoverAudioEngine()
            }
        }
        #endif
    }

    private func recoverAudioEngine() {
        guard isListening, !audioEngine.isRunning, let recognizer else { return }
        Self.logger.info("Rebuilding the microphone after an audio route change or interruption")
        endRecognitionSession()
        do {
            try startAudioEngine()
        } catch {
            stopAudioEngine()
            errorMessage = Self.describeMicrophoneFailure(error)
            stopListening()
            scheduleListeningRetry()
            return
        }
        beginRecognitionSession(with: recognizer)
        // The microphone has just been taken again, so make sure it is live.
        hasRetriedForSilence = false
        scheduleSilenceCheck()
    }

    // MARK: - Name capture

    /// Handles the cumulative transcript while names are being collected. The words
    /// heard since the last name was added form the pending name; once the speaker
    /// pauses for `nameGap` that name is added and listening carries on.
    private func handleNameSpeech(_ text: String, isFinal: Bool) {
        let words = text.split(separator: " ").map(String.init)
        latestWordCount = words.count
        if words.count > processedWordCount { restartNameIdleTimer() }

        var newWords = words.count > processedWordCount ? Array(words[processedWordCount...]) : []
        // People often say "shooter John" or "add shooter John"; keep just the name.
        while let first = newWords.first, Self.namePrefixWords.contains(first) {
            newWords.removeFirst()
        }
        let name = Self.cleanedName(newWords.joined(separator: " "))

        if isFinal {
            // The recogniser has ended this session; add what we have. A fresh
            // session is started once the session end is handled.
            pendingShooterName = name
            confirmPendingShooter()
            return
        }

        // Only restart the pause timer when the name actually changed, so repeated
        // identical updates from the recogniser do not keep delaying the add.
        guard name != pendingShooterName else { return }
        pendingShooterName = name

        nameCommitTask?.cancel()
        guard !name.isEmpty else { return }
        nameCommitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.nameGap)
            guard !Task.isCancelled, let self, self.isAddingShooter else { return }
            self.confirmPendingShooter()
        }
    }

    /// Words that are spoken before a name but are not part of it.
    private static let namePrefixWords: Set<String> = ["add", "shooter", "and", "next", "then"]

    /// Applies anything still waiting on a pause timer when a session ends. The
    /// speaker has clearly stopped, so the words are as complete as they will get
    /// and nothing that was said is lost in the changeover to the next session.
    private func flushPendingWork() {
        switch listeningMode {
        case .scoring:
            if scoreCommitTask != nil {
                scoreCommitTask?.cancel()
                processPendingScoreWords()
            }
            if clearCommitTask != nil {
                commitPendingClear()
            }
        case .addingShooter:
            if nameCommitTask != nil {
                confirmPendingShooter()
            }
        }
    }

    private static func describeMicrophoneFailure(_ error: Error) -> String {
        if error is NoMicrophoneError {
            return "No microphone input was found. Check that a microphone is connected and selected."
        }
        return "Could not start the microphone: \(error.localizedDescription)"
    }

    /// A readable message for the cryptic errors the speech recogniser returns,
    /// such as "The operation couldn't be completed. (kAFAssistantErrorDomain error 1101.)".
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == "kAFAssistantErrorDomain" else { return error.localizedDescription }
        switch nsError.code {
        case 1101, 1107:
            return "Speech recognition failed on this device. Check that Siri & Dictation are enabled in Settings and that English dictation is downloaded. Listening will retry shortly."
        case 216:
            return "Dictation is turned off. Enable it in Settings > General > Keyboard. Listening will retry shortly."
        case 1110:
            return "No speech was heard. Listening will retry shortly."
        default:
            return "Speech recognition stopped (error \(nsError.code)). Listening will retry shortly."
        }
    }

    // MARK: - Command handling

    /// Applies a cumulative scoring transcript. Internal rather than private so the
    /// command handling can be exercised without a microphone.
    ///
    /// The recogniser delivers a phrase a word or two at a time, so "pair hit"
    /// would otherwise arrive as "pair" (meaningless alone) followed by "hit" (a
    /// single). New words are therefore held for `scoreGap` until the phrase stops
    /// changing, then scored together in order.
    func handleSpeech(_ text: String) {
        let words = text.split(separator: " ").map(String.init)
        latestWordCount = words.count
        if isManualMode {
            processedWordCount = words.count
            return
        }

        // A "clear …" command is still being spoken: keep collecting it until the
        // speaker pauses, and do not score anything in the meantime.
        if let start = pendingClearStart {
            processedWordCount = words.count
            schedulePendingClear(start < words.count ? Array(words[start...]) : [])
            return
        }

        // Only act on words that have arrived since the last time we processed the transcript.
        guard words.count > processedWordCount else { return }
        let newWords = Array(words[processedWordCount...])

        // Only restart the settle timer when the words actually changed, so repeated
        // identical updates from the recogniser do not keep delaying the score.
        guard newWords != pendingScoreWords || scoreCommitTask == nil else { return }
        pendingScoreWords = newWords
        scoreCommitTask?.cancel()
        scoreCommitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.scoreGap)
            guard !Task.isCancelled, let self else { return }
            self.processPendingScoreWords()
        }
    }

    /// Acts on the words that have settled since the last processed position:
    /// clear commands, shooter names and then the hits and misses in order.
    private func processPendingScoreWords() {
        scoreCommitTask = nil
        var newWords = pendingScoreWords
        pendingScoreWords = []
        guard !newWords.isEmpty else { return }

        let chunkStart = processedWordCount
        processedWordCount += newWords.count

        // "clear" begins a multi-word command. Hold back everything from that word
        // on, but still score anything said before it.
        var startedClear = false
        if let clearIndex = newWords.firstIndex(where: { Self.isCommandWord($0, "clear") }) {
            let phrase = Array(newWords[clearIndex...])
            newWords = Array(newWords[..<clearIndex])
            pendingClearStart = chunkStart + clearIndex
            schedulePendingClear(phrase)
            startedClear = true
        }

        // A pair word on its own, straight after a single score, means the speaker
        // said "hit pair" or "lost pair" and the two words arrived separately:
        // score the second target of the pair with the same result.
        // A shooter's name (such as Paul) is never taken as a mangled "pair".
        if !startedClear, newWords.allSatisfy({ Self.isPairWord($0) }), matchShooter(in: newWords) == nil,
           let last = lastSingleScore, Date.now.timeIntervalSince(last.time) < Self.pairFollowUpWindow {
            addScore(last.value)
            lastSingleScore = nil
            return
        }

        // "stand 3" moves scoring to that stand and "next stand" to the one after
        // this, before any shooter or score in the same phrase is dealt with.
        var endedWithLoneStand = false
        if !startedClear {
            endedWithLoneStand = applyStandCommands(in: &newWords)
        }

        // Mentioning an existing shooter's name (with or without the word "shooter")
        // switches scoring to that shooter. Any scoring words in the same phrase,
        // such as "john hit", are still applied afterwards.
        if let match = matchShooter(in: newWords) {
            selectShooter(at: match.index)
            newWords.removeSubrange(match.range)
            newWords.removeAll { SpeechMatcher.soundsLike($0, "shooter") }
            if currentTarget >= Self.targetsPerStand, currentStand < numberOfStands {
                // Their scores would be ignored, so say why rather than stay silent.
                var message = "\(shooters[match.index].name.capitalized) has already shot stand \(currentStand + 1)."
                if currentStand + 1 < numberOfStands {
                    message += " Say \"stand \(currentStand + 2)\" to move on."
                }
                errorMessage = message
            }
        }

        let result = scoreSequence(newWords)
        lastSingleScore = result.endedWithSingle.map { (value: $0, time: .now) }

        // A phrase ending in "pair" is waiting for its "hit" or "lost", and one
        // ending in "stand" for its number: leave that word unprocessed so it is
        // read again together with whatever comes next.
        if result.endedWithLonePair || endedWithLoneStand, !startedClear {
            processedWordCount -= 1
        }
    }

    // MARK: Stand commands

    /// Carries out any "stand <number>" or "next stand" command in the words and
    /// removes it, so the rest can still be scored ("stand 3 john hit"). Returns
    /// true when the words end with a bare "stand" still waiting for its number.
    /// As with clear commands, "stand" must be followed by a number so that a
    /// shooter called Stan is never mistaken for a stand.
    private func applyStandCommands(in words: inout [String]) -> Bool {
        var index = 0
        while index < words.count {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil

            if Self.isCommandWord(word, "stand") {
                if let next, let number = Self.number(from: next) {
                    moveToStand(number - 1)
                    words.removeSubrange(index...(index + 1))
                    continue
                }
                if next == nil {
                    words.removeLast()
                    return true
                }
            } else if Self.isCommandWord(word, "next"), let next, Self.isCommandWord(next, "stand") {
                moveToNextStand()
                words.removeSubrange(index...(index + 1))
                continue
            }
            index += 1
        }
        return false
    }

    /// Moves scoring to the given stand (counting from 0), staying with the
    /// current shooter if they still have targets there and otherwise picking
    /// the first shooter who does.
    func moveToStand(_ stand: Int) {
        guard (0..<numberOfStands).contains(stand) else {
            errorMessage = "There is no stand \(stand + 1) in this shoot."
            return
        }
        currentStand = stand
        guard !shooters.isEmpty else { return }

        let start = currentShooterIndex ?? 0
        let order = Array(start..<shooters.count) + Array(0..<start)
        if let index = order.first(where: { firstUnscoredTarget(ofShooterAt: $0, stand: stand) != nil }) {
            selectShooter(at: index)
        } else {
            selectShooter(at: start)
            errorMessage = "Every shooter has already shot stand \(stand + 1)."
        }
    }

    /// Moves scoring to the stand after the current one.
    func moveToNextStand() {
        moveToStand(currentStand + 1)
    }

    /// Scores a run of words in the order they were spoken. Words are matched by
    /// sound rather than exactly, so "it" counts as "hit" and "mist" as "miss".
    /// "Lost" is the usual clay call for a miss, so "miss" and "lost" both count
    /// as misses. A pair is two targets, so "pair hit", "hit pair", "pair lost" and
    /// "lost pair" each score the next two cells, and "hit hit" scores two singles.
    ///
    /// Returns whether the last word was a pair word with nothing to pair it with,
    /// and the value of the final single score if the phrase ended with one.
    private func scoreSequence(_ words: [String]) -> (endedWithLonePair: Bool, endedWithSingle: Int?) {
        var index = 0
        var endedWithSingle: Int?
        while index < words.count {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil
            endedWithSingle = nil

            if Self.isPairWord(word) {
                if let next, let value = Self.scoreValue(of: next) {
                    addScore(value)
                    addScore(value)
                    index += 2
                } else if next == nil {
                    return (true, nil)
                } else {
                    index += 1
                }
            } else if let value = Self.scoreValue(of: word) {
                if let next, Self.isPairWord(next) {
                    addScore(value)
                    addScore(value)
                    index += 2
                } else {
                    addScore(value)
                    endedWithSingle = value
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return (false, endedWithSingle)
    }

    /// Words that mean a target was missed.
    private static let missWords = ["miss", "lost"]

    /// "Pair" and the ways the recogniser has been heard to mangle it when it
    /// starts a phrase ("pay lost", "paul missed", "per missed", "perm").
    /// Shooter names are matched and removed before these are checked, so a
    /// shooter called Paul still wins over the mishearing.
    private static let pairWords = [
        "pair", "pear", "pare", "pier", "pay", "per", "perm", "paul", "palo", "pal",
        "bear", "bare", "fair", "hair", "air"
    ]

    private static func isPairWord(_ word: String) -> Bool {
        pairWords.contains { SpeechMatcher.soundsLike(word, $0) }
    }

    /// 1 for a hit, 0 for a miss, nil for any other word.
    private static func scoreValue(of word: String) -> Int? {
        if SpeechMatcher.soundsLike(word, "hit") { return 1 }
        if missWords.contains(where: { SpeechMatcher.soundsLike(word, $0) }) { return 0 }
        return nil
    }

    /// Command words are matched a little more strictly than scoring words: exact,
    /// a longer form such as "scores" or "clearing", or a single letter out.
    private static func isCommandWord(_ heard: String, _ target: String) -> Bool {
        guard let quality = SpeechMatcher.matchQuality(heard, target) else { return false }
        return quality <= 1
    }

    // MARK: Clear commands

    /// Remembers the words of a "clear …" command heard so far and (re)starts the
    /// pause timer whenever they change. The command runs once the speaker pauses.
    private func schedulePendingClear(_ phrase: [String]) {
        guard phrase != pendingClearPhrase || clearCommitTask == nil else { return }
        pendingClearPhrase = phrase
        clearCommitTask?.cancel()
        clearCommitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.commandGap)
            guard !Task.isCancelled, let self else { return }
            self.commitPendingClear()
        }
    }

    private func commitPendingClear() {
        let phrase = pendingClearPhrase
        cancelPendingClear()
        performClear(phrase)
    }

    private func cancelPendingClear() {
        clearCommitTask?.cancel()
        clearCommitTask = nil
        pendingClearStart = nil
        pendingClearPhrase = []
    }

    /// Drops any scoring words still waiting to settle, e.g. when a session ends.
    private func cancelPendingScores() {
        scoreCommitTask?.cancel()
        scoreCommitTask = nil
        pendingScoreWords = []
        lastSingleScore = nil
    }

    /// Carries out a complete "clear …" phrase (starting with the word "clear"):
    ///
    /// - "clear shooters" removes every shooter.
    /// - "clear shooter <name>" removes that shooter.
    /// - "clear score <name>" wipes that shooter's scores on every stand.
    /// - "clear score <name> stand 3" wipes that shooter's scores on stand 3 only.
    /// - "clear score" (with or without a stand) applies to the current shooter.
    private func performClear(_ phrase: [String]) {
        var words = Array(phrase.dropFirst())

        // "stand 3" or "stand three" picks out one stand. The number must follow the
        // word "stand" so a shooter called Stan is never mistaken for a stand.
        var stand: Int?
        if let standIndex = words.indices.first(where: { index in
            index + 1 < words.count
                && Self.isCommandWord(words[index], "stand")
                && Self.number(from: words[index + 1]) != nil
        }) {
            stand = Self.number(from: words[standIndex + 1]).map { $0 - 1 }
            words.removeSubrange(standIndex...(standIndex + 1))
        }

        let wantsScores = words.contains { Self.isCommandWord($0, "score") }
        let mentionsShooter = words.contains { Self.isCommandWord($0, "shooter") }

        // Strip the command and filler words so only the name is left to match.
        let nameWords = words.filter { word in
            !Self.isCommandWord(word, "score")
                && !Self.isCommandWord(word, "shooter")
                && !Self.fillerWords.contains(word)
        }
        let match = matchShooter(in: nameWords)

        if wantsScores {
            guard let index = match?.index ?? currentShooterIndex else { return }
            if match == nil, !nameWords.isEmpty {
                errorMessage = "No shooter called \"\(nameWords.joined(separator: " "))\" was found."
                return
            }
            clearScores(ofShooterAt: index, stand: stand)
        } else if let match {
            removeShooter(at: match.index)
        } else if mentionsShooter, nameWords.isEmpty {
            removeAllShooters()
        } else if !nameWords.isEmpty {
            errorMessage = "No shooter called \"\(nameWords.joined(separator: " "))\" was found."
        }
    }

    /// Small words that may be spoken inside a clear command but never form part of a name.
    private static let fillerWords: Set<String> = [
        "the", "for", "of", "on", "from", "and", "please", "all", "a", "an", "to"
    ]

    private static let numberWords = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"
    ]

    /// Reads a stand number spoken either as digits ("3") or as a word ("three").
    /// Common mishearings such as "to" for "two" and "for" for "four" are accepted.
    private static func number(from word: String) -> Int? {
        let digits = word.filter(\.isNumber)
        if !digits.isEmpty, let value = Int(digits) {
            return value
        }
        if let index = numberWords.firstIndex(where: { SpeechMatcher.soundsLike(word, $0) }) {
            return index + 1
        }
        return nil
    }

    // MARK: Shooter matching

    /// Finds a shooter mentioned in the words, matching by sound rather than exact
    /// spelling. Full names are tried first (longest first, so "john taylor" wins
    /// over "john"), then a first name on its own when it clearly belongs to one
    /// shooter. Returns the shooter and the range of words that named them.
    private func matchShooter(in words: [String]) -> (index: Int, range: Range<Int>)? {
        // Exact matches beat sounds-like matches, so "jon" picks Jon rather than John
        // when both are shooting.
        let byLength = shooters.indices.sorted { shooters[$0].name.count > shooters[$1].name.count }
        for exactOnly in [true, false] {
            for index in byLength {
                let nameWords = shooters[index].name.lowercased().split(separator: " ").map(String.init)
                guard !nameWords.isEmpty, words.count >= nameWords.count else { continue }
                for start in 0...(words.count - nameWords.count) {
                    let window = Array(words[start..<(start + nameWords.count)])
                    let matches = exactOnly
                        ? window == nameWords
                        : zip(window, nameWords).allSatisfy { SpeechMatcher.soundsLike($0, $1) }
                    if matches {
                        return (index, start..<(start + nameWords.count))
                    }
                }
            }
        }

        // A first name on its own: pick the shooter whose first name is the closest
        // match, as long as no other shooter matches equally well.
        for (position, word) in words.enumerated() {
            var best: (index: Int, quality: Int)?
            var isAmbiguous = false
            for index in shooters.indices {
                guard let firstName = shooters[index].name.lowercased().split(separator: " ").first,
                      let quality = SpeechMatcher.matchQuality(word, String(firstName)) else { continue }
                if let current = best {
                    if quality < current.quality {
                        best = (index, quality)
                        isAmbiguous = false
                    } else if quality == current.quality {
                        isAmbiguous = true
                    }
                } else {
                    best = (index, quality)
                }
            }
            if let best, !isAmbiguous {
                return (best.index, position..<(position + 1))
            }
        }

        return nil
    }

    // MARK: Scoring position

    /// Makes the given shooter current and resumes at their next unscored target
    /// on the current stand, so switching between shooters never overwrites scores.
    func selectShooter(at index: Int) {
        guard shooters.indices.contains(index) else { return }
        currentShooterIndex = index
        selectionCount += 1

        let scores = shooters[index].scores
        if scores.indices.contains(currentStand),
           let next = scores[currentStand].firstIndex(where: { $0 < 0 }) {
            currentTarget = next
        } else {
            currentTarget = Self.targetsPerStand
        }
    }

    /// Records a hit on the current target, exactly as if "hit" had been spoken.
    /// Triggered by the Y key.
    func recordHit() {
        recordKeyedScore(1)
    }

    /// Records a miss on the current target, exactly as if "lost" had been spoken.
    /// Triggered by the X key.
    func recordMiss() {
        recordKeyedScore(0)
    }

    private func recordKeyedScore(_ value: Int) {
        guard !isAddingShooter, !isComplete else { return }
        // Scoring always has a current shooter; default to the first on the list.
        if currentShooterIndex == nil, !shooters.isEmpty {
            selectShooter(at: 0)
        }
        addScore(value)
    }

    private func addScore(_ value: Int) {
        guard let index = currentShooterIndex,
              shooters.indices.contains(index),
              shooters[index].scores.indices.contains(currentStand),
              currentTarget < Self.targetsPerStand else { return }

        shooters[index].scores[currentStand][currentTarget] = value
        // Confirmation beep for every recorded score, spoken or manual.
        AudioServicesPlaySystemSound(1057)
        UINotificationFeedbackGenerator().notificationOccurred(value == 1 ? .success : .warning)

        currentTarget += 1

        if currentTarget >= Self.targetsPerStand {
            advanceToNextShooter()
        }
        // Listening carries on after the last target so "clear …" commands can
        // still correct a result.
    }

    /// Moves scoring on to the next unscored target. The current stand is finished
    /// first: the shooters after the current one, then anyone earlier in the list
    /// who has not shot it yet, whatever order the squad shot in. Only once every
    /// shooter has shot this stand does scoring move on to the next stand with
    /// targets left. Shooters who have already completed a stand (for example
    /// after a score was cleared and re-shot) are skipped rather than overwritten.
    private func advanceToNextShooter() {
        guard let index = currentShooterIndex, !shooters.isEmpty else { return }

        let afterCurrent = Array((index + 1)..<shooters.count) + Array(0...index)
        if let shooter = afterCurrent.first(where: { firstUnscoredTarget(ofShooterAt: $0, stand: currentStand) != nil }),
           let target = firstUnscoredTarget(ofShooterAt: shooter, stand: currentStand) {
            currentShooterIndex = shooter
            currentTarget = target
            return
        }

        var stand = currentStand + 1
        while stand < numberOfStands {
            if let shooter = shooters.indices.first(where: { firstUnscoredTarget(ofShooterAt: $0, stand: stand) != nil }),
               let target = firstUnscoredTarget(ofShooterAt: shooter, stand: stand) {
                currentStand = stand
                currentShooterIndex = shooter
                currentTarget = target
                return
            }
            stand += 1
        }

        // Every target has been scored.
        currentStand = numberOfStands
        currentTarget = 0
        currentShooterIndex = 0
    }

    /// The first target the shooter has not yet scored on the stand, if any.
    private func firstUnscoredTarget(ofShooterAt index: Int, stand: Int) -> Int? {
        guard shooters.indices.contains(index), shooters[index].scores.indices.contains(stand) else { return nil }
        return shooters[index].scores[stand].firstIndex { $0 < 0 }
    }
}

/// Hands microphone buffers from the audio engine's tap to whichever recognition
/// request is current. The tap runs on a realtime audio thread, so the request is
/// swapped under a lock rather than read from main-actor state.
nonisolated final class RecognitionAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var bufferCount = 0
    private var hasSound = false

    /// True once any buffer has contained a non-zero sample. Stays false while
    /// the system hands over digital silence instead of real microphone audio.
    var hasDetectedSound: Bool {
        lock.withLock { hasSound }
    }

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.withLock {
            self.request = request
            bufferCount = 0
        }
    }

    /// Forgets that sound was heard, for when the microphone is rebuilt.
    func resetSoundDetection() {
        lock.withLock { hasSound = false }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (current, count, heardSoundBefore) = lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, Int, Bool) in
            bufferCount += 1
            return (request, bufferCount, hasSound)
        }
        current?.append(buffer)

        // Measure the level until real sound has been seen once, and for the
        // occasional logged buffer, so the console shows whether the microphone
        // is really delivering audio: a peak of exactly 0 means digital silence.
        let shouldLog = count == 1 || count % 200 == 0
        guard !heardSoundBefore || shouldLog else { return }
        let peak = Self.peakLevel(of: buffer)
        if peak > 0 {
            lock.withLock { hasSound = true }
        }
        if shouldLog {
            let format = buffer.format
            ShootViewModel.logger.info("Audio buffer \(count): \(buffer.frameLength) frames, \(format.sampleRate) Hz, \(format.channelCount) ch, common format \(format.commonFormat.rawValue), peak \(peak, format: .fixed(precision: 4)), request \(current == nil ? "none" : "set", privacy: .public)")
        }
    }

    /// The loudest sample in the buffer, from 0 (silence) to 1. Every sample
    /// format the microphone can deliver is handled, because a format that was
    /// not understood would look exactly like silence and raise a false alarm.
    /// Returns 1 for any format that cannot be read, so it is never mistaken for
    /// a silent microphone.
    private static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var peak: Float = 0

        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frames {
                peak = max(peak, abs(channel[index]))
            }
        } else if let channel = buffer.int16ChannelData?[0] {
            for index in 0..<frames {
                peak = max(peak, abs(Float(channel[index])) / Float(Int16.max))
            }
        } else if let channel = buffer.int32ChannelData?[0] {
            for index in 0..<frames {
                peak = max(peak, abs(Float(channel[index])) / Float(Int32.max))
            }
        } else {
            return 1
        }

        return peak
    }
}

/// Thrown when the audio engine's input has no usable format.
nonisolated struct NoMicrophoneError: Error {}
