import Foundation

/// One documented condition for a carrier call from the watch while the paired iPhone is off.
///
/// Apple documents this route as: the carrier offers Wi-Fi calling, Wi-Fi calling is on for the iPhone
/// together with `Add Wi-Fi Calling For Other Devices`, and the watch is within range of a Wi-Fi network
/// the iPhone has already connected to. A watch app can read none of the carrier's half of that, so each
/// row here carries the state the app could actually establish and never the one it could not.
enum WatchCarrierCallRequirementID: String, Codable, Hashable, Sendable, CaseIterable {
    case watchHasNetwork
    case watchHasWiFiPath
    case watchPairedToIPhone
    case iPhoneHasUsedThisWiFi
    case carrierOffersWiFiCalling
    case allowCallsOnOtherDevices
    case ownerConfirmsOnWatch
}

enum WatchCarrierCallRequirementState: String, Codable, Hashable, Sendable {
    case satisfied
    case unmet
    /// No public API on watchOS reports this, so the app states it as an owner step instead of guessing.
    case notDetectable
}

struct WatchCarrierCallRequirement: Equatable, Sendable, Identifiable {
    let id: WatchCarrierCallRequirementID
    let state: WatchCarrierCallRequirementState
    let evidence: String
}

enum WatchCarrierCallRequirements {
    /// What the watch can establish itself, from the path it is on, its pairing, and the one piece of
    /// evidence the system does give it about the call.
    ///
    /// `paired` is `nil` when WatchConnectivity is unsupported on this device rather than "not paired",
    /// because the two are not the same fact.
    static func evaluate(
        network: SystemDialNetworkSnapshot,
        paired: Bool?,
        verdict: WatchCarrierCallVerdict
    ) -> [WatchCarrierCallRequirement] {
        [
            networkRequirement(network),
            wiFiPathRequirement(network),
            pairingRequirement(paired),
            notDetectable(.iPhoneHasUsedThisWiFi, evidence: "Програма не бачить список мереж iPhone. Потрібна та сама Wi-Fi мережа, до якої iPhone вже підключався."),
            notDetectable(.carrierOffersWiFiCalling, evidence: "Підтримку Wi-Fi викликів оператором перевіряє сам оператор, не програма."),
            notDetectable(.allowCallsOnOtherDevices, evidence: "Увімкніть на iPhone: Параметри → Телефон → Виклики по Wi-Fi, увімкніть «Виклики по Wi-Fi на цьому iPhone» і «Додати виклики по Wi-Fi для інших пристроїв»."),
            confirmationRequirement(verdict)
        ]
    }

    static func displayText(for requirement: WatchCarrierCallRequirement) -> String {
        let mark: String
        switch requirement.state {
        case .satisfied: mark = "OK"
        case .unmet: mark = "НІ"
        case .notDetectable: mark = "—"
        }
        return "\(mark) \(requirement.evidence)"
    }

    private static func networkRequirement(_ network: SystemDialNetworkSnapshot) -> WatchCarrierCallRequirement {
        if network.status == "satisfied", !network.interfaces.isEmpty {
            return .init(id: .watchHasNetwork, state: .satisfied, evidence: "Годинник у мережі: \(network.interfaces.joined(separator: ", ")).")
        }
        return .init(id: .watchHasNetwork, state: .unmet, evidence: "Годинник без мережі — дзвінок піти не зможе.")
    }

    private static func wiFiPathRequirement(_ network: SystemDialNetworkSnapshot) -> WatchCarrierCallRequirement {
        // An interface listed on a path that is not satisfied is not a route, so the status decides first.
        guard network.status == "satisfied" else {
            return .init(id: .watchHasWiFiPath, state: .unmet, evidence: "Мережа не працює, тому шляху для дзвінка немає.")
        }
        if network.interfaces.contains("wifi") {
            return .init(id: .watchHasWiFiPath, state: .satisfied, evidence: "Є шлях Wi-Fi.")
        }
        if network.interfaces.contains("cellular") {
            return .init(id: .watchHasWiFiPath, state: .unmet, evidence: "Немає Wi-Fi. Зараз дзвінок піде лише через стільникову мережу, якщо вона є на годиннику.")
        }
        return .init(id: .watchHasWiFiPath, state: .unmet, evidence: "Немає ні Wi-Fi, ні стільникового шляху.")
    }

    private static func pairingRequirement(_ paired: Bool?) -> WatchCarrierCallRequirement {
        switch paired {
        case .some(true):
            return .init(id: .watchPairedToIPhone, state: .satisfied, evidence: "Годинник з’єднаний з iPhone.")
        case .some(false):
            return .init(id: .watchPairedToIPhone, state: .unmet, evidence: "Годинник не з’єднаний з iPhone: дзвінки по Wi-Fi з iPhone не налаштовуються.")
        case nil:
            return .init(id: .watchPairedToIPhone, state: .notDetectable, evidence: "Стан з’єднання з iPhone на цьому пристрої недоступний.")
        }
    }

    private static func confirmationRequirement(_ verdict: WatchCarrierCallVerdict) -> WatchCarrierCallRequirement {
        switch verdict {
        case .notRequested:
            return .init(id: .ownerConfirmsOnWatch, state: .notDetectable, evidence: "Ще не натискали трубку.")
        case .awaitingOwnerConfirmation:
            return .init(id: .ownerConfirmsOnWatch, state: .unmet, evidence: "Очікує натискання «Виклик» на екрані Телефону.")
        case .observedOutgoing, .connected, .endedAfterConnecting, .endedBeforeConnecting:
            return .init(id: .ownerConfirmsOnWatch, state: .satisfied, evidence: "Системний дзвінок створено після підтвердження.")
        case .notObserved:
            return .init(id: .ownerConfirmsOnWatch, state: .notDetectable, evidence: "Дзвінок створюється системою поза цією програмою, тому вона не бачить підтвердження.")
        }
    }

    private static func notDetectable(
        _ id: WatchCarrierCallRequirementID,
        evidence: String
    ) -> WatchCarrierCallRequirement {
        .init(id: id, state: .notDetectable, evidence: evidence)
    }
}
