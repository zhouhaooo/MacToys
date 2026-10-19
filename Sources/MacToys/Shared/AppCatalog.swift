// SPDX-License-Identifier: MIT
import Foundation
struct AppIdentity: Equatable {
    var bundleID: String? = nil
    var name: String? = nil
}
enum AppCatalog {
    static let finder = "com.apple.finder"
}
