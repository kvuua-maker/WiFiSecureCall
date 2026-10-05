import XCTest

/// Exercises the same task owner and commit point used by the production Watch dialer. Gates
/// deliberately ignore cancellation: correctness must not depend on URLSession responding promptly.
@MainActor
final class WatchCallHandoffCoordinatorTests: XCTestCase {
    private let evidence = WatchCallHandoffEvidence.withoutProvenPath(.validationFailed)

    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var count: Int { waiters.count }
        func wait() async { await withCheckedContinuation { waiters.append($0) } }
        func release() { waiters.removeFirst().resume() }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Main-actor task did not reach the expected state", file: file, line: line)
    }

    private func drain() async { for _ in 0..<20 { await Task.yield() } }

    func testClosingDuringPreparationCancelsAndRejectsLateResponse() async {
        let gate = Gate(), owner = UUID()
        let coordinator = WatchCallHandoffCoordinator()
        var cancelled = 0, opened = 0
        coordinator.screenDidAppear(owner: owner)
        XCTAssertTrue(coordinator.begin(owner: owner, prepare: {
            await gate.wait(); return self.evidence
        }, cancelPreparation: { cancelled += 1 }, handoff: { _ in opened += 1 }))
        await eventually { gate.count == 1 }
        coordinator.screenDidDisappear(owner: owner)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(coordinator.phase, .idle)
        gate.release()
        await drain()
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(coordinator.handoffCount, 0)
    }

    func testReturnAndRetryCannotBeCompletedOrUnlockedByOldRequest() async {
        let old = Gate(), new = Gate(), delay = Gate()
        let coordinator = WatchCallHandoffCoordinator(sleep: { _ in await delay.wait() })
        let oldOwner = UUID(), newOwner = UUID()
        var opened: [String] = []
        coordinator.screenDidAppear(owner: oldOwner)
        coordinator.begin(owner: oldOwner, prepare: {
            await old.wait(); return self.evidence
        }, cancelPreparation: {}, handoff: { _ in opened.append("old") })
        await eventually { old.count == 1 }
        coordinator.screenDidDisappear(owner: oldOwner)
        coordinator.screenDidAppear(owner: newOwner)
        XCTAssertTrue(coordinator.begin(owner: newOwner, prepare: {
            await new.wait(); return self.evidence
        }, cancelPreparation: {}, handoff: { _ in opened.append("new") }))
        await eventually { new.count == 1 }
        old.release()
        coordinator.screenDidDisappear(owner: oldOwner) // delayed callback from dismissed view
        await drain()
        XCTAssertEqual(coordinator.phase, .preparing)
        XCTAssertTrue(opened.isEmpty)
        new.release()
        await eventually { delay.count == 1 }
        XCTAssertEqual(opened, ["new"])
        XCTAssertEqual(coordinator.handoffCount, 1)
        delay.release()
        await eventually { !coordinator.isBusy }
    }

    func testRapidDoubleTapHasOnePreparationAndOneHandoffAndKeepsGuard() async {
        let preparation = Gate(), delay = Gate(), owner = UUID()
        let coordinator = WatchCallHandoffCoordinator(sleep: { _ in await delay.wait() })
        var opened = 0, prepared = 0
        coordinator.screenDidAppear(owner: owner)
        func tap() -> Bool {
            coordinator.begin(owner: owner, prepare: {
                prepared += 1; await preparation.wait(); return self.evidence
            }, cancelPreparation: {}, handoff: { _ in opened += 1 })
        }
        XCTAssertTrue(tap())
        XCTAssertFalse(tap())
        await eventually { preparation.count == 1 }
        preparation.release()
        await eventually { delay.count == 1 }
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(prepared, 1)
        XCTAssertFalse(tap(), "Guard must remain held after openSystemURL, before system transition")
        coordinator.applicationDidBecomeActive() // duplicate callback, not a return
        XCTAssertFalse(tap())
        delay.release()
        await eventually { !coordinator.isBusy }
    }

    func testSystemReturnReleasesHandoffEvenIfScreenWasDismissed() async {
        let delay = Gate(), owner = UUID()
        let coordinator = WatchCallHandoffCoordinator(sleep: { _ in await delay.wait() })
        coordinator.screenDidAppear(owner: owner)
        coordinator.begin(owner: owner, prepare: { self.evidence }, cancelPreparation: {}, handoff: { _ in })
        await eventually { delay.count == 1 }
        coordinator.screenDidDisappear(owner: owner)
        XCTAssertTrue(coordinator.isBusy)
        coordinator.applicationWillResignActive()
        XCTAssertTrue(coordinator.isBusy)
        coordinator.applicationDidBecomeActive()
        XCTAssertFalse(coordinator.isBusy)
        coordinator.screenDidAppear(owner: owner)
        let next = Gate()
        XCTAssertTrue(coordinator.begin(owner: owner, prepare: {
            await next.wait(); return self.evidence
        }, cancelPreparation: {}, handoff: { _ in XCTFail("Cancelled retry dialled") }))
        await eventually { next.count == 1 }
        delay.release() // cancelled old fallback cannot unlock this new preparation
        await drain()
        XCTAssertEqual(coordinator.phase, .preparing)
        coordinator.screenDidDisappear(owner: owner)
        next.release()
        await drain()
    }

    func testBackgroundDuringPreparationCancelsAndAllowsFreshRetry() async {
        let gate = Gate(), owner = UUID()
        let coordinator = WatchCallHandoffCoordinator()
        var cancelled = 0
        coordinator.screenDidAppear(owner: owner)
        coordinator.begin(owner: owner, prepare: {
            await gate.wait(); return self.evidence
        }, cancelPreparation: { cancelled += 1 }, handoff: { _ in XCTFail("Background attempt dialled") })
        await eventually { gate.count == 1 }
        coordinator.applicationWillResignActive()
        XCTAssertEqual(cancelled, 1)
        XCTAssertFalse(coordinator.begin(owner: owner, prepare: { self.evidence },
                                          cancelPreparation: {}, handoff: { _ in XCTFail() }))
        coordinator.applicationDidBecomeActive()
        gate.release()
        await drain()
        XCTAssertEqual(coordinator.handoffCount, 0)
        XCTAssertFalse(coordinator.isBusy)
        let retry = expectation(description: "fresh retry handed off")
        XCTAssertTrue(coordinator.begin(owner: owner, prepare: { self.evidence },
                                         cancelPreparation: {}, handoff: { _ in retry.fulfill() }))
        await fulfillment(of: [retry], timeout: 1)
        coordinator.applicationWillResignActive()
        coordinator.applicationDidBecomeActive()
    }

    func testRefusedSystemTransitionHasBoundedUnlockAndCanRetry() async {
        let delay = Gate(), owner = UUID()
        let coordinator = WatchCallHandoffCoordinator(sleep: { seconds in
            XCTAssertEqual(seconds, 3); await delay.wait()
        })
        coordinator.screenDidAppear(owner: owner)
        var opened = 0
        for expected in 1...2 {
            XCTAssertTrue(coordinator.begin(owner: owner, prepare: { self.evidence }, cancelPreparation: {}, handoff: {
                XCTAssertEqual($0, self.evidence, "Failed health check must not block the system route")
                opened += 1
            }))
            await eventually { delay.count == 1 }
            XCTAssertEqual(opened, expected)
            XCTAssertTrue(coordinator.isBusy)
            delay.release()
            await eventually { !coordinator.isBusy }
        }
        XCTAssertEqual(coordinator.handoffCount, 2)
    }

    func testReentrantSystemLifecycleCannotStrandButton() async {
        let coordinator = WatchCallHandoffCoordinator(), owner = UUID()
        coordinator.screenDidAppear(owner: owner)
        let opened = expectation(description: "system action")
        coordinator.begin(owner: owner, prepare: { self.evidence }, cancelPreparation: {}, handoff: { _ in
            XCTAssertTrue(coordinator.isBusy, "Guard must be committed before invoking the system")
            coordinator.applicationWillResignActive()
            coordinator.applicationDidBecomeActive()
            opened.fulfill()
        })
        await fulfillment(of: [opened], timeout: 1)
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(coordinator.handoffCount, 1)
    }
}

