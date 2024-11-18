import UIKit
import GoogleMobileAds
import SafariServices

protocol AdManagerDelegate: AnyObject {
    func adDidDismiss()
}

final class AdManager: NSObject {
    // MARK: - Properties
    private weak var viewController: UIViewController?
    private weak var delegate: AdManagerDelegate?
    private var interstitialAd: GADInterstitialAd?
    private var isInitialized = false
    private var isInitializing = false
    private var adLoadRetryCount = 0
    private let maxAdLoadRetries = 2
    private let customAdDuration: TimeInterval = 5.0
    private var shouldUseAdMob = true
    
    private var customAdImages: [UIImage] = []
    private var currentImageIndex = 0
    
    private var adUnitID: String {
        Environment.AdMob.interstitialID
    }
    
    // MARK: - Initialization
    init(viewController: UIViewController, delegate: AdManagerDelegate) {
        super.init()
        self.viewController = viewController
        self.delegate = delegate
        loadCustomAdImages()
        initializeAdMob()
    }
    
    // MARK: - AdMob Setup
    private func initializeAdMob() {
        // 프리미엄 사용자인 경우 초기화 건너뛰기
        if UserDefaults.standard.isPremiumPurchased {
            print("👑 Premium user detected, skipping AdMob initialization")
            return
        }
        
        guard !isInitialized && !isInitializing else { return }
        
        isInitializing = true
        print("🎯 Initializing AdMob...")
        
        let requestConfiguration = GADMobileAds.sharedInstance().requestConfiguration
        if Environment.isTestEnvironment {
            requestConfiguration.testDeviceIdentifiers = Environment.AdMob.testDeviceIdentifiers
        }
        
        GADMobileAds.sharedInstance().start { [weak self] status in
            guard let self = self else { return }
            self.isInitializing = false
            
            let isReady = status.adapterStatusesByClassName.values.allSatisfy { $0.state == .ready }
            if isReady {
                print("✅ AdMob initialized successfully")
                self.isInitialized = true
                if !UserDefaults.standard.isPremiumPurchased {
                    self.loadInterstitialAd()
                }
            } else {
                print("❌ AdMob initialization failed")
                self.shouldUseAdMob = false
            }
        }
    }
    
    // MARK: - Ad Loading
    private func loadInterstitialAd() {
        // 프리미엄 사용자인 경우 광고 로드 건너뛰기
        if UserDefaults.standard.isPremiumPurchased {
            print("👑 Premium user detected, skipping ad load")
            return
        }
        
        guard shouldUseAdMob else {
            print("⚠️ AdMob disabled due to previous failures")
            return
        }
        
        guard adLoadRetryCount < maxAdLoadRetries else {
            print("⚠️ Maximum AdMob retry attempts reached, switching to local ads only")
            shouldUseAdMob = false
            return
        }
        
        print("🎯 Loading interstitial ad (Attempt \(adLoadRetryCount + 1)/\(maxAdLoadRetries))")
        let request = GADRequest()
        
        GADInterstitialAd.load(withAdUnitID: adUnitID, request: request) { [weak self] ad, error in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ Failed to load interstitial ad:", error.localizedDescription)
                self.adLoadRetryCount += 1
                
                if self.adLoadRetryCount >= self.maxAdLoadRetries {
                    print("⚠️ Maximum retry attempts reached, disabling AdMob")
                    self.shouldUseAdMob = false
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        self.loadInterstitialAd()
                    }
                }
                return
            }
            
