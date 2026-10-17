import Combine
import Foundation

/// User settings, backed by `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let isEnabled = "isEnabled"
        static let isTimeoutEnabled = "isTimeoutEnabled"
        static let thresholdAngle = "thresholdAngle"
        static let maxBlurRadius = "maxBlurRadius"
        static let viewingDistance = "viewingDistance"
        static let recession = "recession"
        static let showsAngleInMenuBar = "showsAngleInMenuBar"
        static let isLivePicture = "isLivePicture"
        static let isHeadTrackingEnabled = "isHeadTrackingEnabled"
        static let isGlassEnabled = "isGlassEnabled"
        static let glassReflections = "glassReflections"
        static let frost = "frost"
        static let lightLoss = "lightLoss"

        static let all = [
            isEnabled, isTimeoutEnabled, thresholdAngle, maxBlurRadius,
            viewingDistance, recession, showsAngleInMenuBar, isLivePicture, isHeadTrackingEnabled,
            isGlassEnabled, glassReflections, frost, lightLoss,
        ]
    }

    private static let factory: [String: Any] = [
        Key.isEnabled: true,
        Key.isTimeoutEnabled: false,
        Key.thresholdAngle: 90.0,
        Key.maxBlurRadius: 60.0,
        // About 50 cm from a 14-inch panel: where people sit, so the
        // picture looks fixed even before the camera has found the face.
        Key.viewingDistance: 2.6,
        Key.recession: 1.0,
        Key.showsAngleInMenuBar: false,
        Key.isLivePicture: true,
        Key.isHeadTrackingEnabled: true,
        Key.isGlassEnabled: true,
        Key.glassReflections: 0.6,
        Key.frost: 0.75,
        Key.lightLoss: 0.6,
    ]

    /// Master switch for the depth effect.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    /// Ends the effect early if the angle holds still while below the
    /// threshold, instead of waiting for the lid to open back past it.
    @Published var isTimeoutEnabled: Bool {
        didSet { defaults.set(isTimeoutEnabled, forKey: Key.isTimeoutEnabled) }
    }

    /// Closing past this angle starts the depth effect. Degrees.
    @Published var thresholdAngle: Double {
        didSet { defaults.set(thresholdAngle, forKey: Key.thresholdAngle) }
    }

    /// The most the glass blurs, in points.
    @Published var maxBlurRadius: Double {
        didSet { defaults.set(maxBlurRadius, forKey: Key.maxBlurRadius) }
    }

    /// Distance from the eye to the middle of the screen, as a multiple of
    /// the screen height.
    @Published var viewingDistance: Double {
        didSet { defaults.set(viewingDistance, forKey: Key.viewingDistance) }
    }

    /// Degrees the picture turns away from the glass for each degree the lid
    /// closes. One holds the picture still in the room.
    @Published var recession: Double {
        didSet { defaults.set(recession, forKey: Key.recession) }
    }

    /// Draw the live angle next to the menu bar icon.
    @Published var showsAngleInMenuBar: Bool {
        didSet { defaults.set(showsAngleInMenuBar, forKey: Key.showsAngleInMenuBar) }
    }

    /// Keep the picture under the effect updating, instead of holding the one
    /// frame that was on screen at the trigger angle.
    @Published var isLivePicture: Bool {
        didSet { defaults.set(isLivePicture, forKey: Key.isLivePicture) }
    }

    /// Follow the viewer's head with the camera while the effect is up, so
    /// the picture holds still in the room. Needs camera permission.
    @Published var isHeadTrackingEnabled: Bool {
        didSet { defaults.set(isHeadTrackingEnabled, forKey: Key.isHeadTrackingEnabled) }
    }

    /// Put a pane of frosted glass, carried by the lid, between the viewer
    /// and the left-behind screen. Off is clear glass.
    @Published var isGlassEnabled: Bool {
        didSet { defaults.set(isGlassEnabled, forKey: Key.isGlassEnabled) }
    }

    /// How much of the room the glass reflects, 0...1.
    @Published var glassReflections: Double {
        didSet { defaults.set(glassReflections, forKey: Key.glassReflections) }
    }

    /// How rough the glass gets with the lid closed, 0 clear to 1 fully
    /// frosted.
    @Published var frost: Double {
        didSet { defaults.set(frost, forKey: Key.frost) }
    }

    /// How much light is lost behind the glass, 0...1. At the default the
    /// top of the left-behind screen is gone well before the lid shuts.
    @Published var lightLoss: Double {
        didSet { defaults.set(lightLoss, forKey: Key.lightLoss) }
    }

    /// Eye distance in screen heights, at the two ends of the perspective
    /// slider. The panel offers the strength, which runs the other way.
    static let farthestEye: Double = 6
    static let nearestEye: Double = 1
    static let eyeRange: Double = farthestEye - nearestEye

    /// Highest angle above the threshold at which the pre-warm may run.
    let prewarmCeiling: Double = 70

    /// Closing speed in degrees per second that starts the pre-warm.
    let closingSpeed: Double = 8

    /// How long the pre-warm runs after the lid stops moving.
    let prewarmLinger: TimeInterval = 2

    /// Seconds between pre-warm screenshots.
    let prewarmInterval: TimeInterval = 0.25

    /// Degrees above the threshold before the overlay is released.
    let hysteresis: Double = 4

    /// Settings from earlier versions, removed at launch.
    private static let retired = [
        "blurFrontWidth", "maxTilt", "tiltDegrees", "tiltRatio", "dimEvenness",
        // Effects once applied to the picture itself; the glass does it now.
        "blurSpan", "maxDim", "blurEvenness", "dimReach",
    ]

    private let defaults = UserDefaults.standard

    // No inline values on purpose. Swift skips property observers for the
    // assignment that initialises a property.
    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: Self.factory)
        for key in Self.retired { defaults.removeObject(forKey: key) }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isTimeoutEnabled = defaults.bool(forKey: Key.isTimeoutEnabled)
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        maxBlurRadius = defaults.double(forKey: Key.maxBlurRadius)
        viewingDistance = defaults.double(forKey: Key.viewingDistance)
        recession = defaults.double(forKey: Key.recession)
        showsAngleInMenuBar = defaults.bool(forKey: Key.showsAngleInMenuBar)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
        isHeadTrackingEnabled = defaults.bool(forKey: Key.isHeadTrackingEnabled)
        isGlassEnabled = defaults.bool(forKey: Key.isGlassEnabled)
        glassReflections = defaults.double(forKey: Key.glassReflections)
        frost = defaults.double(forKey: Key.frost)
        lightLoss = defaults.double(forKey: Key.lightLoss)
    }

    func resetToDefaults() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isTimeoutEnabled = defaults.bool(forKey: Key.isTimeoutEnabled)
        thresholdAngle = defaults.double(forKey: Key.thresholdAngle)
        maxBlurRadius = defaults.double(forKey: Key.maxBlurRadius)
        viewingDistance = defaults.double(forKey: Key.viewingDistance)
        recession = defaults.double(forKey: Key.recession)
        showsAngleInMenuBar = defaults.bool(forKey: Key.showsAngleInMenuBar)
        isLivePicture = defaults.bool(forKey: Key.isLivePicture)
        isHeadTrackingEnabled = defaults.bool(forKey: Key.isHeadTrackingEnabled)
        isGlassEnabled = defaults.bool(forKey: Key.isGlassEnabled)
        glassReflections = defaults.double(forKey: Key.glassReflections)
        frost = defaults.double(forKey: Key.frost)
        lightLoss = defaults.double(forKey: Key.lightLoss)
    }
}
