# The carrier call from the watch, and what it depends on

Build 207 was tested on a Series 5 LTE watch, watchOS 10.6.2, with **no carrier eSIM on the watch**. The
first call from the watch went through; turning the iPhone's Wi-Fi off broke it; turning Wi-Fi and LTE off
broke it too; turning both back on did not restore it. This is what the code does about that, what it cannot
do, and how to tell the two apart on the next build.

## The chain, and where it leaves this app

```
dialpad green key
  → WatchCallPreparer.prepareForHandOff()        this app: bring the watch's own network up, bounded
  → WKApplication.openSystemURL(tel:)            watchOS: the number goes to the system Phone app
  → owner taps "Виклик"                          watchOS: the user chooses whether to continue
  → carrier / paired iPhone places the call      not this app, not this server
  → CXCallObserver reports what happened         the only signal back into this app
```

Everything above the second arrow is app code. Everything below it belongs to watchOS, the carrier and the
paired iPhone. There is no public API on watchOS that places a PSTN call, adds a cellular plan to a watch, or
registers a watch for Wi-Fi calling — `WKApplication.openSystemURL(_:)` is the entire telephony surface, and
`TelephonyConversationManager` is iOS-only and gated behind the `com.apple.developer.calling-app`
entitlement, which Apple restricts to developers registered in the EU/EEA.

## Why the first call worked and the next ones did not

watchOS gives the watch three possible routes to a carrier call, and only one of them is independent of the
iPhone:

1. **The paired iPhone**, over Bluetooth, or over the internet when the two are not near each other. This is
   *Calls on Other Devices* / *Add Wi-Fi Calling For Other Devices*, and Apple documents that *"Wi-Fi Calling
   is enabled automatically for Apple Watch when you turn on Allow Calls on Other Devices."*
2. **The watch's own cellular plan.** lifecell is the only Ukrainian carrier on Apple's Apple Watch cellular
   list. Without a plan there is nothing here.
3. **The watch's own Wi-Fi calling.** Apple documents it: *"If your cellular carrier offers Wi-Fi calling, you
   can use your Apple Watch to make and receive calls over Wi-Fi instead of the cellular network — even when
   your paired iPhone isn't with you or is turned off. Your Apple Watch just has to be within range of a
   Wi-Fi network that your iPhone has connected to in the past."*