            print("✅ Interstitial ad loaded successfully")
            self.interstitialAd = ad
            self.interstitialAd?.fullScreenContentDelegate = self
            self.adLoadRetryCount = 0
        }
    }
    
    // MARK: - Public Methods
    func showInterstitial() {
        guard let viewController = viewController else {
            print("⚠️ No view controller available")
            return
        }
        
        // 프리미엄 상태 확인
        if UserDefaults.standard.isPremiumPurchased {
            print("👑 Premium user detected, skipping ad")
            delegate?.adDidDismiss()
            return
        }
        
        if shouldUseAdMob, let interstitialAd = interstitialAd {
            print("🎯 Showing AdMob interstitial ad...")
            interstitialAd.present(fromRootViewController: viewController)
        } else {
            print("🎯 Showing local custom ad...")
            showCustomAd()
        }
    }

    
    // MARK: - Custom Ad View
    private let appStoreURL = "https://apps.apple.com/kr/app/smap-%EC%9C%84%EC%B9%98%EC%B6%94%EC%A0%81-%EC%9D%B4%EB%8F%99%EA%B2%BD%EB%A1%9C-%EC%9D%BC%EC%A0%95/id6480279658"
    
    private func showCustomAd() {
        guard let viewController = viewController else {
            print("❌ No view controller available for showing ad")
            delegate?.adDidDismiss()
            return
        }
        
        // 뷰 컨트롤러가 준비되었는지 확인
        guard viewController.view.window != nil else {
            print("⚠️ View controller is not in window hierarchy, retrying after delay...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showCustomAd()
            }
            return
        }
        
        print("🎯 Preparing to show custom ad...")
        
        let customAdVC = UIViewController()
        customAdVC.modalPresentationStyle = .fullScreen
        customAdVC.view.backgroundColor = .black
        
        // 광고 콘텐츠 버튼 (탭 가능한 영역)
        let adButton = UIButton(type: .custom)
        adButton.backgroundColor = .clear
        adButton.translatesAutoresizingMaskIntoConstraints = false
        adButton.addTarget(self, action: #selector(adContentTapped), for: .touchUpInside)
        
        // 컨테이너 뷰
        let containerView = UIView()
        containerView.backgroundColor = .clear
        containerView.translatesAutoresizingMaskIntoConstraints = false
        
        if let adImage = getNextAdImage() {
            print("✅ Using custom ad image")
            adButton.setImage(adImage, for: .normal)
            adButton.imageView?.contentMode = .scaleAspectFit
        } else {
            print("⚠️ No custom ad images, showing fallback UI")
            let fallbackView = createFallbackAdView()
            fallbackView.translatesAutoresizingMaskIntoConstraints = false
            adButton.addSubview(fallbackView)
            
            NSLayoutConstraint.activate([
                fallbackView.topAnchor.constraint(equalTo: adButton.topAnchor),
                fallbackView.leadingAnchor.constraint(equalTo: adButton.leadingAnchor),
                fallbackView.trailingAnchor.constraint(equalTo: adButton.trailingAnchor),
                fallbackView.bottomAnchor.constraint(equalTo: adButton.bottomAnchor)
            ])
        }
        
        // UI 설정
        containerView.addSubview(adButton)
        customAdVC.view.addSubview(containerView)
        
        // 닫기 버튼 및 타이머 레이블 설정
        let closeButton = createCloseButton()
        let timerLabel = createTimerLabel()
        let tapHintLabel = createTapHintLabel()
        
        customAdVC.view.addSubview(closeButton)
        customAdVC.view.addSubview(timerLabel)
        customAdVC.view.addSubview(tapHintLabel)
        
        // 레이아웃 설정
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: customAdVC.view.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: customAdVC.view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: customAdVC.view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: customAdVC.view.bottomAnchor),
            
            adButton.topAnchor.constraint(equalTo: containerView.topAnchor),
            adButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            adButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            adButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            
            closeButton.topAnchor.constraint(equalTo: customAdVC.view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: customAdVC.view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 100),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
            
            timerLabel.centerXAnchor.constraint(equalTo: customAdVC.view.centerXAnchor),
            timerLabel.bottomAnchor.constraint(equalTo: customAdVC.view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            timerLabel.widthAnchor.constraint(equalToConstant: 80),
            timerLabel.heightAnchor.constraint(equalToConstant: 40),
            
            tapHintLabel.centerXAnchor.constraint(equalTo: customAdVC.view.centerXAnchor),
            tapHintLabel.bottomAnchor.constraint(equalTo: timerLabel.topAnchor, constant: -8),
            tapHintLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            tapHintLabel.heightAnchor.constraint(equalToConstant: 30)
        ])
        
        // 타이머 설정
        setupTimer(timerLabel: timerLabel, customAdVC: customAdVC)
        
        print("🎯 Presenting custom ad...")
        DispatchQueue.main.async {
            viewController.present(customAdVC, animated: true) {
                print("✅ Custom ad presented successfully")
            }
        }
    }
    
    private func setupTimer(timerLabel: UILabel, customAdVC: UIViewController) {
        var remainingTime = Int(customAdDuration)
        timerLabel.text = "\(remainingTime)초"
        
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak timerLabel] timer in
            remainingTime -= 1
            timerLabel?.text = "\(remainingTime)초"
            
            if remainingTime <= 0 {
                timer.invalidate()
                self?.dismissCustomAd()
            }
        }
        
        // 타이머를 런루프에 추가
        RunLoop.current.add(timer, forMode: .common)
    }
    
    private func createCloseButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("광고 닫기", for: .normal)
        button.backgroundColor = .black.withAlphaComponent(0.7)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(dismissCustomAd), for: .touchUpInside)
        return button
    }
    
    private func createTimerLabel() -> UILabel {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = .black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
    
    private func createTapHintLabel() -> UILabel {
        let label = UILabel()
        label.text = "터치하여 앱스토어로 이동"
        label.textColor = .white
        label.font = .systemFont(ofSize: 14)
        label.textAlignment = .center
        label.backgroundColor = .black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
    
    @objc private func dismissCustomAd() {
        guard let viewController = viewController else { return }
        
        DispatchQueue.main.async {
            viewController.dismiss(animated: true) { [weak self] in
                print("✅ Custom ad dismissed")
                self?.delegate?.adDidDismiss()
            }
        }
    }
    
    @objc private func adContentTapped() {
        print("🎯 Ad content tapped, opening App Store...")
        
        guard let url = URL(string: appStoreURL) else {
            print("❌ Invalid App Store URL")
            return
        }
        
        // 앱스토어 열기
        DispatchQueue.main.async { [weak self] in
            UIApplication.shared.open(url) { success in
                if success {
                    print("✅ Successfully opened App Store")
                } else {
                    print("❌ Failed to open App Store")
                    // 실패 시 Safari로 열기 시도
                    let safariVC = SFSafariViewController(url: url)
                    self?.viewController?.present(safariVC, animated: true)
                }
            }
        }
    }

    private func createFallbackAdView() -> UIView {
        let fallbackView = UIView()
        fallbackView.backgroundColor = .systemGray6
        fallbackView.layer.cornerRadius = 12
        fallbackView.isUserInteractionEnabled = false  // 버튼의 탭 이벤트가 동작하도록 
        
        // 광고 제목
        let titleLabel = UILabel()
        titleLabel.text = "SMAP"
        titleLabel.font = .boldSystemFont(ofSize: 24)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // 광고 설명
        let descriptionLabel = UILabel()
        descriptionLabel.text = "SMAP으로 우리 가족 안전 지키세요."
        descriptionLabel.font = .systemFont(ofSize: 18)
        descriptionLabel.textAlignment = .center
        descriptionLabel.textColor = .gray
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // 로고 이미지나 아이콘
        let logoLabel = UILabel()
        logoLabel.text = ""
        logoLabel.font = .systemFont(ofSize: 48)
        logoLabel.textAlignment = .center
        logoLabel.translatesAutoresizingMaskIntoConstraints = false
        
        fallbackView.addSubview(titleLabel)
        fallbackView.addSubview(descriptionLabel)
        fallbackView.addSubview(logoLabel)
        
        NSLayoutConstraint.activate([
            logoLabel.centerXAnchor.constraint(equalTo: fallbackView.centerXAnchor),
            logoLabel.centerYAnchor.constraint(equalTo: fallbackView.centerYAnchor, constant: -30),
            
            titleLabel.centerXAnchor.constraint(equalTo: fallbackView.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: logoLabel.bottomAnchor, constant: 20),
            
            descriptionLabel.centerXAnchor.constraint(equalTo: fallbackView.centerXAnchor),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8)
        ])
        
        return fallbackView
    }
    
    // MARK: - Custom Ad Images
    private func loadCustomAdImages() {
        print("\n📂 Starting to load custom ad images...")
        
        // Asset catalog에서 직접 이미지 로드
        let imageNames = ["smap_ad1", "smap_ad2", "smap_ad3", "smap_ad4", "smap_ad5", "smap_ad6"]
        
        for imageName in imageNames {
            if let image = UIImage(named: imageName) {
                customAdImages.append(image)
                print("✅ Loaded image from assets: \(imageName)")
            } else {
                print("❌ Failed to load image: \(imageName)")
            }
        }
        
        // CustomAds 폴더에서도 이미지 로드 시도
        if let customAdsURL = Bundle.main.url(forResource: "CustomAds", withExtension: nil) {
            print("📁 Found CustomAds folder, checking for additional images...")
            
            do {
                let fileManager = FileManager.default
                let files = try fileManager.contentsOfDirectory(at: customAdsURL, includingPropertiesForKeys: nil)
                
                let imageFiles = files.filter { url in
                    let ext = url.pathExtension.lowercased()
                    return ["jpg", "jpeg", "png"].contains(ext)
                }
                
                for fileURL in imageFiles {
                    if let image = UIImage(contentsOfFile: fileURL.path) {
                        customAdImages.append(image)
                        print("✅ Loaded image from CustomAds: \(fileURL.lastPathComponent)")
                    }
                }
            } catch {
                print("ℹ️ No additional images found in CustomAds folder")
            }
        }
        
        print("\n📊 Final Results:")
        print("- Total loaded images: \(customAdImages.count)")
        
        if customAdImages.isEmpty {
            print("⚠️ No ad images were loaded!")
            print("Please check:")
            print("1. Image names in Assets.xcassets match exactly: smap_ad1, smap_ad2, etc.")
            print("2. Images are properly added to Assets.xcassets")
            print("3. Target membership is properly set")
        } else {
            print("✅ Successfully loaded \(customAdImages.count) images")
        }
        print("--------------------------------\n")
    }
    
    private func getNextAdImage() -> UIImage? {
        guard !customAdImages.isEmpty else { return nil }
        let image = customAdImages[currentImageIndex]
        currentImageIndex = (currentImageIndex + 1) % customAdImages.count
        return image
    }
}

