import AppKit
import Carbon.HIToolbox
import SwiftUI

// A global shortcut that toggles the menu popover from anywhere. Off until the owner records one
// in Settings. Carbon's RegisterEventHotKey needs no permission and no dependency.

struct ShortcutCombo: Codable, Equatable, Sendable {
  var keyCode: UInt32
  /// Carbon modifier mask: cmdKey, optionKey, controlKey, shiftKey.
  var modifiers: UInt32

  static let allowedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)

  /// A global shortcut needs Command, Option, or Control so ordinary typing never triggers it.
  var isValid: Bool { modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 }

  init(keyCode: UInt32, modifiers: UInt32) {
    self.keyCode = keyCode
    self.modifiers = modifiers & Self.allowedModifiers
  }

  init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
    var mask: UInt32 = 0
    if flags.contains(.command) { mask |= UInt32(cmdKey) }
    if flags.contains(.option) { mask |= UInt32(optionKey) }
    if flags.contains(.control) { mask |= UInt32(controlKey) }
    if flags.contains(.shift) { mask |= UInt32(shiftKey) }
    self.init(keyCode: UInt32(keyCode), modifiers: mask)
  }

  /// "⌃⌥⌘S", in the order macOS menus use.
  var display: String {
    var text = ""
    if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
    if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
    if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
    return text + Self.keyName(keyCode)
  }

  private static let names: [Int: String] = [
    kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
    kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
    kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
    kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
    kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
    kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
    kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
    kVK_ANSI_9: "9", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
    kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
    kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
    kVK_ANSI_Grave: "`",
  ]

  private static func keyName(_ code: UInt32) -> String { names[Int(code)] ?? "Key \(code)" }
}

enum GlobalShortcutPreferences {
  static let key = "globalShortcut"

  static func load(defaults: UserDefaults = .standard) -> ShortcutCombo? {
    guard let data = defaults.data(forKey: key),
          let combo = try? JSONDecoder().decode(ShortcutCombo.self, from: data),
          combo.isValid else { return nil }
    return combo
  }

  static func save(_ combo: ShortcutCombo?, defaults: UserDefaults = .standard) {
    if let combo, combo.isValid, let data = try? JSONEncoder().encode(combo) {
      defaults.set(data, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

/// Registers one Carbon hot key and calls `onTrigger` on the main actor when it is pressed.
@MainActor
final class GlobalShortcut {
  static let shared = GlobalShortcut()

  var onTrigger: (() -> Void)?
  /// What the system accepted last; nil when no shortcut is registered.
  private(set) var registered: ShortcutCombo?
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?

  /// Registers `combo`, replacing the earlier shortcut. A nil or invalid combo only unregisters.
  /// Returns false when the system refuses the combination, such as one another app already owns.
  @discardableResult
  func apply(_ combo: ShortcutCombo?) -> Bool {
    guard combo != registered else { return true }
    if let hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = nil
    registered = nil
    guard let combo, combo.isValid else { return true }
    installHandlerIfNeeded()
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x5357_4348), id: 1)  // 'SWCH'
    let status = RegisterEventHotKey(
      combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    guard status == noErr, let ref else { return false }
    hotKey = ref
    registered = combo
    return true
  }

  private func installHandlerIfNeeded() {
    guard handler == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { GlobalShortcut.shared.onTrigger?() } }
        return noErr
      }, 1, &spec, nil, &handler)
  }
}

// MARK: - Recorder

/// Settings control: click, press a combination, done. Delete clears; Escape cancels.
struct ShortcutRecorder: View {
  @State private var combo = GlobalShortcutPreferences.load()
  @State private var recording = false
  @State private var monitor: Any?
  @State private var hint: String?

  static let placeholder = "Click to record"

  var body: some View {
    HStack(spacing: 8) {
      if let hint {
        Text(hint).font(.caption).foregroundStyle(AIMTheme.amber)
      }
      Button(action: toggleRecording) {
        Text(recording ? "Press a shortcut…" : combo?.display ?? Self.placeholder)
          .foregroundStyle(combo == nil && !recording ? AIMTheme.muted : AIMTheme.ink)
          .frame(minWidth: 112)
      }
      .buttonStyle(.bordered)
      .tint(recording ? AIMTheme.blue : nil)
      .accessibilityLabel("Global shortcut")
      .accessibilityValue(combo?.display ?? "Not set")
      .accessibilityHint("Records a shortcut that opens the menu popover from anywhere")
      if combo != nil {
        AIMIconButton(icon: .close, label: "Clear global shortcut") { set(nil) }
      }
    }
    .onDisappear(perform: stopRecording)
  }

  private func toggleRecording() {
    recording ? stopRecording() : startRecording()
  }

  private func startRecording() {
    hint = nil
    recording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      switch Int(event.keyCode) {
      case kVK_Escape:
        stopRecording()
      case kVK_Delete, kVK_ForwardDelete:
        set(nil)
        stopRecording()
      default:
        let candidate = ShortcutCombo(keyCode: event.keyCode, flags: event.modifierFlags)
        if candidate.isValid {
          set(candidate)
          stopRecording()
        } else {
          hint = "Include ⌘, ⌥, or ⌃."
        }
      }
      return nil
    }
  }

  private func stopRecording() {
    recording = false
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  private func set(_ next: ShortcutCombo?) {
    combo = next
    hint = nil
    GlobalShortcutPreferences.save(next)
    // The app delegate registers on the defaults change; refuse a taken combination at once.
    if !GlobalShortcut.shared.apply(next) {
      hint = "macOS or another app already uses this shortcut."
      combo = nil
      GlobalShortcutPreferences.save(nil)
      _ = GlobalShortcut.shared.apply(nil)
    }
  }
}
