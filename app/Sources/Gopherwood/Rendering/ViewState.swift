import SwiftUI

/// SwiftUI's State property wrapper. In the macOS 27 SDK, `@State` expands through a macro
/// whose plugin ships with Xcode only, so a build with the Command Line Tools cannot use it;
/// this alias names the property wrapper itself, which works with either.
typealias ViewState<Value> = SwiftUI.State<Value>
