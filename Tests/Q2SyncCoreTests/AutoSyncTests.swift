//
//  AutoSyncTests.swift
//  Q2-Sync › Tests
//
//  PURPOSE
//  Tests that automatic syncs stop for anything needing review, and only
//  go ahead when it's safe.
//

import Foundation
import Testing
@testable import Q2SyncCore

@Suite("Auto-sync policy")
struct AutoSyncPolicyTests {

    var addPlan: SyncPlan {
        var plan = SyncPlan()
        plan.copies = [CopyOperation(kind: .add, track: makeCopyableTrack(id: "1", title: "A"),
                                     destination: "Music/a.mp3", obsoletePath: nil, reason: nil)]
        return plan
    }

    @Test("Additions only, no problems: apply")
    func apply() {
        #expect(AutoSyncPolicy.decide(plan: addPlan, assessment: SafetyAssessment()) == .apply)
    }

    @Test("Nothing to do: up to date")
    func upToDate() {
        #expect(AutoSyncPolicy.decide(plan: SyncPlan(), assessment: SafetyAssessment()) == .nothingToDo)
    }

    @Test("First sync, blockers, removals and orphans each stop it")
    func stops() {
        var firstSync = SafetyAssessment(); firstSync.isDryRunOnly = true
        var blocked = SafetyAssessment(); blocked.blockers = ["Doesn't fit"]
        var withRemoval = addPlan
        withRemoval.removals = [RemoveOperation(trackID: "x", entry: makeEntry("Music/x.mp3"))]
        var withOrphan = addPlan
        withOrphan.orphanedEntries = [RemoveOperation(trackID: "y", entry: makeEntry("Music/y.mp3"))]

        for (plan, assessment) in [(addPlan, firstSync), (addPlan, blocked),
                                   (withRemoval, SafetyAssessment()), (withOrphan, SafetyAssessment())] {
            guard case .needsReview(let reasons) = AutoSyncPolicy.decide(plan: plan, assessment: assessment) else {
                Issue.record("Expected needsReview"); continue
            }
            #expect(!reasons.isEmpty)
        }
    }

    @Test("Card-only music doesn't stop it (it's left alone)")
    func cardOnlyAllowed() {
        var plan = addPlan
        plan.cardOnly = [CardOnlyItem(path: "Old/x.mp3", size: 1, origin: .unmanaged)]
        #expect(AutoSyncPolicy.decide(plan: plan, assessment: SafetyAssessment()) == .apply)
    }

    @Test("Older devices.json files default to Ask")
    func defaultMode() {
        let device = KnownDevice(volumeUUID: "U", name: "Q2", firmware: .q2Pod, bookmarkData: Data(),
                                 addedDate: .now, hasCompletedFirstSync: false)
        #expect(device.effectiveAutoSync == .ask)
    }
}
