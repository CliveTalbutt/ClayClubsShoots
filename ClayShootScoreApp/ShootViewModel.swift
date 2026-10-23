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

/// What the microphone is currently being used for.
enum ListeningMode {
    /// Listening for "hit", "miss", "pair hit" and "shooter <name>" commands.
    case scoring
    /// Listening for a new shooter's name after the Add Shooter button was pressed.
    case addingShooter
}

@Observable
class ShootViewModel {
    /// The number of stands in the shoot. Every shooter has this many rows of targets.
    static let numberOfStands = 5
    /// The number of targets shot on each stand.
    static let targetsPerStand = 10

    private static let shootNameKey = "shootName"

    /// User-editable name of the shoot, shown in the heading alongside today's date.
    /// Saved to user defaults so it survives relaunching the app.
    var shootName: String {
        didSet { UserDefaults.standard.set(shootName, forKey: Self.shootNameKey) }
    }

    init() {
        shootName = UserDefaults.standard.string(forKey: Self.shootNameKey) ?? "West Peckham Shoot"
    }

    /// The full heading, e.g. "West Peckham Shoot - 23 October 2026".
    var title: String {
        let today = Date.now.formatted(date: .long, time: .omitted)
        let name = shootName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? today : "\(name) - \(today)"
    }

    var shooters: [Shooter] = []
    var currentShooterIndex: Int? = nil
    var currentStand = 0
    var currentTarget = 0   // 0–9

    /// True while the audio engine is running and speech is being recognised.
    var isListening = false
    /// Whether the current (or last) listening session is for scoring or a new name.
    private(set) var listeningMode: ListeningMode = .scoring
    /// The most recent transcription heard from the microphone, for on-screen feedback.
    var transcript = ""
    /// A human-readable description of the last failure, if any.
    var errorMessage: String?

    /// True from pressing Add Shooter until the name is confirmed or cancelled.
    var isAddingShooter = false
    /// The name heard so far while adding a shooter. Editable by hand before confirming.
    var pendingShooterName = ""

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isStartingSession = false

    // Tracks which part of the transcript has already been scored, so the same
    // "hit" is not counted again every time the recogniser updates the sentence.
    private var processedWordCount = 0

