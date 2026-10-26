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
    static let standOptions = Array(1...25)
    /// The pair counts that can be chosen: 2 to 10 pairs per stand.
    static let pairOptions = Array(2...10)
    static let defaultPairs = 5
    private static let pairsKey = "pairsPerStand"
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
    enum ShootOrder: String, CaseIterable, Identifiable {
        case asEntered, alphabetic, random
        var id: String { rawValue }
        var title: String {
            switch self {
            case .asEntered: "As entered"
            case .alphabetic: "Alphabetic"
            case .random: "Random"
            }
        }
    }

    var shootOrder: ShootOrder = .asEntered

    /// Puts the shooters in the chosen order before the shoot starts. Nothing is reordered once anyone has scored.
    func applyShootOrder() {
        guard !isStarted, shootOrder != .asEntered,
              !shooters.contains(where: { $0.scores.contains { $0.contains { $0 >= 0 } } }) else { return }
        switch shootOrder {
        case .alphabetic: shooters.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .random: shooters.shuffle()
        case .asEntered: break
        }
        if !shooters.isEmpty { selectShooter(at: 0) }
    }

    func applyRoster(_ selected: [RosterShooter]) {
        guard !isStarted else { return }
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

    /// Applies the website's current roster to shooters already in the shoot:
    /// colours follow member/guest changes, emails follow edits, and anyone whose
    /// membership expired or who was removed is greyed out (and dropped if they
    /// have not scored yet). Scored results are never removed.
    func syncRoster(_ roster: [RosterShooter]) {
        let byName = Dictionary(roster.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for index in shooters.indices.reversed() {
            let key = shooters[index].name.lowercased()
            guard kinds[key] != nil else { continue }
            if let entry = byName[key] {
                kinds[key] = entry.kind
                if emails[key] != entry.email { setEmail(entry.email, for: entry.name) }
            } else {
                let scored = shooters[index].scores.contains { $0.contains { $0 >= 0 } }
                if scored { kinds[key] = "expired" } else { removeShooter(at: index) }
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
        didSet {
            UserDefaults.standard.set(shootName, forKey: Self.shootNameKey)
            restoreStands(forShoot: shootName)
        }
    }

    /// The number of stands in the shoot. Every shooter has this many rows of targets.
    /// Changing it keeps the scores already recorded on the stands that remain.
    /// Saved to user defaults so it survives relaunching the app.
    var numberOfStands: Int {
        didSet {
            guard numberOfStands != oldValue else { return }
            if isStarted { numberOfStands = oldValue; return }
            UserDefaults.standard.set(numberOfStands, forKey: Self.numberOfStandsKey)
            rememberStands(numberOfStands, forShoot: shootName)
            applyStandCount()
        }
    }

    /// Pairs of targets on each new stand (default 5, so 10 targets). Changing it sets every stand.
    var pairsPerStand: Int = {
        let saved = UserDefaults.standard.integer(forKey: "pairsPerStand")
        return ShootViewModel.pairOptions.contains(saved) ? saved : ShootViewModel.defaultPairs
    }() {
        didSet {
            guard pairsPerStand != oldValue else { return }
            if isStarted { pairsPerStand = oldValue; return }
            UserDefaults.standard.set(pairsPerStand, forKey: Self.pairsKey)
            standPairs = Array(repeating: pairsPerStand, count: numberOfStands)
        }
    }

    /// Pairs on each stand; each stand can differ. Fixed once the shoot starts.
    var standPairs: [Int] = (UserDefaults.standard.array(forKey: "standPairsList") as? [Int]) ?? [] {
        didSet {
            guard standPairs != oldValue else { return }
            if isStarted { standPairs = oldValue; return }
            UserDefaults.standard.set(standPairs, forKey: "standPairsList")
            applyStandCount()
        }
    }

    func pairs(forStand stand: Int) -> Int {
        standPairs.indices.contains(stand) ? standPairs[stand] : pairsPerStand
    }
    func targets(forStand stand: Int) -> Int { pairs(forStand: stand) * 2 }
    var standTargets: [Int] { (0..<numberOfStands).map { targets(forStand: $0) } }
    /// The widest stand, in targets.
    var targetsPerStand: Int { standTargets.max() ?? pairsPerStand * 2 }

    func setPairs(_ pairs: Int, forStand stand: Int) {
        guard !isStarted, stand >= 0, stand < numberOfStands, Self.pairOptions.contains(pairs) else { return }
        var list = (0..<numberOfStands).map { self.pairs(forStand: $0) }
        list[stand] = pairs
        standPairs = list
    }

    private static let standsByShootKey = "standsByShoot"

    private static func shootKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func rememberStands(_ count: Int, forShoot name: String) {
        var map = (UserDefaults.standard.dictionary(forKey: Self.standsByShootKey) as? [String: Int]) ?? [:]
        map[Self.shootKey(name)] = count
        UserDefaults.standard.set(map, forKey: Self.standsByShootKey)
    }

    /// Switching to a shoot that has been run before restores its last stand count,
    /// but only while nothing is scored so no results are ever trimmed.
    private func restoreStands(forShoot name: String) {
        guard !hasAnyScore,
              let map = UserDefaults.standard.dictionary(forKey: Self.standsByShootKey) as? [String: Int],
              let count = map[Self.shootKey(name)], Self.standOptions.contains(count),
              count != numberOfStands else { return }
        numberOfStands = count
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
        restoreSnapshot()
        wireSpeaker()
    }

    // MARK: - Resuming after the app was closed

    /// How long after the last change a closed shoot is still picked up again on relaunch.
    static let resumeWindow: TimeInterval = 30 * 60
    private static let snapshotKey = "shootSnapshot"

    private struct Snapshot: Codable {
        struct Entry: Codable { var name: String; var scores: [[Int]] }
        var savedAt: Date
        var sessionId: String
        var shootStart: Date
        var shooters: [Entry]
        var currentShooterIndex: Int?
        var currentStand: Int
        var currentTarget: Int
        var kinds: [String: String]
        var started: Bool?
        var confirmed: [Int]?
        var handicapShoot: Bool?
        var handicaps: [String: Double]?
    }

    /// Changes whenever anything worth resuming changes, so the view can save on every change.
    var snapshotSignature: String {
        let rows = shooters.map { $0.name + ":" + $0.scores.map { $0.map(String.init).joined(separator: ",") }.joined(separator: "|") }
        return "\(isStarted)#\(rows.joined(separator: ";"))#\(currentShooterIndex ?? -1)#\(currentStand)#\(currentTarget)#\(shootSessionId)#\(kinds.count)"
    }

    /// Saves the shoot so a relaunch within the resume window carries on where it stopped.
    func saveSnapshot() {
        let snapshot = Snapshot(
            savedAt: .now, sessionId: shootSessionId, shootStart: shootStart,
            shooters: shooters.map { .init(name: $0.name, scores: $0.scores) },
            currentShooterIndex: currentShooterIndex, currentStand: currentStand,
            currentTarget: currentTarget, kinds: kinds, started: isStarted,
            confirmed: Array(confirmedStands).sorted(),
            handicapShoot: isHandicapShoot, handicaps: handicaps)
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: Self.snapshotKey) }
    }

    private func restoreSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: Self.snapshotKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snap.shooters.isEmpty,
              Date.now.timeIntervalSince(snap.savedAt) <= Self.resumeWindow else { return }
        shootSessionId = snap.sessionId
        shootStart = snap.shootStart
        kinds = snap.kinds
        if let rows = snap.shooters.first?.scores, !rows.isEmpty, rows.allSatisfy({ $0.count >= 4 && $0.count <= 20 && $0.count % 2 == 0 }) {
            standPairs = rows.map { $0.count / 2 }
        }
        shooters = snap.shooters.map { entry in
            var shooter = Shooter(name: entry.name, standTargets: standTargets)
            for (stand, row) in entry.scores.enumerated() where shooter.scores.indices.contains(stand) && row.count == shooter.scores[stand].count {
                shooter.scores[stand] = row
            }
            return shooter
        }
        currentShooterIndex = snap.currentShooterIndex.flatMap { shooters.indices.contains($0) ? $0 : nil }
        currentStand = min(max(snap.currentStand, 0), numberOfStands)
        currentTarget = min(max(snap.currentTarget, 0), max(targets(forStand: currentStand), 1) - 1)
        isStarted = snap.started ?? hasAnyScore
        confirmedSession = snap.sessionId
        isHandicapShoot = snap.handicapShoot ?? false
        handicaps = snap.handicaps ?? [:]
        // Shoots saved before stands needed confirming keep their completed stands locked.
        confirmedStands = Set(snap.confirmed ?? shooters.first.map { Array($0.scores.indices) }.map { $0.filter(isStandComplete) } ?? [])
    }

    /// The full heading, e.g. "West Peckham Shoot - 23 October 2026".
    var title: String {
        let today = shootStart.formatted(date: .long, time: .shortened)
        let name = shootName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? today : "\(name) - \(today)"
    }

    var shooters: [Shooter] = []

    /// True once "Start Shoot" has been pressed (here or on another device). From then on the
    /// shooters and the number of stands are fixed, and the shoot is on the server.
    private(set) var isStarted = false

    /// A handicap shoot ranks on net scores: each shooter's total less their handicap, which is
    /// their average score per stand over the last year times the number of stands. Set up before
    /// the shoot starts, fixed afterwards.
    var isHandicapShoot = false

    /// The tone of the remark added to the spoken end-of-stand announcement. Chosen in the shoot setup.
    enum FeedbackStyle: String, CaseIterable, Identifiable {
        case off, enthusiastic, sarcastic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .enthusiastic: "Enthusiastic"
            case .sarcastic: "Sarcastic"
            }
        }
    }

    var feedbackStyle: FeedbackStyle = FeedbackStyle(rawValue: UserDefaults.standard.string(forKey: "feedbackStyle") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "enthusiasticFeedback") ? .enthusiastic : .off) {
        didSet { UserDefaults.standard.set(feedbackStyle.rawValue, forKey: "feedbackStyle") }
    }

    /// Whether "Possible n" is shown and spoken before a stand's last pair. On by default.
    var announcePossibleScore: Bool = UserDefaults.standard.object(forKey: "announcePossible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(announcePossibleScore, forKey: "announcePossible") }
    }

    /// Identifier of the chosen announcer voice; empty means the best available British voice.
    var voiceID: String = UserDefaults.standard.string(forKey: "voiceID") ?? "" {
        didSet {
            UserDefaults.standard.set(voiceID, forKey: "voiceID")
            speaker.voiceID = voiceID
        }
    }

    /// Plays a short sample in the chosen voice.
    func previewVoice() {
        guard voiceID != Speaker.offID else { return }
        speaker.say("Pull! Welcome to the shoot.")
    }

    private func remark(for score: Int, outOf total: Int) -> String {
        let ratio = total > 0 ? Double(score) / Double(total) : 0
        let phrases: [String]
        switch (feedbackStyle, ratio) {
        case (.off, _): return ""
        case (.enthusiastic, 1): phrases = ["Absolutely magnificent! A perfect round!", "Spot on! Not a feather out of place!", "Brilliant! Every single one, well done sir!"]
        case (.enthusiastic, 0.9...): phrases = ["Splendid shooting!", "Jolly good show!", "Superb! Almost perfect!"]
        case (.enthusiastic, 0.7...): phrases = ["Well shot!", "Very good indeed!", "Nicely done!"]
        case (.enthusiastic, 0.5...): phrases = ["Not bad at all, keep it up!", "A solid effort, onwards!", "Steady as she goes!"]
        case (.enthusiastic, _): phrases = ["Chin up, the next one's yours!", "Never mind, plenty more to come!", "Shake it off, you'll get them next time!"]
        case (.sarcastic, 1): phrases = ["Oh, perfect. Do try not to let it go to your head.", "Flawless. Well, someone had to be.", "Every single one. How terribly dull for the rest of us."]
        case (.sarcastic, 0.9...): phrases = ["So close to perfect. Shame about that, really.", "Almost impressive. Almost.", "One little slip. We'll all remember it."]
        case (.sarcastic, 0.7...): phrases = ["Competent. How very average.", "Not terrible. Don't let that frighten you.", "Perfectly adequate. Congratulations, I suppose."]
        case (.sarcastic, 0.5...): phrases = ["Half of them. The clays must be so relieved.", "Mediocrity at its finest.", "Well, the clays certainly had a good day."]
        case (.sarcastic, _): phrases = ["Marvellous. Have you considered taking up croquet?", "The clays send their thanks for not being disturbed.", "Truly remarkable. I've seen pigeons shoot better."]
        }
        return phrases.randomElement() ?? ""
    }
    var handicapPeriod: HandicapPeriod = .lastYear
    private var handicapAverages: [String: Double] = [:]
    private(set) var handicaps: [String: Double] = [:]

    private static func handicapKey(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    func handicap(for name: String) -> Double { handicaps[Self.handicapKey(name)] ?? 0 }

    /// Total less handicap. Starts below zero on a handicap shoot and climbs as targets are hit.
    func netTotal(_ shooter: Shooter) -> Double {
        Double(shooter.grandTotal) - (isHandicapShoot ? handicap(for: shooter.name) : 0)
    }

    func totalText(_ shooter: Shooter) -> String {
        isHandicapShoot ? "\(Int(netTotal(shooter)))" : "\(shooter.grandTotal)"
    }

    /// Loads the last year's averages (when this is a handicap shoot) and then starts the shoot.
    func beginShoot(client: ClayShootsClient?) async {
        if isHandicapShoot, let client, let averages = try? await client.handicapAverages(period: handicapPeriod) {
            handicapAverages = Dictionary(averages.map { (Self.handicapKey($0.name), $0.average) }, uniquingKeysWith: { $1 })
        }
        startShoot()
    }

    /// Locks in the shooters and stands and begins the shoot.
    static let minimumShooters = 2
    var hasMinimumShooters: Bool { shooters.count >= Self.minimumShooters }

    func startShoot() {
        guard hasMinimumShooters, !isStarted else { return }
        if isHandicapShoot {
            handicaps = Dictionary(shooters.map { shooter in
                let key = Self.handicapKey(shooter.name)
                return (key, ((handicapAverages[key] ?? 0) * Double(numberOfStands) + 1e-9).rounded(.down))
            }, uniquingKeysWith: { $1 })
        }
        finishAddingShooters()
        isStarted = true
        saveSnapshot()
    }

    /// Stands this device scores, e.g. "1-3, 5". Blank means every stand. When several
    /// devices share a shoot each is given different stands so they never overwrite each other.
    var ownedStandsText: String = UserDefaults.standard.string(forKey: "ownedStands") ?? "" {
        didSet {
            UserDefaults.standard.set(ownedStandsText, forKey: "ownedStands")
            if currentStand < numberOfStands, !isStandOwned(currentStand) {
                currentStand = firstOwnedStand
                if let index = currentShooterIndex { selectShooter(at: index) }
            }
        }
    }

    /// The stands (counting from 0) this device scores; nil when it scores them all.
    var ownedStands: Set<Int>? {
        var set = Set<Int>()
        for part in ownedStandsText.split(whereSeparator: { ", ;".contains($0) }) {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 1 { set.insert(bounds[0] - 1) }
            else if bounds.count == 2, bounds[0] <= bounds[1] { (bounds[0]...bounds[1]).forEach { set.insert($0 - 1) } }
        }
        set = set.filter { $0 >= 0 && $0 < numberOfStands }
        return set.isEmpty ? nil : set
    }

    func isStandOwned(_ stand: Int) -> Bool { ownedStands?.contains(stand) ?? true }
    var firstOwnedStand: Int { ownedStands?.min() ?? 0 }

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
        if standPairs.count != numberOfStands {
            let fixed = (0..<numberOfStands).map { pairs(forStand: $0) }
            if fixed != standPairs { standPairs = fixed; return }
        }
        for index in shooters.indices {
            shooters[index].resize(standTargets: standTargets)
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

    /// The shoot is over for display purposes only once every target is scored and the last stand
    /// is locked, so the results and podium never appear while a stand can still be edited.
    var isFinished: Bool {
        isComplete && (0..<numberOfStands).allSatisfy { isStandLocked($0) }
    }

    /// Finishing position for each shooter, using competition ranking so that
    /// equal totals share a place. Empty until the shoot is complete.
    var placings: [Shooter.ID: Int] {
        guard isFinished else { return [:] }
        let ranked = shooters.sorted { netTotal($0) > netTotal($1) }
        var result: [Shooter.ID: Int] = [:]
        var lastTotal: Double?
        var lastPlace = 0
        for (index, shooter) in ranked.enumerated() {
            if netTotal(shooter) != lastTotal {
                lastPlace = index + 1
                lastTotal = netTotal(shooter)
            }
            result[shooter.id] = lastPlace
        }
        return result
    }

    /// Reads out every shooter's score and place, best first.
    func announceFinalResults() {
        let placings = placings
        guard !placings.isEmpty else { return }
        func ordinal(_ n: Int) -> String {
            let f = NumberFormatter()
            f.numberStyle = .ordinal
            f.locale = Locale(identifier: "en_GB")
            return f.string(from: NSNumber(value: n)) ?? "\(n)"
        }
        let ranked = shooters.sorted {
            (placings[$0.id] ?? 0, $0.name) < (placings[$1.id] ?? 0, $1.name)
        }
        // One utterance per place, so a long announcement can never be cut short before the last place.
        speaker.say("Final results.", interrupt: false)
        // Shooters on the same place are announced together: "Joint 1st, A and B, with 40."
        var announced = Set<Int>()
        for (index, shooter) in ranked.enumerated() {
            let place = placings[shooter.id] ?? (index + 1)
            guard announced.insert(place).inserted else { continue }
            let group = ranked.filter { (placings[$0.id] ?? 0) == place }
            let names = group.map { $0.name.capitalized }
            let score = isHandicapShoot ? "\(Int(netTotal(shooter))) net" : "\(shooter.grandTotal)"
            if names.count > 1 {
                let list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
                speaker.say("Joint \(ordinal(place)), \(list), with \(score).", interrupt: false)
            } else {
                speaker.say("\(ordinal(place)), \(names[0]), \(score).", interrupt: false)
            }
        }
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
            targetsPerStand: targetsPerStand
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
        guard !isStarted else { return }
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
        guard !name.isEmpty, !isFull, !isStarted else { return }
        shooters.append(
            Shooter(name: name.lowercased(),
                    standTargets: standTargets)
        )
        if currentShooterIndex == nil {
            currentShooterIndex = 0
        }
    }

    /// Removes one shooter and keeps scoring pointed at a sensible shooter.
    func removeShooter(at index: Int) {
        guard shooters.indices.contains(index), !isStarted else { return }
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
        standSummary = nil
        scoringPausedUntil = .distantPast
        isStarted = false
        isHandicapShoot = false
        handicaps = [:]
        handicapAverages = [:]
        confirmedStands = []
        editingStands = [:]
        shootSessionId = UUID().uuidString
        shooters.removeAll()
        currentShooterIndex = nil
        currentStand = firstOwnedStand
        currentTarget = 0
    }

    /// Ends the shoot: targets not yet scored count as misses, which completes every stand, so
    /// the final results show and all scoring is locked until a new shoot is started.
    func finishShoot() {
        guard !shooters.isEmpty else { return }
        for index in shooters.indices {
            for stand in shooters[index].scores.indices {
                for target in shooters[index].scores[stand].indices where shooters[index].scores[stand][target] < 0 {
                    shooters[index].scores[stand][target] = 0
                }
            }
        }
        isStarted = true
        confirmedSession = shootSessionId
        confirmedStands = Set(0..<numberOfStands)
        editingStands = [:]
        saveSnapshot()
    }

    /// Clears the finished shoot and gets ready for the next one, with a fresh session
    /// and the start time reset to now.
    func startNewShoot() {
        removeAllShooters()
        shootStart = Self.halfHour(.now)
        saveSnapshot()
    }

    /// Every shooter has scored every target on the stand.
    func isStandComplete(_ stand: Int) -> Bool {
        !shooters.isEmpty && shooters.indices.allSatisfy {
            shooters[$0].scores.indices.contains(stand) && firstUnscoredTarget(ofShooterAt: $0, stand: stand) == nil
        }
    }

    /// Stands this device has confirmed as finished, for the current shoot.
    private(set) var confirmedStands: Set<Int> = []
    private var confirmedSession = ""

    /// Stands where the scorer chose to keep editing, with when they last changed and their scores then.
    private var editingStands: [Int: (changed: Date, scores: String)] = [:]
    static let editLockDelay: TimeInterval = 2

    /// A stand is locked once it is complete and confirmed (or after 2 s without edits). Stands
    /// scored by other devices lock as soon as they are complete, since this device can't edit them.
    func isStandLocked(_ stand: Int) -> Bool {
        isStandComplete(stand) && (confirmedStands.contains(stand) || !isStandOwned(stand))
    }

    private func scoresKey(_ stand: Int) -> String {
        shooters.map { $0.scores.indices.contains(stand) ? $0.scores[stand].map(String.init).joined(separator: ",") : "" }.joined(separator: "|")
    }

    /// Call whenever scores change and about once a second: asks about newly completed stands and
    /// locks stands that have sat unedited for the delay after the scorer chose to keep editing.
    func evaluateStandCompletion() {
        if confirmedSession != shootSessionId {
            confirmedSession = shootSessionId
            confirmedStands = []
            editingStands = [:]
            }
        guard isStarted, !shooters.isEmpty else { return }

        // A finished stand stays editable until scoring moves on: any score on a later stand locks it.
        for stand in 0..<numberOfStands where isStandComplete(stand) && !confirmedStands.contains(stand) && hasScores(afterStand: stand) {
            confirmedStands.insert(stand)
            editingStands[stand] = nil
            saveSnapshot()
        }

        // The last stand has no later stand, so once complete it locks after 2 s without edits.
        let last = numberOfStands - 1
        if last >= 0, isStandComplete(last), !confirmedStands.contains(last) {
            let key = scoresKey(last)
            if let state = editingStands[last], state.scores == key {
                if Date.now.timeIntervalSince(state.changed) >= Self.editLockDelay {
                    editingStands[last] = nil
                    confirmedStands.insert(last)
                    saveSnapshot()
                }
            } else {
                editingStands[last] = (.now, key)
            }
        } else if last >= 0 {
            editingStands[last] = nil
        }
    }

    private func hasScores(afterStand stand: Int) -> Bool {
        shooters.contains { shooter in
            shooter.scores.indices.contains { $0 > stand && shooter.scores[$0].contains { $0 >= 0 } }
        }
    }

    /// Wipes a shooter's scores, either on one stand or on every stand, and moves
    /// scoring to that shooter at the first cleared stand so it can be shot again.
    func clearScores(ofShooterAt index: Int, stand: Int? = nil) {
        guard shooters.indices.contains(index) else { return }
        if let stand, isStandLocked(stand) {
            errorMessage = "Stand \(stand + 1) is complete for all shooters and can no longer be changed."
            return
        }
        if stand == nil, let locked = shooters[index].scores.indices.first(where: { isStandLocked($0) }) {
            errorMessage = "Stand \(locked + 1) is complete for all shooters and can no longer be changed."
            return
        }
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
    /// False while any screen other than the scoresheet is showing (home, roster, settings, past results).
    private(set) var voiceAllowed = true

    func setVoiceAllowed(_ allowed: Bool) {
        guard allowed != voiceAllowed else { return }
        voiceAllowed = allowed
        if allowed {
            resumeListening()
        } else {
            retryTask?.cancel()
            retryTask = nil
            speechResumeTask?.cancel()
            pausedForSpeech = false
            if isListening || isStartingSession { stopListening() }
        }
    }

    func resumeListening() {
        isInBackground = false
        guard voiceAllowed, !isListening, !isStartingSession else { return }
        startListening(mode: isAddingShooter ? .addingShooter : .scoring)
    }

    private func startListening(mode: ListeningMode) {
        guard voiceAllowed, !isStartingSession, !isInBackground else { return }
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
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
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
        if speaker.isBusy {
            processedWordCount = words.count
            return
        }
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
        // The app's own spoken dialogues are picked up by the microphone; never score them.
        if speaker.isBusy {
            processedWordCount = words.count
            return
        }
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
            if currentStand < numberOfStands, currentTarget >= targets(forStand: currentStand) {
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
        guard isStandOwned(stand) else {
            errorMessage = "Stand \(stand + 1) is scored by another device."
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
        } else if isStarted {
            errorMessage = "The shoot has started, so shooters can no longer be removed."
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
            currentTarget = targets(forStand: currentStand)
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
        addScore(value, announce: true)
    }

    /// `announce` is for key and button entries; voice scoring stays silent.
    private func addScore(_ value: Int, announce: Bool = false) {
        guard let index = currentShooterIndex,
              shooters.indices.contains(index),
              shooters[index].scores.indices.contains(currentStand),
              isStandOwned(currentStand),
              currentTarget < targets(forStand: currentStand),
              Date.now >= scoringPausedUntil else { return }

        // Always use the first free entry; never overwrite a score that is already there.
        guard let free = firstUnscoredTarget(ofShooterAt: index, stand: currentStand) else { return }
        currentTarget = free

        shooters[index].scores[currentStand][currentTarget] = value
        // Confirmation beep for every recorded score, spoken or manual.
        AudioServicesPlaySystemSound(1057)
        UINotificationFeedbackGenerator().notificationOccurred(value == 1 ? .success : .warning)
        if announce { speaker.say(value == 1 ? "Hit" : "Miss") }

        currentTarget = firstUnscoredTarget(ofShooterAt: index, stand: currentStand) ?? targets(forStand: currentStand)

        if currentTarget == targets(forStand: currentStand) - 2 {
            announcePossible(shooterIndex: index, stand: currentStand)
        }
        if currentTarget >= targets(forStand: currentStand) {
            let finished = (index: index, stand: currentStand)
            advanceToNextShooter()
            announceStandDone(shooterIndex: finished.index, stand: finished.stand)
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
            if isStandOwned(stand),
               let shooter = shooters.indices.first(where: { firstUnscoredTarget(ofShooterAt: $0, stand: stand) != nil }),
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

    // MARK: Shared shoot

    private func scores(fromPatterns patterns: [String], stand: Int) -> [Int]? {
        guard patterns.indices.contains(stand), patterns[stand].count >= targets(forStand: stand) else { return nil }
        return patterns[stand].prefix(targets(forStand: stand)).map { $0 == "1" ? 1 : ($0 == "0" ? 0 : -1) }
    }

    private func makeShooter(from entry: RemoteShoot.Entry) -> Shooter {
        var shooter = Shooter(name: entry.name, standTargets: standTargets)
        for stand in shooter.scores.indices {
            if let row = scores(fromPatterns: entry.patterns, stand: stand) { shooter.scores[stand] = row }
        }
        return shooter
    }

    /// Replaces the scoresheet with the club's current shoot from the server.
    func adoptRemote(_ remote: RemoteShoot) {
        isStarted = false
        shootSessionId = remote.externalId
        shootName = remote.name
        venue = remote.venue ?? ""
        let parts = (remote.time ?? "00:00").split(separator: ":").compactMap { Int($0) }
        var components = DateComponents()
        let day = remote.date.split(separator: "-").compactMap { Int($0) }
        if day.count == 3, parts.count == 2 {
            components.year = day[0]; components.month = day[1]; components.day = day[2]
            components.hour = parts[0]; components.minute = parts[1]
            if let start = Calendar.current.date(from: components) { shootStart = start }
        }
        numberOfStands = remote.stands
        let remoteTargets = remote.standTargets ?? Array(repeating: remote.targetsPerStand, count: remote.stands)
        if remoteTargets.count == remote.stands, remoteTargets.allSatisfy({ $0 >= 4 && $0 <= 20 && $0 % 2 == 0 }) {
            standPairs = remoteTargets.map { $0 / 2 }
        }
        isHandicapShoot = remote.handicap ?? false
        handicaps = Dictionary(remote.shooters.compactMap { e in e.handicap.map { (Self.handicapKey(e.name), $0) } }, uniquingKeysWith: { $1 })
        shooters = remote.shooters.map { makeShooter(from: $0) }
        currentShooterIndex = nil
        currentStand = firstOwnedStand
        currentTarget = 0
        if !shooters.isEmpty {
            selectShooter(at: shooters.indices.first { firstUnscoredTarget(ofShooterAt: $0, stand: currentStand) != nil } ?? 0)
        }
        // A shoot on the server has always been started.
        isStarted = true
        saveSnapshot()
    }

    /// Brings in what other devices scored on the stands this device does not own, and any
    /// shooters they added. Stands owned by this device are never overwritten.
    /// With `includeOwned` (nothing of ours is waiting to send) the server copy wins on every
    /// stand, so a change made by any other app shows here too.
    func mergeRemote(_ remote: RemoteShoot, includeOwned: Bool = false) {
        guard remote.externalId == shootSessionId else { return }
        func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if remote.handicap == true {
            if !isHandicapShoot { isHandicapShoot = true }
            for e in remote.shooters {
                if let h = e.handicap, handicaps[Self.handicapKey(e.name)] != h { handicaps[Self.handicapKey(e.name)] = h }
            }
        }
        var lastChange: (shooter: Int, stand: Int)?
        var changedStands = Set<Int>()
        for entry in remote.shooters {
            if let index = shooters.firstIndex(where: { key($0.name) == key(entry.name) }) {
                for stand in shooters[index].scores.indices where includeOwned || !isStandOwned(stand) {
                    if let row = scores(fromPatterns: entry.patterns, stand: stand), shooters[index].scores[stand] != row {
                        shooters[index].scores[stand] = row
                        lastChange = (index, stand)
                        changedStands.insert(stand)
                    }
                }
            } else if !isAddingShooter {
                shooters.append(makeShooter(from: entry))
                if currentShooterIndex == nil { selectShooter(at: 0) }
            }
        }
        // A stand closed by scores that arrived from another device is locked here without asking;
        // only the device that entered the closing scores is asked to confirm.
        for stand in changedStands where isStandComplete(stand) && !confirmedStands.contains(stand) {
            confirmedStands.insert(stand)
            editingStands[stand] = nil
        }
        if let lastChange { followRemoteChange(shooter: lastChange.shooter, stand: lastChange.stand) }
    }

    /// Keeps the focus magnifier on live action after scores arrive from another device: it
    /// steps past anything that was just filled in, and when this device has nothing left of its
    /// own to score it follows the other device to its stand and shooter.
    private func followRemoteChange(shooter: Int, stand: Int) {
        guard isStarted, !isComplete, !isAddingShooter else { return }

        if isStandOwned(currentStand), let current = currentShooterIndex,
           let target = firstUnscoredTarget(ofShooterAt: current, stand: currentStand) {
            currentTarget = target
            return
        }

        let ownedWorkLeft = (0..<numberOfStands).contains { owned in
            isStandOwned(owned) && shooters.indices.contains { firstUnscoredTarget(ofShooterAt: $0, stand: owned) != nil }
        }
        if ownedWorkLeft {
            if isStandOwned(currentStand) { advanceToNextShooter() }
            return
        }

        // Follow the remote scorer: the next shooter still to shoot on that stand, else the one just scored.
        let order = Array((shooter + 1)..<shooters.count) + Array(0...shooter)
        let next = order.first { firstUnscoredTarget(ofShooterAt: $0, stand: stand) != nil }
        currentStand = stand
        currentShooterIndex = next ?? shooter
        currentTarget = firstUnscoredTarget(ofShooterAt: currentShooterIndex ?? shooter, stand: stand) ?? 0
        selectionCount += 1
    }

    /// After a score is entered by hand, moves on to the next shooter (or stand) once
    /// that shooter has scored every target on the stand, as spoken scoring does.
    func advanceIfStandComplete(shooterIndex: Int, stand: Int) {
        guard shooterIndex == currentShooterIndex, stand == currentStand,
              firstUnscoredTarget(ofShooterAt: shooterIndex, stand: stand) == nil else { return }
        advanceToNextShooter()
        announceStandDone(shooterIndex: shooterIndex, stand: stand)
    }

    /// Shown briefly when a shooter finishes a stand: what they scored and who is up next.
    @ObservationIgnored private let speaker: Speaker = {
        let speaker = Speaker()
        speaker.voiceID = UserDefaults.standard.string(forKey: "voiceID") ?? ""
        return speaker
    }()
    @ObservationIgnored private var pausedForSpeech = false
    @ObservationIgnored private var speechResumeTask: Task<Void, Never>?

    /// The microphone is switched off while the app is talking and back on shortly after.
    private func wireSpeaker() {
        speaker.onStart = { [weak self] in
            guard let self else { return }
            self.speechResumeTask?.cancel()
            if self.isListening, !self.pausedForSpeech {
                self.pausedForSpeech = true
                self.stopListening()
            }
        }
        speaker.onEnd = { [weak self] in
            guard let self, self.pausedForSpeech else { return }
            self.speechResumeTask?.cancel()
            self.speechResumeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                // Keeps trying until the microphone is really back on.
                for _ in 0..<20 {
                    guard let self, !Task.isCancelled, self.pausedForSpeech else { return }
                    if self.isInBackground || self.isListening { break }
                    if !self.isStartingSession { self.resumeListening() }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                self?.pausedForSpeech = false
            }
        }
    }

    struct StandSummary: Equatable {
        let id = UUID()
        let shooter: String
        let stand: Int
        let score: Int
        let total: Int
        let next: String
        /// Set for the brief "Possible" card shown before a shooter's final pair.
        var possible: Int? = nil
    }
    var standSummary: StandSummary?

    /// Scoring input (voice, keys) is ignored until this time, so entries meant for the shooter
    /// who just finished are not recorded against the next one.
    private var scoringPausedUntil = Date.distantPast
    static let summaryDuration: TimeInterval = 3
    private static let inputSettleTime: TimeInterval = 0.7

    private func announceStandDone(shooterIndex: Int, stand: Int) {
        guard shooters.indices.contains(shooterIndex), shooters[shooterIndex].scores.indices.contains(stand) else { return }
        let shooter = shooters[shooterIndex]
        let next: String
        if isComplete || currentStand >= numberOfStands || !shooters.indices.contains(currentShooterIndex ?? -1) {
            next = "All targets scored"
        } else if let nextIndex = currentShooterIndex {
            let name = shooters[nextIndex].name.capitalized
            next = currentStand == stand ? "Next: \(name)" : "Next: \(name) on stand \(currentStand + 1)"
        } else {
            next = ""
        }
        let score = shooter.standTotal(stand)
        let cheer = feedbackStyle == .off ? "" : " " + remark(for: score, outOf: shooter.scores[stand].count)
        let said = "\(shooter.name.capitalized), \(score) on stand \(stand + 1).\(cheer)"
        standSummary = StandSummary(shooter: shooter.name.capitalized, stand: stand + 1, score: score,
                                    total: shooter.scores[stand].count, next: next)
        speaker.say(next.hasPrefix("Next: ") ? "\(said) Next shooter, \(next.dropFirst(6))." : "\(said) \(next)", interrupt: false)
        scoringPausedUntil = Date.now.addingTimeInterval(Self.summaryDuration + Self.inputSettleTime)
        AudioServicesPlaySystemSound(1025)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Before the final pair: the stand score the shooter reaches if both targets are hit.
    /// Input is not paused, so the pair can be scored straight away.
    private func announcePossible(shooterIndex: Int, stand: Int) {
        guard announcePossibleScore, shooters.indices.contains(shooterIndex), shooters[shooterIndex].scores.indices.contains(stand) else { return }
        let row = shooters[shooterIndex].scores[stand]
        guard row.prefix(max(row.count - 2, 0)).allSatisfy({ $0 >= 0 }) else { return }
        standSummary = StandSummary(shooter: shooters[shooterIndex].name.capitalized, stand: stand + 1,
                                    score: shooters[shooterIndex].standTotal(stand), total: row.count, next: "",
                                    possible: shooters[shooterIndex].standTotal(stand) + 2)
        speaker.say("Possible \(shooters[shooterIndex].standTotal(stand) + 2)", interrupt: false)
    }

    func dismissStandSummary() {
        standSummary = nil
        scoringPausedUntil = Date.now.addingTimeInterval(Self.inputSettleTime)
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

/// Speaks the app's dialogues. `isBusy` stays true shortly after speech ends so the microphone's
/// echo of the voice is not mistaken for scoring.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var speaking = false
    private var quietAt = Date.distantPast

    static let offID = "off"
    var voiceID = ""

    /// Up to five female and five male English voices, best quality and British accents first.
    static func voiceChoices() -> (female: [AVSpeechSynthesisVoice], male: [AVSpeechSynthesisVoice]) {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func ranked(_ gender: AVSpeechSynthesisVoiceGender) -> [AVSpeechSynthesisVoice] {
            var seen = Set<String>()
            return english.filter { $0.gender == gender }
                .sorted {
                    let a = ($0.language == "en-GB" ? 100 : 0) + $0.quality.rawValue * 10
                    let b = ($1.language == "en-GB" ? 100 : 0) + $1.quality.rawValue * 10
                    return a != b ? a > b : $0.name < $1.name
                }
                .filter { seen.insert($0.name).inserted }
                .prefix(5).map { $0 }
        }
        return (ranked(.female), ranked(.male))
    }

    private var currentVoice: AVSpeechSynthesisVoice? {
        if !voiceID.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: voiceID) { return chosen }
        let british = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
        return british.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    var isBusy: Bool { speaking || Date.now < quietAt }
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Hits and misses cut across whatever is being said; announcements queue behind them.
    func say(_ text: String, interrupt: Bool = true) {
        guard voiceID != Speaker.offID else { return }
        if interrupt { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = currentVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.pitchMultiplier = 0.92
        utterance.postUtteranceDelay = 0.1
        speaking = true
        quietAt = Date.now.addingTimeInterval(60)
        onStart?()
        synthesizer.speak(utterance)
    }

    private func finished() {
        guard !synthesizer.isSpeaking else { return }
        speaking = false
        quietAt = Date.now.addingTimeInterval(0.8)
        onEnd?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished() }
}
