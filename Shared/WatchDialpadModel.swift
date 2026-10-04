import Foundation

/// What the green key on the watch dialpad is offering, decided only by the number that has been typed.
///
/// Deliberately nothing else. Reachability, a linked account and the Wi-Fi route are all reported beside
/// the keypad instead of being folded into this, because a call action that is derived from presentation
/// state is a call action that can be present, unavailable and silent at the same time.
enum WatchDialpadCallButtonState: Equatable {
    case needsNumber
    case ready
}

/// What the green key should do with what has been typed, and the reason when it cannot do anything.
///
/// A reason travels with the refusal so a key that cannot act says which of its two reasons applies,
/// rather than leaving the owner to tell an empty keypad from a rejected one.
enum WatchDialpadDialDecision: Equatable {
    case noNumber
    case invalidNumber
    case start(URL)
}

/// The typed number and the actions a keypad offers, with no networking, no clock and no scheduler.
///
/// The two keys reported dead on a watch are decided here rather than in a button closure, so what they do
/// is covered by unit tests on every platform instead of by one tap on one device.
struct WatchDialpadModel: Equatable {
    private(set) var number: String = ""
    private(set) var isDialing = false

    /// The same ceiling the Build 20 to 29 system dialer enforced, so a number that one accepted is
    /// accepted here and the two screens cannot disagree about what a keypad holds.
    let maximumCharacterCount: Int

    init(maximumCharacterCount: Int = 20) {
        self.maximumCharacterCount = maximumCharacterCount
    }

    var isEmpty: Bool { number.isEmpty }

    /// A delete key on an empty number is offered and does nothing, so the key is never dead to a tap.
    var canDelete: Bool { !number.isEmpty }

    var callButtonState: WatchDialpadCallButtonState { isEmpty ? .needsNumber : .ready }

    /// The digits alone, so a leading + is validated without counting towards the length.
    var digits: String { number.filter { $0.isASCII && $0.isNumber } }

    /// A normal mobile number is 3 to 15 digits. Fewer cannot be dialled at all and more is not a number
    /// any carrier will accept.
    var isCallable: Bool { (3...15).contains(digits.count) }

    /// The address the green key hands to the system, and the same one that produced a connected carrier
    /// call in Build 20 to 29 with the iPhone on LTE and its Wi-Fi off.
    var dialURL: URL? {
        guard isCallable else { return nil }
        var components = URLComponents()
        components.scheme = "tel"
        components.path = number
        return components.url
    }

    /// E.164 for the Wi-Fi account route, which resolves a number to another Wi-Fi Secure Call user and is
    /// therefore not a phone call. Kept separate from `dialURL` so the two can never be confused for one
    /// another at the call site.
    var e164: String? {
        guard isCallable else { return nil }
        return "+" + digits
    }

    /// Why the call key would act right now, without acting.
    var dialDecision: WatchDialpadDialDecision {
        guard !number.isEmpty else { return .noNumber }
        guard let url = dialURL else { return .invalidNumber }
        return .start(url)
    }

    @discardableResult
    mutating func append(_ character: Character) -> Bool {
        guard number.count < maximumCharacterCount else { return false }
        if character == "+" {
            guard number.isEmpty else { return false }
            number = "+"
            return true
        }
        guard character.isASCII, character.isNumber else { return false }
        number.append(character)
        return true
    }

    /// Removes one digit.
    ///
    /// The empty case returns without touching the value instead of calling `removeLast()` on it. A tap
    /// that must be guarded against an empty string is a tap whose only failure mode is taking the keypad
    /// down with it.
    @discardableResult
    mutating func deleteLast() -> Bool {
        guard !number.isEmpty else { return false }
        number.removeLast()
        return true
    }

    mutating func clear() {
        number = ""
    }

    /// Claims the one dial request this press is allowed to make.
    ///
    /// The first caller is told yes and every caller until `endDial()` is told no, so a double tap, a
    /// second route started from the same screen, or a retry after a failure cannot each open a call of
    /// their own.
    mutating func beginDial() -> Bool {
        guard !isDialing else { return false }
        isDialing = true
        return true
    }

    /// Releases the claim once the route has finished with it, whether it connected or refused.
    mutating func endDial() {
        isDialing = false
    }
}
