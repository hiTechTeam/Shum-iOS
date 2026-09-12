import Foundation
import UIKit

@MainActor
final class NextButtonViewModel: ObservableObject {
    
    // MARK: - Constants and Variables
    var action: () -> Void = {}
    
    // MARK: - Functions
    /// Go next registrationa - toggle the scan
    func nextAction() {
        action()
    }
}