    // Commits the spoken name once the speaker has paused for a moment.
    private var nameCommitTask: Task<Void, Never>?

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
            numberOfStands: Self.numberOfStands,
            targetsPerStand: Self.targetsPerStand
        )
    }

    /// A sensible default file name for the exported workbook.
    var exportFileName: String {
        let name = shootName.trimmingCharacters(in: .whitespaces)
        let date = Date.now.formatted(.iso8601.year().month().day())
        return (name.isEmpty ? "Shoot" : name) + " " + date
    }

    // MARK: - Shooters

    /// Starts listening for a spoken name to add as a new shooter.
    func startAddingShooter() {
        isAddingShooter = true
        pendingShooterName = ""
        startListening(mode: .addingShooter)
    }

    /// Adds the pending name (spoken or typed) as a new shooter and stops listening.
    func confirmPendingShooter() {
        let name = pendingShooterName.trimmingCharacters(in: .whitespacesAndNewlines)
        nameCommitTask?.cancel()
        nameCommitTask = nil
        isAddingShooter = false
        pendingShooterName = ""
        stopListening()
        guard !name.isEmpty else { return }
        addShooter(named: name)
    }

    func cancelAddingShooter() {
        nameCommitTask?.cancel()
        nameCommitTask = nil
        isAddingShooter = false
        pendingShooterName = ""
        stopListening()
    }

    func addShooter(named name: String) {
        shooters.append(
            Shooter(name: name.lowercased(),
                    numberOfStands: Self.numberOfStands,
                    targetsPerStand: Self.targetsPerStand)
        )
        if currentShooterIndex == nil {
            currentShooterIndex = 0
        }
    }

    // MARK: - Listening

    /// Starts listening for scoring commands.
    func startListening() {
        startListening(mode: .scoring)
    }

    private func startListening(mode: ListeningMode) {
        guard !isStartingSession else { return }
        if isListening {
            stopListening()
        }
        // Scoring always has a current shooter; default to the first on the list.
        if mode == .scoring, currentShooterIndex == nil, !shooters.isEmpty {
            selectShooter(at: 0)
        }
        listeningMode = mode
        errorMessage = nil
        transcript = ""
        isStartingSession = true

        Task {
            defer { isStartingSession = false }

            let speechAuthorized = await requestSpeechAuthorization()
            guard speechAuthorized else {
                errorMessage = "Speech recognition permission was not granted. Enable it in System Settings > Privacy & Security."
                return
            }

            let micAuthorized = await requestMicrophoneAuthorization()
            guard micAuthorized else {
                errorMessage = "Microphone permission was not granted. Enable it in System Settings > Privacy & Security."
                return
            }

            guard let recognizer, recognizer.isAvailable else {
                errorMessage = "Speech recognition is not available on this device right now."
                return
            }

            beginRecognition(with: recognizer)
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        isListening = false
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
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Recognition

    private func beginRecognition(with recognizer: SFSpeechRecognizer) {
        // A recognition request can only be used once, so create a fresh one each session.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        processedWordCount = 0

        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "No microphone input was found. Check that a microphone is connected and selected."
            return
        }

        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            node.removeTap(onBus: 0)
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
            return
        }

        isListening = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The recogniser calls back on a background queue; hop to the main actor
            // before touching any observable state.
            Task { @MainActor in
                guard let self, self.request === request else { return }
                if let result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    self.transcript = text
                    switch self.listeningMode {
                    case .scoring:
                        self.handleSpeech(text)
                    case .addingShooter:
                        self.handleNameSpeech(text, isFinal: result.isFinal)
                    }
                }
                if let error {
                    // Cancellation when the user taps Stop is expected; anything else is reported.
                    if self.isListening {
                        self.errorMessage = error.localizedDescription
                        self.stopListening()
                    }
                }
            }
        }
    }

    // MARK: - Name capture

    private func handleNameSpeech(_ text: String, isFinal: Bool) {
        var name = text
        // People often say "shooter John" or "add shooter John"; keep just the name.
        for prefix in ["add shooter", "shooter", "add"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        pendingShooterName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        nameCommitTask?.cancel()
        if isFinal {
            confirmPendingShooter()
            return
        }

        // Commit automatically once the speaker pauses for a couple of seconds.
        nameCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.isAddingShooter else { return }
            self.confirmPendingShooter()
        }
    }

    // MARK: - Command handling

    /// Applies a cumulative scoring transcript. Internal rather than private so the
    /// command handling can be exercised without a microphone.
    func handleSpeech(_ text: String) {
        // Only act on words that have arrived since the last time we processed the transcript.
        let words = text.split(separator: " ").map(String.init)
        guard words.count > processedWordCount else { return }
        let newWords = words[processedWordCount...]
        processedWordCount = words.count

        var phrase = newWords.joined(separator: " ")

        // Mentioning an existing shooter's name (with or without the word "shooter")
        // switches scoring to that shooter. Any scoring words in the same phrase,
        // such as "john hit", are still applied afterwards.
        if let match = matchShooter(in: phrase) {
            selectShooter(at: match.index)
            phrase = phrase
                .replacingOccurrences(of: match.matchedText, with: " ")
                .replacingOccurrences(of: "shooter", with: " ")
        }

        // "Lost" is the usual clay call for a miss, so "miss", "missed" and "lost" all
        // count as misses. A pair is two targets, so "pair hit", "pair lost",
        // "lost pair" and similar score the next two cells.
        let isPair = phrase.contains("pair")
        let isHit = phrase.contains("hit")
        let isMiss = Self.missWords.contains { phrase.contains($0) }

        if isHit {
            addScore(1)
            if isPair { addScore(1) }
        } else if isMiss {
            addScore(0)
            if isPair { addScore(0) }
        }
    }

    /// Words that mean a target was missed.
    private static let missWords = ["miss", "lost"]

    /// Finds a shooter mentioned in the phrase. Full names are tried first (longest
    /// first, so "john taylor" wins over "john"), then a first name on its own when
    /// it belongs to exactly one shooter.
    private func matchShooter(in phrase: String) -> (index: Int, matchedText: String)? {
        let words = phrase.split(separator: " ").map(String.init)

        let byLength = shooters.indices.sorted { shooters[$0].name.count > shooters[$1].name.count }
        for index in byLength {
            let name = shooters[index].name.lowercased()
            if !name.isEmpty, containsWholeWords(words, name.split(separator: " ").map(String.init)) {
                return (index, name)
            }
        }

        for word in words {
            let candidates = shooters.indices.filter {
                shooters[$0].name.lowercased().split(separator: " ").first.map(String.init) == word
            }
            if candidates.count == 1 {
                return (candidates[0], word)
            }
        }

        return nil
    }

    /// True if `sequence` appears as consecutive whole words inside `words`.
    private func containsWholeWords(_ words: [String], _ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, words.count >= sequence.count else { return false }
        for start in 0...(words.count - sequence.count)
        where Array(words[start..<(start + sequence.count)]) == sequence {
            return true
        }
        return false
    }

    /// Makes the given shooter current and resumes at their next unscored target
    /// on the current stand, so switching between shooters never overwrites scores.
    func selectShooter(at index: Int) {
        guard shooters.indices.contains(index) else { return }
        currentShooterIndex = index

        let scores = shooters[index].scores
        if scores.indices.contains(currentStand),
           let next = scores[currentStand].firstIndex(where: { $0 < 0 }) {
            currentTarget = next
        } else {
            currentTarget = Self.targetsPerStand
        }
    }

    private func addScore(_ value: Int) {
        guard let index = currentShooterIndex,
              shooters.indices.contains(index),
              shooters[index].scores.indices.contains(currentStand),
              currentTarget < Self.targetsPerStand else { return }

        shooters[index].scores[currentStand][currentTarget] = value

        currentTarget += 1

        if currentTarget >= Self.targetsPerStand {
            advanceToNextShooter()
        }
    }

    private func advanceToNextShooter() {
        guard let index = currentShooterIndex else { return }

        let nextIndex = index + 1

        if nextIndex < shooters.count {
            currentShooterIndex = nextIndex
            currentTarget = 0
        } else {
            currentStand += 1
            currentTarget = 0
            currentShooterIndex = 0
        }
    }
}
