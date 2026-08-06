shader_type canvas_item;

// Weather on the glass. Drawn as a shader rather than with GPUParticles2D because it is a
// full-screen repeating pattern with no per-drop behaviour, so particles would cost thousands of
// nodes to say the same thing — and this stays cheap on an older phone.
//
// Streaks are procedural: the screen is divided into vertical columns, each with its own random
// speed and phase, so no two columns fall in step. `amount` at 0 outputs nothing.

uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float speed : hint_range(0.0, 4.0) = 1.0;
uniform float columns = 90.0;
uniform vec3 rain_tint : source_color = vec3(0.72, 0.80, 0.90);
// Fog is a separate, slower layer: the same uniform driving both would make heavy rain foggy.
uniform float fog : hint_range(0.0, 1.0) = 0.0;

float hash(float x) {
	return fract(sin(x * 127.1) * 43758.5453);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec3 col = vec3(0.0);
	float alpha = 0.0;

	if (amount > 0.001) {
		float col_id = floor(UV.x * columns);
		float in_col = fract(UV.x * columns);

		// Per-column randomness: which columns have drops at all, how fast, and where they start.
		float active = step(1.0 - amount, hash(col_id * 1.7));
		float rate = 0.6 + hash(col_id * 3.3) * 1.4;
		float offset = hash(col_id * 7.9);

		// Streak position down the column, wrapping.
		float y = fract(UV.y * 2.4 - TIME * speed * rate + offset);
		// Short bright head fading to a tail: a uniform line reads as a scratch, not a drop.
		float streak = pow(clamp(1.0 - y * 7.0, 0.0, 1.0), 2.0);
		// Keep the drop thin and off-centre in its column.
		float across = smoothstep(0.42, 0.5, in_col) * smoothstep(0.62, 0.54, in_col);

		float drop = streak * across * active;
		col += rain_tint * drop;
		alpha += drop * 0.55 * amount;
	}

	if (fog > 0.001) {
		// Slow drifting haze. Two offset samples so it does not read as a single sliding texture.
		vec2 p = UV * vec2(3.0, 5.0);
		float a = hash2(floor(p + vec2(TIME * 0.03, 0.0)));
		float b = hash2(floor(p * 1.7 - vec2(0.0, TIME * 0.02)));
		float haze = (a * 0.6 + b * 0.4);
		// Heavier toward the top, where a window would mist first.
		haze *= mix(0.35, 1.0, 1.0 - UV.y);
		col += vec3(0.62, 0.68, 0.74) * haze * fog;
		alpha += haze * fog * 0.28;
	}

	COLOR = vec4(col, clamp(alpha, 0.0, 1.0));
}
