import UIKit
import StoreKit
import GoogleMobileAds
import AdSupport
import AppTrackingTransparency
import SystemConfiguration
import Network

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    private var currentInitRetryCount = 0
    private let maxInitRetries = 3
    private let initRetryInterval: TimeInterval = 2.0
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        print("\n========================================")
        print("📱 App Launch")
        print("========================================\n")
        setupErrorHandling()
        setupStoreKit()
        setupAdMob()
        
        return true
    }

    // iOS 13 이상에서 Scene 설정
    func application(_ application: UIApplication,
                    configurationForConnecting connectingSceneSession: UISceneSession,
                    options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration",
                                  sessionRole: connectingSceneSession.role)
    }
    
    private func initializeAdMob(withATTStatus status: ATTrackingManager.AuthorizationStatus?) {
        // AdMob 설정
        let requestConfiguration = GADMobileAds.sharedInstance().requestConfiguration

         // 테스트 기기 설정
        #if DEBUG
        GADMobileAds.sharedInstance().requestConfiguration.testDeviceIdentifiers = 
            [ "4db0dd2e2e2d0f3e98eb1492d9b86847" ]
        print("📱 Debug mode: Test device configured for AdMob")
        #endif
        
        // IDFA 수집 설정
        if #available(iOS 14, *), let status = status {
            requestConfiguration.tagForUnderAgeOfConsent = false
            requestConfiguration.tagForChildDirectedTreatment = false
            
            switch status {
            case .authorized:
                // IDFA 수집 가능
                break
            default:
                // IDFA 수집 불가능한 경우 처리
                break
            }
        }
        
        // 초기화 시작
        startAdMobInitialization()
    }
    
    private func setupAdMob() {
        print("📱 Getting device ID for AdMob...")
        print("Device ID: \(GADMobileAds.sharedInstance().requestConfiguration.testDeviceIdentifiers ?? [])")
    
        if #available(iOS 14, *) {
            // ATT 권한 요청 전에 딜레이 추가
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                ATTrackingManager.requestTrackingAuthorization { [weak self] status in
                    print("📱 ATT Status: \(status.rawValue)")
                    // ATT 권한 응답을 기다린 후 AdMob 초기화
                    DispatchQueue.main.async {
                        self?.initializeAdMob(withATTStatus: status)
                    }
                }
            }
        } else {
            initializeAdMob(withATTStatus: nil)
        }
    }

    private func checkNetworkConnection() async -> Bool {
        return await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.smap.network.monitor", qos: .userInitiated)
            
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            
            monitor.start(queue: queue)
            
            // 1초 후 타임아웃
            queue.asyncAfter(deadline: .now() + 1.0) {
                monitor.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    private func startAdMobInitialization() {
        guard currentInitRetryCount < maxInitRetries else {
            print("❌ Exceeded maximum retry attempts for AdMob initialization")
            NotificationCenter.default.post(name: .adMobInitializationFailed, object: nil)
            return
        }
        
        print("🎯 Starting AdMob initialization... (Attempt \(currentInitRetryCount + 1)/\(maxInitRetries))")
        
        // 더 긴 타임아웃 설정
//        let timeout = DispatchTimeInterval.seconds(5)
        
        GADMobileAds.sharedInstance().start { [weak self] status in
            guard let self = self else { return }
            
            self.logInitializationStatus(status)
            
            // 성공 조건 완화
            let isInitialized = status.adapterStatusesByClassName.values.contains { 
                $0.state == .ready || $0.latency > 0 
            }
            
            if isInitialized {
                print("✅ AdMob initialized successfully")
                self.currentInitRetryCount = 0
                
                DispatchQueue.main.async {
                    Environment.AdMob.isInitialized = true
                    NotificationCenter.default.post(name: .adMobReady, object: nil)
                }
            } else {
                print("❌ AdMob initialization failed")
                // 더 긴 재시도 간격 설정
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.retryInitialization()
                }
            }
        }
    }
    
    private func retryInitialization() {
        currentInitRetryCount += 1
        
        if currentInitRetryCount < maxInitRetries {
            print("⚠️ AdMob initialization incomplete, retrying in \(initRetryInterval) seconds...")
            DispatchQueue.main.asyncAfter(deadline: .now() + initRetryInterval) { [weak self] in
                self?.startAdMobInitialization()
            }
        } else {
            print("❌ Failed to initialize AdMob after \(maxInitRetries) attempts")
            NotificationCenter.default.post(name: .adMobInitializationFailed, object: nil)
        }
    }
    
    private func logInitializationStatus(_ status: GADInitializationStatus) {
        print("\n📱 AdMob Initialization Details:")
        print("--------------------------------")
        status.adapterStatusesByClassName.forEach { (className, status) in
            print("Adapter: \(className)")
            print("State: \(status.state.rawValue)")
            print("Latency: \(status.latency)ms")
            print("Description: \(status.description)")
            print("--------------------------------")
        }
    }
    
    private func isNetworkAvailable() -> Bool {
        let monitor = NWPathMonitor()
        var isConnected = false
        let group = DispatchGroup()
        
        // 높은 우선순위의 큐 사용
        let queue = DispatchQueue(label: "com.smap.network.monitor", qos: .userInitiated)
        
        group.enter()
        monitor.pathUpdateHandler = { path in
            isConnected = path.status == .satisfied
            group.leave()
        }
        
        monitor.start(queue: queue)
        
        // 타임아웃 설정
        let result = group.wait(timeout: .now() + 1.0)
        monitor.cancel()
        
        switch result {
        case .success:
            return isConnected
        case .timedOut:
            print("⚠️ Network check timed out")
            return false
        }
    }
    
    private func handleTrackingAuthorizationResponse(_ status: ATTrackingManager.AuthorizationStatus) {
        let statusMessage: String
        switch status {
        case .authorized:
            let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            statusMessage = "✅ Authorized (IDFA: \(idfa))"
        case .denied:
            statusMessage = "❌ Denied"
        case .notDetermined:
            statusMessage = "⚠️ Not Determined"
        case .restricted:
            statusMessage = "⚠️ Restricted"
        @unknown default:
            statusMessage = "❓ Unknown"
        }
        
        print("🔒 Tracking authorization status: \(statusMessage)")
    }
}

// MARK: - Error Handling Setup
    private func setupErrorHandling() {
        NSSetUncaughtExceptionHandler { exception in
            print("❌ Uncaught exception: \(exception)")
            print("❌ Exception name: \(exception.name)")
            print("❌ Exception reason: \(exception.reason ?? "Unknown reason")")
            print("❌ Stack trace: \(exception.callStackSymbols.joined(separator: "\n"))")
        }
    }
    
    // MARK: - StoreKit Setup
    private func setupStoreKit() {
        guard UserDefaults.standard.bool(forKey: "isPremium") else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Task {
                do {
                    try await AppStore.sync()
                    print("✅ StoreKit sync completed")
                } catch {
                    if error.localizedDescription != "userCancelled" {
                        print("❌ StoreKit sync error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }


// MARK: - Extensions
extension Notification.Name {
    static let adMobReady = Notification.Name("AdMobReady")
    static let adMobInitializationFailed = Notification.Name("AdMobInitializationFailed")
}
