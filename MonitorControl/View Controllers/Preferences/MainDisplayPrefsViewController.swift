//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//
//  Feature B — main display switching settings pane (programmatic, no Main.storyboard editing).
//
//  A button switches the main display between the external monitor and the built-in screen; the same
//  action is in the menu-bar menu and on a global shortcut. Optionally InputSourceWatcher does it
//  automatically by watching DDC responsiveness — off by default, since it costs a periodic DDC
//  query. Monitor sleep is never mistaken for an input change, so windows are not reshuffled on sleep.

import Cocoa
import KeyboardShortcuts
import os.log
import Settings

class MainDisplayPrefsViewController: NSViewController, SettingsPane {
  let paneIdentifier = Settings.PaneIdentifier.mainDisplay
  let paneTitle: String = NSLocalizedString("Main Display", comment: "Shown in the main display prefs window")

  var toolbarItemIcon: NSImage {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Main Display")!
    } else {
      return NSImage(named: NSImage.infoName)!
    }
  }

  private let switchButton = NSButton(title: NSLocalizedString("Switch main display (external ↔ built-in)", comment: "Main display prefs"), target: nil, action: nil)
  private let statusLabel = NSTextField(labelWithString: "")
  private let altAddressingCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Use LG alternate input addressing (try this if switching the monitor input does nothing)", comment: "Main display prefs"), target: nil, action: nil)
  private let autoSwitchCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Move the main display automatically when the monitor changes input", comment: "Main display prefs"), target: nil, action: nil)
  private let keepDisplayAwakeCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Keep display awake (prevent the screen from sleeping)", comment: "Main display prefs"), target: nil, action: nil)
  private let keepSystemAwakeCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Keep system awake (prevent the Mac from sleeping)", comment: "Main display prefs"), target: nil, action: nil)

  // MARK: - View construction

  override func loadView() {
    self.switchButton.bezelStyle = .rounded
    self.switchButton.target = self
    self.switchButton.action = #selector(self.switchClicked(_:))

    let explanation = NSTextField(wrappingLabelWithString: NSLocalizedString("Use this to move the main display (menu bar and windows) between your monitor and the built-in screen — for example before switching the monitor to a Windows PC. Switch the monitor's input yourself with its own button. Monitor sleep does NOT move your windows. This action is also in the menu-bar menu.", comment: "Main display prefs"))
    explanation.textColor = .secondaryLabelColor
    explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    self.statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

    self.altAddressingCheckbox.target = self
    self.altAddressingCheckbox.action = #selector(self.altAddressingChanged(_:))

    let inputNote = NSTextField(wrappingLabelWithString: NSLocalizedString("To switch which input the monitor shows (DisplayPort / HDMI 1 / HDMI 2), use the “Monitor input” submenu in the menu bar. Selecting a non-Mac input also moves windows to the built-in screen. Returning to the Mac input is done from the other computer or the monitor's own button — turn on automatic switching above to have windows move back by themselves.", comment: "Main display prefs"))
    inputNote.textColor = .secondaryLabelColor
    inputNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    self.autoSwitchCheckbox.target = self
    self.autoSwitchCheckbox.action = #selector(self.autoSwitchChanged(_:))

    let autoNote = NSTextField(wrappingLabelWithString: NSLocalizedString("The monitor stops answering DDC while it shows another computer, so the app can tell that apart from the monitor going to sleep (which never moves your windows). When it stops answering, the built-in screen becomes main; when it answers again, the monitor does. Costs a small DDC query every two seconds.", comment: "Main display prefs"))
    autoNote.textColor = .secondaryLabelColor
    autoNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    let shortcutsHeader = NSTextField(labelWithString: NSLocalizedString("Global keyboard shortcuts", comment: "Main display prefs"))
    shortcutsHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    let toggleRow = self.shortcutRow(NSLocalizedString("Switch main display:", comment: "Main display prefs"), KeyboardShortcuts.RecorderCocoa(for: .toggleMainDisplay))
    let inputRow = self.shortcutRow(NSLocalizedString("Cycle monitor input:", comment: "Main display prefs"), KeyboardShortcuts.RecorderCocoa(for: .switchMonitorInput))

    let keepAwakeHeader = NSTextField(labelWithString: NSLocalizedString("Keep awake", comment: "Main display prefs"))
    keepAwakeHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    self.keepDisplayAwakeCheckbox.target = self
    self.keepDisplayAwakeCheckbox.action = #selector(self.keepDisplayAwakeChanged(_:))
    self.keepSystemAwakeCheckbox.target = self
    self.keepSystemAwakeCheckbox.action = #selector(self.keepSystemAwakeChanged(_:))

    let stack = NSStackView(views: [self.switchButton, self.statusLabel, explanation, self.separator(), self.autoSwitchCheckbox, autoNote, self.separator(), self.altAddressingCheckbox, inputNote, self.separator(), shortcutsHeader, toggleRow, inputRow, self.separator(), keepAwakeHeader, self.keepDisplayAwakeCheckbox, self.keepSystemAwakeCheckbox])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
      stack.widthAnchor.constraint(equalToConstant: 460),
    ])
    self.view = container
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    self.populateSettings()
  }

  func populateSettings() {
    self.switchButton.isEnabled = DisplayLayoutManager.canSwitch()
    self.altAddressingCheckbox.state = prefs.bool(forKey: PrefKey.useAlternateInputAddressing.rawValue) ? .on : .off
    self.autoSwitchCheckbox.state = InputSourceWatcher.shared.isEnabled ? .on : .off
    self.keepDisplayAwakeCheckbox.state = KeepAwakeManager.shared.isDisplayAwakeEnabled ? .on : .off
    self.keepSystemAwakeCheckbox.state = KeepAwakeManager.shared.isSystemAwakeEnabled ? .on : .off
    self.updateStatus()
  }

  private func shortcutRow(_ title: String, _ recorder: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: title)
    label.widthAnchor.constraint(equalToConstant: 180).isActive = true
    let row = NSStackView(views: [label, recorder])
    row.orientation = .horizontal
    row.spacing = 8
    return row
  }

  private func separator() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    box.translatesAutoresizingMaskIntoConstraints = false
    box.widthAnchor.constraint(equalToConstant: 460).isActive = true
    return box
  }

  private func updateStatus() {
    if DisplayLayoutManager.canSwitch() {
      let mainName = DisplayManager.getDisplayNameByID(displayID: CGMainDisplayID())
      self.statusLabel.stringValue = String(format: NSLocalizedString("Current main display: %@", comment: "Main display prefs"), mainName)
    } else {
      self.statusLabel.stringValue = NSLocalizedString("Connect both the built-in screen and an external monitor to switch.", comment: "Main display prefs")
    }
  }

  // MARK: - Actions

  @objc private func switchClicked(_: NSButton) {
    _ = DisplayLayoutManager.toggleMain()
    self.updateStatus()
  }

  @objc private func altAddressingChanged(_ sender: NSButton) {
    prefs.set(sender.state == .on, forKey: PrefKey.useAlternateInputAddressing.rawValue)
  }

  @objc private func autoSwitchChanged(_ sender: NSButton) {
    prefs.set(sender.state == .on, forKey: PrefKey.autoSwitchMainDisplay.rawValue)
    // Start from a clean baseline: whatever the monitor is doing right now is recorded, not acted on.
    InputSourceWatcher.shared.refreshTargets()
  }

  @objc private func keepDisplayAwakeChanged(_ sender: NSButton) {
    KeepAwakeManager.shared.setDisplayAwake(sender.state == .on)
  }

  @objc private func keepSystemAwakeChanged(_ sender: NSButton) {
    KeepAwakeManager.shared.setSystemAwake(sender.state == .on)
  }
}
