import Foundation

/// The whole scene in one compute kernel that writes the drawable directly.
///
/// Every drawable pixel is a point on the real screen, which the lid carries
/// through the room. The kernel casts a ray from the eye through that point
/// and follows it into the held picture: a display panel under a pane of
/// frosted cover glass, set into an endless black plane that stands where the
/// screen stood when the effect began. The real display folds away from it
/// like a film peeled off the front.
///
/// Cost is kept where it shows. `glassKernel` runs for every pixel and holds
/// no ray tracing code, so it keeps a small register footprint and full
/// occupancy: across the flat middle of the pane the ray meets two parallel
/// planes, solved in closed form. Pixels whose ray lands in the thin band
/// around the rounded edge are appended to a list, and `edgeKernel`, a
/// second, indirect dispatch over only that list, follows them into the
/// acceleration structure (`USE_RAYTRACING`), which Apple silicon from M3 on
/// walks in hardware. Without ray tracing the band uses an analytic box.
///
/// The frost is a rough surface: each pixel gathers the picture from a small
/// disc of jittered taps on a blurred level of the pyramid, with the jitter
/// fixed to the glass, so the grain stays on the pane as the lid moves. Haze
/// lifts the darks the way scattering does, and soft reflections sit on top.
/// The result is dithered before it is quantised to 8 bits, so dark gradients
/// do not band.
enum GlassShaders {
    static let source = """
    #include <metal_stdlib>
    #if USE_RAYTRACING
    #include <metal_raytracing>
    #endif
    using namespace metal;
    #if USE_RAYTRACING
    using namespace metal::raytracing;
    #endif

    // All float4, so the layout cannot drift from the Swift side.
    struct GlassUniforms {
        float4 worldToModel0;     // rows of the world to picture-model transform
        float4 worldToModel1;
        float4 worldToModel2;
        float4 eyeAndGlass;       // eye in world points, glass amount
        float4 lidOriginAndScale; // real screen's bottom-left in world points, pixel scale
        float4 lidAxisY;          // real screen's up axis in world space
        float4 screen;            // screen width and height in points, drawable size in pixels
        float4 padded;            // padded picture origin and size, in points
        float4 blur;              // max depth blur radius in pixels, strength, hinge floor, max level
        float4 dim;               // hinge floor, strength, reach, max dim
        float4 slab;              // glass bounds in plan: min x, min y, max x, max y
        float4 glass;             // thickness, index of refraction, environment strength, corner radius
        float4 frost;             // amount, max frost radius in pixels, edge radius, edge list capacity
        float4 keyLight;          // world direction to the key light, intensity
    };

    struct SlabHit {
        bool found;
        float distance;
        float3 normal;            // outward, unit length
    };

    #if USE_RAYTRACING
    #define SCENE_PARAMS , primitive_acceleration_structure accel, const device packed_float3 *normals, const device uint *indices
    #define SCENE_PASS , accel, normals, indices
    #define KERNEL_SCENE , primitive_acceleration_structure accel [[buffer(3)]], const device packed_float3 *normals [[buffer(4)]], const device uint *indices [[buffer(5)]]
    #else
    #define SCENE_PARAMS
    #define SCENE_PASS
    #define KERNEL_SCENE
    #endif

    // Eight points spread over the unit disc on a golden-angle spiral.
    constant float2 spiral[8] = {
        float2( 0.2500,  0.0000), float2(-0.3193,  0.2925), float2( 0.0489, -0.5569),
        float2( 0.4024,  0.5249), float2(-0.7385, -0.1306), float2( 0.6996, -0.4450),
        float2(-0.2340,  0.8705), float2(-0.4463, -0.8593)
    };
    constant float3 absorption = float3(0.0040, 0.0012, 0.0030);  // per point: a faint green in long paths

    static float3 toModel(constant GlassUniforms &u, float3 p) {
        float4 h = float4(p, 1.0);
        return float3(dot(u.worldToModel0, h), dot(u.worldToModel1, h), dot(u.worldToModel2, h));
    }

    static float3 toModelDirection(constant GlassUniforms &u, float3 d) {
        return float3(dot(u.worldToModel0.xyz, d), dot(u.worldToModel1.xyz, d), dot(u.worldToModel2.xyz, d));
    }

    static float3 toWorldDirection(constant GlassUniforms &u, float3 d) {
        return u.worldToModel0.xyz * d.x + u.worldToModel1.xyz * d.y + u.worldToModel2.xyz * d.z;
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

    static float roundedRectDistance(float2 p, float4 bounds, float radius) {
        float2 centre = (bounds.xy + bounds.zw) * 0.5;
        float2 halfSize = (bounds.zw - bounds.xy) * 0.5;
        float2 q = abs(p - centre) - halfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    static float3 sampleAt(constant GlassUniforms &u, texture2d<float> picture, float2 point, float lod) {
        constexpr sampler pyramid(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float2 unit = (point - u.padded.xy) / u.padded.zw;
        return picture.sample(pyramid, float2(unit.x, 1.0 - unit.y), level(lod)).rgb;
    }

    // The panel seen through the frosted pane at a point in model space.
    static float3 frostedPicture(constant GlassUniforms &u, texture2d<float> picture, float2 point, float frost) {
        float scale = u.lidOriginAndScale.w;
        float height = clamp(point.y / u.screen.y, 0.0, 1.0);
        float depthBlur = u.blur.y * (u.blur.z + (1.0 - u.blur.z) * height) * u.blur.x;
        float radius = depthBlur + frost * u.frost.y;   // pixels

        float3 colour;
        if (radius < 0.75) {
            colour = sampleAt(u, picture, point, 0.0);
        } else {
            // Eight taps on a golden-angle spiral, each from a level blurred
            // to about the gap between taps, so together they cover the disc.
            // The spiral turns by a noise fixed to the glass, which is what
            // makes the result grainy like frost rather than smooth.
            float spread = radius / scale;
            float lod = clamp(log2(max(radius * 0.35, 1.0)), 0.0, u.blur.w);
            float turn = 6.2831853 * gradientNoise(floor(point * scale));
            float2 rotation = float2(cos(turn), sin(turn)) * spread;
            colour = float3(0.0);
            for (int tap = 0; tap < 8; ++tap) {
                float2 o = spiral[tap];
                float2 offset = float2(o.x * rotation.x - o.y * rotation.y, o.x * rotation.y + o.y * rotation.x);
                colour += sampleAt(u, picture, point + offset, lod);
            }
            colour *= 0.125;
        }

        if (frost > 0.001) {
            // Scattering lifts the darks towards the pane's average light, and
            // the rough surface leaves a fine, fixed grain.
            float3 haze = sampleAt(u, picture, point, max(u.blur.w - 2.0, 0.0)) * 0.85 + 0.03;
            colour = mix(colour, haze, frost * 0.22);
            colour *= 1.0 + (hash12(floor(point * 1.5)) - 0.5) * 0.08 * frost;
        }

        // Dimming by height. smoothstep, so the height where it reaches full
        // strength leaves no edge; the 2.2 keeps the setting a fraction of
        // the encoded brightness.
        float spreadDim = smoothstep(0.0, max(u.dim.z, 0.02), height);
        float fade = u.dim.y * (u.dim.x + (1.0 - u.dim.x) * spreadDim);
        return colour * pow(1.0 - u.dim.w * fade, 2.2);
    }

    // The room: dark, with a broad soft light overhead and behind the viewer,
    // and one small key light. Frost spreads both into a sheen.
    static float3 sky(constant GlassUniforms &u, float3 modelDirection, float frost) {
        float3 w = normalize(toWorldDirection(u, modelDirection));
        float soft = mix(0.0, 0.25, frost);
        float panel = smoothstep(0.30 - soft, 0.70 + soft, w.y) * smoothstep(-0.25 - soft, 0.30 + soft, w.z);
        float3 colour = float3(0.86, 0.90, 1.0) * (0.45 * panel);
        colour += float3(0.020, 0.021, 0.024) * (0.6 + 0.4 * w.y);
        float sharpness = mix(900.0, 40.0, frost);
        float glint = pow(saturate(dot(w, u.keyLight.xyz)), sharpness) * u.keyLight.w * mix(1.0, 0.15, frost);
        return colour + float3(glint);
    }

    #if USE_RAYTRACING
    static SlabHit hitSlab(constant GlassUniforms &u, float3 origin, float3 direction, float limit SCENE_PARAMS) {
        ray probe(origin, direction, 0.0f, limit);
        intersector<triangle_data> finder;
        finder.assume_geometry_type(geometry_type::triangle);
        finder.force_opacity(forced_opacity::opaque);
        finder.accept_any_intersection(false);
        intersection_result<triangle_data> result = finder.intersect(probe, accel);

        SlabHit hit;
        hit.found = false;
        hit.distance = 0.0;
        hit.normal = float3(0.0, 0.0, 1.0);
        if (result.type != intersection_type::triangle) { return hit; }
        uint base = result.primitive_id * 3;
        float2 b = result.triangle_barycentric_coord;
        float3 n0 = float3(normals[indices[base]]);
        float3 n1 = float3(normals[indices[base + 1]]);
        float3 n2 = float3(normals[indices[base + 2]]);
        hit.found = true;
        hit.distance = result.distance;
        hit.normal = normalize(n0 * (1.0 - b.x - b.y) + n1 * b.x + n2 * b.y);
        return hit;
    }
    #else
    // The slab as an axis-aligned box in model space.
    static SlabHit hitSlab(constant GlassUniforms &u, float3 origin, float3 direction, float limit SCENE_PARAMS) {
        float3 low = float3(u.slab.xy, 0.0);
        float3 high = float3(u.slab.zw, u.glass.x);
        float3 inverse = 1.0 / direction;
        float3 t0 = (low - origin) * inverse;
        float3 t1 = (high - origin) * inverse;
        float3 nearest = min(t0, t1);
        float3 farthest = max(t0, t1);
        float enter = max(max(nearest.x, nearest.y), nearest.z);
        float leave = min(min(farthest.x, farthest.y), farthest.z);

        SlabHit hit;
        hit.found = false;
        hit.distance = 0.0;
        hit.normal = float3(0.0, 0.0, 1.0);
        if (!(leave >= max(enter, 0.0))) { return hit; }
        float3 side = -sign(direction);
        float distance;
        float3 normal;
        if (enter > 0.0) {
            distance = enter;
            normal = enter == nearest.x ? float3(side.x, 0.0, 0.0)
                   : (enter == nearest.y ? float3(0.0, side.y, 0.0) : float3(0.0, 0.0, side.z));
        } else {
            distance = leave;
            normal = leave == farthest.x ? float3(-side.x, 0.0, 0.0)
                   : (leave == farthest.y ? float3(0.0, -side.y, 0.0) : float3(0.0, 0.0, -side.z));
        }
        if (distance > limit) { return hit; }
        hit.found = true;
        hit.distance = distance;
        hit.normal = normal;
        return hit;
    }
    #endif

    // The edge band: the ray enters the rolled edge, refracts, may reflect
    // inside a few times, and lands on the panel or leaves the glass.
    static float3 traceEdge(constant GlassUniforms &u, texture2d<float> picture,
                            float3 origin, float3 direction, float2 straightPoint, float frost SCENE_PARAMS) {
        const float limit = 1.0e7;
        SlabHit entry = hitSlab(u, origin, direction, limit SCENE_PASS);
        if (!entry.found) { return float3(0.0); }
        float cosine = -dot(direction, entry.normal);
        if (cosine <= 0.0 || entry.normal.z < -0.5) { return float3(0.0); }

        float ior = u.glass.y;
        float f0 = pow((ior - 1.0) / (ior + 1.0), 2.0);
        float fresnel = schlick(cosine, f0);
        float3 colour = sky(u, reflect(direction, entry.normal), frost) * (fresnel * u.glass.z);

        float3 position = origin + direction * entry.distance;
        float3 inside = refract(direction, entry.normal, 1.0 / ior);
        float3 throughput = float3(1.0 - fresnel);
        for (int bounce = 0; bounce < 4; ++bounce) {
            SlabHit next = hitSlab(u, position + inside * 0.01, inside, limit SCENE_PASS);
            if (!next.found) { break; }
            position += inside * (next.distance + 0.01);
            throughput *= exp(-absorption * next.distance);
            if (next.normal.z < -0.9 && position.z < 0.05) {
                float3 panel = frostedPicture(u, picture, position.xy, frost);
                // Shorter wavelengths bend more: the colours part a little
                // where the edge bends the light the most.
                float2 shift = (position.xy - straightPoint) * 0.035;
                if (length_squared(shift) > 0.0004) {
                    panel.r = mix(panel.r, sampleAt(u, picture, position.xy - shift, 1.0).r, 0.6);
                    panel.b = mix(panel.b, sampleAt(u, picture, position.xy + shift, 1.0).b, 0.6);
                }
                colour += throughput * panel;
                break;
            }
            float3 escape = refract(inside, -next.normal, ior);
            float3 mirrored = reflect(inside, -next.normal);
            if (all(escape == float3(0.0))) {
                inside = mirrored;
                continue;
            }
            float leaving = schlick(dot(escape, next.normal), f0);
            colour += throughput * (1.0 - leaving) * sky(u, escape, frost) * u.glass.z;
            throughput *= leaving;
            inside = mirrored;
        }
        return colour;
    }

    static float3 encodeSRGB(float3 c) {
        c = max(c, 0.0);
        return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, 12.92 * c, c <= 0.0031308);
    }

    // The ray from the eye through one drawable pixel, in model space.
    static void primaryRay(constant GlassUniforms &u, uint2 gid, thread float3 &origin, thread float3 &direction) {
        // Pixels run down from the top; points run up from the bottom.
        float scale = u.lidOriginAndScale.w;
        float2 screenPoint = float2((float(gid.x) + 0.5) / scale,
                                    u.screen.y - (float(gid.y) + 0.5) / scale);
        float3 onLid = u.lidOriginAndScale.xyz
                     + float3(screenPoint.x, 0.0, 0.0)
                     + u.lidAxisY.xyz * screenPoint.y;
        float3 eye = u.eyeAndGlass.xyz;
        origin = toModel(u, eye);
        direction = normalize(toModelDirection(u, normalize(onLid - eye)));
    }

    static void writePixel(texture2d<float, access::write> output, uint2 gid, float3 colour) {
        // Triangular dither of one 8-bit step, so gradients do not band.
        float2 pixel = float2(gid);
        float dither = (gradientNoise(pixel) + hash12(pixel + 17.0) - 1.0) / 255.0;
        output.write(float4(saturate(encodeSRGB(colour) + dither), 1.0), gid);
    }

    kernel void glassKernel(texture2d<float, access::write> output [[texture(0)]],
                            texture2d<float> picture [[texture(1)]],
                            constant GlassUniforms &u [[buffer(0)]],
                            device atomic_uint *edgeCount [[buffer(1)]],
                            device uint2 *edgePixels [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
        float3 origin;
        float3 direction;
        primaryRay(u, gid, origin, direction);

        float glassAmount = u.eyeAndGlass.w;
        float frost = u.frost.x;
        float3 colour = float3(0.0);
        if (direction.z < -1.0e-5) {
            // The straight line to the panel: exactly the screen at the start
            // angle, so the overlay fades in and out without a seam.
            float2 straightPoint = (origin + direction * (-origin.z / direction.z)).xy;
            if (glassAmount <= 0.001) {
                colour = frostedPicture(u, picture, straightPoint, 0.0);
            } else {
                float thickness = u.glass.x;
                float3 front = origin + direction * ((thickness - origin.z) / direction.z);
                float edge = roundedRectDistance(front.xy, u.slab, u.glass.w);
                float band = u.frost.z + 2.0;
                if (edge < -band) {
                    // The flat middle: two parallel planes, in closed form.
                    float ior = u.glass.y;
                    float f0 = pow((ior - 1.0) / (ior + 1.0), 2.0);
                    float fresnel = schlick(-direction.z, f0) * glassAmount;
                    float3 inside = refract(direction, float3(0.0, 0.0, 1.0), 1.0 / ior);
                    float travel = thickness / max(-inside.z, 1.0e-3);
                    float2 refracted = front.xy + inside.xy * travel;
                    float2 point = mix(straightPoint, refracted, glassAmount);
                    float3 through = frostedPicture(u, picture, point, frost)
                                   * mix(float3(1.0), exp(-absorption * travel), glassAmount);
                    float3 reflection = sky(u, reflect(direction, float3(0.0, 0.0, 1.0)), frost) * u.glass.z;
                    colour = through * (1.0 - fresnel) + reflection * fresnel;
                } else if (edge < band) {
                    // The rolled edge: leave it to the edge pass, which
                    // overwrites this pixel. The straight picture stands in
                    // if the list is full.
                    uint slot = atomic_fetch_add_explicit(edgeCount, 1, memory_order_relaxed);
                    if (slot < uint(u.frost.w)) { edgePixels[slot] = gid; }
                    colour = frostedPicture(u, picture, straightPoint, frost);
                } else {
                    // Beyond the glass: the black plane the panel was left on,
                    // standing at the start angle and running on without end.
                    // It is lacquer black and shows only by what it reflects.
                    float sheen = schlick(-direction.z, 0.045) * glassAmount * u.glass.z;
                    colour = sky(u, reflect(direction, float3(0.0, 0.0, 1.0)), 0.7) * sheen;
                }
            }
        }
        writePixel(output, gid, colour);
    }

    // Turns the edge count into an indirect dispatch of 64-thread groups.
    kernel void edgeArguments(device const uint *edgeCount [[buffer(1)]],
                              device uint *arguments [[buffer(6)]],
                              constant GlassUniforms &u [[buffer(0)]]) {
        uint count = min(edgeCount[0], uint(u.frost.w));
        arguments[0] = (count + 63) / 64;
        arguments[1] = 1;
        arguments[2] = 1;
    }

    kernel void edgeKernel(texture2d<float, access::write> output [[texture(0)]],
                           texture2d<float> picture [[texture(1)]],
                           constant GlassUniforms &u [[buffer(0)]],
                           device const uint *edgeCount [[buffer(1)]],
                           device const uint2 *edgePixels [[buffer(2)]]
                           KERNEL_SCENE,
                           uint index [[thread_position_in_grid]]) {
        if (index >= min(edgeCount[0], uint(u.frost.w))) { return; }
        uint2 gid = edgePixels[index];
        float3 origin;
        float3 direction;
        primaryRay(u, gid, origin, direction);
        float2 straightPoint = (origin + direction * (-origin.z / direction.z)).xy;
        float frost = u.frost.x;
        float3 traced = traceEdge(u, picture, origin, direction, straightPoint, frost SCENE_PASS);
        float3 straight = frostedPicture(u, picture, straightPoint, 0.0);
        writePixel(output, gid, mix(straight, traced, u.eyeAndGlass.w));
    }
    """
}