// MARK: - GADFullScreenContentDelegate
extension AdManager: GADFullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        print("✅ AdMob ad dismissed")
        delegate?.adDidDismiss()
        
        // 프리미엄 상태가 아닐 때만 다음 광고 로드
        if !UserDefaults.standard.isPremiumPurchased {
            loadInterstitialAd()
        }
    }
    
    func ad(_ ad: GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        print("❌ AdMob ad failed to present:", error.localizedDescription)
        adLoadRetryCount += 1
        if adLoadRetryCount >= maxAdLoadRetries {
            print("⚠️ Maximum retry attempts reached, switching to local ads")
            shouldUseAdMob = false
        }
        
        // 프리미엄 상태가 아닐 때만 광고 표시
        if !UserDefaults.standard.isPremiumPurchased {
            showCustomAd()
        } else {
            delegate?.adDidDismiss()
        }
    }
}

extension AdManager {
    convenience init?(viewController: UIViewController, delegate: AdManagerDelegate, adImageNames: [String]) {
        self.init(viewController: viewController, delegate: delegate)
        
        print("\n📂 Loading ad images from resources...")
        
        // 각 이미지 이름에 대해 리소스 로드 시도
        for (index, name) in adImageNames.enumerated() {
            if let path = Bundle.main.path(forResource: name, ofType: "jpg"),
               let image = UIImage(contentsOfFile: path) {
                customAdImages.append(image)
                print("✅ Loaded image \(index + 1): \(name).jpg")
            } else if let path = Bundle.main.path(forResource: name, ofType: "png"),
                      let image = UIImage(contentsOfFile: path) {
                customAdImages.append(image)
                print("✅ Loaded image \(index + 1): \(name).png")
            } else {
                print("❌ Failed to load image: \(name)")
            }
        }
        
        print("\n📊 Ad Image Loading Results:")
        print("- Attempted to load: \(adImageNames.count) images")
        print("- Successfully loaded: \(customAdImages.count) images")
        
        // 이미지가 하나도 없으면 초기화 실패
        if customAdImages.isEmpty {
            print("⚠️ No images were loaded successfully")
            return nil
        }
        
        print("✅ Ad Manager initialized with \(customAdImages.count) images")
        print("--------------------------------\n")
    }
}
