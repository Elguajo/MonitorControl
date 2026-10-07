// Exercises the production shortcut implementation in an isolated process.
// Appended to KeyboardShortcuts.swift by the runner to inspect private registration state.

let legacyDefaults = [
  "KeyboardShortcuts_toggleMainDisplay": "{\"carbonKeyCode\":14,\"carbonModifiers\":4352}",
  "KeyboardShortcuts_switchMonitorInput": "{\"carbonKeyCode\":15,\"carbonModifiers\":6144}",
]
UserDefaults.standard.setVolatileDomain(legacyDefaults, forName: UserDefaults.argumentDomain)
for key in ["toggleMainDisplay", "switchMonitorInput"] {
  let name = KeyboardShortcuts.Name(key)
  guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { fatalError("Failed to load legacy shortcut: \(key)") }
  guard let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shortcut)) as? [String: Int],
        let original = try JSONSerialization.jsonObject(with: legacyDefaults["KeyboardShortcuts_" + key]!.data(using: .utf8)!) as? [String: Int]
  else {
    fatalError("Shortcut JSON is not a dictionary of integers")
  }
  precondition(encoded == original, "Legacy JSON round trip changed shortcut")
}

print("PASS: both fork shortcut names read and round-trip legacy UserDefaults JSON")

extension KeyboardShortcuts {
  static func verifySharedBinding() throws {
    var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    let encoded = "{\"carbonKeyCode\":14,\"carbonModifiers\":4352}"
    domain["KeyboardShortcuts_auditBrightness"] = encoded
    domain["KeyboardShortcuts_auditContrast"] = encoded
    UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    let brightness = Name("auditBrightness")
    let contrast = Name("auditContrast")
    let shortcut = getShortcut(for: brightness)!
    isPaused = true // No global hotkey is registered by this harness.
    onKeyDown(for: brightness) {}
    onKeyDown(for: contrast) {}
    precondition(shortcutsForHandlers == Set([shortcut]))
    disable(brightness)
    precondition(shortcutsForHandlers == Set([shortcut]), "Disabling brightness removed contrast's shared binding")
    disable(contrast)
    precondition(shortcutsForHandlers.isEmpty)
    enable(brightness)
    precondition(shortcutsForHandlers == Set([shortcut]))
    precondition(registeredShortcuts.isEmpty && hotKeys.isEmpty, "Harness registered a global hotkey")
    removeAllHandlers()
    disabledNames = []
    isPaused = false
    print("PASS: shared shortcut remains selected until both commands are disabled; enabling restores selection")
  }
}

try KeyboardShortcuts.verifySharedBinding()
