shader_type canvas_item;

// The wrong-ADMIT punish beat: torn signal bands and a static burst.
//
// This draws its OWN bands additively rather than distorting the screen behind it. Sampling
// the screen in 2D needs a BackBufferCopy and is unreliable under the Compatibility renderer
// we ship on, so a self-contained overlay is both simpler and safer on device. At
// intensity 0 it outputs alpha 0 and costs nothing, so it can live in the tree permanently.

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float band_count = 30.0;
uniform float static_amount : hint_range(0.0, 1.0) = 0.55;
uniform vec3 tear_tint : source_color = vec3(0.72, 0.78, 0.85);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float hash1(float x) {
	return fract(sin(x * 91.3458) * 47453.5453);
}

void fragment() {
	if (intensity < 0.001) {
		COLOR = vec4(0.0);
	} else {
		// Quantise to bands and pick a few at random to light up each tick, so it reads as
		// intermittent tearing rather than a uniform flash.
		float tick = floor(TIME * 45.0);
		float band = floor(UV.y * band_count);
		float pick = hash1(band * 3.7 + tick);
		float lit = step(0.62, pick);

		// Horizontal smear within a lit band.
		float smear = hash1(band + tick);
		float across = step(smear * 0.6, UV.x) * step(UV.x, smear * 0.6 + 0.55);

		float bar = lit * across * (0.35 + 0.65 * hash1(band * 7.1 + tick));

		// Static across the whole frame, heaviest at peak intensity.
		float noise = hash(UV * vec2(1280.0, 720.0) + vec2(tick, tick * 1.7));
		float fuzz = step(1.0 - static_amount * intensity * 0.35, noise);

		float a = clamp(bar * 0.55 + fuzz * 0.5, 0.0, 1.0) * intensity;
		COLOR = vec4(tear_tint * (0.6 + 0.4 * noise), a);
	}
}
