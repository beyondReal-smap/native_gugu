import UIKit
@preconcurrency import WebKit
import StoreKit
import GoogleMobileAds
import SafariServices

final class ViewController: UIViewController, PremiumStatusHandling, AdManagerDelegate {
    // MARK: - Properties
    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        if #available(iOS 14.0, *) {
            configuration.limitsNavigationsToAppBoundDomains = false
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        configuration.applicationNameForUserAgent = "gugudan"
        setupScriptsAndHandlers(configuration)
        
        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        
        #if DEBUG
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        
        return webView
    }()
    
    private lazy var premiumChecker: PremiumStatusChecker = {
        return PremiumStatusChecker(delegate: self)
    }()
    
    private var adManager: AdManager?
    private var interstitialAdTest: GADInterstitialAd?
    private var isAdInitTest = false
    private var isPremiumHandlersInitialized = false
    
    // MARK: - Initialization
    override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    private func commonInit() {
        // Common initialization code here
        modalPresentationStyle = .fullScreen
    }
    
    // MARK: - Lifecycle Methods
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        
        setupWebView()
        setupDependencies()
        loadWebsite()
        
        #if DEBUG || targetEnvironment(simulator)
        setupTestEnvironment()
        #endif

        // 프리미엄 상태 초기화
        checkInitialPremiumStatus() 

        // 내부 광고
        setupAdManager()

        // 웹뷰 로딩 완료 시 프리미엄 상태 확인 및 동기화
        webView.addObserver(self, forKeyPath: "loading", options: [.new], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "loading", let loading = change?[.newKey] as? Bool, !loading {
            // 웹뷰 로딩 완료 - 프리미엄 상태 동기화 트리거
            print("✅ 웹뷰 로딩 완료 - 프리미엄 상태 확인 중")
            Task { await syncPremiumStatusWithWeb() }
        }
    }

    // 프리미엄 상태에 대한 단일 소스
    private func syncPremiumStatusWithWeb() async {
        // 1. 프리미엄 상태 가져오기 (UserDefaults 및/또는 StoreKit 확인에서)
        let isPremium = await verifyAndUpdatePremiumStatus() // UserDefaults 및 StoreKit 확인 결합
        let purchaseDate = UserDefaults.standard.premiumPurchaseDate
        let transactionId = UserDefaults.standard.premiumTransactionId

        // 2. 핸들러 초기화 대기 (React Context가 준비될 때까지)
        await waitForPremiumHandlersReady()

        // 3. 웹 상태 업데이트 - notifyWebPremiumStatus 사용 (간소화된 로직)
        notifyWebPremiumStatus(isPremium, purchaseDate: purchaseDate, transactionId: transactionId)
    }
    
    // MARK: - Protocol Conformance
    var contentWebView: UIView? {
        return webView
    }

    // MARK: - PremiumStatusHandling Protocol
    func premiumStatusDidChange(isPremium: Bool, purchaseDate: Date?) {
        let dateString = purchaseDate.map { formatDate($0) }
        let script = """
        if (window.premiumHandlers) {
            window.premiumHandlers.setPremiumStatus(
                \(isPremium),
                \(dateString.map { "'\($0)'" } ?? "null")
            );
        }
        """
        executeJavaScript(script, completion: nil)
    }
    
    // MARK: - AdManagerDelegate
    func adDidDismiss() {
        print("✅ Ad dismissed - performing post-ad actions")
        
        let script = """
        if (typeof onAdDismissed === 'function') {
            onAdDismissed();
        }
        """
        executeJavaScript(script)
    }
    
    private func setupPremiumChecker() {
        premiumChecker = PremiumStatusChecker(delegate: self)
    }

    private func setupDependencies() {
        // Premium 체커 초기화
        premiumChecker = PremiumStatusChecker(delegate: self)
        
        // AdManager 초기화를 메인 큐에서 수행
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.adManager = AdManager(viewController: self, delegate: self)
        }
        
        setupTransactionListener()
        addPremiumStatusObserver()
    }

    // MARK: - Test AdMob Methods
    private func initAdTest() {
        GADMobileAds.sharedInstance().start { [weak self] status in
            print("📱 [TEST] AdMob Init Details:")
            print("--------------------------------")
            status.adapterStatusesByClassName.forEach { (className, status) in
                print("📱 [TEST] Adapter: \(className)")
                print("📱 [TEST] State: \(status.state.rawValue)")
            }
            
            if status.adapterStatusesByClassName.values.allSatisfy({ $0.state == .ready }) {
                print("✅ [TEST] AdMob init success")
                self?.isAdInitTest = true
                
                DispatchQueue.main.async {
                    // delegate 파라미터 추가
                    self?.adManager = AdManager(viewController: self!, delegate: self!)
                    // 초기화 성공 시 바로 광고 로드
                    self?.loadAdTest()
                }
            } else {
                print("❌ [TEST] AdMob init failed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.retryAdTest()
                }
            }
        }
    }

    private func retryAdTest() {
        guard !isAdInitTest else { return }
        print("🔄 [TEST] Retry AdMob init...")
        initAdTest()
    }
    
    private func loadAdTest() {
        print("🎯 [TEST] Loading interstitial ad...")
        let request = GADRequest()
        // 테스트 광고 단위 ID 사용
        GADInterstitialAd.load(withAdUnitID: "ca-app-pub-3940256099942544/4411468910",
                              request: request) { [weak self] ad, error in
            if let error = error {
                print("❌ [TEST] Failed to load interstitial ad: \(error.localizedDescription)")
                return
            }
            
            print("✅ [TEST] Interstitial ad loaded successfully")
            self?.interstitialAdTest = ad
            self?.interstitialAdTest?.fullScreenContentDelegate = self
        }
    }

    func showAdTest() {
        guard isAdInitTest else {
            print("⚠️ [TEST] Cannot show ad - Not initialized")
            retryAdTest()
            return
        }
        
        if let ad = interstitialAdTest {
            print("🎯 [TEST] Showing interstitial ad...")
            ad.present(fromRootViewController: self)
        } else {
            print("⚠️ [TEST] Ad not ready, loading new one")
            loadAdTest()
        }
    }
    
    // WebView JavaScript 실행
    func executeJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)?) {
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(script) { (result, error) in
                if let error = error {
                    print("❌ JavaScript execution error: \(error.localizedDescription)")
                } else {
                    print("✅ JavaScript executed successfully")
                }
                completion?(result, error)
            }
        }
    }

    // MARK: - Debug Setup
    #if DEBUG
    private func setupDebugButton() {
        let resetButton = UIButton(type: .system)
        resetButton.setTitle("Reset Premium", for: .normal)
        resetButton.backgroundColor = .systemRed
        resetButton.setTitleColor(.white, for: .normal)
        resetButton.layer.cornerRadius = 8
        resetButton.addTarget(self, action: #selector(resetPremiumStatusTapped), for: .touchUpInside)
        
        view.addSubview(resetButton)
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            resetButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            resetButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            resetButton.widthAnchor.constraint(equalToConstant: 120),
            resetButton.heightAnchor.constraint(equalToConstant: 40)
        ])
        
        resetButton.layer.zPosition = 999
    }

    @objc private func resetPremiumStatusTapped() {
        UserDefaults.standard.resetPremiumStatus()
        let script = """
        if (window.setPremiumStatus) {
            window.setPremiumStatus(false, null);
            const event = new CustomEvent('updatePremiumStatus', {
                detail: { isPremium: false, purchaseDate: null }
            });
            window.dispatchEvent(event);
        }
        """
        executeJavaScript(script)
        showAlert(message: "구매 상태가 초기화되었습니다.")
    }
    #endif
}

