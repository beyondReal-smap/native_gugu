import Foundation
import WebKit

// MARK: - Premium Status Protocols
/// Premium 상태 처리를 위한 프로토콜
protocol PremiumStatusHandling: AnyObject {
    /// 컨텐츠를 표시하는 WebView
    var contentWebView: UIView? { get }
    
    /// Premium 상태 처리에 사용되는 WebView
    var webView: WKWebView { get }
    
    /// JavaScript 코드를 실행하는 메서드
    /// - Parameters:
    ///   - script: 실행할 JavaScript 코드
    ///   - completion: 실행 완료 후 호출되는 콜백
    func executeJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)?)
}

/// Premium 상태 변경 알림을 위한 델리게이트 프로토콜
protocol PremiumStatusHandlingDelegate: AnyObject {
    /// Premium 상태가 변경되었을 때 호출되는 메서드
    /// - Parameters:
    ///   - isPremium: Premium 상태 여부
    ///   - purchaseDate: 구매 날짜
    func premiumStatusDidChange(isPremium: Bool, purchaseDate: Date?)
}

// MARK: - Advertisement Protocols
/// 광고 관련 이벤트 처리를 위한 델리게이트 프로토콜
//protocol AdManagerDelegate: AnyObject {
//    /// 광고가 닫혔을 때 호출되는 메서드
//    func adDidDismiss()
//}