The observations line up with route 1 or 3 being broken by the iPhone's radios rather than with anything this
app did: an iPhone-relayed call and a watch Wi-Fi calling registration both depend on the iPhone's IMS
registration, and *Wi-Fi Calling on iPhone* is supported in Ukraine by Vodafone only, while the watch cellular
list has lifecell only (Apple's two carrier lists, read for this work).

For a watch with no plan of its own, route 3 is the only one that survives the iPhone being off, and it needs
three things set up on devices, none of which any app can perform:

- **The watch must have Wi-Fi calling enabled**: Watch app → My Watch → Phone → **Wi-Fi Calling** on. Apple's
  own *"Use your Apple Watch without your iPhone nearby"* says: *"If you're on Wi-Fi and want to call a phone
  number, make sure that Wi-Fi calling is turned on for your Apple Watch. Otherwise, try making a FaceTime
  audio call."*
- **The iPhone must have Wi-Fi Calling on and Calls on Other Devices on**, and the carrier must support
  *"Wi-Fi Calling on supported iCloud-connected devices"* for the watch's registration.
- **The watch must be on a 2.4 GHz Wi-Fi network the iPhone has already joined.** watchOS does not join
  5 GHz-only networks, and the credentials come from the iPhone.

If the owner wants a PSTN call from the watch with the iPhone definitively off and no dependence on any of
that, the only remaining route is the watch's own cellular plan on the hardware already in hand. No new
device, no third-party app, no router change; a monthly plan on the existing LTE watch. Nothing in this
repository can substitute for it, and this build does not pretend otherwise.

## What this build changed

### 1. The watch's own network is brought up before the number is handed over

Apple documents the reason precisely: *"Wi-Fi and cellular data are turned off when your iPhone isn't nearby,
until you open and use an app that requires a network connection. Incoming phone calls are sent to voicemail
when your iPhone isn't nearby, and outgoing calls might take longer to make."*

Build 207 handed the number to the system with nothing done about that. `WatchCallPreparer` now makes a real,
bounded request to the owner's own server — `GET /v1/health`, unauthenticated, already implemented on both
sides — on launch, on every return to the foreground, and on every tap. A successful round trip is recorded as
proof that the watch's own network is carrying traffic, and it outranks the path monitor's own answer, because
traffic either arrived or it did not.

Preparation **never refuses to dial**. The system phone app and the carrier may have a path this app cannot
see, so the hand-off always happens; what preparation decides is how much of the watch's network is brought up
first. The wait is bounded at 2.5 s, so the call key cannot hang, and the keypad is never disabled while it
happens.

### 2. Sleep and network changes invalidate what was learned before

`NWPathMonitor` will happily keep reporting the path it saw an hour ago, so `SystemDialNetworkMonitor` now
carries the timestamp of each observation and `WatchCallPreparation` refuses anything older than its validity.
A changed radio discards the proof made over the old one, and a return to the foreground discards everything,
because watchOS is free to tear the radios down while an app is not running. Coming back from a lost network
is therefore a *new* attempt that re-validates, not a silent reuse of an old success.

Three events are kept apart, because they are not the same thing: **screen on** is not **the app resumed**,
and neither is **the network being ready**. Only the return to the foreground re-establishes, and it re-checks
rather than reuses.

Background execution was investigated and deliberately not used: `WKApplication.scheduleBackgroundRefresh` can
wake the app later, but it cannot place a call and cannot make the carrier's service available, so it would
only add a periodic wake that looks like progress.

### 3. A failed attempt cannot block the next one

Build 207 held the dial claim across the hand-off, inside the same statement as `openSystemURL`. If watchOS
suspended the app in that window — which is what handing over to another app does — the release never ran, and
because the sheet's state survives the suspension, every later tap on that screen was refused by a latch
nothing would ever clear. There are now two claims: the keypad's, released before the hand-off is made, and
the app-wide one, released by the hand-off, by a wake, or by a changed path.

`WatchRootView` also no longer hides **Call number** behind the *Done* button of a finished app-to-app call: a
carrier dial does not use that state, and a keypad that cannot be reached is a failed dial with no message.

### 4. A failure can be read against the path it was given

Each hand-off records whether the watch's own network was proven before the number left
(`WatchCallHandoffEvidence`). If it was not, one line appears beside the verdict naming that, so a "Call
Failed" can be told apart from a carrier whose service the app never had a chance to use. The line appears only
in that case.

The condition list added in Build 207 was removed. It could not affect a call, and a list of things the app
cannot know is not a mechanism.

## Verified, and not verified here

**Verified by unit tests in this repository** (`Tests/WatchCallPreparationTests.swift` 28 cases,
`Tests/WatchCarrierCallObservationTests.swift` 25 cases), on values with no watch and no clock:

- a fresh validated path hands off with no wait; anything else warms up first, with a bounded budget;
- a stale path observation and a stale round trip are each refused, and a stale path is reported as a stale
  path rather than as a stale round trip;
- a radio that changes, or a network that drops and comes back, discards the earlier proof and re-validates;
- a late monitor callback cannot roll back a newer observation, and a fresh report that the path went away does
  discard the proof;
- waking discards a proof that was valid a moment earlier, and releases a dial claim a suspension stranded;
- no preparation outcome refuses a hand-off, and no verdict other than an observed connect claims audio.

**Not verified here, and honestly not verifiable without the device:** compilation and on-watch behaviour. There
is no Swift toolchain in this environment, GitHub Actions and CircleCI must not be run, and the build is to be
produced on MacinCloud FF146-I. Two things need the physical watch:

1. Whether the watch's own network is up by the time the owner confirms in the Phone app — the warm-up makes
   the request, and the system is what places the call afterwards.
2. Whether the carrier call connects at all with the iPhone off, which is a property of the carrier's
   registration and cannot be established from inside the app.

## Recovery when the network comes back

The app now recovers its own state on every return to the foreground. The device-side registration does not
recover by itself, and Apple's documented order for that is: turn Wi-Fi Calling off and on again, restart the
iPhone, then try a different Wi-Fi network — waiting about two minutes between steps. For this watch the
per-watch toggle matters as much: Watch app → My Watch → Phone → Wi-Fi Calling off and on again.
