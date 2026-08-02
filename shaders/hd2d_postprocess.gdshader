// HD-2D Post-Processing Shader
// Applies subtle vignette, warm color grading, and edge darkening
// for the Octopath Traveler-style HD-2D aesthetic.
shader_type canvas_item;

// --- Uniforms ---
uniform float vignette_intensity : hint_range(0.0, 1.0) = 0.35;
uniform float vignette_radius : hint_range(0.3, 1.0) = 0.75;
uniform float vignette_softness : hint_range(0.1, 2.0) = 0.5;

uniform vec3 warm_tint : source_color = vec3(1.08, 0.98, 0.88);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.25;

uniform float contrast : hint_range(0.8, 1.5) = 1.08;
uniform float saturation : hint_range(0.5, 1.5) = 1.05;
uniform float brightness : hint_range(0.8, 1.2) = 0.98;

uniform float edge_darken : hint_range(0.0, 0.5) = 0.1;

void fragment() {
	vec4 color = texture(TEXTURE, UV);

	// --- Vignette ---
	vec2 center = UV - 0.5;
	float dist = length(center);
	float vignette = smoothstep(vignette_radius, vignette_radius - vignette_softness, dist);
	vignette = mix(1.0 - vignette_intensity, 1.0, vignette);

	// --- Color Grading ---
	// Warm tint (multiply toward warm color)
	color.rgb = mix(color.rgb, color.rgb * warm_tint, tint_strength);

	// Brightness
	color.rgb *= brightness;

	// Contrast (center around mid-gray)
	color.rgb = (color.rgb - 0.5) * contrast + 0.5;

	// Saturation
	float luma = dot(color.rgb, vec3(0.299, 0.587, 0.114));
	color.rgb = mix(vec3(luma), color.rgb, saturation);

	// --- Edge Darkening (subtle fake AO on screen edges) ---
	float edge = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));
	edge = smoothstep(0.0, 0.1, edge);
	color.rgb *= mix(1.0 - edge_darken, 1.0, edge);

	// Apply vignette
	color.rgb *= vignette;

	COLOR = color;
}