extension ViewController {
    private func verifyAndSyncPremiumStatus() async -> Bool {
        print("\n🔍 Verifying premium status...")
        
        // 1. UserDefaults 확인
        let hasUserDefaultsData = UserDefaults.standard.premiumPurchaseDate != nil
        if !hasUserDefaultsData {
            print("- No purchase data in UserDefaults")
        }
        
        // 2. 트랜잭션 확인
        var hasValidTransaction = false
        var latestTransaction: Transaction?
        
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                print("- Found transaction: \(transaction.id)")
                if transaction.revocationDate == nil {
                    hasValidTransaction = true
                    latestTransaction = transaction
                    print("  → Transaction is valid")
                } else {
                    print("  → Transaction is revoked")
                }
            case .unverified(_, let error):
                print("⚠️ Unverified transaction: \(error.localizedDescription)")
            }
        }
        
        // 3. 상태 결정
        let isPremium = hasUserDefaultsData && hasValidTransaction
        print("Status determination:")
        print("- UserDefaults data exists: \(hasUserDefaultsData)")
        print("- Valid transaction exists: \(hasValidTransaction)")
        print("- Final premium status: \(isPremium)")
        
        // 4. 상태 동기화
        if isPremium, let transaction = latestTransaction {
            print("Syncing premium state...")
            UserDefaults.standard.premiumPurchaseDate = transaction.purchaseDate
            UserDefaults.standard.set(transaction.id.description, forKey: "premiumTransactionId")
            
            let dateString = formatDate(transaction.purchaseDate)
            let script = """
            if (window.premiumHandlers) {
                window.premiumHandlers.setPremiumStatus(true, '\(dateString)', '\(transaction.id)');
            }
            """
            executeJavaScript(script)
        } else {
            print("Syncing non-premium state...")
            UserDefaults.standard.resetPremiumStatus()
            
            let script = """
            if (window.premiumHandlers) {
                window.premiumHandlers.setPremiumStatus(false, null, null);
            }
            """
            executeJavaScript(script)
        }
        
        print("✅ Status verification completed - Premium: \(isPremium)\n")
        return isPremium
    }
    
    // MARK: - WebView Setup
    func setupWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        
        // 웹뷰 설정
        if #available(iOS 14.0, *) {
            let preferences = WKWebpagePreferences()
            preferences.allowsContentJavaScript = true
            configuration.defaultWebpagePreferences = preferences
            
            #if DEBUG
            configuration.limitsNavigationsToAppBoundDomains = false
            #else
            configuration.limitsNavigationsToAppBoundDomains = true
            #endif
        }
        
        // 유저 에이전트 설정
        configuration.applicationNameForUserAgent = "gugudan"
        
        // 웹뷰 생성
        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        
        // 스크롤 및 바운스 효과 비활성화
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        
        // Safe Area 존중
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        
        // 웹뷰 레이아웃 설정
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        
        // 제약 조건 설정 - Safe Area 유지
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        
        #if DEBUG
        // 개발 도구 활성화
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        
        setupScriptsAndHandlers(configuration)
    }
    
    // Update Info.plist entries
    private func getAppBoundDomains() -> [String] {
        return [
            "next.smap.site",
            "smap.site",
            "www.next.smap.site",
            "www.smap.site"
        ]
    }
    
    private func loadWebsite() {
        print("🌐 Starting to load website")
        
        #if DEBUG
        // 개발 환경
        let baseUrl = "http://localhost:3000" // HTTP 사용
        #else
        // 프로덕션 환경
        let baseUrl = "https://next.smap.site" // HTTPS 사용
        #endif
        
        guard var urlComponents = URLComponents(string: baseUrl) else {
            print("❌ Invalid URL")
            return
        }
        
        #if !DEBUG
        // 프로덕션에서는 항상 HTTPS 사용
        urlComponents.scheme = "https"
        #endif
        
        guard let url = urlComponents.url else {
            print("❌ Invalid URL components")
            return
        }
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        
        print("🌐 Loading URL: \(url)")
        
        DispatchQueue.main.async { [weak self] in
            self?.webView.load(request)
        }
    }

    private func setupScriptsAndHandlers(_ configuration: WKWebViewConfiguration) {
        // 메시지 핸들러 등록
        let handlers = [
            "hapticFeedbackHandler",
            "consoleLog",
            "showInterstitialAd",
            "handlePremiumPurchase",
            "openExternalLink"
        ]
        
        handlers.forEach { handler in
            configuration.userContentController.add(self, name: handler)
        }
        
        // 스크립트 추가
        let scripts: [(String, WKUserScriptInjectionTime)] = [
            (createExternalLinkScript(), .atDocumentStart),
            (createHapticScript(), .atDocumentStart),
            (createConsoleScript(), .atDocumentStart),
            (createPurchaseScript(), .atDocumentStart),
            (createPremiumScript(), .atDocumentStart)
        ]
        
        scripts.forEach { script, injectionTime in
            configuration.userContentController.addUserScript(
                WKUserScript(source: script,
                            injectionTime: injectionTime,
                            forMainFrameOnly: false)
            )
        }
    }

    // 각 스크립트를 별도 함수로 분리
    private func createExternalLinkScript() -> String {
        """
        window.openExternalLink = function(url) {
            try {
                window.webkit.messageHandlers.openExternalLink.postMessage(url);
                console.log('🔗 Requesting to open external link:', url);
            } catch(e) {
                console.error('External link error:', e);
            }
        };
        """
    }

    private func createHapticScript() -> String {
        """
        (function() {
            if (window._hapticFeedbackInitialized) {
                return;
            }
            
            window.triggerHapticFeedback = function(type) {
                try {
                    window.webkit.messageHandlers.hapticFeedbackHandler.postMessage(type);
                } catch(e) {
                    console.error('Haptic feedback error:', e);
                }
            };
            
            window._hapticFeedbackInitialized = true;
            
            window.showInterstitialAd = function() {
                try {
                    window.webkit.messageHandlers.showInterstitialAd.postMessage('');
                    console.log('🎯 Requesting interstitial ad from native code');
                } catch(e) {
                    console.error('Interstitial ad error:', e);
                }
            };
        })();
        """
    }

    private func createConsoleScript() -> String {
        """
        (function() {
            let originalLog = console.log;
            let originalError = console.error;
            let originalWarn = console.warn;
            
            console.log = function() {
                try {
                    window.webkit.messageHandlers.consoleLog.postMessage('[log] ' + Array.from(arguments).join(' '));
                } catch(e) {}
                originalLog.apply(console, arguments);
            };
            
            console.error = function() {
                try {
                    window.webkit.messageHandlers.consoleLog.postMessage('[error] ' + Array.from(arguments).join(' '));
                } catch(e) {}
                originalError.apply(console, arguments);
            };
            
            console.warn = function() {
                try {
                    window.webkit.messageHandlers.consoleLog.postMessage('[warn] ' + Array.from(arguments).join(' '));
                } catch(e) {}
                originalWarn.apply(console, arguments);
            };
        })();
        """
    }

    private func createPurchaseScript() -> String {
        """
        window.handlePremiumPurchase = function() {
            return new Promise((resolve, reject) => {
                window.onPremiumPurchaseSuccess = function() {
                    resolve();
                    delete window.onPremiumPurchaseSuccess;
                    delete window.onPremiumPurchaseFailure;
                };
                
                window.onPremiumPurchaseFailure = function(error) {
                    reject(new Error(error));
                    delete window.onPremiumPurchaseSuccess;
                    delete window.onPremiumPurchaseFailure;
                };
                
                window.webkit.messageHandlers.handlePremiumPurchase.postMessage('');
            });
        };
        """
    }

    private func createPremiumScript() -> String {
        """
        window.setPremiumStatus = function(isPremium, purchaseDate) {
            console.log('Premium status set:', isPremium, 'Purchase date:', purchaseDate);
            const event = new CustomEvent('premiumStatusChanged', {
                detail: { isPremium, purchaseDate }
            });
            window.dispatchEvent(event);
        };
        """
    }

    private func setupMessageHandlers(_ configuration: WKWebViewConfiguration) {
        let handlers = [
            "hapticFeedbackHandler",
            "consoleLog",
            "showInterstitialAd",
            "handlePremiumPurchase",
            "openExternalLink"
        ]
        
        handlers.forEach { handler in
            configuration.userContentController.add(self, name: handler)
        }
    }
    
    private func setupWebViewScripts(_ configuration: WKWebViewConfiguration) {
        // 외부 링크 처리를 위한 스크립트 추가
        let externalLinkScript = """
        window.openExternalLink = function(url) {
            try {
                window.webkit.messageHandlers.openExternalLink.postMessage(url);
                console.log('🔗 Requesting to open external link:', url);
            } catch(e) {
                console.error('External link error:', e);
            }
        };
        """
        
        configuration.userContentController.addUserScript(
            WKUserScript(source: externalLinkScript,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: false)
        )
        
        // 메시지 핸들러 추가
        configuration.userContentController.add(self, name: "openExternalLink")

        // 햅틱 피드백 스크립트
        let hapticScript = """
        (function() {
            if (window._hapticFeedbackInitialized) {
                return;
            }
            
            window.triggerHapticFeedback = function(type) {
                try {
                    window.webkit.messageHandlers.hapticFeedbackHandler.postMessage(type);
                } catch(e) {
                    console.error('Haptic feedback error:', e);
                }
            };
            
            window._hapticFeedbackInitialized = true;
            
            let setupAttempts = 0;
            const maxAttempts = 5;
            
            function ensureHapticFeedback() {
                if (!window.triggerHapticFeedback && setupAttempts < maxAttempts) {
                    setupAttempts++;
                    window.triggerHapticFeedback = function(type) {
                        try {
                            window.webkit.messageHandlers.hapticFeedbackHandler.postMessage(type);
                        } catch(e) {
                            console.error('Haptic feedback error:', e);
                        }
                    };
                }
            }
            
            const checkInterval = setInterval(() => {
                ensureHapticFeedback();
                if (setupAttempts >= maxAttempts) {
                    clearInterval(checkInterval);
                }
            }, 1000);

            window.showInterstitialAd = function() {
                try {
                    window.webkit.messageHandlers.showInterstitialAd.postMessage('');
                    console.log('🎯 Requesting interstitial ad from native code');
                } catch(e) {
                    console.error('Interstitial ad error:', e);
                }
            };
        })();
        """
        
        // 콘솔 로그 스크립트
        let consoleScript = """
        (function() {
            let originalLog = console.log;
            let originalError = console.error;
            let originalWarn = console.warn;
            
            console.log = function() {
                try {
                    window.webkit.messageHandlers.consoleLog.postMessage('[log] ' + Array.from(arguments).join(' '));
                } catch(e) {}
                originalLog.apply(console, arguments);
            };
            
            console.error = function() {
                try {
                    window.webkit.messageHandlers.consoleLog.postMessage('[error] ' + Array.from(arguments).join(' '));
                } catch(e) {}
                originalError.apply(console, arguments);
            };
            
            console.warn = function() {
                try {
                    window.webkit.messageHandlers.consoleLog.postMessage('[warn] ' + Array.from(arguments).join(' '));
                } catch(e) {}
                originalWarn.apply(console, arguments);
            };
        })();
        """
        
        // 구매 핸들러 스크립트
        let purchaseScript = """
        window.handlePremiumPurchase = function() {
            return new Promise((resolve, reject) => {
                window.onPremiumPurchaseSuccess = function() {
                    resolve();
                    delete window.onPremiumPurchaseSuccess;
                    delete window.onPremiumPurchaseFailure;
                };
                
                window.onPremiumPurchaseFailure = function(error) {
                    reject(new Error(error));
                    delete window.onPremiumPurchaseSuccess;
                    delete window.onPremiumPurchaseFailure;
                };
                
                window.webkit.messageHandlers.handlePremiumPurchase.postMessage('');
            });
        };
        """
        
        // 프리미엄 상태 스크립트
        let premiumScript = """
        window.setPremiumStatus = function(isPremium, purchaseDate) {
            console.log('Premium status set:', isPremium, 'Purchase date:', purchaseDate);
            const event = new CustomEvent('premiumStatusChanged', {
                detail: { isPremium, purchaseDate }
            });
            window.dispatchEvent(event);
        };
        """
        
        // 스크립트 등록
        let scripts: [(String, WKUserScriptInjectionTime)] = [
            (hapticScript, .atDocumentStart),
            (consoleScript, .atDocumentStart),
            (purchaseScript, .atDocumentStart),
            (premiumScript, .atDocumentStart)
        ]
        
        scripts.forEach { script, injectionTime in
            configuration.userContentController.addUserScript(
                WKUserScript(source: script,
                            injectionTime: injectionTime,
                            forMainFrameOnly: false)
            )
        }
    }
}
// MARK: - WKNavigationDelegate
extension ViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, 
                 didFailProvisionalNavigation navigation: WKNavigation!, 
                 withError error: Error) {
        let nsError = error as NSError
        
        if nsError.domain == NSURLErrorDomain && nsError.code == -1200 {
            #if DEBUG
            // 개발 환경에서의 SSL 오류 처리
            print("⚠️ SSL Error in development environment")
            // HTTP로 재시도
            guard let currentUrl = webView.url,
                  var components = URLComponents(url: currentUrl, resolvingAgainstBaseURL: true) else {
                return
            }
            components.scheme = "http"
            if let newUrl = components.url {
                let request = URLRequest(url: newUrl)
                webView.load(request)
            }
            #else
            handleLoadError()
            #endif
        } else {
            handleLoadError()
        }
        
        print("❌ Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            print("🌐 Attempting to navigate to: \(url.absoluteString)")
            
            // 외부 링크 처리
            if isExternalLink(url) {
                handleExternalLink(url)
                decisionHandler(.cancel)
                return
            }
            
            // 모든 네비게이션 허용
            decisionHandler(.allow)
            return
        }
        
        decisionHandler(.allow)
    }
    
    private func isExternalLink(_ url: URL) -> Bool {
        let externalDomains = [
            "smap.co.kr",
            "apps.apple.com"
        ]
        
        return externalDomains.contains { domain in
            url.host?.contains(domain) ?? false
        }
    }
    
    private func handleExternalLink(_ url: URL) {
        print("🔗 Opening external link: \(url.absoluteString)")
        
        let safariVC = SFSafariViewController(url: url)
        safariVC.modalPresentationStyle = .pageSheet
        
        if url.host?.contains("apps.apple.com") ?? false {
            // 앱스토어 링크는 Safari로 직접 열기
            UIApplication.shared.open(url, options: [:]) { success in
                if !success {
                    print("❌ Failed to open App Store link")
                    self.present(safariVC, animated: true)
                }
            }
        } else {
            // 다른 외부 링크는 SFSafariViewController로 열기
            present(safariVC, animated: true)
        }
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        print("🔵 WebView started loading")
    }

    private func setupPremiumHandlersAndSyncState() async {
        // 1. Initialize Premium Handlers: Wait for the webview to be ready
        await waitForPremiumHandlersReady()

        // 2. Sync Premium Status: Now that handlers are ready, sync the state
        let isPremium = UserDefaults.standard.isPremiumPurchased
        let purchaseDate = UserDefaults.standard.premiumPurchaseDate
        let transactionId = UserDefaults.standard.premiumTransactionId
        await syncPremiumStateToWeb(isPremium: isPremium, purchaseDate: purchaseDate, transactionId: transactionId)
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("❌ WebView failed to load: \(error)")

        switch error {
        case let error as WKError where error.code == .webContentProcessTerminated:
            print("❌ Web Content Process Terminated: \(error.localizedDescription)")
            resetWebView()
        case URLError.notConnectedToInternet:
            print("❌ No Internet Connection")
            handleLoadError()
        case URLError.timedOut:
            print("❌ Request Timed Out")
            handleLoadError()
        default:
            print("❌ Other WebView Error: \(error.localizedDescription)")
            handleLoadError()
        }
    }
}

