import Foundation
import WebKit

final class PremiumStatusChecker {
    private var retryCount = 0
    private let maxRetries = 5
    private weak var delegate: PremiumStatusHandling?
    
    init(delegate: PremiumStatusHandling) {
        self.delegate = delegate
    }
    
    func verifyPremiumStatus() {
        if retryCount >= maxRetries {
            print("⚠️ Max retry attempts (\(maxRetries)) reached for premium status verification")
            retryCount = 0
            return
        }

        retryCount += 1
        print("🔄 Verifying premium status (attempt \(retryCount)/\(maxRetries))...")
        
        let verificationScript = """
        (function() {
            return new Promise((resolve) => {
                function isAppMounted() {
                    const requiredComponents = {
                        headerSection: document.querySelector('[data-component="header-section"]'),
                        premiumButton: document.querySelector('[data-component="premium-button"]'),
                        practiceButton: document.querySelector('[data-component="practice-button"]'),
                        timeAttackButton: document.querySelector('[data-component="time-attack-button"]'),
                        statusSection: document.querySelector('[data-component="status-section"]')
                    };
                    
                    const checkResult = {
                        hasHeaderSection: !!requiredComponents.headerSection,
                        hasPremiumButton: !!requiredComponents.premiumButton,
                        hasPracticeButton: !!requiredComponents.practiceButton,
                        hasTimeAttackButton: !!requiredComponents.timeAttackButton,
                        hasStatusSection: !!requiredComponents.statusSection
                    };
                    
                    const isMounted = checkResult.hasHeaderSection || 
                                    (checkResult.hasPracticeButton && checkResult.hasTimeAttackButton) ||
                                    checkResult.hasPremiumButton;
                    
                    console.log('App mount check:', JSON.stringify({
                        ...checkResult,
                        isMounted
                    }, null, 2));
                    
                    return isMounted;
                }

                function checkPremiumContext() {
                    const premiumContext = document.querySelector('[data-premium-context]');
                    console.log('Premium context element:', premiumContext);
                    
                    try {
                        if (premiumContext) {
                            const contextData = JSON.parse(premiumContext.textContent || '{}');
                            console.log('Premium context raw data:', premiumContext.textContent);
                            console.log('Parsed premium context data:', JSON.stringify(contextData, null, 2));
                            
                            const windowStatus = {
                                setPremiumStatus: typeof window.setPremiumStatus === 'function',
                                isPremiumActive: window.isPremiumActive,
                                onPremiumPurchaseSuccess: typeof window.onPremiumPurchaseSuccess === 'function',
                                onPremiumPurchaseFailure: typeof window.onPremiumPurchaseFailure === 'function'
                            };

                            console.log('Window status:', JSON.stringify(windowStatus, null, 2));
                            
                            resolve({
                                contextFound: true,
                                contextStatus: contextData.isPremium,
                                purchaseDate: contextData.purchaseDate,
                                windowStatus: windowStatus
                            });
                        } else {
                            console.log('Premium context element not found');
                            resolve({
                                contextFound: false,
                                needsRetry: true,
                                error: 'Premium context element not found',
                                windowStatus: {
                                    setPremiumStatus: typeof window.setPremiumStatus === 'function',
                                    isPremiumActive: window.isPremiumActive
                                }
                            });
                        }
                    } catch (e) {
                        console.error('Error parsing premium context:', e);
                        resolve({
                            contextFound: false,
                            needsRetry: true,
                            error: e.message
                        });
                    }
                }

                function waitForAppMount() {
                    let attempts = 0;
                    const maxAttempts = 10;
                    const checkInterval = 300;

                    function check() {
                        console.log('Checking app mount status (attempt ' + (attempts + 1) + ')');
                        
                        if (isAppMounted()) {
                            console.log('App mounted successfully');
                            checkPremiumContext();
                            return;
                        }

                        attempts++;
                        if (attempts >= maxAttempts) {
                            console.log('Failed to detect app mount after ' + maxAttempts + ' attempts');
                            resolve({
                                contextFound: false,
                                needsRetry: true,
                                error: 'App not mounted'
                            });
                            return;
                        }

                        setTimeout(check, checkInterval);
                    }

                    check();
                }

                waitForAppMount();
            });
        })();
        """
        delegate?.webView.evaluateJavaScript(verificationScript) { [weak self] (result: Any?, error: Error?) in
            guard let self = self else { return }
            
            if let error = error {
                print("❌ Premium status verification failed: \(error.localizedDescription)")
                if self.retryCount < self.maxRetries {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.verifyPremiumStatus()
                    }
                }
                return
            }
            
            if let result = result as? [String: Any] {
                print("✅ Premium status verification result:")
                print("Context found: \(result["contextFound"] ?? false)")
                print("Context status: \(result["contextStatus"] ?? "undefined")")
                print("Purchase date: \(result["purchaseDate"] ?? "undefined")")
                if let error = result["error"] as? String {
                    print("Error: \(error)")
                }
                
                if let needsRetry = result["needsRetry"] as? Bool, needsRetry {
                    if self.retryCount < self.maxRetries {
                        print("⏳ Scheduling retry...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.verifyPremiumStatus()
                        }
                    } else {
                        print("⚠️ Max retries reached, giving up")
                        self.retryCount = 0
                    }
                    return
                }
                
                // Context를 찾은 경우
                if result["contextFound"] as? Bool == true {
                    print("✅ Premium context found, syncing status...")
                    self.retryCount = 0  // 성공적으로 찾았으므로 카운터 리셋
                    
                    let hasContextPremium = (result["contextStatus"] as? Bool) ?? false
                    let hasPurchaseDate = UserDefaults.standard.premiumPurchaseDate != nil
                    
                    if hasContextPremium != hasPurchaseDate {
                        print("🔄 Syncing premium status due to mismatch...")
                        self.syncPremiumStatus()
                    }
                }
            }
        }
    }
   
   func syncPremiumStatus() {
        let hasPurchase = UserDefaults.standard.premiumPurchaseDate != nil
        print("📱 iOS Premium Status - hasPurchase:", hasPurchase)
        if let purchaseDate = UserDefaults.standard.premiumPurchaseDate {
            print("📱 iOS Premium Status - purchaseDate:", purchaseDate)
        }
        
        let dateString = UserDefaults.standard.premiumPurchaseDate.map { formatDate($0) } ?? "null"
        
       let synchronizationScript = """
       (function() {
           console.log('Starting premium status synchronization...');
           console.log('Setting premium status to:', {
               isPremium: \(hasPurchase),
               purchaseDate: '\(dateString)'
           });
           
           if (window.setPremiumStatus) {
               window.setPremiumStatus(\(hasPurchase), \(dateString));
               console.log('Premium status set via window.setPremiumStatus');
           } else {
               console.warn('window.setPremiumStatus is not available');
           }
           
           // Premium context 강제 업데이트
           const contextElement = document.querySelector('[data-premium-context]');
           if (contextElement) {
               const newData = {
                   isPremium: \(hasPurchase),
                   purchaseDate: \(dateString)
               };
               contextElement.textContent = JSON.stringify(newData);
               console.log('Premium context element updated with:', JSON.stringify(newData));
           } else {
               console.warn('Premium context element not found');
           }
           
           // React 컴포넌트 상태 업데이트 이벤트
           const updateEvent = new CustomEvent('updatePremiumStatus', {
               detail: { 
                   isPremium: \(hasPurchase), 
                   purchaseDate: \(dateString)
               }
           });
           window.dispatchEvent(updateEvent);
           console.log('Premium status update event dispatched');
       })();
       """
       
      delegate?.executeJavaScript(synchronizationScript, completion: { _, _ in })
    }
   
   func resetPremiumStatus() {
       let resetScript = """
       (function() {
           // localStorage 초기화
           localStorage.removeItem('premiumStatus');
           localStorage.removeItem('purchaseDate');
           
           // Premium context 초기화
           const contextElement = document.querySelector('[data-premium-context]');
           if (contextElement) {
               contextElement.textContent = JSON.stringify({
                   isPremium: false,
                   purchaseDate: null
               });
           }
           
           // React 상태 업데이트 이벤트 발생
           const event = new CustomEvent('updatePremiumStatus', {
               detail: { 
                   isPremium: false, 
                   purchaseDate: null 
               }
           });
           window.dispatchEvent(event);
           
           console.log('Premium status has been reset');
       })();
       """
       
       print("🔄 Attempting to reset premium status...")
        UserDefaults.standard.premiumPurchaseDate = nil
        
        delegate?.webView.evaluateJavaScript(resetScript) { [weak self] (result: Any?, error: Error?) in
            if let error = error {
                print("❌ Failed to reset premium status:", error.localizedDescription)
            } else {
                print("✅ Premium status has been reset")
                self?.verifyPremiumStatus()
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
