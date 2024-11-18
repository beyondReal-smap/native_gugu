import UIKit
import StoreKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
              willConnectTo session: UISceneSession,
              options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        if #available(iOS 14.0, *) {
            print("🔒 WKWebView Security Configuration:")
            print("- App-bound domains enabled")
            print("- Allowed domains: \(Bundle.main.object(forInfoDictionaryKey: "WKAppBoundDomains") ?? "none")")
        }
        
        // Window 설정
        let window = UIWindow(windowScene: windowScene)
        let viewController = ViewController()
        window.rootViewController = viewController
        self.window = window
        window.makeKeyAndVisible()
        
        // 앱 시작 로그 출력
        viewController.logAppStart()
    
        #if DEBUG
        viewController.checkStoreKitConfig()
        #endif
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {
        print("\n========================================")
        print("📱 App Scene Disconnected")
        print("========================================\n")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        print("\n========================================")
        print("📱 App Scene Became Active")
        print("========================================\n")
        
        // Scene이 활성화될 때 Premium 상태 확인
        if let viewController = window?.rootViewController as? ViewController {
            viewController.logAppStart()
            
            // StoreKit 설정 확인
            #if DEBUG
            Task {
                do {
                    let products = try await Product.products(for: [Environment.StoreKit.premiumProductID])
                    print("\n🛍 StoreKit Status:")
                    print("Products found: \(products.count)")
                    products.forEach { product in
                        print("- \(product.id): \(product.displayName) (\(product.price))")
                    }
                    print("")
                } catch {
                    print("❌ StoreKit error: \(error.localizedDescription)")
                }
            }
            #endif
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        print("\n========================================")
        print("📱 App Scene Will Resign Active")
        print("========================================\n")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        print("\n========================================")
        print("📱 App Will Enter Foreground")
        print("========================================\n")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        print("\n========================================")
        print("📱 App Entered Background")
        print("========================================\n")
    }
}