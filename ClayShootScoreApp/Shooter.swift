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

    init(name: String, numberOfStands: Int, targetsPerStand: Int = 10) {
        self.name = name
        self.scores = Array(
            repeating: Array(repeating: -1, count: targetsPerStand),
            count: numberOfStands
        )
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
