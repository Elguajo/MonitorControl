//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//
//  Feature A — brightness scheduler settings pane.
//
//  Built fully programmatically (no Main.storyboard editing) and registered as a Settings pane.
//  Lets the user toggle the schedule and edit the morning/evening times and brightness values.
//  All changes are written to UserDefaults and immediately re-applied via BrightnessScheduler.

import Cocoa
import os.log
import Settings

class SchedulePrefsViewController: NSViewController, SettingsPane {
  let paneIdentifier = Settings.PaneIdentifier.schedule
  let paneTitle: String = NSLocalizedString("Schedule", comment: "Shown in the schedule prefs window")

  var toolbarItemIcon: NSImage {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return NSImage(systemSymbolName: "clock", accessibilityDescription: "Schedule")!
    } else {
      return NSImage(named: NSImage.infoName)!
    }
  }

  private let scheduler = BrightnessScheduler.shared

  private let enabledCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Enable brightness schedule", comment: "Schedule prefs"), target: nil, action: nil)

  private let morningTimePicker = SchedulePrefsViewController.makeTimePicker()
  private let morningSlider = NSSlider(value: 0.96, minValue: 0, maxValue: 1, target: nil, action: nil)
  private let morningValueLabel = NSTextField(labelWithString: "96%")

  private let eveningTimePicker = SchedulePrefsViewController.makeTimePicker()
  private let eveningSlider = NSSlider(value: 0.65, minValue: 0, maxValue: 1, target: nil, action: nil)
  private let eveningValueLabel = NSTextField(labelWithString: "65%")

  private var rowControls: [NSControl] = []

  // MARK: - View construction (programmatic)

  override func loadView() {
    let grid = NSGridView(numberOfColumns: 3, rows: 0)
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.rowAlignment = .firstBaseline
    grid.columnSpacing = 12
    grid.rowSpacing = 12

    // Enable checkbox spanning all columns.
    self.enabledCheckbox.target = self
    self.enabledCheckbox.action = #selector(self.enabledChanged(_:))
    let enableRow = grid.addRow(with: [self.enabledCheckbox])
    enableRow.mergeCells(in: NSRange(location: 0, length: 3))

    // Header row.
    grid.addRow(with: [
      NSGridCell.emptyContentView,
      self.boldLabel(NSLocalizedString("Time", comment: "Schedule prefs")),
      self.boldLabel(NSLocalizedString("Brightness", comment: "Schedule prefs")),
    ])

    // Morning row.
    self.configureSlider(self.morningSlider, action: #selector(self.morningSliderChanged(_:)))
    self.morningTimePicker.target = self
    self.morningTimePicker.action = #selector(self.morningTimeChanged(_:))
    grid.addRow(with: [
      NSTextField(labelWithString: NSLocalizedString("Morning", comment: "Schedule prefs")),
      self.morningTimePicker,
      self.sliderStack(self.morningSlider, self.morningValueLabel),
    ])

    // Evening row.
    self.configureSlider(self.eveningSlider, action: #selector(self.eveningSliderChanged(_:)))
    self.eveningTimePicker.target = self
    self.eveningTimePicker.action = #selector(self.eveningTimeChanged(_:))
    grid.addRow(with: [
      NSTextField(labelWithString: NSLocalizedString("Evening", comment: "Schedule prefs")),
      self.eveningTimePicker,
      self.sliderStack(self.eveningSlider, self.eveningValueLabel),
    ])

    // Explanatory footer.
    let footer = NSTextField(wrappingLabelWithString: NSLocalizedString("Brightness is changed over DDC (hardware) and transitions smoothly. Values and times are saved and restored on restart.", comment: "Schedule prefs"))
    footer.textColor = .secondaryLabelColor
    footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    let footerRow = grid.addRow(with: [footer])
    footerRow.mergeCells(in: NSRange(location: 0, length: 3))

    let container = NSView()
    container.addSubview(grid)
    NSLayoutConstraint.activate([
      grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
      grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
      grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
      grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
      grid.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
    ])
    self.view = container
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    self.populateSettings()
  }

  // MARK: - Populate from prefs

  func populateSettings() {
    self.enabledCheckbox.state = self.scheduler.isEnabled ? .on : .off
    self.morningTimePicker.dateValue = Self.dateFromMinutes(self.scheduler.morningTime)
    self.morningSlider.floatValue = self.scheduler.morningBrightness
    self.eveningTimePicker.dateValue = Self.dateFromMinutes(self.scheduler.eveningTime)
    self.eveningSlider.floatValue = self.scheduler.eveningBrightness
    self.updateValueLabels()
    self.updateEnabledState()
  }

  private func updateValueLabels() {
    self.morningValueLabel.stringValue = "\(Int(round(self.morningSlider.floatValue * 100)))%"
    self.eveningValueLabel.stringValue = "\(Int(round(self.eveningSlider.floatValue * 100)))%"
  }

  private func updateEnabledState() {
    let on = self.enabledCheckbox.state == .on
    for control in [self.morningTimePicker, self.morningSlider, self.eveningTimePicker, self.eveningSlider] as [NSControl] {
      control.isEnabled = on
    }
  }

  // MARK: - Actions

  @objc private func enabledChanged(_ sender: NSButton) {
    prefs.set(sender.state == .on, forKey: PrefKey.scheduleEnabled.rawValue)
    self.updateEnabledState()
    self.scheduler.settingsChanged()
  }

  @objc private func morningTimeChanged(_ sender: NSDatePicker) {
    prefs.set(Self.minutesFromDate(sender.dateValue), forKey: PrefKey.scheduleMorningTime.rawValue)
    self.scheduler.settingsChanged()
  }

  @objc private func eveningTimeChanged(_ sender: NSDatePicker) {
    prefs.set(Self.minutesFromDate(sender.dateValue), forKey: PrefKey.scheduleEveningTime.rawValue)
    self.scheduler.settingsChanged()
  }

  @objc private func morningSliderChanged(_ sender: NSSlider) {
    prefs.set(sender.floatValue, forKey: PrefKey.scheduleMorningBrightness.rawValue)
    self.updateValueLabels()
    self.scheduler.settingsChanged()
  }

  @objc private func eveningSliderChanged(_ sender: NSSlider) {
    prefs.set(sender.floatValue, forKey: PrefKey.scheduleEveningBrightness.rawValue)
    self.updateValueLabels()
    self.scheduler.settingsChanged()
  }

  // MARK: - Helpers

  private func boldLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    return label
  }

  private func configureSlider(_ slider: NSSlider, action: Selector) {
    slider.target = self
    slider.action = action
    slider.isContinuous = true
    slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
  }

  private func sliderStack(_ slider: NSSlider, _ label: NSTextField) -> NSStackView {
    label.alignment = .right
    label.widthAnchor.constraint(equalToConstant: 44).isActive = true
    let stack = NSStackView(views: [slider, label])
    stack.orientation = .horizontal
    stack.spacing = 8
    return stack
  }

  private static func makeTimePicker() -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerStyle = .textFieldAndStepper
    picker.datePickerElements = .hourMinute
    picker.translatesAutoresizingMaskIntoConstraints = false
    return picker
  }

  private static func dateFromMinutes(_ minutes: Int) -> Date {
    var comps = DateComponents()
    comps.hour = minutes / 60
    comps.minute = minutes % 60
    return Calendar.current.date(from: comps) ?? Date()
  }

  private static func minutesFromDate(_ date: Date) -> Int {
    let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
  }
}
