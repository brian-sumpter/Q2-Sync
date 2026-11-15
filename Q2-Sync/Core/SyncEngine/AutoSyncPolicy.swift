//
//  AutoSyncPolicy.swift
//  Q2-Sync › Core › SyncEngine
//
//  PURPOSE
//  Decides whether a sync that started on its own (auto-sync, or "Sync
//  Now" from a notification) may go ahead without you, or must stop and
//  wait for you to review it.
//
//  THE RULE
//  Auto-sync follows every safety rule, and anything that would normally
//  ask you something makes it STOP and wait instead. It goes ahead only if
//  all of these are true:
//    • it isn't this card's first sync (that's always a preview);
//    • no safety check failed (library health, free space);
//    • no songs you deselected would be removed;
//    • no songs Q2 Sync put on the card have left your library.
//  Music that's only on the card never blocks it: auto-sync always leaves
//  those files alone, and the notification tells you they're there.
//  Auto-sync never removes anything.
//
//  HOW IT FITS
//  `SyncCoordinator` asks this after planning an automatic sync.
//

import Foundation

/// What happens when a card connects.
enum AutoSyncMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Nothing; sync by hand.
    case off
    /// Show a notification with a "Sync Now" button.
    case ask
    /// Sync straight away, stopping for anything that needs review.
    case automatic

    var id: String { rawValue }

    /// Label for the setting.
    var title: String {
        switch self {
        case .off:       return "Do Nothing"
        case .ask:       return "Ask Me (Notification)"
        case .automatic: return "Sync Automatically"
        }
    }
}

/// The outcome of checking an automatic sync.
enum AutoSyncDecision: Sendable, Equatable {
    /// Safe to apply without asking.
    case apply
    /// Nothing to do: the card is up to date.
    case nothingToDo
    /// Must wait for the user. Each string is a user-facing reason.
    case needsReview([String])
}

/// The decision rules for automatic syncs.
enum AutoSyncPolicy {

    /// Decides whether an automatic sync may proceed.
    ///
    /// - Parameters:
    ///   - plan: The planned sync.
    ///   - assessment: The safety assessment with removals turned OFF.
    /// - Returns: The decision.
    static func decide(plan: SyncPlan, assessment: SafetyAssessment) -> AutoSyncDecision {
        var reasons: [String] = []
        if assessment.isDryRunOnly {
            reasons.append("This is the card's first sync, which is always a preview.")
        }
        reasons += assessment.blockers
        if !plan.removals.isEmpty {
            reasons.append("\(plan.removals.count) songs you deselected would be removed.")
        }
        if !plan.orphanedEntries.isEmpty {
            reasons.append("\(plan.orphanedEntries.count) songs on the card are no longer in your library.")
        }
        if !reasons.isEmpty { return .needsReview(reasons) }
        return plan.isEmpty ? .nothingToDo : .apply
    }
}
