// Type-erased button style, so a view can pick between concrete styles
// (e.g. .bordered vs .borderedProminent) with a ternary.

import SwiftUI

struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
