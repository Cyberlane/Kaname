import SwiftUI
import KanamePrototypeUI

@main
struct KanameIPhonePrototypeApp: App {
    var body: some Scene {
        WindowGroup {
            IPhoneControlSurface()
                .preferredColorScheme(.dark)
        }
    }
}
