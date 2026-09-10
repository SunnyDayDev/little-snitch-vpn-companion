import SwiftUI

/// Мост между представлением состояния helper (Application) и тонами
/// дизайн-системы: экраны не переводят тона сами.
extension HelperPresentation.Tone {
    var dsTone: DSTextTone {
        switch self {
        case .normal: .normal
        case .warning: .warning
        case .danger: .danger
        case .ok: .ok
        }
    }
}
