shader_type canvas_item;
// 纸张着色器。
// TEXTURE 是剪纸遮罩（白 = 有纸），纸色、纤维、洒金、光泽、剪口阴影都在这里生成。
// 纸面纹理按“纸张坐标”生成（wpos），所以展开后各层之间不会出现镜像重复的花纹。
// 顶点颜色 COLOR：rgb 为明暗色调，a 为整体透明度。

uniform vec4 paper_color : source_color = vec4(0.72, 0.07, 0.06, 1.0);
uniform float gold_amount = 0.0;    // 洒金
uniform float gloss = 0.0;          // 蜡光纸的光泽
uniform float metal = 0.0;          // 金箔
uniform float fiber_amount = 1.0;   // 纤维明显程度
uniform float cloud_amount = 1.0;   // 明暗起伏（染纸更明显）
uniform float shadow_mode = 0.0;    // 1 = 画成模糊投影
uniform vec2 tex_px = vec2(1024.0); // 遮罩像素尺寸
uniform vec2 w_scale = vec2(1.0);   // 色块、缩略图用：顶点坐标 → 纹理坐标
uniform vec2 w_offset = vec2(0.0);
// 剪纸用：纹理坐标 → 这片纸在展开后整张纸上的位置。纹路“印”在纸上，翻折、移动都跟着纸走
uniform bool circle = false;        // 圆形色块
uniform bool use_sheet = false;
uniform vec2 sheet_o = vec2(0.0);
uniform vec2 sheet_x = vec2(1.0, 0.0);
uniform vec2 sheet_y = vec2(0.0, 1.0);

varying vec2 wpos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * noise(p);
		p = p * 2.07 + vec2(3.1, 7.7);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	wpos = VERTEX * w_scale + w_offset;
}

void fragment() {
	vec2 uv = UV;
	vec2 px = 1.0 / tex_px;

	if (shadow_mode > 0.5) {
		float s = 0.0;
		for (int i = -2; i <= 2; i++) {
			for (int j = -2; j <= 2; j++) {
				s += texture(TEXTURE, uv + vec2(float(i), float(j)) * px * 2.5).r;
			}
		}
		s /= 25.0;
		COLOR = vec4(0.06, 0.03, 0.01, s * 0.5 * COLOR.a);
	} else {
		float m = texture(TEXTURE, uv).r;
		float a = smoothstep(0.3, 0.7, m);
		vec2 p = use_sheet ? sheet_o + uv.x * sheet_x + uv.y * sheet_y : wpos;

		// 明暗起伏 + 不同方向的细纤维 + 细颗粒
		float cloud = fbm(p * 0.008);
		float cloud2 = fbm(p * 0.035 + 5.0);
		vec2 r1 = vec2(0.8 * p.x + 0.6 * p.y, -0.6 * p.x + 0.8 * p.y);
		vec2 r2 = vec2(0.28 * p.x - 0.96 * p.y, 0.96 * p.x + 0.28 * p.y);
		vec2 r3 = vec2(0.97 * p.x + 0.26 * p.y, -0.26 * p.x + 0.97 * p.y);
		float fa = noise(vec2(r1.x * 0.5, r1.y * 0.06));
		float fb = noise(vec2(r2.x * 0.5, r2.y * 0.06) + 11.0);
		float fc = noise(vec2(r3.x * 0.06, r3.y * 0.5) + 23.0);
		float fib = smoothstep(0.80, 0.97, max(max(fa, fb), fc));
		fib *= smoothstep(0.3, 0.7, noise(p * 0.02 + 40.0));
		float grain = noise(p * 0.9) - 0.5;
		float speck = step(0.994, hash(floor(p * 0.5)));

		vec3 col = paper_color.rgb;
		col *= 1.0 + ((0.84 + 0.22 * cloud + 0.06 * cloud2) - 1.0) * cloud_amount;
		col = mix(col, col * 1.3 + vec3(0.07, 0.06, 0.05), fib * 0.16 * fiber_amount);
		col *= 1.0 + grain * 0.06 * fiber_amount;
		col *= 1.0 - speck * 0.2 * fiber_amount;

		// 金箔：拉丝纹 + 大块明暗
		if (metal > 0.0) {
			float brush = noise(vec2(p.x * 0.02, p.y * 1.4));
			float sheen = 0.5 + 0.5 * sin((p.x + p.y) * 0.004 + cloud * 3.0);
			vec3 g = mix(vec3(0.62, 0.43, 0.14), vec3(1.0, 0.86, 0.5), sheen);
			g *= 0.9 + 0.2 * brush;
			col = mix(col, g, metal);
		}

		// 蜡光纸：斜向高光带
		if (gloss > 0.0) {
			float band = exp(-pow(((p.x * 0.7 + p.y * 0.7) / 420.0) - 0.15, 2.0) * 9.0);
			col = mix(col, vec3(1.0, 0.9, 0.86), band * 0.16 * gloss);
			float fine = noise(p * 0.05 + 3.0);
			col *= 1.0 + 0.05 * gloss * (fine - 0.5);
		}

		// 剪口边缘略暗，像纸的厚度
		float nb = texture(TEXTURE, uv + vec2(px.x * 1.5, 0.0)).r
				+ texture(TEXTURE, uv - vec2(px.x * 1.5, 0.0)).r
				+ texture(TEXTURE, uv + vec2(0.0, px.y * 1.5)).r
				+ texture(TEXTURE, uv - vec2(0.0, px.y * 1.5)).r;
		float edge = clamp(1.0 - nb * 0.25, 0.0, 1.0);
		col *= 1.0 - edge * 0.5;

		// 洒金
		if (gold_amount > 0.0) {
			vec2 gp = p / 5.0;
			vec2 cell = floor(gp);
			float h = hash(cell);
			vec2 f = fract(gp) - 0.5 - (vec2(hash(cell + 1.3), hash(cell + 2.9)) - 0.5) * 0.4;
			float shape = smoothstep(0.42, 0.12, length(f * vec2(1.0, 1.0 + hash(cell + 5.1) * 1.6)));
			float cluster = smoothstep(0.35, 0.75, noise(p * 0.015));
			float fleck = step(1.0 - 0.22 * gold_amount * cluster, h) * shape;
			vec3 gold = vec3(0.96, 0.78, 0.38) * (0.75 + 0.45 * hash(cell + 7.7));
			col = mix(col, gold, fleck * 0.95);
		}

		col *= COLOR.rgb;
		if (circle) {
			float d = length(UV - vec2(0.5));
			a *= 1.0 - smoothstep(0.48, 0.5, d);
			col *= 1.0 - smoothstep(0.3, 0.5, d) * 0.12;
		}
		COLOR = vec4(col, a * COLOR.a);
	}
}
