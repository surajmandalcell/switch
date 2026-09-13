import CoreText
import Foundation

enum AppFonts {
    static func register() {
        for name in ["Geist-Variable", "GeistMono-Variable"] {
            guard let url = Bundle.main.url(
                forResource: name, withExtension: "ttf", subdirectory: "Fonts"
            ) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
