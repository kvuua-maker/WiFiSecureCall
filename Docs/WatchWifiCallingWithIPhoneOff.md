# Calling an ordinary number from Apple Watch with the iPhone switched off

## What the platform does, in the app's own terms

The dialpad's green key hands a number to watchOS. Everything after that belongs to the system and to the
carrier, and the app can only watch. This is the whole route, and each step is a documented platform
behaviour rather than an assumption:

1. **`tel:` hand-off — `WKApplication.openSystemURL(_:)`** (watchOS 7+).
   `Watch/…/placePhoneCall()` builds `tel:` from the typed number and calls it. Apple: *"The URL you open is
   sent to the appropriate system app for handling, at which point the user can choose whether to continue
   the operation."* The function returns `Void`, so the app learns nothing from the call itself.
2. **Owner confirmation in the system Phone app.** Because the user chooses whether to continue, watchOS
   shows its own confirmation (Cancel / the number / Call) before anything is placed. Until that tap the
   call does not exist. Build 206 reported this state as *"Передано системному телефону."*, which reads as a
   finished call; the screen now states that the call has not started yet.
3. **Carrier call over Wi-Fi.** Apple documents this route for the watch: *"If your cellular carrier offers
   Wi-Fi calling, you can use your Apple Watch to make and receive calls over Wi-Fi instead of the cellular
   network — even when your paired iPhone isn't with you or is turned off. Your Apple Watch just has to be
   within range of a Wi-Fi network that your iPhone has connected to in the past."* Setup is on the iPhone:
   Settings → Phone/Cellular → Wi-Fi Calling → **Wi-Fi Calling on This iPhone** and **Add Wi-Fi Calling For
   Other Devices** (a.k.a. Allow Calls on Other Devices). *"Wi-Fi Calling is enabled automatically for Apple
   Watch when you turn on Allow Calls on Other Devices."*
   The voice path is the carrier's IMS registration over Wi-Fi; the watch microphone and speaker are the
   endpoints. No app code is involved in the audio, which is why the app cannot improve its quality and
   must not claim to have produced it.
4. **Evidence — `CXCallObserver` on watchOS.** `CXCallObserver` and `CXCall` are available from **watchOS
   9.0** (this app's deployment target is 9.2) and Apple documents that *"any app can create a new
   `CXCallObserver` object to be notified of any calls activity on the system."* `CXCall` exposes
   `isOutgoing`, `hasConnected`, `hasEnded`. This is the only public signal a watch app can get about the
   call its own hand-off asked for, and it is what the Build 207 screen reports instead of a hand-off
   message.

## What the code does with those four steps

- `Shared/WatchCarrierCallObservation.swift` — the verdict rules as values. `.connected` and
  `.endedAfterConnecting` exist **only** where the system reported `hasConnected`; nothing else may be read
  as proof that two-way audio happened. Reports about this app's own CallKit call, and about a second call,
  are counted and dropped.
- `Shared/WatchCarrierCallRequirements.swift` — the conditions the app can establish itself (watch network,
  a Wi-Fi path, pairing) and the conditions it cannot (carrier Wi-Fi calling, *Add Wi-Fi Calling For Other
  Devices*, whether the iPhone has ever joined the current Wi-Fi). The three latter are reported as
  `notDetectable` with the owner step that satisfies them. No row is ever claimed `satisfied` without
  evidence.
- `Watch/WatchCarrierCallObserver.swift` — the `CXCallObserver` delegate for the whole app lifetime; the
  report only fills after a hand-off.
- `Watch/WatchSecureDialerView.swift` — the green key records the hand-off, then shows the verdict and the
  requirements. The verdict replaces the editing hint while a number is being called, and is discarded when
  the number changes, so a report can never describe a different number.
- `Watch/WatchCallKitAdapter.swift` — registers this app's own `CXProvider` call IDs in
  `WatchOwnProviderCallLedger`, so an app-to-app call can never be reported as the carrier's.
- `Watch/WatchNotificationController.swift` — starts the observer at launch and re-reads it when the owner
  returns from the Phone app.

## The limit that is not a bug

While the system Phone app is frontmost this app is suspended, so no CallKit report can arrive during the
call. If the owner returns and nothing was observed, the screen says `notObserved` and states that this is
not proof of a failed call — absence of a report is not a report of a failed call. A call that is still
running when the owner returns *is* found, because `CXCallObserver.calls` is re-read on becoming active.

## Carrier availability in Ukraine, as far as public sources go

Apple's own carrier lists, read for this work:

| Source | Ukraine |
| --- | --- |
| Wireless carrier support for iPhone (`support.apple.com/en-us/108048`) | Kyivstar: eSIM, FaceTime over Cellular, LTE, Personal Hotspot. Lifecell: FaceTime, Personal Hotspot. **Vodafone: eSIM, FaceTime over Cellular, LTE, Personal Hotspot, VoLTE, Wi-Fi Calling.** |
| Apple Watch cellular carriers (`apple.com/watch/cellular/`) | **lifecell only.** |

So a watch that has no cellular plan of its own depends on the carrier's Wi-Fi calling, and in Ukraine that
is a Vodafone line today. A lifecell cellular plan on the watch (lifecell offers Number Sharing/eSIM for
Apple Watch from watchOS 64.1) provides a second, cellular route to the same kind of call. Neither fact is
detectable from inside the app, which is why they are owner steps rather than rows in a status list.

## Rejected alternatives, and why

- **Private `MediaDevice`/`MDCallManager` telephony APIs.** Would reach the telephony stack directly. Not
  shippable: private API, and the project's own research policy in `Docs/CarrierCallingPublicAPIResearch.md`
  is public interfaces only. The earlier `probe/circleci-mediadevice-compile` work is a compile probe, not a
  ship path.
- **`CXStartCallAction` / `CXProvider` on watchOS.** These are for a VoIP call the app carries itself. A
  `CXProvider` call never becomes a carrier PSTN call, so it cannot place a call to an ordinary number.
- **iOS `TelephonyConversationManager.startCellularConversation(_:)` (iOS 26+).** iOS only, needs the app to
  be the default calling app, and that entitlement is restricted to developers registered in the EU/EEA.
- **Pushing the dial action to the iPhone.** Meaningless when the iPhone is off, which is the case this work
  is about.
- **Claiming success after the hand-off.** Rejected: it is the one thing the previous build did, and it is
  what made a working carrier call indistinguishable from a dead key.

## Verified / not verified here

- Verified in this repository by unit tests (`Tests/WatchCarrierCallObservationTests.swift`, value-level,
  no device): the verdict rules, the own-call and second-call exclusions, that only an observed connect
  claims duplex audio, that an unproven call is not a failure, that the carrier's half of the route is never
  claimed satisfied, and that the requirements list is complete and unique.
- Not verified here: compilation and on-watch behaviour. No Swift toolchain is available in this environment
  and GitHub Actions must not be run; the build is to be produced on MacinCloud FF146-I. The one API
  behaviour that needs a physical watch is whether `CXCallObserver` reports the **system** cellular call on
  watchOS as well as `CXProvider` calls. The code is written so that either answer is safe: if watchOS does
  not report the carrier call, the screen reports `notObserved` rather than a false result.
