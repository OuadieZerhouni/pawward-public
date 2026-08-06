shader_type canvas_item;

// Full-screen atmosphere pass: film grain + vignette whose pulse rate is driven by strike
// count. One ColorRect on a CanvasLayer above the scene, one overdraw pass.
//
// Uses UV (local to the rect, which spans the whole logical canvas) rather than SCREEN_UV,
// so the look is identical regardless of window size or device resolution.

uniform float grain_amount : hint_range(0.0, 0.3) = 0.055;
uniform float vignette_base : hint_range(0.0, 2.0) = 0.85;
uniform float vignette_pulse : hint_range(0.0, 0.8) = 0.0;
uniform float pulse_rate : hint_range(0.0, 8.0) = 0.0;
uniform vec3 tint : source_color = vec3(0.02, 0.025, 0.04);
// Canvas aspect (width / height). Without this the vignette is measured in normalized
// units and reaches the short edge far sooner, which clips into hard horizontal bands.
uniform float aspect = 0.5625;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	// Correct to square space so the falloff is a true ellipse around the centre.
	vec2 d = (UV - vec2(0.5)) * vec2(1.0, 1.0 / max(aspect, 0.0001)) * aspect;
	float dist = length(d) * 2.0;

	float pulse = vignette_pulse * (0.5 + 0.5 * sin(TIME * pulse_rate));
	float strength = vignette_base + pulse;

	// Generous, overlapping stops so the gradient never saturates into a visible edge.
	float vig = smoothstep(0.15, 1.25, dist) * strength;

	float g = hash(UV * vec2(1920.0, 1920.0) + vec2(TIME * 13.0, TIME * 7.0));
	float grain = (g - 0.5) * grain_amount;

	float alpha = clamp(vig + abs(grain), 0.0, 1.0);
	COLOR = vec4(tint + vec3(grain), alpha);
}
