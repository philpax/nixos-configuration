// Cel-shaded top-down landscape
precision highp float;

varying vec2 v_coords;
uniform vec2 size;
uniform float alpha;
uniform vec2 u_camera;

// --- Tuning ---
const float SCALE = 0.0015;         // world scale (smaller = bigger landmasses)

// Terrain thresholds (applied to 0..1 noise)
const float WATER_LEVEL = 0.46;
const float SAND_LEVEL  = 0.49;
const float GRASS_LEVEL = 0.58;
const float HILL_LEVEL  = 0.65;
const float ROCK_LEVEL  = 0.72;
const float SNOW_LEVEL  = 0.78;

// Colors — bold and saturated
const vec3 WATER      = vec3(0.12, 0.33, 0.72);
const vec3 FOAM       = vec3(0.85, 0.93, 1.00);
const vec3 SAND       = vec3(0.92, 0.85, 0.60);
const vec3 GRASS      = vec3(0.18, 0.62, 0.22);
const vec3 DARK_GRASS = vec3(0.12, 0.48, 0.15);
const vec3 HILL       = vec3(0.28, 0.52, 0.20);
const vec3 ROCK       = vec3(0.48, 0.44, 0.42);
const vec3 ROCK_DARK  = vec3(0.35, 0.32, 0.30);
const vec3 SNOW       = vec3(0.92, 0.94, 0.96);
// --------------

vec2 hash2(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    vec2 a = hash2(i);
    vec2 b = hash2(i + vec2(1.0, 0.0));
    vec2 c = hash2(i + vec2(0.0, 1.0));
    vec2 d = hash2(i + vec2(1.0, 1.0));
    return mix(mix(a.x, b.x, f.x), mix(c.x, d.x, f.x), f.y);
}

// Broad shapes — only 4 octaves for smooth, chunky landmasses
float fbm4(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    mat2 rot = mat2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 4; i++) {
        v += a * noise(p);
        p = rot * p * 2.0;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 canvas_pos = v_coords * size + u_camera;
    vec2 world = canvas_pos * SCALE;

    float h = fbm4(world);

    // Secondary noise for grass light/dark patches (low freq)
    float patch = noise(world * 1.5 + vec2(5.3, 2.7));

    vec3 col;

    if (h < WATER_LEVEL) {
        // Flat water — single color, no depth variation
        col = WATER;

    } else if (h < SAND_LEVEL) {
        // Beach
        col = SAND;

        // Foam fringe at water edge
        float foam_noise = noise(world * 30.0);
        float foam = step(0.4, foam_noise) * smoothstep(SAND_LEVEL, WATER_LEVEL, h);
        col = mix(col, FOAM, foam * 0.9);

    } else if (h < GRASS_LEVEL) {
        // Grass — two-tone patches
        col = (patch > 0.5) ? GRASS : DARK_GRASS;

    } else if (h < HILL_LEVEL) {
        // Hills
        col = HILL;

    } else if (h < ROCK_LEVEL) {
        // Mountain rock — two-tone
        col = (patch > 0.45) ? ROCK : ROCK_DARK;

    } else if (h < SNOW_LEVEL) {
        // High rock with snow patches
        float snow_patch = noise(world * 8.0);
        col = (snow_patch > 0.5) ? SNOW : ROCK;

    } else {
        // Snow cap
        col = SNOW;
    }

    gl_FragColor = vec4(col, 1.0) * alpha;
}
