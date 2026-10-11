shader_type canvas_item;
// 开屏图标：part 0 完整；1 只留圆窗外的一圈；2 只留圆窗里的圆片。剪口处略暗，像纸的厚度。
uniform vec2 center = vec2(0.4996, 0.4899);
uniform float radius = 0.4204;
uniform int part = 0;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float d = distance(UV, center) - radius;
	float fw = max(fwidth(d), 1e-5);
	float a = 1.0;
	if (part == 1) {
		a = smoothstep(-fw, fw, d);
	} else if (part == 2) {
		a = 1.0 - smoothstep(-fw, fw, d);
	}
	float shade = 1.0;
	if (part != 0) {
		shade = 1.0 - 0.35 * exp(-abs(d) / (fw * 2.5));
	}
	COLOR = vec4(c.rgb * shade, c.a * a);
}
