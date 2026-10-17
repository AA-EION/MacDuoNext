import AppKit
import MacDuoNextVision
import ServiceManagement
import SwiftUI

/// The menu bar panel. A grouped form, the way System Settings lays out its
/// panes: one switch or slider per row, a short explanation under each, and
/// the privacy story right next to the camera switch.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: LidController

    /// Empty means following the system language.
    @AppStorage("settingsLanguage") private var language = ""

    private var selectedLanguage: SettingsLanguage {
        SettingsLanguage(rawValue: language) ?? .preferred
    }

    private func localized(_ key: String) -> String {
        selectedLanguage.localized(key)
    }

    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @State private var settingsOpenFailed = false

    var onQuit: () -> Void

    private static let width: CGFloat = 340
    private static let bodyHeight: CGFloat = 520
    private static let publisherURL = URL(string: "https://issen.kurokamicorp.com/")!
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!
    private static let cameraSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera"
    )!

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            if controller.isSensorAvailable {
                Form {
                    if !hasScreenPermission { permissionSection }
                    effectSection
                    headTrackingSection
                    glassSection
                    startSection
                    lookSection
                    perspectiveSection
                    appSection
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(height: Self.bodyHeight)
            } else {
                unavailableNotice
                    .padding(16)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        controller.refreshCameraAuthorization()
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "MacDuoNext").font(.headline)
                Text(controller.isActive ? localized("Effect on") : localized("Ready"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%.1f°", controller.currentAngle))
                .font(.system(.title3, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .accessibilityLabel(localized("Lid angle"))
                .accessibilityValue(String(format: "%.0f°", controller.currentAngle))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(localized("Reset")) { preferences.resetToDefaults() }
            Button(localized("Preview")) { controller.runPreview() }
                .disabled(!preferences.isEnabled || controller.isActive || !controller.isSensorAvailable)
                .help(localized("Plays the effect once without moving the lid."))
            Spacer()
            Button(localized("Quit"), action: onQuit)
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }

    private var unavailableNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "laptopcomputer.trianglebadge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(localized("No Lid Angle Sensor"))
                .font(.headline)
            Text(localized("This Mac has no lid angle sensor. Only some MacBook models have one."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sections

    private var permissionSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Screen Recording permission is required to show the depth effect."))
                        .fixedSize(horizontal: false, vertical: true)
                    if settingsOpenFailed {
                        Text(localized("Could not open System Settings. Open it manually and enable screen recording for MacDuoNext under Privacy & Security."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: "rectangle.dashed.badge.record")
                    .foregroundStyle(.orange)
            }
            Button(localized("Open System Settings")) { open(Self.screenRecordingSettingsURL) }
        }
    }

    private var effectSection: some View {
        Section {
            Toggle(isOn: $preferences.isEnabled) {
                Text(localized("Depth effect"))
                Text(localized("Leans the screen away as the lid closes."))
            }
            Toggle(isOn: $preferences.isLivePicture) {
                Text(localized("Live rendering"))
                Text(localized("Off holds the frame from when the effect started."))
            }
            .disabled(!preferences.isEnabled)
        }
    }

    private var headTrackingSection: some View {
        Section {
            Toggle(isOn: $preferences.isHeadTrackingEnabled) {
                Text(localized("Head tracking"))
                Text(localized("Holds the picture still in the room as your head moves."))
            }
            switch controller.cameraAuthorization {
            case .authorized:
                LabeledContent(localized("Status")) {
                    trackingStatusLabel
                }
            case .notDetermined:
                Button(localized("Allow Camera Access…")) { controller.requestCameraAccess() }
                    .disabled(!preferences.isHeadTrackingEnabled)
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("Camera access is off for MacDuoNext."))
                        .foregroundStyle(.secondary)
                    Button(localized("Open System Settings")) { open(Self.cameraSettingsURL) }
                }
            case .unavailable:
                Text(localized("This Mac has no built-in camera."))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(localized("Head Tracking"))
        } footer: {
            Text(localized("The camera turns on only after the lid passes the start angle and turns off when it closes. Faces are found on this Mac, and video is never saved or sent anywhere."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!preferences.isEnabled)
    }

    private var trackingStatusLabel: some View {
        let text: String
        let colour: Color
        switch controller.trackingStatus {
        case .off: (text, colour) = (localized("Off"), .secondary)
        case .standby: (text, colour) = (localized("Waiting for the lid"), .secondary)
        case .searching: (text, colour) = (localized("Looking for you"), .orange)
        case .tracking: (text, colour) = (localized("Tracking"), .green)
        case .returning: (text, colour) = (localized("Returning to centre"), .yellow)
        }
        return HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var glassSection: some View {
        Section {
            Toggle(isOn: $preferences.isGlassEnabled) {
                Text(localized("Glass"))
                Text(localized("Draws the picture under ray-traced frosted glass."))
            }
            slider(
                localized("Frost"), value: $preferences.frost, in: 0...1,
                format: "%.0f%%", scale: 100,
                help: localized("How rough the glass gets as the lid closes.")
            )
            .disabled(!preferences.isGlassEnabled)
            slider(
                localized("Reflections"), value: $preferences.glassReflections, in: 0...1,
                format: "%.0f%%", scale: 100
            )
            .disabled(!preferences.isGlassEnabled)
        } header: {
            Text(localized("Glass"))
        } footer: {
            Text(String(format: localized("Rendering: %@"), localized(controller.renderPath)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!preferences.isEnabled)
    }

    private var startSection: some View {
        Section(localized("Start")) {
            Toggle(isOn: $preferences.isTimeoutEnabled) {
                Text(localized("Timeout"))
                Text(localized("Ends the effect once the angle stops changing."))
            }
            slider(
                localized("Start angle"), value: $preferences.thresholdAngle, in: 5...130, format: "%.0f°",
                help: localized("The effect starts at this angle.")
            )
            slider(
                localized("Full effect after"), value: $preferences.blurSpan, in: 5...60, format: "%.0f°",
                help: localized("Degrees of further closing to reach full strength.")
            )
        }
        .disabled(!preferences.isEnabled)
    }

    private var lookSection: some View {
        Section(localized("Look")) {
            slider(
                localized("Blur"), value: $preferences.maxBlurRadius, in: 10...160, format: "%.0f pt",
                help: localized("Blur radius at the far edge.")
            )
            slider(
                localized("Blur spread"), value: $preferences.blurEvenness, in: 0...1, format: "%.0f%%", scale: 100,
                help: localized("0 blurs the far edge only, 100 the whole picture.")
            )
            slider(
                localized("Dimming"), value: $preferences.maxDim, in: 0...1, format: "%.0f%%", scale: 100,
                help: localized("How dark the far edge goes.")
            )
            slider(
                localized("Dimming spread"), value: $preferences.dimReach, in: 0.2...1, format: "%.0f%%", scale: 100,
                help: localized("Everything above this height goes fully dark.")
            )
        }
        .disabled(!preferences.isEnabled)
    }

    private var perspectiveSection: some View {
        Section(localized("Perspective")) {
            slider(
                localized("Lean back"), value: $preferences.recession, in: 0...3, format: "%.1f×",
                help: localized("Degrees of lean per degree of closing. 1 holds it still.")
            )
            slider(
                localized("Perspective"), value: perspective, in: 0...1, format: "%.0f%%", scale: 100,
                help: localized("Used when no face is tracked. 0 keeps the sides parallel, 100 converges sharply.")
            )
        }
        .disabled(!preferences.isEnabled)
    }

    private var appSection: some View {
        Section {
            Picker(localized("Language"), selection: $language) {
                Text(localized("System")).tag("")
                Text(verbatim: "English").tag(SettingsLanguage.english.rawValue)
                Text(verbatim: "Español").tag(SettingsLanguage.spanish.rawValue)
                Text(verbatim: "简体中文").tag(SettingsLanguage.chinese.rawValue)
            }
            Toggle(localized("Show angle in menu bar"), isOn: $preferences.showsAngleInMenuBar)
            Toggle(localized("Launch at login"), isOn: $launchesAtLogin)
                .onChange(of: launchesAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }
        } footer: {
            HStack(spacing: 0) {
                Text(localized("By ")).foregroundStyle(.secondary)
                Link("Issen Software Group", destination: Self.publisherURL)
                Text(localized(" · based on Mac Duo by Makito")).foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
    }

    // MARK: - Rows

    private var perspective: Binding<Double> {
        Binding(
            get: { (Preferences.farthestEye - preferences.viewingDistance) / Preferences.eyeRange },
            set: { preferences.viewingDistance = Preferences.farthestEye - $0 * Preferences.eyeRange }
        )
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String,
        scale: Double = 1,
        help: String? = nil
    ) -> some View {
        let reading = String(format: format, value.wrappedValue * scale)
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Text(reading)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(reading)
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func open(_ url: URL) {
        settingsOpenFailed = false
        Task { @MainActor in
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.open(url, configuration: configuration)
            } catch {
                settingsOpenFailed = true
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