// MARK: - Error Handling
private extension ViewController {
    func resetWebView() {
        webView.stopLoading()
        
        // 캐시 및 쿠키 삭제
        WKWebsiteDataStore.default().removeData(
            ofTypes: [
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeCookies
            ],
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.reloadWebViewWithDelay()
            }
        }
    }
    
    func reloadWebViewWithDelay() {
        // 짧은 지연 후 재로드
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.loadWebsite()
        }
    }
    
    func handleLoadError() {
        let alert = UIAlertController(
            title: "연결 실패",
            message: "페이지를 불러오는데 실패했습니다.\n네트워크 연결을 확인하고 다시 시도해주세요.",
            preferredStyle: .alert
        )
        
        let retryAction = UIAlertAction(title: "재시도", style: .default) { [weak self] _ in
            self?.resetWebView()
        }
        
        let cancelAction = UIAlertAction(title: "취소", style: .cancel)
        
        alert.addAction(retryAction)
        alert.addAction(cancelAction)
        
        DispatchQueue.main.async { [weak self] in
            self?.present(alert, animated: true)
        }
    }
}

// MARK: - WKScriptMessageHandler
extension ViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "handlePremiumPurchase":
            print("💳 Premium purchase requested")
            
            // 메인 스레드에서 구매 처리 시작
            DispatchQueue.main.async {
                Task {
                    await self.handlePremiumPurchase()
                }
            }
            
        case "showInterstitialAd":
            print("🎯 Received request to show interstitial ad")
            adManager?.showInterstitial()
            
        case "hapticFeedbackHandler":
            if let type = message.body as? String {
                print("📳 Triggering haptic feedback: \(type)")
                DispatchQueue.main.async { [weak self] in
                    self?.triggerHapticFeedback(type: type)
                }
            }
            
        case "consoleLog":
            if let log = message.body as? String {
                print("📱 WebView Console: \(log)")
            }
            
        case "storeKit":
            if let body = message.body as? [String: Any],
               let type = body["type"] as? String {
                switch type {
                case "openSafariView":
                    if let data = body["data"] as? [String: Any],
                       let urlString = data["url"] as? String,
                       let url = URL(string: urlString) {
                        DispatchQueue.main.async { [weak self] in
                            let safariVC = SFSafariViewController(url: url)
                            safariVC.modalPresentationStyle = .formSheet
                            self?.present(safariVC, animated: true)
                        }
                    }
                case "openExternalLink":
                    if let urlString = message.body as? String,
                    let url = URL(string: urlString) {
                        handleExternalLink(url)
                    }
                default:
                    break
                }
            }
            
        default:
            print("❓ Unknown message handler: \(message.name)")
        }
    }
    
    private func triggerHapticFeedback(type: String) {
        switch type.lowercased() {
        case "timeattacksuccess":  // 타임어택 성공
            DispatchQueue.main.async {
                let notificationGenerator = UINotificationFeedbackGenerator()
                notificationGenerator.notificationOccurred(.success)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
                    impactGenerator.impactOccurred()
                }
            }
            
        case "timeattackfail":  // 타임어택 실패
            DispatchQueue.main.async {
                let notificationGenerator = UINotificationFeedbackGenerator()
                notificationGenerator.notificationOccurred(.error)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let impactGenerator = UIImpactFeedbackGenerator(style: .heavy)
                    impactGenerator.impactOccurred()
                }
            }
            
        case "comboachievement":  // 연속 정답 달성
            DispatchQueue.main.async {
                let notificationGenerator = UINotificationFeedbackGenerator()
                notificationGenerator.notificationOccurred(.success)
                
                // 연속으로 세 번의 진동
                let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
                impactGenerator.impactOccurred()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    impactGenerator.impactOccurred()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    impactGenerator.impactOccurred()
                }
            }
            
        case "levelup":  // 새로운 단계 해금
            DispatchQueue.main.async {
                let notificationGenerator = UINotificationFeedbackGenerator()
                notificationGenerator.notificationOccurred(.success)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let impactGenerator = UIImpactFeedbackGenerator(style: .rigid)
                    impactGenerator.impactOccurred()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    let impactGenerator = UIImpactFeedbackGenerator(style: .heavy)
                    impactGenerator.impactOccurred()
                }
            }
            
        case "perfectscore":  // 만점 달성
            DispatchQueue.main.async {
                let notificationGenerator = UINotificationFeedbackGenerator()
                notificationGenerator.notificationOccurred(.success)
                
                // 점점 강해지는 진동
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let light = UIImpactFeedbackGenerator(style: .light)
                    light.impactOccurred()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let medium = UIImpactFeedbackGenerator(style: .medium)
                    medium.impactOccurred()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let heavy = UIImpactFeedbackGenerator(style: .heavy)
                    heavy.impactOccurred()
                }
            }
            
        case "timerprogress":  // 타이머 진행 상황 (10초 이하 남았을 때)
            DispatchQueue.main.async {
                let generator = UIImpactFeedbackGenerator(style: .soft)
                generator.impactOccurred()
            }
            
        case "timerurgent":  // 타이머 긴급 상황 (5초 이하)
            DispatchQueue.main.async {
                let generator = UIImpactFeedbackGenerator(style: .rigid)
                generator.impactOccurred()
            }
            
        case "newrecord":  // 새로운 기록 달성
            DispatchQueue.main.async {
                let notificationGenerator = UINotificationFeedbackGenerator()
                notificationGenerator.notificationOccurred(.success)
                
                // 리듬감 있는 진동
                let timings = [0.1, 0.2, 0.3, 0.5]
                timings.forEach { timing in
                    DispatchQueue.main.asyncAfter(deadline: .now() + timing) {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                    }
                }
            }
            
        case "success":
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            
        case "error":
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
            
        case "warning":
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
            
        case "impactlight":
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            
        case "impactmedium":
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            
        case "impactheavy":
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
            
        case "impactsoft":
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.impactOccurred()
            
        case "impactrigid":
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.impactOccurred()
            
        default:
            print("⚠️ Unknown haptic type: \(type)")
        }
    }
}

// MARK: - WKUIDelegate
extension ViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, 
                for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
    
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, 
                initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alertController = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "확인", style: .default) { _ in
            completionHandler()
        })
        present(alertController, animated: true)
    }
    
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, 
                initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alertController = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "확인", style: .default) { _ in
            completionHandler(true)
        })
        alertController.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in
            completionHandler(false)
        })
        present(alertController, animated: true)
    }
}

