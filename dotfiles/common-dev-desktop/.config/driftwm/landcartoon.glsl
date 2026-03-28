// Cel-shaded top-down landscape with biomes
precision highp float;

varying vec2 v_coords;
uniform vec2 size;
uniform float alpha;
uniform vec2 u_camera;

// --- Tuning ---
const float SCALE = 0.0015;          // terrain scale
const float BIOME_SCALE = 0.00025;   // biome scale (much larger than terrain)

// Terrain thresholds
const float WATER_LEVEL = 0.46;
const float SAND_LEVEL  = 0.49;
const float GRASS_LEVEL = 0.58;
const float HILL_LEVEL  = 0.65;
const float ROCK_LEVEL  = 0.72;
const float SNOW_LEVEL  = 0.78;

// Biome thresholds
const float TEMP_MID = 0.5;
const float MOIST_MID = 0.5;

// --- Biome palettes ---
// Temperate (warm + wet): classic greens
const vec3 TE_WATER      = vec3(0.12, 0.33, 0.72);
const vec3 TE_SAND       = vec3(0.92, 0.85, 0.60);
const vec3 TE_GRASS      = vec3(0.18, 0.62, 0.22);
const vec3 TE_DARK_GRASS = vec3(0.12, 0.48, 0.15);
const vec3 TE_HILL       = vec3(0.28, 0.52, 0.20);
const vec3 TE_ROCK       = vec3(0.48, 0.44, 0.42);
const vec3 TE_ROCK_DARK  = vec3(0.35, 0.32, 0.30);

// Tropical (hot + wet): lush jungle, turquoise water
const vec3 TR_WATER      = vec3(0.05, 0.42, 0.65);
const vec3 TR_SAND       = vec3(0.95, 0.90, 0.70);
const vec3 TR_GRASS      = vec3(0.10, 0.68, 0.28);
const vec3 TR_DARK_GRASS = vec3(0.05, 0.52, 0.18);
const vec3 TR_HILL       = vec3(0.15, 0.58, 0.22);
const vec3 TR_ROCK       = vec3(0.42, 0.40, 0.35);
const vec3 TR_ROCK_DARK  = vec3(0.30, 0.28, 0.24);

// Desert (hot + dry): golden sand, sparse scrub
const vec3 DE_WATER      = vec3(0.15, 0.30, 0.58);
const vec3 DE_SAND       = vec3(0.88, 0.78, 0.50);
const vec3 DE_GRASS      = vec3(0.72, 0.68, 0.42);
const vec3 DE_DARK_GRASS = vec3(0.60, 0.55, 0.35);
const vec3 DE_HILL       = vec3(0.65, 0.55, 0.38);
const vec3 DE_ROCK       = vec3(0.58, 0.50, 0.40);
const vec3 DE_ROCK_DARK  = vec3(0.45, 0.38, 0.30);

// Tundra (cold + dry): frozen, sparse
const vec3 TU_WATER      = vec3(0.18, 0.35, 0.55);
const vec3 TU_SAND       = vec3(0.75, 0.72, 0.65);
const vec3 TU_GRASS      = vec3(0.45, 0.55, 0.42);
const vec3 TU_DARK_GRASS = vec3(0.35, 0.45, 0.35);
const vec3 TU_HILL       = vec3(0.50, 0.50, 0.48);
const vec3 TU_ROCK       = vec3(0.55, 0.53, 0.52);
const vec3 TU_ROCK_DARK  = vec3(0.42, 0.40, 0.40);

// Shared
const vec3 FOAM = vec3(0.85, 0.93, 1.00);
const vec3 SNOW = vec3(0.92, 0.94, 0.96);
// --------------

// Integer-based hash — avoids expensive sin() entirely
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm3(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    mat2 rot = mat2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 3; i++) {
        v += a * noise(p);
        p = rot * p * 2.0;
        a *= 0.5;
    }
    return v;
}

// Single octave for biome maps — broad features don't need more
float fbm1(vec2 p) {
    return noise(p);
}

void main() {
    vec2 canvas_pos = v_coords * size + u_camera;
    vec2 world = canvas_pos * SCALE;

    // Terrain height (3 octaves — 4th added negligible detail)
    float h = fbm3(world);

    // Biome axes — single octave is enough at this scale
    float temperature = fbm1(canvas_pos * BIOME_SCALE + vec2(42.0, 17.0));
    float moisture = fbm1(canvas_pos * BIOME_SCALE + vec2(91.0, 63.0));

    // Smooth biome blending — gradient transition over BLEND_WIDTH around thresholds
    const float BLEND_WIDTH = 0.24;
    float t = smoothstep(TEMP_MID - BLEND_WIDTH, TEMP_MID + BLEND_WIDTH, temperature);
    float m = smoothstep(MOIST_MID - BLEND_WIDTH, MOIST_MID + BLEND_WIDTH, moisture);

    // Blend all four biome palettes: mix cold/hot along t, then dry/wet along m
    vec3 b_water      = mix(mix(TU_WATER, DE_WATER, t),           mix(TE_WATER, TR_WATER, t), m);
    vec3 b_sand       = mix(mix(TU_SAND, DE_SAND, t),             mix(TE_SAND, TR_SAND, t), m);
    vec3 b_grass      = mix(mix(TU_GRASS, DE_GRASS, t),           mix(TE_GRASS, TR_GRASS, t), m);
    vec3 b_dark_grass = mix(mix(TU_DARK_GRASS, DE_DARK_GRASS, t), mix(TE_DARK_GRASS, TR_DARK_GRASS, t), m);
    vec3 b_hill       = mix(mix(TU_HILL, DE_HILL, t),             mix(TE_HILL, TR_HILL, t), m);
    vec3 b_rock       = mix(mix(TU_ROCK, DE_ROCK, t),             mix(TE_ROCK, TR_ROCK, t), m);
    vec3 b_rock_dark  = mix(mix(TU_ROCK_DARK, DE_ROCK_DARK, t),   mix(TE_ROCK_DARK, TR_ROCK_DARK, t), m);

    // Reuse terrain height for two-tone variation (free — already computed)
    float patch = fract(h * 7.0);

    vec3 col;

    // Thin foam band on the water side, just below the shoreline
    const float FOAM_LEVEL = WATER_LEVEL - 0.015;

    if (h < FOAM_LEVEL) {
        col = b_water;

    } else if (h < WATER_LEVEL) {
        // Shallow water band — lighter blue near shore
        col = mix(b_water, vec3(1.0), 0.35);

    } else if (h < SAND_LEVEL) {
        col = b_sand;

    } else if (h < GRASS_LEVEL) {
        col = (patch > 0.5) ? b_grass : b_dark_grass;

    } else if (h < HILL_LEVEL) {
        col = b_hill;

    } else if (h < ROCK_LEVEL) {
        col = (patch > 0.45) ? b_rock : b_rock_dark;

    } else if (h < SNOW_LEVEL) {
        col = (patch > 0.5) ? SNOW : b_rock;

    } else {
        col = SNOW;
    }

    gl_FragColor = vec4(col, 1.0) * alpha;
}
