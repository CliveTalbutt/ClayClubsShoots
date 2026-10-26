//
//  Shooter.swift
//  MyApp
//
//  Created by Clive Talbutt on 23/10/2026.
//


import Foundation

/// One competitor and their scores. Scores are stored as stands × targets, where
/// -1 means the target has not been shot yet, 0 is a miss and 1 is a hit. A pair
/// occupies two consecutive targets.
nonisolated struct Shooter: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var scores: [[Int]]

    init(name: String, standTargets: [Int]) {
        self.name = name
        self.scores = standTargets.map { Array(repeating: -1, count: $0) }
    }

    /// Changes the number of stands, keeping any scores already recorded on the
    /// stands that remain and adding empty stands as needed.
    mutating func resize(standTargets: [Int]) {
        if scores.count > standTargets.count { scores.removeLast(scores.count - standTargets.count) }
        for (i, n) in standTargets.enumerated() {
            if i >= scores.count { scores.append(Array(repeating: -1, count: n)) }
            else if scores[i].count > n { scores[i].removeLast(scores[i].count - n) }
            else if scores[i].count < n { scores[i].append(contentsOf: Array(repeating: -1, count: n - scores[i].count)) }
        }
    }

    /// Marks every target on one stand as not yet shot.
    mutating func clearStand(_ stand: Int) {
        guard scores.indices.contains(stand) else { return }
        scores[stand] = Array(repeating: -1, count: scores[stand].count)
    }

    /// Marks every target on every stand as not yet shot.
    mutating func clearAllScores() {
        for stand in scores.indices {
            clearStand(stand)
        }
    }

    /// Total for a single stand, counting only scored targets.
    func standTotal(_ stand: Int) -> Int {
        guard scores.indices.contains(stand) else { return 0 }
        return scores[stand].filter { $0 > 0 }.reduce(0, +)
    }

    /// Total across every stand.
    var grandTotal: Int {
        scores.flatMap { $0 }.filter { $0 > 0 }.reduce(0, +)
    }

    /// True once every target on every stand has been scored.
    var isComplete: Bool {
        scores.allSatisfy { $0.allSatisfy { $0 >= 0 } }
    }
}
