import WebKit

extension WKWebView {
    func sendMessage(_ message: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        DispatchQueue.main.async {
            self.evaluateJavaScript("window.postMessage(\(jsonString), '*');", completionHandler: nil)
        }
    }
}