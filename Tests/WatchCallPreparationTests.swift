import XCTest

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