// MARK: - Helper Methods
extension ViewController {    
    private func showAlert(message: String) {
        DispatchQueue.main.async { [weak self] in
            let alert = UIAlertController(title: "알림", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "확인", style: .default))
            self?.present(alert, animated: true)
        }
    }
}

extension ViewController {
    func setupTransactionListener() {
        print("🔄 Setting up transaction listener...")
        
        Task.detached {
            for await verificationResult in Transaction.updates {
                do {
                    switch verificationResult {
                    case .verified(let transaction):
                        print("✅ Verified transaction: \(transaction.id)")
                        
                        if transaction.revocationDate != nil {
                            print("🚫 Transaction revoked")
                            UserDefaults.standard.resetPremiumStatus()
                            await self.syncPremiumStateToWeb(isPremium: false, purchaseDate: nil, transactionId: nil)
                        } else {
                            UserDefaults.standard.premiumPurchaseDate = transaction.purchaseDate
                            UserDefaults.standard.premiumTransactionId = transaction.id.description
                            await self.syncPremiumStateToWeb(
                                isPremium: true,
                                purchaseDate: transaction.purchaseDate,
                                transactionId: transaction.id.description
                            )
                        }
                        
                        await transaction.finish()
                        
                    case .unverified(let transaction, let error):
                        print("❌ Unverified transaction: \(error)")
                        await transaction.finish()
                    }
                }
            }
        }
    }
    
    private enum PurchaseError: Error {
        case paymentsNotAllowed
        case productNotFound
        case purchasePending
        case userCancelled
        case unknown
        case verificationFailed
        
        var message: String {
            switch self {
            case .paymentsNotAllowed:
                return "인앱 결제가 비활성화되어 있습니다."
            case .productNotFound:
                return "프리미엄 상품을 찾을 수 없습니다."
            case .purchasePending:
                return "결제가 진행 중입니다. 잠시만 기다려주세요."
            case .userCancelled:
                return "구매가 취소되었습니다."
            case .verificationFailed:
                return "구매 검증에 실패했습니다."
            case .unknown:
                return "알 수 없는 오류가 발생했습니다."
            }
        }
    }
}


// MARK: - Premium Status Management
extension ViewController {
    func addPremiumStatusObserver() {
        let script = """
        window.addEventListener('premiumStatusChanged', function(event) {
            console.log('Premium status changed event received:', event.detail);
            window.webkit.messageHandlers.consoleLog.postMessage(
                '[Premium] Status changed - isPremium: ' + 
                event.detail.isPremium + 
                ', purchaseDate: ' + 
                event.detail.purchaseDate
            );
        });
        """
        
        webView.evaluateJavaScript(script) { (result, error) in
            if let error = error {
                print("❌ Failed to add premium status observer: \(error.localizedDescription)")
            } else {
                print("✅ Premium status observer added successfully")
            }
        }
    }
    
    func syncPremiumStatus() {
        premiumChecker.syncPremiumStatus()
    }
}

extension UserDefaults {
    // Premium 상태
    var isPremium: Bool {
        get {
            bool(forKey: "isPremium")
        }
        set {
            set(newValue, forKey: "isPremium")
        }
    }
}

// MARK: - Debug StoreKit Testing
extension ViewController {
    #if DEBUG
    func setupStoreKitTesting() {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)
        stackView.layer.zPosition = 999
        
        NSLayoutConstraint.activate([
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            stackView.widthAnchor.constraint(equalToConstant: 150)
        ])
        
        // Test Purchase 버튼
        let purchaseButton = createDebugButton(title: "Test Purchase", color: .systemBlue)
        purchaseButton.addTarget(self, action: #selector(testPurchaseTapped), for: .touchUpInside)
        stackView.addArrangedSubview(purchaseButton)
        
        // Check Products 버튼
        let checkProductsButton = createDebugButton(title: "Check Products", color: .systemGreen)
        checkProductsButton.addTarget(self, action: #selector(checkProductsTapped), for: .touchUpInside)
        stackView.addArrangedSubview(checkProductsButton)
        
        // Reset Purchase 버튼
        let resetButton = createDebugButton(title: "Reset Purchase", color: .systemRed)
        resetButton.addTarget(self, action: #selector(resetPurchaseTapped), for: .touchUpInside)
        stackView.addArrangedSubview(resetButton)
    }
    
    private func createDebugButton(title: String, color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.backgroundColor = color
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return button
    }
    
    @objc private func testPurchaseTapped() {
        Task {
            await handlePremiumPurchase()
        }
    }
    
    @objc private func checkProductsTapped() {
        Task {
            do {
                let products = try await Product.products(for: [Environment.StoreKit.premiumProductID])
                var message = "Available Products:\n\n"
                products.forEach { product in
                    message += "ID: \(product.id)\n"
                    message += "Name: \(product.displayName)\n"
                    message += "Price: \(product.price)\n"
                    message += "Description: \(product.description)\n\n"
                }
                showAlert(message: message)
            } catch {
                showAlert(message: "Error loading products: \(error.localizedDescription)")
            }
        }
    }
    
    @objc private func resetPurchaseTapped() {
        UserDefaults.standard.resetPremiumStatus()
        let script = """
        if (window.setPremiumStatus) {
            window.setPremiumStatus(false, null);
            const event = new CustomEvent('updatePremiumStatus', {
                detail: { isPremium: false, purchaseDate: null }
            });
            window.dispatchEvent(event);
        }
        """
        executeJavaScript(script)
        showAlert(message: "구매 상태가 초기화되었습니다.")
    }
    #endif
}

// MARK: - GADFullScreenContentDelegate
extension ViewController: GADFullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        print("✅ [TEST] Ad dismissed")
        loadAdTest()  // 다음 광고 미리 로드
    }
    
    func ad(_ ad: GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        print("❌ [TEST] Ad failed to present: \(error.localizedDescription)")
    }
}

// StoreKit Configuration 체크를 위한 디버그 익스텐션
#if DEBUG
extension ViewController {
    func checkStoreKitConfiguration() {
        print("\n🛍 StoreKit Configuration:")
        print("--------------------------------")
        print("Product ID: \(Environment.StoreKit.premiumProductID)")
        
        Task {
            do {
                let products = try await Product.products(for: [Environment.StoreKit.premiumProductID])
                print("Found \(products.count) products:")
                products.forEach { product in
                    print("- ID: \(product.id)")
                    print("  Name: \(product.displayName)")
                    print("  Price: \(product.price)")
                    print("  Description: \(product.description)")
                }
            } catch {
                print("❌ Failed to fetch products: \(error)")
            }
        }
        print("--------------------------------\n")
    }
}
#endif

extension ViewController {    
    // MARK: - Purchase State Management
    private func resetPurchaseState() async {
        print("🔄 Resetting purchase state...")
        
        // UserDefaults 초기화
        UserDefaults.standard.resetPremiumStatus()
        
        // 웹 상태 초기화
        await syncPremiumStateToWeb(isPremium: false, purchaseDate: nil, transactionId: nil)
        
        // 잠시 대기하여 상태가 완전히 초기화되도록 함
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5초 대기
        
        print("✅ Purchase state reset completed")
    }
    
    private func handlePremiumStatusChange(isPremium: Bool, purchaseDate: Date?, transactionId: String?) {
        let dateString = purchaseDate.map { formatDate($0) }
        
        let script = """
        if (window.premiumHandlers) {
            window.premiumHandlers.setPremiumStatus(
                \(isPremium),
                \(dateString.map { "'\($0)'" } ?? "null"),
                \(transactionId.map { "'\($0)'" } ?? "null")
            );
        }
        """
        
        executeJavaScript(script)
    }
    
    // 구매 성공 시 호출되는 함수
    private func handleSuccessfulPurchase(transaction: StoreKit.Transaction) async {
        // UserDefaults 업데이트
        UserDefaults.standard.premiumPurchaseDate = transaction.purchaseDate
        UserDefaults.standard.set(transaction.id.description, forKey: "premiumTransactionId")
        
        // 웹으로 상태 전달
        handlePremiumStatusChange(
            isPremium: true,
            purchaseDate: transaction.purchaseDate,
            transactionId: transaction.id.description
        )
        
        // 트랜잭션 완료
        await transaction.finish()
    }
    
    private func clearExistingTransactions() async {
        print("🧹 Clearing existing transactions...")
        
        // 1. 현재 자격 확인 및 정리
        for await verification in Transaction.currentEntitlements {
            switch verification {
            case .verified(let transaction):
                print("📝 Processing existing transaction: \(transaction.id)")
                if transaction.revocationDate != nil {
                    print("🚫 Transaction was revoked")
                }
                await transaction.finish()
                print("✅ Finished transaction: \(transaction.id)")
                
            case .unverified(let transaction, let error):
                print("⚠️ Unverified transaction found: \(error.localizedDescription)")
                await transaction.finish()
                print("✅ Finished unverified transaction")
            }
        }
        
        // 2. 트랜잭션 업데이트 처리
        for await verification in Transaction.updates {
            switch verification {
            case .verified(let transaction):
                print("📝 Processing update transaction: \(transaction.id)")
                await transaction.finish()
                print("✅ Finished update transaction")
                
            case .unverified(let transaction, let error):
                print("⚠️ Unverified update transaction: \(error.localizedDescription)")
                await transaction.finish()
            }
        }
        
        print("✅ Finished clearing all transactions")
    }

