import Foundation

/// The whole scene in one compute kernel that writes the drawable directly.
///
/// The real screen is a sheet of frosted glass carried by the lid. Behind it,
/// left where the screen stood when the effect began, the picture lies on an
/// endless black plane. Every drawable pixel is a point on the frosted sheet:
/// the kernel casts a ray from the eye through it and on to the plane.
///
/// Frosted glass scatters what passes through it by an angle, so a thing
/// touching the glass is sharp and a thing far behind it is a soft glow. The
/// kernel takes the distance from the sheet to the plane along each ray and
/// turns it into both the blur and the light lost on the way: at the start
/// angle that distance is zero and the frame is the screen itself; as the lid
/// closes, the top of the picture falls away behind the sheet, blurs and goes
/// dark first.
///
/// The frost's grain and its sheen belong to the sheet, not to the picture,
/// so they stay on the real screen while the head and the lid move. The
/// result is dithered before it is quantised to 8 bits, so gradients do not
/// band.
enum GlassShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // All float4, so the layout cannot drift from the Swift side.
    struct GlassUniforms {
        float4 worldToModel0;     // rows of the world to picture-plane transform
        float4 worldToModel1;
        float4 worldToModel2;
        float4 eyeAndAmount;      // eye in world points, how far the effect has come in
        float4 lidOriginAndScale; // real screen's bottom-left in world points, pixel scale
        float4 lidAxisY;          // real screen's up axis in world space
        float4 lidNormal;         // real screen's normal in world space, towards the viewer
        float4 screen;            // screen width and height in points, drawable size in pixels
        float4 padded;            // padded picture origin and size, in points
        float4 frost;             // scatter, max blur in pixels, light loss per screen height, haze
        float4 surface;           // pyramid max level, reflection strength, grain, unused
        float4 keyLight;          // world direction to the key light, intensity
    };

    // Eight points spread over the unit disc on a golden-angle spiral.
    constant float2 spiral[8] = {
        float2( 0.2500,  0.0000), float2(-0.3193,  0.2925), float2( 0.0489, -0.5569),
        float2( 0.4024,  0.5249), float2(-0.7385, -0.1306), float2( 0.6996, -0.4450),
        float2(-0.2340,  0.8705), float2(-0.4463, -0.8593)
    };

    static float3 toModel(constant GlassUniforms &u, float3 p) {
        float4 h = float4(p, 1.0);
        return float3(dot(u.worldToModel0, h), dot(u.worldToModel1, h), dot(u.worldToModel2, h));
    }

    static float3 toModelDirection(constant GlassUniforms &u, float3 d) {
        return float3(dot(u.worldToModel0.xyz, d), dot(u.worldToModel1.xyz, d), dot(u.worldToModel2.xyz, d));
    }

    static float schlick(float cosine, float f0) {
        return f0 + (1.0 - f0) * pow(1.0 - saturate(cosine), 5.0);
    }

    // Jimenez's interleaved gradient noise: cheap, and evenly spread.
    static float gradientNoise(float2 p) {
        return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
    }

    static float hash12(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    static float3 sampleAt(constant GlassUniforms &u, texture2d<float> picture, float2 point, float lod) {
        // Clamp to zero: past the picture is the black plane.
        constexpr sampler pyramid(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float2 unit = (point - u.padded.xy) / u.padded.zw;
        return picture.sample(pyramid, float2(unit.x, 1.0 - unit.y), level(lod)).rgb;
    }

    // The plane at `point`, seen through the frosted sheet from `behind`
    // points away. `pixel` seeds the scatter pattern, which belongs to the
    // sheet.
    static float3 throughFrost(constant GlassUniforms &u, texture2d<float> picture,
                               float2 point, float behind, float2 pixel) {
        float scale = u.lidOriginAndScale.w;
        float radius = min(behind * u.frost.x * scale, u.frost.y);   // pixels

        float3 colour;
        if (radius < 0.75) {
            colour = sampleAt(u, picture, point, 0.0);
        } else {
            // Eight taps on a golden-angle spiral, each from a pyramid level
            // blurred to about the gap between taps, so together they cover
            // the disc. The spiral turns by a noise fixed to the sheet,
            // which gives the grain of frost rather than a smooth blur.
            float spread = radius / scale;
            float lod = clamp(log2(max(radius * 0.35, 1.0)), 0.0, u.surface.x);
            float turn = 6.2831853 * gradientNoise(pixel);
            float2 rotation = float2(cos(turn), sin(turn)) * spread;
            colour = float3(0.0);
            for (int tap = 0; tap < 8; ++tap) {
                float2 o = spiral[tap];
                float2 offset = float2(o.x * rotation.x - o.y * rotation.y, o.x * rotation.y + o.y * rotation.x);
                colour += sampleAt(u, picture, point + offset, lod);
            }
            colour *= 0.125;
        }

        float depth = behind / u.screen.y;
        // Scattered light from the whole picture fills in behind the frost
        // a little, the milky look of a lit frosted pane.
        float veil = (1.0 - exp(-depth * 4.0)) * u.frost.w;
        float3 haze = sampleAt(u, picture, point, max(u.surface.x - 2.0, 0.0));
        colour = mix(colour, haze, veil);
        // What lies further behind the frost loses more of its light.
        return colour * exp(-depth * u.frost.z);
    }

    // The room reflected in the sheet: dark, with a broad soft light
    // overhead and behind the viewer. The frost spreads it into a sheen.
    static float3 sheen(constant GlassUniforms &u, float3 w) {
        float panel = smoothstep(0.05, 0.95, w.y) * smoothstep(-0.5, 0.55, w.z);
        float3 colour = float3(0.86, 0.90, 1.0) * (0.35 * panel);
        colour += float3(0.018, 0.019, 0.022) * (0.6 + 0.4 * w.y);
        colour += pow(saturate(dot(w, u.keyLight.xyz)), 40.0) * u.keyLight.w * 0.15;
        return colour;
    }

    static float3 encodeSRGB(float3 c) {
        c = max(c, 0.0);
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
    }

    kernel void glassKernel(texture2d<float, access::write> output [[texture(0)]],
                            texture2d<float> picture [[texture(1)]],
                            constant GlassUniforms &u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }

        // Pixels run down from the top; points run up from the bottom.
        float scale = u.lidOriginAndScale.w;
        float2 pixel = float2(gid);
        float2 screenPoint = float2((pixel.x + 0.5) / scale, u.screen.y - (pixel.y + 0.5) / scale);
        float3 onSheet = u.lidOriginAndScale.xyz
                       + float3(screenPoint.x, 0.0, 0.0)
                       + u.lidAxisY.xyz * screenPoint.y;
        float3 eye = u.eyeAndAmount.xyz;
        float3 worldDirection = normalize(onSheet - eye);

        float3 origin = toModel(u, eye);
        float3 direction = toModelDirection(u, worldDirection);
        float3 colour = float3(0.0);
        if (direction.z < -1.0e-5) {
            float travel = -origin.z / direction.z;
            float3 point = origin + direction * travel;
            // How far behind the sheet the plane is along this ray. The
            // sheet can never be behind the plane it was peeled from.
            float behind = max(travel - distance(eye, onSheet), 0.0);
            colour = throughFrost(u, picture, point.xy, behind, pixel);
        }

        // The sheet's own surface: a soft reflection, and a fine grain that
        // stays with the real screen. Both come in with the effect.
        float amount = u.eyeAndAmount.w;
        float3 normal = u.lidNormal.xyz;
        float fresnel = schlick(-dot(worldDirection, normal), 0.04);
        colour += sheen(u, reflect(worldDirection, normal)) * fresnel * u.surface.y * amount;
        colour *= 1.0 + (hash12(floor(pixel * 0.5)) - 0.5) * u.surface.z * amount;

        // Triangular dither of one 8-bit step, so gradients do not band.
        float dither = (gradientNoise(pixel) + hash12(pixel + 17.0) - 1.0) / 255.0;
        output.write(float4(saturate(encodeSRGB(colour) + dither), 1.0), gid);
    }
    """
}
