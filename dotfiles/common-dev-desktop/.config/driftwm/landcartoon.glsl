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

// Very broad noise for biome maps (2 octaves)
float fbm2(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    mat2 rot = mat2(0.6, 0.8, -0.8, 0.6);
    for (int i = 0; i < 2; i++) {
        v += a * noise(p);
        p = rot * p * 2.0;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 canvas_pos = v_coords * size + u_camera;
    vec2 world = canvas_pos * SCALE;

    // Terrain height
    float h = fbm4(world);

    // Biome axes — large-scale, independent seeds
    float temperature = fbm2(canvas_pos * BIOME_SCALE + vec2(42.0, 17.0));
    float moisture = fbm2(canvas_pos * BIOME_SCALE + vec2(91.0, 63.0));

    // Stippled biome blending: use high-freq noise to dither at boundaries
    float dither = noise(world * 8.0 + vec2(13.7, 29.1));
    // Widen the transition zone: remap biome axes with dither offset
    const float BLEND_ZONE = 0.06; // noise range over which stippling occurs
    bool hot = temperature > TEMP_MID + (dither - 0.5) * BLEND_ZONE;
    bool wet = moisture > MOIST_MID + (dither - 0.5) * BLEND_ZONE;

    // Select biome palette
    vec3 b_water, b_sand, b_grass, b_dark_grass, b_hill, b_rock, b_rock_dark;
    if (hot && wet) {
        // Tropical
        b_water = TR_WATER; b_sand = TR_SAND;
        b_grass = TR_GRASS; b_dark_grass = TR_DARK_GRASS;
        b_hill = TR_HILL; b_rock = TR_ROCK; b_rock_dark = TR_ROCK_DARK;
    } else if (hot && !wet) {
        // Desert
        b_water = DE_WATER; b_sand = DE_SAND;
        b_grass = DE_GRASS; b_dark_grass = DE_DARK_GRASS;
        b_hill = DE_HILL; b_rock = DE_ROCK; b_rock_dark = DE_ROCK_DARK;
    } else if (!hot && wet) {
        // Temperate
        b_water = TE_WATER; b_sand = TE_SAND;
        b_grass = TE_GRASS; b_dark_grass = TE_DARK_GRASS;
        b_hill = TE_HILL; b_rock = TE_ROCK; b_rock_dark = TE_ROCK_DARK;
    } else {
        // Tundra
        b_water = TU_WATER; b_sand = TU_SAND;
        b_grass = TU_GRASS; b_dark_grass = TU_DARK_GRASS;
        b_hill = TU_HILL; b_rock = TU_ROCK; b_rock_dark = TU_ROCK_DARK;
    }

    // Patch noise for two-tone variation
    float patch = noise(world * 1.5 + vec2(5.3, 2.7));

    vec3 col;

    if (h < WATER_LEVEL) {
        col = b_water;

    } else if (h < SAND_LEVEL) {
        col = b_sand;
        // Foam fringe at water edge
        float foam_noise = noise(world * 30.0);
        float foam = step(0.4, foam_noise) * smoothstep(SAND_LEVEL, WATER_LEVEL, h);
        col = mix(col, FOAM, foam * 0.9);

    } else if (h < GRASS_LEVEL) {
        col = (patch > 0.5) ? b_grass : b_dark_grass;

    } else if (h < HILL_LEVEL) {
        col = b_hill;

    } else if (h < ROCK_LEVEL) {
        col = (patch > 0.45) ? b_rock : b_rock_dark;

    } else if (h < SNOW_LEVEL) {
        float snow_patch = noise(world * 8.0);
        col = (snow_patch > 0.5) ? SNOW : b_rock;

    } else {
        col = SNOW;
    }

    gl_FragColor = vec4(col, 1.0) * alpha;
}
