# AGENTS.md — MacDuoNext Implementation Reference

> Working memory for AI agents and human maintainers. Read before starting;
> update after a change that alters what is written here.
>
> **Naming**: MacDuoNext (Issen Software Group) is a fork of `sumimakito/Mac-Duo`.
> Identifiers follow the TetherKitNext scheme: `MacDuoNext*` targets,
> `com.macduonext.*` bundle and log identifiers, `macduonext-*` command-line tools.

## 1. Summary

A menu bar app. When the MacBook lid closes past a start angle, a borderless
overlay window covers the built-in display and draws the screen as it was,
left standing where the screen stood on an endless black plane, seen through
the real screen as a pane of frosted glass, from the viewer's tracked eye.

**The captured picture is never altered.** Blur, light loss, grain and
reflections all belong to the simulated glass of the real screen; the blur and
loss come from the distance behind the pane along each ray. Do not add effects
that act on the picture directly (by height, by progress); the user rejected that.

## 2. Targets and dependency direction

```
MacDuoNextLidKit   MacDuoNextCore  ← (no Apple frameworks; stdlib SIMD only)
        ↑            ↑      ↑
        │   MacDuoNextEngine  MacDuoNextVision
        │            ↑      ↑
        └──── MacDuoNextApp ┘          MacDuoNextProbe → LidKit
```

Keep `MacDuoNextCore` free of Apple frameworks so its tests stay pure. Vector
helpers are methods (`a.dot(b)`), never free functions, so they cannot collide
with the `simd` module.

## 3. Coordinate conventions (do not change without updating the shader)

- **World**: screen points. Hinge along x through the origin, y up, z towards the
  viewer. Lid at angle θ: `y = (0, sin θ, cos θ)`, `z = (0, −cos θ, sin θ)`.
- **Screen / model**: x right, y up, points from the bottom-left pixel; model z
  leaves the screen. The left-behind picture lies at model z = 0.
- **Camera**: millimetres; x is the camera picture's right, i.e. world −x
  (frames are unmirrored, `FaceTracker` forces it). y up the picture, z along the
  optical axis = lid z.
- **Vision boxes**: normalised, origin bottom-left, relative to the search region
  (`regionOfInterest`); `FaceTracker` converts back to full-frame.

## 4. Invariants

| Invariant | Why |
|---|---|
| At the start angle the rendered frame equals the screen | The overlay fades in and out over the real screen; the distance behind the pane is 0 there, and the pane's sheen and grain ramp in over `GlassOverlay.surfaceRampDegrees`. |
| The camera runs only while the effect is active and the lid is above `CameraSchedule.closedAngle` | Privacy and battery; the user asked for polling to start only past the threshold. |
| Camera permission is requested only from the panel | A prompt must never appear under the effect. |
| A face sighting is placed with the lid angle at its capture time (`LidAngleHistory`) | The camera rides on the lid; using the current angle reads lid motion as head motion. |
| A lost face holds `holdDuration`, then returns with `returningFrequency` (~11 s settle) | "As slow as possible" return to centre, without overshoot. |
| Reduce Motion disables head tracking | Apple HIG: reduce parallax. |
| The shader source is a Swift string compiled at runtime | CI compiles it with `xcrun metal` via `scripts/extract-shaders.py`; keep backslashes out of it. |
| `GlassUniforms` is all `float4` | Layout cannot drift between Swift and MSL. |

## 5. Verified facts

- `displaySyncEnabled = false` tears (users see horizontal "banding"). Keep vsync on
  and draw from a `CAMetalDisplayLink`, which hands drawables over without blocking.
- The hinge sensor refreshes at ~10 Hz. Draw at the angle predicted for the frame's
  presentation time (`LidAnglePredictor`), or the held picture trails the lid and
  looks attached to it instead of to the room.
- A ray-traced glass slab inside the virtual scene was tried and dropped: it moved
  with head tracking (the glass must stay on the real screen), its edge absorption
  showed as a green border, and an intersector in the per-pixel kernel costs every
  thread registers. The frosted pane on the real screen needs only a ray-plane hit.

- Vision ships a struct `FaceObservation` on macOS 15+; ours is `FaceSighting`.
- `VNRequest.supportedComputeStageDevices` is a throwing **property** (macOS 14+).
- SwiftPM resource bundle: `MacDuoNext_MacDuoNextApp.bundle`, copied to
  `Contents/Resources` by `scripts/build-release.sh`.
- Hardened runtime needs `com.apple.security.device.camera`
  (`Resources/MacDuoNext.entitlements`) or the camera silently delivers nothing.

## 6. Release

`VERSION` holds the marketing version. Tag `vX.Y.Z[-suffix]`; a suffix publishes an
ad-hoc signed prerelease without secrets (`.github/workflows/release.yml`).
Where tags cannot be pushed, a branch commit whose message contains `[prerelease]`
makes CI publish `v<VERSION>-beta.<run>` on that commit.
