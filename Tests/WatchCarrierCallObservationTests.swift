import XCTest

/// The watch hands a number to the system and the system reports nothing back through that call site.
/// Every rule about what may be claimed afterwards is asserted here, on values, with no watch, no carrier,
/// no CallKit and no clock.
final class WatchCarrierCallObservationTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(id: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        outgoing: Bool = true,
        connected: Bool = false,
        ended: Bool = false,
        hold: Bool = false
    ) -> WatchCarrierCallSnapshot {
        .init(callID: id, isOutgoing: outgoing, hasConnected: connected, hasEnded: ended, onHold: hold)
    }

    // MARK: - A report needs a hand-off before it may say anything about a call

    func testAFreshReportClaimsNothing() {
        let report = WatchCarrierCallReport()
        XCTAssertEqual(report.verdict, .notRequested)
        XCTAssertFalse(report.isHandedOff)
        XCTAssertNil(report.handoffRequestedAt)
        XCTAssertNil(report.talkDuration)
        XCTAssertFalse(report.verdict.isConnectedEvidence)
    }

    func testACallReportedBeforeAnyHandoffIsNotEvidenceOfAnything() {
        var report = WatchCarrierCallReport()
        report.apply(snapshot(connected: true), isOwnProviderCall: false, at: start)
        XCTAssertEqual(report.verdict, .notRequested)
        XCTAssertNil(report.observedCallID)
        XCTAssertNil(report.observedConnectedAt)
    }

    func testAHandOffIsNotAConnectedCall() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        XCTAssertEqual(report.handoffRequestedAt, start)
        XCTAssertEqual(report.verdict, .awaitingOwnerConfirmation)
        XCTAssertFalse(report.verdict.isConnectedEvidence)
        XCTAssertTrue(report.isHandedOff)
    }

    // MARK: - The app's own CallKit call is never the carrier's call

    func testThisAppsOwnProviderCallIsCountedAndDropped() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(connected: true), isOwnProviderCall: true, at: start.addingTimeInterval(1))
        report.apply(snapshot(ended: true), isOwnProviderCall: true, at: start.addingTimeInterval(9))
        XCTAssertEqual(report.verdict, .awaitingOwnerConfirmation)
        XCTAssertNil(report.observedCallID)
        XCTAssertEqual(report.ignoredOwnProviderCallCount, 2)
    }

    func testASecondCallsReportsAreDroppedOnceTheCarrierCallIsKnown() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        let carrierID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        report.apply(snapshot(id: carrierID, connected: true), isOwnProviderCall: false, at: start.addingTimeInterval(2))
        report.apply(snapshot(id: carrierID, ended: true), isOwnProviderCall: false, at: start.addingTimeInterval(8))
        report.apply(snapshot(id: UUID(), connected: true), isOwnProviderCall: false, at: start.addingTimeInterval(9))
        XCTAssertEqual(report.observedCallID, carrierID)
        XCTAssertEqual(report.ignoredForeignCallCount, 1)
        XCTAssertEqual(report.verdict, .endedAfterConnecting)
    }

    // MARK: - What a reported call is allowed to claim

    func testAnOutgoingCallIsNotYetAConnectedCall() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(), isOwnProviderCall: false, at: start.addingTimeInterval(2))
        XCTAssertEqual(report.verdict, .observedOutgoing)
        XCTAssertFalse(report.verdict.isConnectedEvidence)
        XCTAssertNil(report.talkDuration)
    }

    func testAConnectedCallIsTheOnlyEvidenceOfDuplexAudio() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(), isOwnProviderCall: false, at: start.addingTimeInterval(2))
        report.apply(snapshot(connected: true), isOwnProviderCall: false, at: start.addingTimeInterval(4))
        XCTAssertEqual(report.verdict, .connected)
        XCTAssertTrue(report.verdict.isConnectedEvidence)
        XCTAssertEqual(report.observedConnectedAt, start.addingTimeInterval(4))
        XCTAssertNil(report.talkDuration, "Talk time needs an end as well as a connect.")
        report.apply(snapshot(connected: true, hold: true), isOwnProviderCall: false, at: start.addingTimeInterval(5))
        XCTAssertEqual(report.verdict, .connected, "A held call is still a call that connected.")
    }

    func testACallThatEndsAfterConnectingKeepsBothEnds() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(connected: true), isOwnProviderCall: false, at: start.addingTimeInterval(2))
        report.apply(snapshot(connected: true, ended: true), isOwnProviderCall: false, at: start.addingTimeInterval(32))
        XCTAssertEqual(report.verdict, .endedAfterConnecting)
        XCTAssertEqual(report.talkDuration, 30)
    }

    func testACallThatEndsBeforeConnectingIsNotAConnectedCall() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(connected: false, ended: true), isOwnProviderCall: false, at: start.addingTimeInterval(6))
        XCTAssertEqual(report.verdict, .endedBeforeConnecting)
        XCTAssertFalse(report.verdict.isConnectedEvidence)
        XCTAssertNil(report.observedConnectedAt)
        XCTAssertNil(report.talkDuration)
        XCTAssertEqual(report.verdict.severity, .warning)
    }

    func testAnEndNeverInventsAConnect() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(), isOwnProviderCall: false, at: start.addingTimeInterval(2))
        report.apply(snapshot(ended: true), isOwnProviderCall: false, at: start.addingTimeInterval(6))
        XCTAssertEqual(report.verdict, .endedBeforeConnecting)
        XCTAssertFalse(report.verdict.isConnectedEvidence)
        XCTAssertNil(report.observedConnectedAt)
    }

    func testAConnectReportedAfterTheEndIsStillAConnectTheSystemReported() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(connected: false, ended: true), isOwnProviderCall: false, at: start.addingTimeInterval(6))
        XCTAssertEqual(report.verdict, .endedBeforeConnecting)
        XCTAssertNil(report.observedConnectedAt)
        report.apply(snapshot(connected: true, ended: true), isOwnProviderCall: false, at: start.addingTimeInterval(7))
        XCTAssertEqual(report.verdict, .endedAfterConnecting)
        XCTAssertEqual(report.observedConnectedAt, start.addingTimeInterval(7))
        XCTAssertEqual(report.observedEndedAt, start.addingTimeInterval(6), "The end stays where the system first reported it.")
    }

    func testRepeatedReportsOfOneCallDoNotMoveItsFirstEvidence() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(connected: true), isOwnProviderCall: false, at: start.addingTimeInterval(2))
        report.apply(snapshot(connected: true), isOwnProviderCall: false, at: start.addingTimeInterval(3))
        XCTAssertEqual(report.observedConnectedAt, start.addingTimeInterval(2))
    }

    // MARK: - Absence of reports is not a report of a failed call

    func testComingBackWithNothingReportedIsNotAFailedCall() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.noteReturnedToApp(at: start.addingTimeInterval(40))
        XCTAssertEqual(report.verdict, .notObserved)
        XCTAssertFalse(report.verdict.isConnectedEvidence)
        XCTAssertNotEqual(report.verdict.severity, .neutral, "An unproven call must not read as plain progress.")
        XCTAssertNil(report.observedCallID)
    }

    func testComingBackAfterACallWasReportedDoesNotDowngradeIt() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(connected: true), isOwnProviderCall: false, at: start.addingTimeInterval(2))
        report.noteReturnedToApp(at: start.addingTimeInterval(40))
        XCTAssertEqual(report.verdict, .connected)
    }

    func testACallStillRunningWhenTheOwnerReturnsIsFound() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.noteReturnedToApp(at: start.addingTimeInterval(40))
        XCTAssertEqual(report.verdict, .notObserved)
        report.apply(snapshot(connected: true), isOwnProviderCall: false, at: start.addingTimeInterval(41))
        XCTAssertEqual(report.verdict, .connected, "A call that started while this app was suspended is still a call.")
    }

    func testAReturnBeforeAHandOffIsNotAReturnFromACall() {
        var report = WatchCarrierCallReport()
        report.noteReturnedToApp(at: start)
        XCTAssertNil(report.returnedToAppAt)
        XCTAssertEqual(report.verdict, .notRequested)
    }

    func testTheFirstReturnOnlyIsRecorded() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.noteReturnedToApp(at: start.addingTimeInterval(40))
        report.noteReturnedToApp(at: start.addingTimeInterval(90))
        XCTAssertEqual(report.returnedToAppAt, start.addingTimeInterval(40))
    }

    // MARK: - One report belongs to one number

    func testASecondHandoffForgetsTheFirstOne() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(connected: true, ended: true), isOwnProviderCall: false, at: start.addingTimeInterval(2))
        report.apply(snapshot(id: UUID(), connected: true), isOwnProviderCall: true, at: start.addingTimeInterval(3))
        report.requestHandoff(at: start.addingTimeInterval(60))
        XCTAssertEqual(report.verdict, .awaitingOwnerConfirmation)
        XCTAssertEqual(report.handoffRequestedAt, start.addingTimeInterval(60))
        XCTAssertNil(report.observedCallID)
        XCTAssertNil(report.observedConnectedAt)
        XCTAssertNil(report.observedEndedAt)
        XCTAssertEqual(report.ignoredOwnProviderCallCount, 0)
    }

    func testDiscardingReturnsTheReportToHavingSaidNothing() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.apply(snapshot(connected: true), isOwnProviderCall: false, at: start.addingTimeInterval(2))
        report.discard()
        XCTAssertEqual(report, WatchCarrierCallReport())
        XCTAssertFalse(report.isHandedOff)
    }

    // MARK: - Everything the screen can say is sayable

    func testEveryVerdictHasTextAndOnlyConnectedOnesClaimAudio() {
        let connected: Set<WatchCarrierCallVerdict> = [.connected, .endedAfterConnecting]
        for verdict in [
            WatchCarrierCallVerdict.notRequested,
            .awaitingOwnerConfirmation,
            .observedOutgoing,
            .connected,
            .endedAfterConnecting,
            .endedBeforeConnecting,
            .notObserved
        ] {
            XCTAssertFalse(verdict.displayText.isEmpty, "\(verdict)")
            XCTAssertEqual(verdict.isConnectedEvidence, connected.contains(verdict), "\(verdict)")
            XCTAssertNotEqual(verdict.displayText, verdict.rawValue, "\(verdict)")
        }
    }

    func testTheHandoffTextTellsTheOwnerTheCallHasNotStartedYet() {
        XCTAssertTrue(WatchCarrierCallVerdict.awaitingOwnerConfirmation.displayText.contains("Виклик"))
    }

    // MARK: - What the hand-off itself was given, so a later failure can be read

    func testAHandOffRemembersThePathItWasGiven() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.noteHandoffEvidence(.withoutProvenPath(.pathUnsatisfied))
        XCTAssertEqual(report.handoffEvidence, .withoutProvenPath(.pathUnsatisfied))
    }

    func testAProvenPathCarriesNoCaution() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.noteHandoffEvidence(.withProvenPath(validatedAt: start))
        XCTAssertNil(report.handoffEvidence?.caution)
    }

    func testASecondHandoffDoesNotInheritTheFirstPathsEvidence() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.noteHandoffEvidence(.withoutProvenPath(.validationFailed))
        report.requestHandoff(at: start.addingTimeInterval(60))
        XCTAssertNil(report.handoffEvidence, "A proof belongs to the number it was made for.")
    }

    func testDiscardingAlsoForgetsThePathEvidence() {
        var report = WatchCarrierCallReport()
        report.requestHandoff(at: start)
        report.noteHandoffEvidence(.withoutProvenPath(.pathUnsatisfied))
        report.discard()
        XCTAssertEqual(report, WatchCarrierCallReport())
    }
}
