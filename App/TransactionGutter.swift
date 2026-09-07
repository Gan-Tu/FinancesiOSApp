import SwiftUI

/// Status adornments never change the common leading edge of transaction text.
struct TransactionGutter: View {
    let cleared: Bool
    let hasAttachment: Bool
    var body: some View {
        VStack(spacing: 0) {
            if !cleared { Circle().fill(Color(uiColor: .systemGray)).frame(width: 12, height: 12).frame(height: 20) }
            if hasAttachment { Image(systemName: "paperclip").font(.system(size: 16)).foregroundColor(Color(uiColor: .systemGray)).frame(height: 20) }
        }
        .frame(width: 18, alignment: .center)
        .offset(x: -22, y: 3)
        .accessibilityHidden(true)
    }
}