    private func cleanupAllTransactions() async throws {
        print("🧹 Starting transaction cleanup")
        
        // UserDefaults 초기화
        UserDefaults.standard.resetPremiumStatus()
        
        // 웹 상태 초기화
        let resetScript = """
        if (window.premiumHandlers) {
            window.premiumHandlers.setPremiumStatus(false, null, null);
        }
        """
        executeJavaScript(resetScript)
        
        // StoreKit 트랜잭션 정리
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                print("📝 Finishing transaction: \(transaction.id)")
                await transaction.finish()
                
            case .unverified(let transaction, let error):
                print("⚠️ Finishing unverified transaction: \(error.localizedDescription)")
                await transaction.finish()
            }
        }
        
        // 약간의 지연을 주어 트랜잭션이 완전히 정리되도록 함
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1초 대기
        
        print("✅ Transaction cleanup completed")
    }

    private func processSuccessfulPurchase(_ verification: VerificationResult<Transaction>) async throws {
        switch verification {
        case .verified(let transaction):
            print("✅ Transaction verified: \(transaction.id)")
            
            // 1. 상태 저장
            UserDefaults.standard.set(transaction.purchaseDate, forKey: "premiumPurchaseDate")
            UserDefaults.standard.set(transaction.id.description, forKey: "premiumTransactionId")
            UserDefaults.standard.synchronize()
            
            // 2. 웹 상태 업데이트
            let dateString = formatDate(transaction.purchaseDate)
            let script = """
            if (window.premiumHandlers) {
                window.premiumHandlers.setPremiumStatus(true, '\(dateString)', '\(transaction.id)');
                if (window.onPremiumPurchaseSuccess) {
                    window.onPremiumPurchaseSuccess();
                }
            }
            """
            
            executeJavaScript(script)
            showAlert(message: "구매가 완료되었습니다.")
            
            // 3. 트랜잭션 완료
            await transaction.finish()
            
        case .unverified(let transaction, let error):
            print("❌ Transaction verification failed: \(error)")
            await transaction.finish()
            throw PurchaseError.verificationFailed
        }
    }
    
    private func clearStoreKitTransactions() async {
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                print("📝 Finishing transaction: \(transaction.id)")
                await transaction.finish()
            case .unverified(let transaction, let error):
                print("⚠️ Finishing unverified transaction: \(error.localizedDescription)")
                await transaction.finish()
            }
        }
        print("✅ Cleared all StoreKit transactions")
    }
    
    private func resetWebState() async {
        let script = """
        if (window.premiumHandlers) {
            console.log('Resetting premium state in web...');
            window.premiumHandlers.setPremiumStatus(false, null, null);
            window.dispatchEvent(new CustomEvent('updatePremiumStatus', {
                detail: {
                    isPremium: false,
                    purchaseDate: null,
                    transactionId: null
                }
            }));
            console.log('Premium state reset complete');
        }
        """
        
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                self?.webView.evaluateJavaScript(script) { _, error in
                    if let error = error {
                        print("❌ Web reset error: \(error.localizedDescription)")
                    } else {
                        print("✅ Web state reset successful")
                    }
                    continuation.resume()
                }
            }
        }
    }
    
    private func handlePurchaseError(_ error: Error) async {
        let message: String
        if let purchaseError = error as? PurchaseError {
            message = purchaseError.message
        } else {
            message = error.localizedDescription
        }
        
        print("❌ Purchase error: \(message)")
        showAlert(message: message)
        
        let script = "if (window.onPremiumPurchaseFailure) { window.onPremiumPurchaseFailure('\(message)'); }"
        executeJavaScript(script)
    }

    private func handleAlreadyPurchased() {
        print("ℹ️ Showing already purchased message")
        showAlert(message: "이미 구매한 상품입니다.")
        
        if let purchaseDate = UserDefaults.standard.object(forKey: "premiumPurchaseDate") as? Date {
            let dateString = formatDate(purchaseDate)
            let transactionId = UserDefaults.standard.string(forKey: "premiumTransactionId") ?? "unknown"
            
            // 웹에도 현재 상태 동기화
            let script = """
            if (window.premiumHandlers) {
                window.premiumHandlers.setPremiumStatus(true, '\(dateString)', '\(transactionId)');
                console.log('Synchronized existing purchase status');
            }
            """
            executeJavaScript(script)
        }
        
        // 구매 모달 닫기
        let closeScript = """
        if (window.premiumHandlers && window.premiumHandlers.closeModal) {
            window.premiumHandlers.closeModal();
        }
        """
        executeJavaScript(closeScript)
    }

    // 구매 복원 기능 (필요한 경우 추가)
    func restorePurchases() async {
        print("🔄 Restoring purchases...")
        
        var restoredPurchase = false
        
        for await verification in Transaction.currentEntitlements {
            if case .verified(let transaction) = verification {
                print("✅ Restored transaction: \(transaction.id)")
                UserDefaults.standard.set(transaction.purchaseDate, forKey: "premiumPurchaseDate")
                UserDefaults.standard.set(transaction.id.description, forKey: "premiumTransactionId")
                
                let dateString = formatDate(transaction.purchaseDate)
                let script = """
                if (window.premiumHandlers) {
                    window.premiumHandlers.setPremiumStatus(true, '\(dateString)', '\(transaction.id)');
                }
                """
                executeJavaScript(script)
                
                restoredPurchase = true
                break
            }
        }
        
        DispatchQueue.main.async {
            if restoredPurchase {
                self.showAlert(message: "구매가 복원되었습니다.")
            } else {
                self.showAlert(message: "복원할 구매 내역이 없습니다.")
            }
        }
    }

    func handlePremiumPurchase() async {
        print("\n=== Starting Purchase Process ===")
        
        // 1. 먼저 현재 구매 상태 확인
        if let purchaseDate = UserDefaults.standard.object(forKey: "premiumPurchaseDate") as? Date {
            print("💎 Already purchased on: \(formatDate(purchaseDate))")
            handleAlreadyPurchased()
            return
        }
        
        do {
            // 2. StoreKit 트랜잭션 확인
//            var hasValidTransaction = false
            for await verification in Transaction.currentEntitlements {
                if case .verified(let transaction) = verification {
                    print("✅ Found valid transaction: \(transaction.id)")
//                    hasValidTransaction = true
                    // 구매 정보 복원
                    UserDefaults.standard.set(transaction.purchaseDate, forKey: "premiumPurchaseDate")
                    UserDefaults.standard.set(transaction.id.description, forKey: "premiumTransactionId")
                    handleAlreadyPurchased()
                    return
                }
            }
            
            // 3. 새 구매 프로세스 시작
            print("🔍 No existing purchase found, starting new purchase...")
            
            guard AppStore.canMakePayments else {
                throw PurchaseError.paymentsNotAllowed
            }
            
            let productID = Environment.StoreKit.premiumProductID
            let products = try await Product.products(for: [productID])
            
            guard let product = products.first else {
                throw PurchaseError.productNotFound
            }
            
            print("✅ Found product: \(product.id)")
            print("💰 Price: \(product.price)")
            
            let result = try await product.purchase()
            
            switch result {
            case .success(let verification):
                try await processSuccessfulPurchase(verification)
            case .pending:
                throw PurchaseError.purchasePending
            case .userCancelled:
                throw PurchaseError.userCancelled
            @unknown default:
                throw PurchaseError.unknown
            }
            
        } catch {
            await handlePurchaseError(error)
        }
    }
    
    private func handlePurchaseCancelled() {
        print("🚫 Purchase cancelled by user")
        handlePurchaseFailure(message: "구매가 취소되었습니다.")
    }
    
    private func handlePurchaseFailure(message: String) {
        print("❌ Purchase failed: \(message)")
        showAlert(message: message)
        executeJavaScript("window.onPremiumPurchaseFailure && window.onPremiumPurchaseFailure('\(message)')")
    }

    // MARK: - Web Sync
    private func syncPremiumStateToWeb(isPremium: Bool, purchaseDate: Date?, transactionId: String?) async {
        let dateString = purchaseDate.map { formatDate($0) }
        
        let script = """
        (function() {
            const updateState = () => {
                // Premium 상태 데이터
                const stateData = {
                    isPremium: \(isPremium),
                    purchaseDate: \(dateString.map { "'\($0)'" } ?? "null"),
                    transactionId: \(transactionId.map { "'\($0)'" } ?? "null"),
                    lastUpdated: new Date().toISOString()
                };
                
                console.log('[Premium] Syncing state:', stateData);
                
                // React Context 업데이트
                if (window.__PREMIUM_CONTEXT__?.setState) {
                    window.__PREMIUM_CONTEXT__.setState({
                        ...stateData,
                        showModal: false,
                        isProcessing: false
                    });
                }
                
                // Premium handlers 업데이트
                if (window.premiumHandlers?.setPremiumStatus) {
                    window.premiumHandlers.setPremiumStatus(
                        stateData.isPremium,
                        stateData.purchaseDate,
                        stateData.transactionId
                    );
                }
                
                // Legacy handler 호출
                if (window.setPremiumStatus) {
                    window.setPremiumStatus(
                        stateData.isPremium,
                        stateData.purchaseDate,
                        stateData.transactionId
                    );
                }
                
                // Context element 업데이트
                const contextElement = document.querySelector('[data-premium-context]') ||
                    (() => {
                        const el = document.createElement('div');
                        el.setAttribute('data-premium-context', 'true');
                        el.style.display = 'none';
                        document.body.appendChild(el);
                        return el;
                    })();
                contextElement.textContent = JSON.stringify(stateData);
                
                // 이벤트 발생
                window.dispatchEvent(new CustomEvent('updatePremiumStatus', {
                    detail: stateData
                }));
                
                return stateData;
            };

            // React가 마운트될 때까지 대기
            const waitForReact = new Promise((resolve) => {
                const check = () => {
                    if (window.__PREMIUM_CONTEXT__?.setState) {
                        resolve(updateState());
                    } else {
                        setTimeout(check, 100);
                    }
                };
                check();
            });

            // 최대 3초 대기
            return Promise.race([
                waitForReact,
                new Promise((_, reject) => 
                    setTimeout(() => reject('React mount timeout'), 3000)
                )
            ]);
        })();
        """
        
        do {
            let result = try await webView.evaluateJavaScript(script)
            print("✅ Premium state synced successfully:", result)
        } catch {
            print("❌ Failed to sync premium state:", error)
        }
    }

    private func notifyWebPremiumStatus(_ isPremium: Bool, purchaseDate: Date?, transactionId: String?) {
        let dateString = purchaseDate.map { formatDate($0) }
        
        let script = """
        (function() {
            const stateData = {
                isPremium: \(isPremium),
                purchaseDate: \(dateString.map { "'\($0)'" } ?? "null"),
                transactionId: \(transactionId.map { "'\($0)'" } ?? "null"),
                lastUpdated: new Date().toISOString()
            };
            
            console.log('[Premium] Setting status from native:', stateData);
            
            // Context Provider 상태 업데이트
            if (window.__PREMIUM_CONTEXT__?.setState) {
                window.__PREMIUM_CONTEXT__.setState({
                    isPremium: stateData.isPremium,
                    purchaseDate: stateData.purchaseDate,
                    transactionId: stateData.transactionId,
                    isProcessing: false,
                    showModal: false
                });
            }
            
            // Context Element 업데이트
            let contextElement = document.querySelector('[data-premium-context]');
            if (!contextElement) {
                contextElement = document.createElement('div');
                contextElement.setAttribute('data-premium-context', 'true');
                contextElement.style.display = 'none';
                document.body.appendChild(contextElement);
            }
            contextElement.textContent = JSON.stringify(stateData);
            
            // Premium Handlers 업데이트
            if (window.premiumHandlers?.setPremiumStatus) {
                window.premiumHandlers.setPremiumStatus(
                    stateData.isPremium,
                    stateData.purchaseDate,
                    stateData.transactionId
                );
            }
            
            // 이벤트 발생
            window.dispatchEvent(new CustomEvent('updatePremiumStatus', {
                detail: stateData
            }));
            
            return {
                success: true,
                state: stateData
            };
        })();
        """
        
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error = error {
                print("❌ Premium status update failed:", error.localizedDescription)
                return
            }
            
            print("✅ Premium status updated successfully")
            
            // 상태 검증
            self?.verifyPremiumStateSync()
        }
    }
    
    private func verifyPremiumStateSync() {
        let verificationScript = """
        (function() {
            const state = {
                contextState: document.querySelector('[data-premium-context]')?.textContent,
                providerState: window.__PREMIUM_CONTEXT__?.state,
                handlersState: window.premiumHandlers?.getState?.()
            };
            return state;
        })();
        """
        
        webView.evaluateJavaScript(verificationScript) { result, error in
            if let error = error {
                print("❌ State verification failed:", error.localizedDescription)
                return
            }
            
            if let state = result as? [String: Any] {
                print("\n=== Premium State Verification ===")
                if let contextState = state["contextState"] as? String {
                    print("Context Element:", contextState)
                }
                if let providerState = state["providerState"] as? [String: Any] {
                    print("Provider State:", providerState)
                }
                print("==============================\n")
            }
        }
    }
    
    func syncInitialPremiumState() {
        let script = """
        (function() {
            let readyAttempts = 0;
            const maxAttempts = 10;
            
            function checkReady() {
                const isReady = window.__PREMIUM_CONTEXT__?.setState && window.premiumHandlers;
                console.log('[Premium] Context ready:', isReady);
                return isReady;
            }
            
            if (checkReady()) {
                return { ready: true, attempts: 1 };
            }
            
            return new Promise((resolve) => {
                const interval = setInterval(() => {
                    readyAttempts++;
                    if (checkReady() || readyAttempts >= maxAttempts) {
                        clearInterval(interval);
                        resolve({
                            ready: checkReady(),
                            attempts: readyAttempts
                        });
                    }
                }, 500);
            });
        })();
        """
        
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result as? [String: Any],
               let ready = result["ready"] as? Bool {
                print("Premium context ready:", ready)
                
                if ready {
                    if let purchaseDate = UserDefaults.standard.premiumPurchaseDate,
                       let transactionId = UserDefaults.standard.premiumTransactionId {
                        self.notifyWebPremiumStatus(true, purchaseDate: purchaseDate, transactionId: transactionId)
                    } else {
                        self.notifyWebPremiumStatus(false, purchaseDate: nil, transactionId: nil)
                    }
                }
            }
        }
    }

    private func waitForPremiumHandlersReady() async {
        print("⏳ Waiting for premium handlers and React context...")

        let script = """
        (function() {
            return new Promise((resolve) => {
                const maxAttempts = 20;
                let attempts = 0;

                function checkReady() {
                    const ready = !!(window.__PREMIUM_CONTEXT__?.setState && window.premiumHandlers);
                    console.log(`Checking premium handlers (attempt ${attempts + 1}): ${ready ? 'Ready' : 'Not ready'}`);

                    if (ready) {
                        resolve({ success: true, attempts: attempts + 1 });
                    } else {
                        attempts++;
                        if (attempts < maxAttempts) {
                            setTimeout(checkReady, 300);
                        } else {
                            resolve({ success: false, attempts });
                        }
                    }
                }

                checkReady();
            });
        })();
        """

        let result: [String: Any]? = await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                self?.webView.evaluateJavaScript(script) { result, error in
                    continuation.resume(returning: result as? [String: Any])
                }
            }
        }

        if let result = result,
           let success = result["success"] as? Bool,
           let attempts = result["attempts"] as? Int {
            if success {
                print("✅ Premium handlers ready after \(attempts) attempts")
            } else {
                print("❌ Premium handlers not ready after \(attempts) attempts")
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("✅ WebView loaded - Waiting for React initialization")
        
        // React 초기화 확인 스크립트
        let checkScript = """
        (function() {
            const reactReady = !!window.__PREMIUM_CONTEXT__;
            console.log('[Premium] React context ready:', reactReady);
            return reactReady;
        })();
        """
        
        // 3초 후에 상태 동기화 시도
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.webView.evaluateJavaScript(checkScript) { result, error in
                guard let self = self else { return }
                
                let reactReady = (result as? Bool) ?? false
                if reactReady {
                    if let purchaseDate = UserDefaults.standard.premiumPurchaseDate,
                       let transactionId = UserDefaults.standard.premiumTransactionId {
                        print("📱 Syncing premium state (Active)")
                        self.notifyWebPremiumStatus(true, purchaseDate: purchaseDate, transactionId: transactionId)
                    } else {
                        print("📱 Syncing premium state (Inactive)")
                        self.notifyWebPremiumStatus(false, purchaseDate: nil, transactionId: nil)
                    }
                } else {
                    print("⚠️ React context not ready, retrying in 1 second...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.webView.evaluateJavaScript(checkScript) { result, _ in
                            if (result as? Bool) ?? false {
                                print("📱 React context now ready, syncing state...")
                                if let purchaseDate = UserDefaults.standard.premiumPurchaseDate,
                                   let transactionId = UserDefaults.standard.premiumTransactionId {
                                    self.notifyWebPremiumStatus(true, purchaseDate: purchaseDate, transactionId: transactionId)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func retryPremiumStatusUpdate(isPremium: Bool, purchaseDate: Date?, transactionId: String?) {
        let verificationScript = """
        (function() {
            if (!window.__PREMIUM_CONTEXT__) {
                console.log('[Premium] React context not ready');
                return { ready: false };
            }
            
            return {
                ready: true,
                state: window.__PREMIUM_CONTEXT__.state
            };
        })();
        """
        
        webView.evaluateJavaScript(verificationScript) { [weak self] result, error in
            if let result = result as? [String: Any],
               (result["ready"] as? Bool == true) {
                print("📱 Retrying premium status update...")
                self?.notifyWebPremiumStatus(isPremium, purchaseDate: purchaseDate, transactionId: transactionId)
            } else {
                print("❌ React context still not ready, giving up")
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    
    private func verifyWebState() {
        let verificationScript = """
        (function() {
            const state = {
                reactState: window.__PREMIUM_CONTEXT__?.state,
                contextElement: document.querySelector('[data-premium-context]')?.textContent,
                isPremiumValue: window.__PREMIUM_CONTEXT__?.state?.isPremium === true,
                purchaseDate: window.__PREMIUM_CONTEXT__?.state?.purchaseDate,
                transactionId: window.__PREMIUM_CONTEXT__?.state?.transactionId
            };
            console.log('[Premium] State check:', state);
            return state;
        })();
        """
        
        webView.evaluateJavaScript(verificationScript) { result, error in
            if let error = error {
                print("❌ State verification failed:", error)
                return
            }
            
            if let state = result as? [String: Any] {
                print("\n=== Web State Verification ===")
                print("isPremium:", state["isPremiumValue"] as? Bool ?? false)
                print("purchaseDate:", state["purchaseDate"] as? String ?? "nil")
                print("transactionId:", state["transactionId"] as? String ?? "nil")
                print("===========================\n")
            }
        }
    }
    
    // MARK: - Premium Status Management
    private func updatePremiumStatus(isPremium: Bool, purchaseDate: Date?, transactionId: String?) {
        // 1. UserDefaults 업데이트
        if isPremium {
            UserDefaults.standard.premiumPurchaseDate = purchaseDate
            UserDefaults.standard.premiumTransactionId = transactionId
        } else {
            UserDefaults.standard.resetPremiumStatus()
        }
        
        // 2. 웹 상태 동기화
        notifyWebPremiumStatus(isPremium, purchaseDate: purchaseDate, transactionId: transactionId)
        
        // 3. 로깅
        print("\n=== Premium Status Update ===")
        print("Status: \(isPremium ? "Active" : "Inactive")")
        if let date = purchaseDate {
            print("Purchase Date: \(formatDate(date))")
        }
        if let id = transactionId {
            print("Transaction ID: \(id)")
        }
        print("===========================\n")
    }

    // Purchase Success Handler
    private func handlePurchaseSuccess(_ verification: VerificationResult<Transaction>) async {
        switch verification {
        case .verified(let transaction):
            print("✅ Transaction verified:", transaction.id)
            updatePremiumStatus(
                isPremium: true,
                purchaseDate: transaction.purchaseDate,
                transactionId: transaction.id.description
            )
            await transaction.finish()
            showAlert(message: "구매가 완료되었습니다.")
            
        case .unverified(let transaction, let error):
            print("❌ Transaction verification failed:", error)
            updatePremiumStatus(isPremium: false, purchaseDate: nil, transactionId: nil)
            await transaction.finish()
            handlePurchaseFailure(message: "구매 검증에 실패했습니다.")
        }
    }
    
    // Reset Premium Status
    func resetPremiumStatus() {
        updatePremiumStatus(isPremium: false, purchaseDate: nil, transactionId: nil)
        print("✅ Premium status reset completed")
    }
    
    // Verify Premium Status
    func verifyAndUpdatePremiumStatus() async -> Bool {
        // 빠른 응답을 위해 UserDefaults 먼저 확인
//        if let purchaseDate = UserDefaults.standard.premiumPurchaseDate {
//            // 구매 날짜가 있는 경우 유효한 트랜잭션 확인
//            for await result in Transaction.currentEntitlements {
//                if case .verified(let transaction) = result, transaction.revocationDate == nil {
//                    print("✅ 유효한 트랜잭션 찾음")
//                    return true
//                }
//            }
//            // 유효한 트랜잭션이 없는 경우 UserDefaults 지우기
//            UserDefaults.standard.clearPremiumStatus()
//            print("⚠️ UserDefaults 지움 - 일치하는 트랜잭션을 찾을 수 없음")
//        }

        // UserDefaults에 없으면 새 유효한 트랜잭션 확인
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil {
                // UserDefaults를 새 구매 정보로 업데이트
                UserDefaults.standard.premiumPurchaseDate = transaction.purchaseDate
                UserDefaults.standard.premiumTransactionId = transaction.id.description
                print("✅ 유효한 트랜잭션 찾음 및 UserDefaults 업데이트")
                return true
            }
        }

        print("❌ 활성 프리미엄 구독을 찾을 수 없음")
        return false
    }

    // StoreKit Configuration 체크 (디버그용)
    #if DEBUG
    func checkStoreKitConfig() {
        Task {
            do {
                let products = try await Product.products(for: [Environment.StoreKit.premiumProductID])
                print("\n🛍 Available Products:")
                print("--------------------------------")
                products.forEach { product in
                    print("ID: \(product.id)")
                    print("Name: \(product.displayName)")
                    print("Price: \(product.price)")
                    print("Description: \(product.description)")
                    print("--------------------------------")
                }
            } catch {
                print("❌ Failed to fetch products: \(error)")
            }
        }
    }
    #endif

    func verifyPremiumStatus() {
        guard let purchaseDate = UserDefaults.standard.premiumPurchaseDate else {
            print("ℹ️ No premium purchase found")
            return
        }
        
        // 검증 로직
        let currentDate = Date()
//        let calendar = Calendar.current
        
        // 구매 날짜가 미래인 경우 검증 실패
        if purchaseDate > currentDate {
            print("⚠️ Invalid purchase date detected")
            UserDefaults.standard.resetPremiumStatus()
            return
        }
        
        print("✅ Premium status verified successfully")
    }
}

// UserDefaults extension 개선
extension UserDefaults {
    private enum Keys {
        static let premiumPurchaseDate = "premiumPurchaseDate"
        static let premiumTransactionId = "premiumTransactionId"
    }
}

extension ViewController {
    // AppDelegate나 SceneDelegate에서 호출할 수 있는 앱 시작 로그
    func logAppStart() {
        let logMessage = """
        
        ========================================
        🚀 App Started
        📱 Premium Status Check
        ========================================
        """
        print(logMessage)
        
        // Premium 상태 로깅
        if let purchaseDate = UserDefaults.standard.premiumPurchaseDate {
            print("💎 Current Premium Status: Active")
            print("📅 Purchase Date: \(formatDate(purchaseDate))")
            if let transactionId = UserDefaults.standard.string(forKey: "premiumTransactionId") {
                print("🔑 Transaction ID: \(transactionId)")
            }
        } else {
            print("💎 Current Premium Status: Inactive")
        }
        print("========================================\n")
    }
}

// 앱 시작 시 Premium 상태 체크
extension ViewController {
    func checkInitialPremiumStatus() {
        if let purchaseDate = UserDefaults.standard.premiumPurchaseDate {
            let transactionId = UserDefaults.standard.string(forKey: "premiumTransactionId")
            handlePremiumStatusChange(
                isPremium: true,
                purchaseDate: purchaseDate,
                transactionId: transactionId
            )
        } else {
            handlePremiumStatusChange(
                isPremium: false,
                purchaseDate: nil,
                transactionId: nil
            )
        }
    }
}

extension UserDefaults {
    static let premiumTransactionIdKey = "premiumTransactionId"
    static let premiumPurchaseDateKey = "premiumPurchaseDate"
    
    var premiumPurchaseDate: Date? {
        get { object(forKey: Self.premiumPurchaseDateKey) as? Date }
        set { set(newValue, forKey: Self.premiumPurchaseDateKey) }
    }
    
    var premiumTransactionId: String? {
        get { string(forKey: Self.premiumTransactionIdKey) }
        set { set(newValue, forKey: Self.premiumTransactionIdKey) }
    }
    
    func resetPremiumStatus() {
        print("🔄 Resetting premium status in UserDefaults...")
        removeObject(forKey: "premiumPurchaseDate")
        removeObject(forKey: "premiumTransactionId")
        removeObject(forKey: "isPremium")
        synchronize()
        print("✅ UserDefaults reset completed")
    }

}

// Premium 상태 관리를 위한 extension
extension UserDefaults {
    var isPremiumPurchased: Bool {
        return object(forKey: "premiumPurchaseDate") != nil
    }
    
    func clearPremiumStatus() {
        removeObject(forKey: "premiumPurchaseDate")
        removeObject(forKey: "premiumTransactionId")
        synchronize()
    }
}

#if DEBUG || targetEnvironment(simulator)
// MARK: - Test Environment Extension
extension ViewController {
    func setupTestEnvironment() {
        guard Environment.isTestEnvironment else { return }
        
        print("🧪 Setting up test environment...")
        
        // AdMob 테스트 설정
        setupTestAdMob()
        
        // 테스트 UI 추가
        setupTestUI()
        
        // 환경 정보 출력
        Environment.printEnvironmentInfo()
    }
    
    private func setupTestAdMob() {
        // 테스트 기기 설정
        GADMobileAds.sharedInstance().requestConfiguration.testDeviceIdentifiers = Environment.AdMob.testDeviceIdentifiers
        
        print("📱 AdMob Test Configuration:")
        print("- Ad Unit ID: \(Environment.AdMob.interstitialID)")
        print("- Test Devices: \(Environment.AdMob.testDeviceIdentifiers)")
    }
    
    private func setupTestUI() {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)
        stackView.layer.zPosition = 999 // 항상 최상위에 표시
        
        NSLayoutConstraint.activate([
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            stackView.widthAnchor.constraint(equalToConstant: 150)
        ])
        
        // 테스트 버튼 추가
        let testButtons: [(String, UIColor, Selector)] = [
            ("Test Ad", .systemBlue, #selector(testAdButtonTapped)),
            ("Reset Purchase", .systemRed, #selector(testResetPurchaseButtonTapped)),
            ("Check Status", .systemGreen, #selector(testCheckStatusButtonTapped))
        ]
        
        testButtons.forEach { title, color, selector in
            let button = createTestButton(title: title, color: color)
            button.addTarget(self, action: selector, for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }
    }
    
    private func createTestButton(title: String, color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.backgroundColor = color
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return button
    }
    
    @objc private func testAdButtonTapped() {
        print("🎯 Testing ad display...")
        adManager?.showInterstitial()
    }
    
    @objc private func testResetPurchaseButtonTapped() {
        Task {
            await resetPurchaseStateForTesting()
        }
    }
    
    @objc private func testCheckStatusButtonTapped() {
        Task {
            let isPremium = await verifyPremiumStatus()
            let purchaseDate = UserDefaults.standard.premiumPurchaseDate
            let transactionId = UserDefaults.standard.string(forKey: "premiumTransactionId")
            
            let status = """
            === Premium Status ===
            활성화: \(isPremium)
            구매일: \(purchaseDate?.formatted() ?? "없음")
            거래ID: \(transactionId ?? "없음")
            ===================
            """
            
            print(status)
            showAlert(message: status)
        }
    }
    
    private func checkPremiumStatus() async -> Bool {
        // 1. UserDefaults 체크
        if let purchaseDate = UserDefaults.standard.premiumPurchaseDate {
            print("📅 Found purchase date in UserDefaults: \(purchaseDate)")
            return true
        }
        
        // 2. StoreKit 트랜잭션 체크
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                print("✅ Found valid transaction: \(transaction.id)")
                return true
            }
        }
        
        print("❌ No valid purchase found")
        return false
    }
}
#endif

extension ViewController {
    // JavaScript 실행 함수
    private func executeJavaScript(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(script) { (result, error) in
                if let error = error {
                    print("❌ JavaScript execution error: \(error.localizedDescription)")
                } else {
                    print("✅ JavaScript executed successfully")
                }
            }
        }
    }
    
    // JavaScript 실행 함수 (async 버전)
    private func executeJavaScriptAsync(_ script: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in  // <-- Specify Void
            DispatchQueue.main.async { [weak self] in
                self?.webView.evaluateJavaScript(script) { result, error in
                    if let error = error {
                        print("❌ JavaScript execution error:", error.localizedDescription)
                    } else {
                        print("✅ JavaScript executed successfully")
                    }
                    continuation.resume()
                }
            }
        }
    }
    
    private func resetPurchaseStateForTesting() async {
        print("\n🧹 Starting complete purchase state reset...")
        
        do {
            // 1. UserDefaults 초기화
            print("Resetting UserDefaults...")
            UserDefaults.standard.resetPremiumStatus()
            
            // 2. 모든 트랜잭션 완료 처리
            print("Finishing all transactions...")
            for await result in Transaction.currentEntitlements {
                switch result {
                case .verified(let transaction):
                    print("- Finishing transaction: \(transaction.id)")
                    await transaction.finish()
                case .unverified(let transaction, let verificationError):
                    print("- Finishing unverified transaction: \(verificationError.localizedDescription)")
                    await transaction.finish()
                }
            }
            
            // 3. StoreKit 상태 동기화
            try await AppStore.sync()
            
            // 4. 웹 상태 초기화 - React 상태 즉시 동기화
            print("Resetting web state...")
            let resetScript = """
            (function() {
                return new Promise((resolve) => {
                    const updateState = () => {
                        try {
                            // React context state 직접 업데이트
                            if (window.__PREMIUM_CONTEXT__?.setState) {
                                window.__PREMIUM_CONTEXT__.setState({
                                    isPremium: false,
                                    purchaseDate: null,
                                    transactionId: null,
                                    showModal: false,
                                    isProcessing: false
                                });
                            }
                            
                            // Premium handlers 업데이트
                            if (window.premiumHandlers?.setPremiumStatus) {
                                window.premiumHandlers.setPremiumStatus(false, null, null);
                            }
                            
                            // Context element 업데이트
                            const contextElement = document.querySelector('[data-premium-context]');
                            if (contextElement) {
                                contextElement.textContent = JSON.stringify({
                                    isPremium: false,
                                    purchaseDate: null,
                                    transactionId: null,
                                    lastUpdated: new Date().toISOString()
                                });
                            }
                            
                            // 이벤트 발생
                            window.dispatchEvent(new CustomEvent('updatePremiumStatus', {
                                detail: {
                                    isPremium: false,
                                    purchaseDate: null,
                                    transactionId: null
                                }
                            }));
                            
                            window.dispatchEvent(new CustomEvent('premiumStatusChanged', {
                                detail: {
                                    isPremium: false,
                                    purchaseDate: null
                                }
                            }));
                            
                            return true;
                        } catch (error) {
                            console.error('Failed to update state:', error);
                            return false;
                        }
                    };
                    
                    // React context가 준비될 때까지 대기
                    if (window.__PREMIUM_CONTEXT__?.setState) {
                        resolve(updateState());
                    } else {
                        const checkInterval = setInterval(() => {
                            if (window.__PREMIUM_CONTEXT__?.setState) {
                                clearInterval(checkInterval);
                                resolve(updateState());
                            }
                        }, 100);
                        
                        // 최대 3초 대기
                        setTimeout(() => {
                            clearInterval(checkInterval);
                            resolve(updateState());
                        }, 3000);
                    }
                });
            })();
            """
            
            // 스크립트 실행 및 결과 대기
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.main.async { [weak self] in
                    self?.webView.evaluateJavaScript(resetScript) { result, error in
                        if let error = error {
                            print("❌ Web reset error:", error.localizedDescription)
                            continuation.resume(returning: false)
                        } else {
                            print("✅ Web state reset script executed successfully")
                            continuation.resume(returning: true)
                        }
                    }
                }
            }
            
            // 5. 상태 업데이트 검증
            if result {
                // 검증 스크립트 실행
                let verificationScript = """
                (function() {
                    const state = {
                        reactContext: window.__PREMIUM_CONTEXT__?.state,
                        contextElement: document.querySelector('[data-premium-context]')?.textContent,
                        handlersAvailable: !!window.premiumHandlers
                    };
                    console.log('Verification state:', state);
                    return state;
                })();
                """
                
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { [weak self] in
                        self?.webView.evaluateJavaScript(verificationScript) { result, _ in
                            if let state = result as? [String: Any] {
                                print("State verification completed:")
                                print("- React Context:", state["reactContext"] ?? "Not found")
                                print("- Context Element:", state["contextElement"] ?? "Not found")
                                print("- Handlers Available:", state["handlersAvailable"] ?? "Unknown")
                            }
                            continuation.resume()
                        }
                    }
                }
            }
            
            print("✅ Purchase state reset completed\n")
            showAlert(message: "구매 상태가 초기화되었습니다.")
            
        } catch {
            print("❌ Error during reset:", error.localizedDescription)
            showAlert(message: "초기화 중 오류가 발생했습니다.")
        }
    }
    
    private func verifyPremiumStatus() async -> Bool {
        print("\n🔍 Verifying premium status...")
        
        // 1. UserDefaults 확인
        let hasUserDefaultsData = UserDefaults.standard.premiumPurchaseDate != nil
        
        if hasUserDefaultsData {
            print("- Found purchase date in UserDefaults")
        } else {
            print("- No purchase data in UserDefaults")
            await syncWebPremiumState(isPremium: false)
            return false
        }
        
        // 2. 현재 활성 트랜잭션 확인
        var isValid = false
        
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                print("- Found transaction:", transaction.id)
                if transaction.revocationDate == nil {
                    isValid = true
                    print("  → Valid transaction")
                    await syncWebPremiumState(isPremium: true, transaction: transaction)
                } else {
                    print("  → Transaction revoked")
                    await syncWebPremiumState(isPremium: false)
                }
            case .unverified(_, let error):
                print("⚠️ Unverified transaction:", error.localizedDescription)
            }
        }
        
        return isValid && hasUserDefaultsData
    }

    // 웹 상태 동기화 헬퍼 함수
    private func syncWebPremiumState(isPremium: Bool, transaction: Transaction? = nil) async {
        let script = """
        (function() {
            if (window.premiumHandlers) {
                window.premiumHandlers.setPremiumStatus(
                    \(isPremium),
                    \(transaction.map { "'\(formatDate($0.purchaseDate))'" } ?? "null"),
                    \(transaction.map { "'\($0.id)'" } ?? "null")
                );
                
                const event = new CustomEvent('premiumStatusChanged', {
                    detail: {
                        isPremium: \(isPremium),
                        purchaseDate: \(transaction.map { "'\(formatDate($0.purchaseDate))'" } ?? "null")
                    }
                });
                window.dispatchEvent(event);
            }
            return true;
        })();
        """
        
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                self?.webView.evaluateJavaScript(script) { result, error in
                    if let error = error {
                        print("❌ Failed to sync web state:", error.localizedDescription)
                    } else if let success = result as? Bool, success {
                        print("✅ Web state synced successfully")
                    }
                    continuation.resume()
                }
            }
        }
    }
}

extension ViewController {
    private func setupAdManager() {
        // 광고 이미지 이름 설정 (확장자 제외)
        let adImageNames = ["smap_ad1", "smap_ad2", "smap_ad3", "smap_ad4", "smap_ad5", "smap_ad6"]
        
        if let adManager = AdManager(viewController: self,
                                   delegate: self,
                                   adImageNames: adImageNames) {
            self.adManager = adManager
            print("✅ Ad Manager setup completed")
        } else {
            print("❌ Failed to initialize Ad Manager")
        }
    }

    // MARK: - Purchase State Update
    func handlePurchaseSuccess(_ transaction: Transaction) async {
        print("✅ Purchase successful - Updating state...")
        
        // 1. UserDefaults 업데이트
        UserDefaults.standard.premiumPurchaseDate = transaction.purchaseDate
        UserDefaults.standard.premiumTransactionId = transaction.id.description
        
        // 2. 웹 상태 업데이트
        let updateScript = """
        (function() {
            const purchaseDate = '\(formatDate(transaction.purchaseDate))';
            const transactionId = '\(transaction.id)';
            
            console.log('Updating premium state after purchase:', {
                isPremium: true,
                purchaseDate,
                transactionId
            });
            
            // Premium handlers 업데이트
            if (window.premiumHandlers) {
                window.premiumHandlers.setPremiumStatus(true, purchaseDate, transactionId);
            }
            
            // Context element 업데이트
            const contextElement = document.querySelector('[data-premium-context]');
            if (contextElement) {
                contextElement.textContent = JSON.stringify({
                    isPremium: true,
                    purchaseDate,
                    transactionId
                });
            }
            
            // 이벤트 발생
            const events = [
                new CustomEvent('updatePremiumStatus', {
                    detail: { isPremium: true, purchaseDate, transactionId }
                }),
                new CustomEvent('premiumStatusChanged', {
                    detail: { isPremium: true, purchaseDate }
                })
            ];
            
            events.forEach(event => window.dispatchEvent(event));
            
            // 구매 성공 콜백 실행
            if (window.onPremiumPurchaseSuccess) {
                window.onPremiumPurchaseSuccess();
            }
            
            return true;
        })();
        """
        
        await executeJavaScriptAsync(updateScript)
        print("✅ Web state updated after purchase")
    }
    
    // MARK: - Purchase Cancel/Reset
    func handlePurchaseCancel() {
        print("🚫 Purchase cancelled - Resetting state...")
        
        // 1. UserDefaults 초기화
        UserDefaults.standard.resetPremiumStatus()
        
        // 2. 웹 상태 업데이트
        let resetScript = """
        (function() {
            console.log('Resetting premium state after cancellation');
            
            // Premium handlers 초기화
            if (window.premiumHandlers) {
                window.premiumHandlers.setPremiumStatus(false, null, null);
            }
            
            // Context element 초기화
            const contextElement = document.querySelector('[data-premium-context]');
            if (contextElement) {
                contextElement.textContent = JSON.stringify({
                    isPremium: false,
                    purchaseDate: null,
                    transactionId: null
                });
            }
            
            // 이벤트 발생
            const events = [
                new CustomEvent('updatePremiumStatus', {
                    detail: { isPremium: false, purchaseDate: null, transactionId: null }
                }),
                new CustomEvent('premiumStatusChanged', {
                    detail: { isPremium: false, purchaseDate: null }
                })
            ];
            
            events.forEach(event => window.dispatchEvent(event));
            
            // 구매 실패 콜백 실행
            if (window.onPremiumPurchaseFailure) {
                window.onPremiumPurchaseFailure('Purchase cancelled');
            }
            
            return true;
        })();
        """
        
        executeJavaScript(resetScript)
        print("✅ Web state reset after cancellation")
    }
}

// JSON Encoding Helper
extension Dictionary {
    var jsonString: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
