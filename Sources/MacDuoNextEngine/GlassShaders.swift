import Foundation

/// The whole scene in one compute kernel, plus a pass that presents it.
///
/// Every drawable pixel is a point on the real screen, which the lid carries
/// through the room. The kernel casts a ray from the eye through that point
/// and follows it into the held picture: a display panel under a slab of cover
/// glass, standing where the screen stood when the effect began.
///
/// With `USE_RAYTRACING` the slab is a triangle mesh in a Metal acceleration
/// structure, so its rolled edges and rounded corners refract and reflect, and
/// Apple silicon with ray tracing hardware (M3 and later) walks it in hardware.
/// Without it the slab is an analytic box: no rolled edge, same picture.
///
/// Light is linear throughout. The picture texture is sRGB, so sampling
/// decodes it, and the present pass encodes into an sRGB drawable.
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
        float4 blur;              // max radius in pixels, strength, hinge floor, max level
        float4 dim;               // hinge floor, strength, reach, max dim
        float4 slab;              // glass bounds in plan: min x, min y, max x, max y
        float4 glass;             // thickness, index of refraction, environment strength, unused
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
    #define KERNEL_SCENE , primitive_acceleration_structure accel [[buffer(1)]], const device packed_float3 *normals [[buffer(2)]], const device uint *indices [[buffer(3)]]
    #else
    #define SCENE_PARAMS
    #define SCENE_PASS
    #define KERNEL_SCENE
    #endif

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

    // The picture on the panel at a point in model space, blurred and dimmed
    // by height the same way the flat effect always has been.
    static float3 samplePicture(constant GlassUniforms &u, texture2d<float> picture, float2 point) {
        constexpr sampler linearSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float2 unit = (point - u.padded.xy) / u.padded.zw;
        if (unit.x < 0.0 || unit.x > 1.0 || unit.y < 0.0 || unit.y > 1.0) {
            return float3(0.0);
        }
        float2 texCoord = float2(unit.x, 1.0 - unit.y);

        float height = clamp(point.y / u.screen.y, 0.0, 1.0);
        float blur = u.blur.y * (u.blur.z + (1.0 - u.blur.z) * height);
        // Naming this `level` would shadow Metal's level() selector.
        float mipLevel = clamp(log2(max(blur * u.blur.x, 1.0)), 0.0, u.blur.w);
        float3 colour = picture.sample(linearSampler, texCoord, level(mipLevel)).rgb;

        // smoothstep rather than a clamped ratio, so the height where the
        // dimming reaches full strength leaves no visible edge.
        float spread = smoothstep(0.0, max(u.dim.z, 0.02), height);
        float fade = u.dim.y * (u.dim.x + (1.0 - u.dim.x) * spread);
        // Raising the factor to 2.2 keeps the dimming setting a fraction of
        // the encoded brightness.
        return colour * pow(1.0 - u.dim.w * fade, 2.2);
    }

    // The room around the glass: dark, with a broad soft light overhead and
    // behind the viewer, the way a desk lamp or ceiling panel sits, and one
    // small key light for a glint.
    static float3 sky(constant GlassUniforms &u, float3 modelDirection) {
        float3 w = normalize(toWorldDirection(u, modelDirection));
        float panel = smoothstep(0.30, 0.70, w.y) * smoothstep(-0.25, 0.30, w.z);
        float3 colour = float3(0.86, 0.90, 1.0) * (0.45 * panel);
        colour += float3(0.020, 0.021, 0.024) * (0.6 + 0.4 * w.y);
        float glint = pow(saturate(dot(w, u.keyLight.xyz)), 900.0) * u.keyLight.w;
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

    static float3 panelThroughGlass(constant GlassUniforms &u, texture2d<float> picture,
                                    float2 point, float2 straightPoint) {
        // Shorter wavelengths bend more, so the colours part slightly where
        // the glass bends the light the most: at the rolled edge.
        float2 shift = (point - straightPoint) * 0.035;
        if (length_squared(shift) < 0.0004) {
            return samplePicture(u, picture, point);
        }
        return float3(samplePicture(u, picture, point - shift).r,
                      samplePicture(u, picture, point).g,
                      samplePicture(u, picture, point + shift).b);
    }

    // Follows one ray into the slab: a Fresnel reflection off the surface it
    // enters, then refraction, absorption and internal reflection until the
    // ray lands on the panel or leaves the glass.
    static float3 traceGlass(constant GlassUniforms &u, texture2d<float> picture,
                             float3 origin, float3 direction, float2 straightPoint SCENE_PARAMS) {
        const float limit = 1.0e7;
        // A faint green cast that only long paths through the glass show.
        const float3 absorption = float3(0.0040, 0.0012, 0.0030);

        SlabHit entry = hitSlab(u, origin, direction, limit SCENE_PASS);
        if (!entry.found) { return float3(0.0); }
        float cosine = -dot(direction, entry.normal);
        // Grazing misses, and the back of the panel.
        if (cosine <= 0.0 || entry.normal.z < -0.5) { return float3(0.0); }

        float ior = u.glass.y;
        float f0 = pow((ior - 1.0) / (ior + 1.0), 2.0);
        float fresnel = schlick(cosine, f0);
        float3 colour = sky(u, reflect(direction, entry.normal)) * (fresnel * u.glass.z);

        float3 position = origin + direction * entry.distance;
        float3 inside = refract(direction, entry.normal, 1.0 / ior);
        float3 throughput = float3(1.0 - fresnel);
        for (int bounce = 0; bounce < 4; ++bounce) {
            SlabHit next = hitSlab(u, position + inside * 0.01, inside, limit SCENE_PASS);
            if (!next.found) { break; }
            position += inside * (next.distance + 0.01);
            throughput *= exp(-absorption * next.distance);
            if (next.normal.z < -0.9 && position.z < 0.05) {
                colour += throughput * panelThroughGlass(u, picture, position.xy, straightPoint);
                break;
            }
            float3 escape = refract(inside, -next.normal, ior);
            float3 mirrored = reflect(inside, -next.normal);
            if (all(escape == float3(0.0))) {
                // Total internal reflection.
                inside = mirrored;
                continue;
            }
            float leaving = schlick(dot(escape, next.normal), f0);
            colour += throughput * (1.0 - leaving) * sky(u, escape) * u.glass.z;
            throughput *= leaving;
            inside = mirrored;
        }
        return colour;
    }

    kernel void glassKernel(texture2d<float, access::write> output [[texture(0)]],
                            texture2d<float> picture [[texture(1)]],
                            constant GlassUniforms &u [[buffer(0)]]
                            KERNEL_SCENE,
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }

        // Pixels run down from the top; points run up from the bottom.
        float scale = u.lidOriginAndScale.w;
        float2 screenPoint = float2((float(gid.x) + 0.5) / scale,
                                    u.screen.y - (float(gid.y) + 0.5) / scale);
        float3 onLid = u.lidOriginAndScale.xyz
                     + float3(screenPoint.x, 0.0, 0.0)
                     + u.lidAxisY.xyz * screenPoint.y;
        float3 eye = u.eyeAndGlass.xyz;
        float3 origin = toModel(u, eye);
        float3 direction = normalize(toModelDirection(u, normalize(onLid - eye)));

        // The straight line to the panel: exactly the screen at the start
        // angle, so the overlay can fade in without a seam.
        float3 colour = float3(0.0);
        float2 straightPoint = float2(-1.0e6);
        if (direction.z < -1.0e-5) {
            float travel = -origin.z / direction.z;
            if (travel > 0.0) {
                straightPoint = (origin + direction * travel).xy;
                colour = samplePicture(u, picture, straightPoint);
            }
        }

        float glassAmount = u.eyeAndGlass.w;
        if (glassAmount > 0.001) {
            float3 glass = traceGlass(u, picture, origin, direction, straightPoint SCENE_PASS);
            colour = mix(colour, glass, glassAmount);
        }
        output.write(float4(colour, 1.0), gid);
    }

    struct PresentVertex {
        float4 position [[position]];
    };

    vertex PresentVertex presentVertex(uint vertexID [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        PresentVertex out;
        out.position = float4(corners[vertexID], 0.0, 1.0);
        return out;
    }

    fragment float4 presentFragment(PresentVertex in [[stage_in]],
                                    texture2d<float, access::read> frame [[texture(0)]]) {
        uint2 pixel = min(uint2(in.position.xy), uint2(frame.get_width() - 1, frame.get_height() - 1));
        return float4(frame.read(pixel).rgb, 1.0);
    }
    """
}
