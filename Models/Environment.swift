import Foundation
import UIKit

// MARK: - Environment Configuration
struct Environment {
    // TestFlight 환경 감지
//    static let isTestFlight = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    
    // 디버그 모드 감지
    static let isDebug: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    
    // 테스트 환경 감지 (Debug 또는 TestFlight)
    static let isTestEnvironment = isDebug
    
    // 허용된 도메인
    static let allowedDomains = [
        "next.smap.site",
        "smap.site",
        "smap.co.kr"
    ]
    
    // 기본 URL 설정
    static let baseURL: String = {
        if isDebug {
            return "http://localhost:3000"
            // return "https://next.smap.site"
        } else {
            return "https://next.smap.site"
        }
    }()

    // MARK: - AdMob Configuration
    enum AdMob {
        static var isInitialized = false
        
        // 테스트 전용 ID
        private static let testIds = (
            app: "ca-app-pub-3940256099942544/4411468910",
            banner: "ca-app-pub-3940256099942544/2934735716",
            interstitial: "ca-app-pub-3940256099942544/4411468910"
        )
        
        // 프로덕션 ID
        private static let productionIds = (
            app: "ca-app-pub-7432142706137657~6676630193",
            banner: "ca-app-pub-7432142706137657/9155453875",
            interstitial: "ca-app-pub-7432142706137657/8660043123"
        )
        
        // 환경에 따른 ID 설정
        static let applicationID = isTestEnvironment ? testIds.app : productionIds.app
        static let bannerID = isTestEnvironment ? testIds.banner : productionIds.banner
        static let interstitialID = isTestEnvironment ? testIds.interstitial : productionIds.interstitial
        
        // 테스트 기기 설정
        static let testDeviceIdentifiers: [String] = [
            "2077ef9a63d2b398840261c8221a0c9b",  // 시뮬레이터
            // 여기에 실제 테스트 기기 ID 추가
        ]
        
        static var currentMode: String {
            if isDebug {
                return "Debug Mode (Test Ads)"
            } else {
                return "Release Mode (Production Ads)"
            }
        }
    }

    // MARK: - StoreKit Configuration
    enum StoreKit {
        static let premiumProductID = "site.smap.next.premium"
        
        static var currentMode: String {
            if isTestEnvironment {
                return "Sandbox Environment"
            } else {
                return "Production Environment"
            }
        }
    }
    
    // MARK: - Debug Information
    static func printEnvironmentInfo() {
        print("\n=== Environment Information ===")
        print("Mode: \(isDebug ? "Debug" : "Release")")
        print("Base URL: \(baseURL)")
        print("Test Environment: \(isTestEnvironment)")
        print("AdMob Mode: \(AdMob.currentMode)")
        print("StoreKit Mode: \(StoreKit.currentMode)")
        print("===========================\n")
    }
    
    // MARK: - Device Information
    static func getDeviceInfo() -> String {
        let device = UIDevice.current
        return """
        Device Info:
        - Name: \(device.name)
        - Model: \(device.model)
        - System: \(device.systemName) \(device.systemVersion)
        - Idiom: \(device.userInterfaceIdiom)
        """
    }
}

// MARK: - Environment Extensions
extension Environment {
    enum BuildType {
        case debug
        case testFlight
        case appStore
        
        static var current: BuildType {
            if Environment.isDebug {
                return .debug
            } else {
                return .appStore
            }
        }
    }
    
    static func isRunningTests() -> Bool {
        NSClassFromString("XCTestCase") != nil
    }
    
    static func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

#if DEBUG
// MARK: - Debug Helpers
extension Environment {
    static func simulatePurchase() {
        UserDefaults.standard.set(Date(), forKey: "premiumPurchaseDate")
        UserDefaults.standard.set("test-transaction", forKey: "premiumTransactionId")
        NotificationCenter.default.post(name: NSNotification.Name("PremiumStatusChanged"), object: nil)
    }
    
    static func simulateNonPremium() {
        UserDefaults.standard.removeObject(forKey: "premiumPurchaseDate")
        UserDefaults.standard.removeObject(forKey: "premiumTransactionId")
        NotificationCenter.default.post(name: NSNotification.Name("PremiumStatusChanged"), object: nil)
    }
}
#endif
