import Foundation

enum AppDebugFlags {
    #if DEBUG
    // Single switch for debugging subscription-gated functionality.
    // Set to false to restore normal entitlement checks in Debug builds.
    static let forceProSubscriptionAccess = true
    #else
    static let forceProSubscriptionAccess = false
    #endif
}
