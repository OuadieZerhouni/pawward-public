shader_type canvas_item;
render_mode blend_add;

// The pool of warm light the patient sits in. Additive and radial — a flat ColorRect leaves
// visible rectangular seams where its edges fall, which reads as a rendering bug rather
// than atmosphere. Sits below the patient, so it lights the scene rather than washing it.
//
// `flicker` is what the lamp-flicker beat drives: a cheap noise wobble on brightness, no
// Light2D and therefore no lighting pass on a 2D-only game.

uniform vec3 lamp_color : source_color = vec3(1.0, 0.84, 0.55);
uniform float strength : hint_range(0.0, 1.0) = 0.16;
uniform vec2 centre = vec2(0.5, 0.34);
uniform float radius : hint_range(0.05, 1.5) = 0.62;
uniform float flicker : hint_range(0.0, 1.0) = 0.0;
uniform float aspect = 0.5625;

float hash(float x) {
	return fract(sin(x * 78.233) * 43758.5453);
}

void fragment() {
	vec2 d = (UV - centre) * vec2(1.0, 1.0 / max(aspect, 0.0001)) * aspect;
	float falloff = 1.0 - smoothstep(0.0, radius, length(d) * 2.0);
	falloff = pow(falloff, 1.6);

	// Two offset hash samples give an irregular mains-hum wobble rather than a clean sine.
	float t = TIME * 11.0;
	float wobble = mix(1.0, 0.62 + 0.5 * (hash(floor(t)) * 0.6 + hash(floor(t * 2.7)) * 0.4), flicker);

	COLOR = vec4(lamp_color * strength * falloff * wobble, 1.0);
}
