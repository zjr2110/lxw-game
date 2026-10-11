shader_type canvas_item;
// 开屏遮罩：整屏底色，中间一个圆洞（洞里看到首页），洞边有一圈淡淡的内阴影。
uniform vec4 bg_color : source_color = vec4(0.965, 0.949, 0.918, 1.0);
uniform vec2 rect_size = vec2(720.0, 1280.0);
uniform vec2 hole_c = vec2(360.0, 600.0);
uniform float hole_r = -1.0;

void fragment() {
	vec2 p = UV * rect_size;
	if (hole_r <= 0.0) {
		COLOR = bg_color;
	} else {
		float d = length(p - hole_c) - hole_r;
		if (d >= 0.0) {
			COLOR = vec4(bg_color.rgb, smoothstep(0.0, 1.5, d));
		} else {
			COLOR = vec4(0.12, 0.06, 0.03, 0.22 * exp(d / 9.0));
		}
	}
}
