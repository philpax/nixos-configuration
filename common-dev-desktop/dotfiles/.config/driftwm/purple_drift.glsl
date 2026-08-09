// Procedural marble/fluid background — dark purple with spatial cues
precision highp float;

varying vec2 v_coords;
uniform vec2 size;
uniform float alpha;
uniform vec2 u_camera;

// --- Tuning ---
const float TINT_STRENGTH = 0.3;
const vec3 NORTH_COLOR = vec3(0.15, 0.2, 0.5);   // cool blue
const vec3 SOUTH_COLOR = vec3(0.5, 0.1, 0.15);    // warm red
const vec3 EAST_COLOR  = vec3(0.5, 0.35, 0.1);    // amber
const vec3 WEST_COLOR  = vec3(0.1, 0.4, 0.3);     // teal
const float GRADIENT_SCALE = 1500.0;

const float WAVE_CREST = 1000.0;   // px between wave peaks
const float WAVE_WIDTH = 40.0;     // px width of the dark band
const float WAVE_STRENGTH = 0.02; // +ve brightens, -ve darkens

const float DOT_SPACING = 80.0;
const float DOT_RADIUS = 1.0;
const float DOT_BRIGHTNESS = 0.12;
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

float fbm(vec2 p, int octaves) {
    float v = 0.0;
    float a = 0.5;
    mat2 rot = mat2(0.8, 0.6, -0.6, 0.8);
    for (int i = 0; i < 5; i++) {
        if (i >= octaves) break;
        v += a * noise(p);
        p = rot * p * 2.0;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 canvas_pos = v_coords * size + u_camera;
    vec2 canvas = canvas_pos * 0.01;

    // --- Density gradient: more detail near origin, smoother far out ---
    float dist = length(canvas_pos);
    float warp_intensity = mix(2.5, 1.0, smoothstep(0.0, 3000.0, dist));

    float wx = fbm(canvas + vec2(0.0, 0.0), 5);
    float wy = fbm(canvas + vec2(5.2, 1.3), 5);
    float f = fbm(canvas + vec2(wx, wy) * warp_intensity, 5);

    // --- Base purple marble ---
    vec3 col;
    if (f < 0.35) {
        col = mix(vec3(0.01, 0.005, 0.03), vec3(0.04, 0.01, 0.08), f / 0.35);
    } else if (f < 0.65) {
        col = mix(vec3(0.04, 0.01, 0.08), vec3(0.08, 0.03, 0.14), (f - 0.35) / 0.3);
    } else {
        col = mix(vec3(0.08, 0.03, 0.14), vec3(0.12, 0.04, 0.18), (f - 0.65) / 0.35);
    }

    // --- Compass tint: cardinal color accents ---
    vec2 norm = canvas_pos / (GRADIENT_SCALE + abs(canvas_pos));
    float north = max(-norm.y, 0.0);
    float south = max( norm.y, 0.0);
    float east  = max( norm.x, 0.0);
    float west  = max(-norm.x, 0.0);
    vec3 tint = north * NORTH_COLOR
              + south * SOUTH_COLOR
              + east  * EAST_COLOR
              + west  * WEST_COLOR;
    col += tint * TINT_STRENGTH;

    // --- Radial rings: narrow dark bands with wide gaps ---
    float wave_dist = mod(dist, WAVE_CREST); // distance into current crest
    float wave_center = WAVE_CREST * 0.5;    // peak at midpoint of crest
    float wave = smoothstep(WAVE_WIDTH, 0.0, abs(wave_dist - wave_center));
    col += wave * WAVE_STRENGTH;

    // --- Dot grid overlay: subtle brightening ---
    vec2 canvas_mod = mod(canvas_pos, DOT_SPACING);
    vec2 dist_to_dot = min(canvas_mod, DOT_SPACING - canvas_mod);
    float d = length(dist_to_dot);
    float dot_alpha = 1.0 - smoothstep(DOT_RADIUS - 0.5, DOT_RADIUS + 0.5, d);
    col += dot_alpha * DOT_BRIGHTNESS;

    gl_FragColor = vec4(col, 1.0) * alpha;
}
