shader_type canvas_item;

// Animated HD-2D menu background: warm dusk gradient + drifting sand haze + scanlines
uniform vec4 top_color : source_color = vec4(0.22, 0.13, 0.08, 1.0);
uniform vec4 mid_color : source_color = vec4(0.45, 0.25, 0.12, 1.0);
uniform vec4 bot_color : source_color = vec4(0.10, 0.07, 0.05, 1.0);
uniform float sand_intensity : hint_range(0.0, 1.0) = 0.35;
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.08;
uniform float time_scale = 1.0;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
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

void fragment() {
    float t = TIME * time_scale;
    // Vertical gradient with a slight horizon glow
    float y = UV.y;
    vec3 col;
    if (y < 0.5) {
        col = mix(top_color.rgb, mid_color.rgb, smoothstep(0.0, 0.5, y));
    } else {
        col = mix(mid_color.rgb, bot_color.rgb, smoothstep(0.5, 1.0, y));
    }
    // Horizon glow band
    float horizon = smoothstep(0.45, 0.5, y) * (1.0 - smoothstep(0.5, 0.6, y));
    col += vec3(0.5, 0.3, 0.12) * horizon * 0.6;

    // Drifting sand haze (two layers of scrolling noise)
    vec2 uv1 = UV * vec2(3.0, 1.5) + vec2(t * 0.05, t * 0.01);
    vec2 uv2 = UV * vec2(5.0, 2.5) + vec2(-t * 0.08, t * 0.02);
    float n1 = noise(uv1);
    float n2 = noise(uv2);
    col += vec3(0.6, 0.45, 0.25) * (n1 * 0.5 + n2 * 0.5) * sand_intensity;

    // Subtle scanlines for retro feel
    float scan = sin(UV.y * 720.0) * 0.5 + 0.5;
    col -= scanline_strength * scan;

    // Vignette
    vec2 v = UV - 0.5;
    float vig = 1.0 - dot(v, v) * 1.3;
    col *= clamp(vig, 0.0, 1.0);

    COLOR = vec4(col, 1.0);
}
