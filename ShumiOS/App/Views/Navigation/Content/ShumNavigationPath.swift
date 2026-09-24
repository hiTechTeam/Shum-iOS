import Foundation

/// A list or dismissed card can still deliver another tap during a push.
/// Once a conversation is at the top, only Back may reveal its source again.
extension Array where Element == ShumUIRoute {
    mutating func push(_ route: ShumUIRoute) {
        guard last?.containsMessages != true, last != route else { return }
        append(route)
    }
}

extension Array where Element == ShumProfileRoute {
    mutating func push(_ route: ShumProfileRoute) {
        if case .conversation = last { return }
        guard last != route else { return }
        append(route)
    }
}