/// The watch keeps its radios switched off while the iPhone is not nearby, and nothing learned before a
/// sleep survives one. These are the rules that decide how much of the watch's own network is brought up
/// before a number is handed to the system, and they are values so they can be checked without a watch.
final class WatchCallPreparationTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func warm(_ at: Date? = nil) -> WatchCallPreparation {
        var preparation = WatchCallPreparation()
        preparation.observePath(.satisfied, at: start)
        preparation.validated(at: at ?? start)
        return preparation
    }

    // MARK: - The fast path exists only for a path that has actually been proven

    func testAFreshValidatedPathHandsOffImmediately() {
        XCTAssertEqual(warm().decision(now: start), .handOff)
    }

    func testAValidatedPathStillHandsOffWithoutWaiting() {
        let preparation = warm()
        XCTAssertEqual(preparation.decision(now: start.addingTimeInterval(2)).budget, 0)
    }

    func testNothingObservedYetIsWarmUpThenHandOff() {
        let preparation = WatchCallPreparation()
        XCTAssertEqual(preparation.decision(now: start), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        XCTAssertEqual(preparation.readiness(now: start), .unverified(.pathNotObserved))
    }

    func testAnUnsatisfiedPathIsWarmUpThenHandOffAndNamesTheReason() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.unsatisfied, at: start)
        XCTAssertEqual(preparation.decision(now: start), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        XCTAssertEqual(preparation.readiness(now: start), .unverified(.pathUnsatisfied))
    }

    func testASatisfiedPathWithNoRoundTripIsWarmUpThenHandOff() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.satisfied, at: start)
        XCTAssertEqual(preparation.decision(now: start), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        XCTAssertEqual(preparation.readiness(now: start), .unverified(.notValidated))
    }

    func testAFailedRoundTripNeverPretendsTheNetworkWorks() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.satisfied, at: start)
        preparation.validationFailed()
        XCTAssertEqual(preparation.decision(now: start), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        XCTAssertEqual(preparation.readiness(now: start), .unverified(.validationFailed))
    }

    func testAValidationOlderThanItsValidityIsNotTrusted() {
        // The path is still there and is observed again just before the decision, so the round trip alone is
        // what has gone stale.
        let now = start.addingTimeInterval(WatchCallPreparation.validationValidity + 1)
        var preparation = warm()
        preparation.observePath(.satisfied, at: now.addingTimeInterval(-1))
        XCTAssertEqual(preparation.decision(now: now), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        XCTAssertEqual(preparation.readiness(now: now), .unverified(.validationStale))
    }

    func testAPathObservationOlderThanItsValidityIsNotTrusted() {
        let preparation = warm()
        let now = start.addingTimeInterval(WatchCallPreparation.pathValidity + 1)
        XCTAssertEqual(preparation.decision(now: now), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        XCTAssertEqual(preparation.readiness(now: now), .unverified(.pathStale),
                       "A proof is not the problem when the observation it was made on is itself gone.")
    }

    func testAValidationCannotOutliveThePathItWasMadeOn() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.satisfied, at: start)
        preparation.validated(at: start)
        // A clock that moved backwards must not turn an old proof into a fresh one either.
        XCTAssertEqual(preparation.decision(now: start.addingTimeInterval(-5)), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
    }

    func testASuccessfulRoundTripOutranksAPathTheMonitorStillCallsDown() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.unsatisfied, at: start)
        preparation.validated(at: start.addingTimeInterval(1))
        XCTAssertEqual(preparation.decision(now: start.addingTimeInterval(1)), .handOff,
                       "Traffic either arrived or it did not.")
    }

    func testALateMonitorCallbackCannotUndoANewerObservation() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.satisfied, at: start)
        preparation.validated(at: start.addingTimeInterval(10))
        // The monitor's callback, delayed, describes a moment already overtaken.
        preparation.observePath(.unsatisfied, at: start.addingTimeInterval(2))
        XCTAssertEqual(preparation.decision(now: start.addingTimeInterval(10)), .handOff)
        XCTAssertEqual(preparation.pathObservedAt, start.addingTimeInterval(10))
    }

    func testAFreshMonitorReportThatSaysThePathWentAwayDoesDiscardTheProof() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.satisfied, at: start)
        preparation.validated(at: start.addingTimeInterval(1))
        preparation.observePath(.unsatisfied, at: start.addingTimeInterval(2))
        XCTAssertEqual(preparation.decision(now: start.addingTimeInterval(2)), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        XCTAssertNil(preparation.validatedAt)
    }

    // MARK: - Coming back from a lost network is a new attempt, not a restored one

    func testARadioThatChangesDropsTheProofMadeOverTheOldOne() {
        var preparation = warm()
        preparation.observePath(.unsatisfied, at: start.addingTimeInterval(1))
        XCTAssertEqual(preparation.decision(now: start.addingTimeInterval(1)), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        // The network comes back: the old success is not silently reused.
        preparation.observePath(.satisfied, at: start.addingTimeInterval(2))
        XCTAssertEqual(preparation.decision(now: start.addingTimeInterval(2)), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        preparation.validated(at: start.addingTimeInterval(3))
        XCTAssertEqual(preparation.decision(now: start.addingTimeInterval(3)), .handOff)
    }

    func testReObservingTheSamePathWithinItsValidityKeepsTheProof() {
        var preparation = warm()
        preparation.observePath(.satisfied, at: start.addingTimeInterval(2))
        XCTAssertEqual(preparation.decision(now: start.addingTimeInterval(2)), .handOff)
    }

    func testTheFirstObservationOfAPathIsAlwaysAChange() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.unknown, at: start)
        XCTAssertEqual(preparation.readiness(now: start), .unverified(.pathNotObserved))
    }

    func testLeavingTheForegroundDropsThePathButKeepsTheDialClaim() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.satisfied, at: start)
        preparation.validated(at: start)
        XCTAssertTrue(preparation.openAttempt())
        preparation.discardPathObservation()
        XCTAssertEqual(preparation.decision(now: start), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        XCTAssertFalse(preparation.openAttempt(), "A hand-off already in the system phone app still holds the claim.")
        XCTAssertNil(preparation.validatedAt)
    }

    func testAWakeAfterLeavingTheForegroundStillReleasesTheClaim() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.satisfied, at: start)
        preparation.validated(at: start)
        XCTAssertTrue(preparation.openAttempt())
        preparation.discardPathObservation()
        preparation.invalidateForWake(at: start.addingTimeInterval(5))
        XCTAssertTrue(preparation.openAttempt())
    }

    // MARK: - Nothing learned before a sleep survives it

    func testWakingDropsAProofThatWasValidAMomentEarlier() {
        var preparation = warm()
        let wake = start.addingTimeInterval(1)
        preparation.invalidateForWake(at: wake)
        XCTAssertEqual(preparation.decision(now: wake), .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget))
        XCTAssertEqual(preparation.readiness(now: wake), .unverified(.pathNotObserved))
    }

    func testAWakeIsFollowedByOneWarmUpAndThenTheFastPathReturns() {
        var preparation = warm()
        let wake = start.addingTimeInterval(1)
        preparation.invalidateForWake(at: wake)
        preparation.observePath(.satisfied, at: wake)
        preparation.validated(at: wake)
        XCTAssertEqual(preparation.decision(now: wake), .handOff)
    }

    func testAWakeReleasesADialClaimThatASuspensionStranded() {
        var preparation = WatchCallPreparation()
        XCTAssertTrue(preparation.openAttempt())
        XCTAssertFalse(preparation.openAttempt(), "One dial at a time.")
        preparation.invalidateForWake(at: start)
        XCTAssertTrue(preparation.openAttempt(), "A stranded claim must not outlive the app being resumed.")
    }

    func testAClosedClaimLetsTheNextTapAct() {
        var preparation = WatchCallPreparation()
        XCTAssertTrue(preparation.openAttempt())
        preparation.closeAttempt()
        XCTAssertTrue(preparation.openAttempt())
    }

    func testAClaimDoesNotChangeWhatADecisionSays() {
        var preparation = warm()
        preparation.openAttempt()
        XCTAssertEqual(preparation.decision(now: start), .handOff)
    }

    // MARK: - Preparation never refuses to dial

    func testNoPreparationOutcomeRefusesAHandoff() {
        // The system phone app and the carrier may have a path this app cannot see, so every decision is a
        // hand-off; what preparation controls is only how much network is brought up first.
        var preparation = WatchCallPreparation()
        for path in [WatchCallPathState.unknown, .satisfied, .unsatisfied] {
            preparation.observePath(path, at: start)
            XCTAssertEqual(preparation.decision(now: start),
                           .warmUpThenHandOff(budget: WatchCallPreparation.warmUpBudget), "\(path)")
        }
    }

    func testTheBudgetIsBoundedSoACallKeyCannotHang() {
        XCTAssertGreaterThan(WatchCallPreparation.warmUpBudget, 0)
        XCTAssertLessThanOrEqual(WatchCallPreparation.warmUpBudget, 5)
    }

    // MARK: - What a hand-off may be told about the path it used

    func testAHandOffOnAProvenPathCarriesTheProofAndNoCaution() {
        let evidence = warm().handOffEvidence()
        XCTAssertEqual(evidence, .withProvenPath(validatedAt: start))
        XCTAssertNil(evidence.caution)
    }

    func testAHandOffWithoutAProvenPathCarriesTheReason() {
        var preparation = WatchCallPreparation()
        preparation.observePath(.unsatisfied, at: start)
        XCTAssertEqual(preparation.handOffEvidence(), .withoutProvenPath(.pathUnsatisfied))
        XCTAssertNotNil(preparation.handOffEvidence().caution)
    }

    func testEveryBlockerSaysSomethingAboutTheWatchsOwnNetwork() {
        for blocker in [
            WatchCallPreparationBlocker.pathNotObserved,
            .pathUnsatisfied,
            .pathStale,
            .notValidated,
            .validationStale,
            .validationFailed
        ] {
            XCTAssertFalse(blocker.displayText.isEmpty, "\(blocker)")
            XCTAssertNotEqual(blocker.displayText, blocker.rawValue, "\(blocker)")
        }
    }

    // MARK: - The warm-up is counted, so a silent loop would be visible

    func testWarmUpsAreCounted() {
        var preparation = WatchCallPreparation()
        preparation.noteWarmUpStarted()
        preparation.noteWarmUpStarted()
        XCTAssertEqual(preparation.warmUpCount, 2)
    }
}
