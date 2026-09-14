import CoreText
import Foundation

enum AppFonts {
    static func register() {
        for name in ["Inter-Variable", "PTMono-Regular"] {
            guard let url = Bundle.main.url(
                forResource: name, withExtension: "ttf", subdirectory: "Fonts"
            ) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
