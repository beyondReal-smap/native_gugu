enum MessageType: String, Codable {
    case checkPremium
    case setPremium
    case purchase
    case loadAd
}

struct WebMessage: Codable {
    let type: MessageType
    let status: Bool?
    let adUnitId: String?
}
