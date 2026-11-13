import SwiftUI
import UIKit

/// 收起键盘（Form 里没有回车收键盘的默认行为）
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// 键盘上方加一个「收起」按钮 + 允许下滑收键盘
    func keyboardDoneButton(_ focused: FocusState<Bool>.Binding) -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { focused.wrappedValue = false }
                }
            }
    }
}
