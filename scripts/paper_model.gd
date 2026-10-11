extends RefCounted
## 剪纸数据模型。
##
## 纸折好后，所有层的图案都相同（互为镜像），所以只存“扇区”这一块的遮罩图（白 = 有纸）。
## 显示展开后的整张纸时，每一片都从这张扇区图取样，再按 cells 里的变换摆到各自的位置。
##
## 两种剪法：
## - cut_slit：剪刀/刻刀，沿一条折线剪开一道细缝，不会自动闭合
## - cut_region：纹样印章，整块挖掉
## 剪完后由 Analyzer 在后台做连通分析，与主体断开的碎片会掉落（见 cut_screen）。

const FoldGeom = preload("res://scripts/fold_geom.gd")

const MAX_RES := 1024
const MAX_PX_PER_UNIT := 2.5
const MARGIN := 6.0              # 扇区外留的边，存镜像像素用（纸张单位）
const SLIT_PX := 3.0             # 剪刀缝宽（遮罩像素）
const HISTORY_LIMIT := 25

var fold_id := "eight"
var wedge := PackedVector2Array()
var cells: Array[Transform2D] = []
var stages: Array = []
var neighbors: Array[Transform2D] = []
var bounds := Rect2()            # 展开后整张纸的范围
var wedge_bounds := Rect2()

var tex_rect := Rect2()          # 遮罩图覆盖的纸张坐标范围
var px_per_unit := 1.0
var tex_w := 0
var tex_h := 0
var a_w := 0                     # 分析用的缩小尺寸（遮罩的一半）
var a_h := 0
var classmap := PackedByteArray()  # 分析尺寸下每个像素：2 = 扇区内，1 = 纸上其它层，0 = 纸外

var mask: Image
var texture: ImageTexture
var initial_area := 1            # 扇区内的纸面像素数（分析尺寸）
var cut_count := 0
var tool_uses := {}
var epoch := 0                   # 撤销、换纸时加一，用来作废进行中的分析

var _strip_dst := PackedInt32Array()
var _strip_src := PackedInt32Array()
var _history: Array[Image] = []


func _init(p_fold := "eight") -> void:
	fold_id = p_fold
	var g := FoldGeom.build(fold_id)
	wedge = g["wedge"]
	cells = g["cells"]
	stages = g["stages"]
	neighbors = g["neighbors"]
	bounds = g["bounds"]
	wedge_bounds = g["wedge_bounds"]

	var wb := wedge_bounds.grow(MARGIN)
	px_per_unit = minf(minf(MAX_RES / wb.size.x, MAX_RES / wb.size.y), MAX_PX_PER_UNIT)
	tex_w = int(ceil(wb.size.x * px_per_unit / 2.0)) * 2
	tex_h = int(ceil(wb.size.y * px_per_unit / 2.0)) * 2
	tex_rect = Rect2(wb.position, Vector2(tex_w, tex_h) / px_per_unit)
	a_w = tex_w / 2
	a_h = tex_h / 2

	_build_classmap()
	_build_strips()
	mask = Image.create_empty(tex_w, tex_h, false, Image.FORMAT_L8)
	_fill_blank()
	texture = ImageTexture.create_from_image(mask)
	initial_area = maxi(1, count_paper())


# ---------------------------------------------------------------- 坐标

func to_tex(p: Vector2) -> Vector2:
	return (p - tex_rect.position) * px_per_unit


func from_tex(q: Vector2) -> Vector2:
	return q / px_per_unit + tex_rect.position


func to_ana(p: Vector2) -> Vector2:
	return to_tex(p) * 0.5


func uv_of(p: Vector2) -> Vector2:
	return (p - tex_rect.position) / tex_rect.size


func ana_index(p: Vector2) -> int:
	var q := to_ana(p)
	var x := int(floor(q.x))
	var y := int(floor(q.y))
	if x < 0 or y < 0 or x >= a_w or y >= a_h:
		return -1
	return y * a_w + x


func in_wedge(p: Vector2) -> bool:
	return Geometry2D.is_point_in_polygon(p, wedge)


func layer_count() -> int:
	return cells.size()


# ---------------------------------------------------------------- 剪

## 剪刀/刻刀：沿折线剪一道缝。points 为纸张坐标
func cut_slit(points: PackedVector2Array, tool_id := "scissors", push := true) -> void:
	if points.size() < 2:
		return
	if push:
		_push_history()
	var hw := SLIT_PX * 0.5
	var clip := _tex_poly(wedge)
	for i in points.size() - 1:
		var a := to_tex(points[i])
		var b := to_tex(points[i + 1])
		var d := b - a
		var l := d.length()
		if l < 0.01:
			continue
		d /= l
		var nrm := Vector2(-d.y, d.x) * hw
		a -= d * hw
		b += d * hw
		_fill(mask, PackedVector2Array([a + nrm, b + nrm, b - nrm, a - nrm]), clip, 0.0)
	_after_change(tool_id)


## 纹样：整块挖掉。polys 为纸张坐标下的若干多边形
func cut_region(polys: Array, tool_id := "stamp") -> void:
	_push_history()
	var clip := _tex_poly(wedge)
	for poly in polys:
		if poly.size() >= 3:
			_fill(mask, _tex_poly(poly), clip, 0.0)
	_after_change(tool_id)


## 后台分析得出的掉落碎片：drop_la 为分析尺寸、alpha=255 处掉落。返回掉下来那块的图，用于动画
func drop_pieces(drop_la: Image, keep_la: Image) -> Image:
	var up := drop_la.duplicate() as Image
	up.resize(tex_w, tex_h, Image.INTERPOLATE_NEAREST)
	var keep_up := keep_la.duplicate() as Image
	keep_up.resize(tex_w, tex_h, Image.INTERPOLATE_NEAREST)
	var black := Image.create_empty(tex_w, tex_h, false, Image.FORMAT_L8)
	var piece := mask.duplicate() as Image
	piece.blit_rect_mask(black, keep_up, Rect2i(0, 0, tex_w, tex_h), Vector2i.ZERO)
	mask.blit_rect_mask(black, up, Rect2i(0, 0, tex_w, tex_h), Vector2i.ZERO)
	_mirror_strips()
	texture.update(mask)
	return piece


## 载入保存过的剪纸图
func set_mask(img: Image) -> void:
	var m := img.duplicate() as Image
	if m.is_compressed():
		m.decompress()
	m.convert(Image.FORMAT_L8)
	if m.get_width() != tex_w or m.get_height() != tex_h:
		m.resize(tex_w, tex_h, Image.INTERPOLATE_BILINEAR)
	mask = m
	_mirror_strips()
	texture.update(mask)


## 用分析尺寸的“保留”图（样稿目标）生成成品
func set_mask_from_keep(keep: PackedByteArray) -> void:
	var data := PackedByteArray()
	data.resize(a_w * a_h)
	for i in keep.size():
		if keep[i] == 1:
			data[i] = 255
	var img := Image.create_from_data(a_w, a_h, false, Image.FORMAT_L8, data)
	img.resize(tex_w, tex_h, Image.INTERPOLATE_BILINEAR)
	mask = img
	_mirror_strips()
	texture.update(mask)


func undo() -> bool:
	if _history.is_empty():
		return false
	mask = _history.pop_back()
	texture.update(mask)
	cut_count = maxi(0, cut_count - 1)
	epoch += 1
	return true


func reset() -> void:
	_push_history()
	_fill_blank()
	texture.update(mask)
	cut_count = 0
	tool_uses.clear()
	epoch += 1


func can_undo() -> bool:
	return not _history.is_empty()


func count_paper() -> int:
	var small := mask.duplicate() as Image
	small.resize(a_w, a_h, Image.INTERPOLATE_BILINEAR)
	var data := small.get_data()
	var c := 0
	for i in data.size():
		if data[i] > 240 and classmap[i] == 2:
			c += 1
	return c


func _after_change(tool_id: String) -> void:
	_mirror_strips()
	texture.update(mask)
	cut_count += 1
	tool_uses[tool_id] = tool_uses.get(tool_id, 0) + 1


func _push_history() -> void:
	_history.append(mask.duplicate() as Image)
	if _history.size() > HISTORY_LIMIT:
		_history.pop_front()


func _fill_blank() -> void:
	mask.fill(Color(0, 0, 0))
	var w := _tex_poly(wedge)
	_fill(mask, w, w, 1.0)
	_mirror_strips()


func _tex_poly(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(poly.size())
	for i in poly.size():
		out[i] = to_tex(poly[i])
	return out


# ---------------------------------------------------------------- 扇区分类与镜像边带

func _build_classmap() -> void:
	var img := Image.create_empty(a_w, a_h, false, Image.FORMAT_L8)
	var s := px_per_unit * 0.5
	for g in cells:
		var poly := PackedVector2Array()
		for p in g * wedge:
			poly.append((p - tex_rect.position) * s)
		_fill(img, poly, poly, 1.0 / 255.0)
	var wp := PackedVector2Array()
	for p in wedge:
		wp.append((p - tex_rect.position) * s)
	_fill(img, wp, wp, 2.0 / 255.0)
	classmap = img.get_data()


## 沿扇区与相邻片共用的每条边，向外走几个像素，记下“外侧像素 ← 扇区内对应的镜像像素”
func _build_strips() -> void:
	var seen := {}
	var center := Vector2.ZERO
	for p in wedge:
		center += p
	center /= wedge.size()
	for n in neighbors:
		var cell := n * wedge
		var inv := n.affine_inverse()
		for i in wedge.size():
			var a := wedge[i]
			var b := wedge[(i + 1) % wedge.size()]
			if not (_has_vertex(cell, a) and _has_vertex(cell, b)):
				continue
			var edge := b - a
			var len_px := edge.length() * px_per_unit
			var out := Vector2(-edge.y, edge.x).normalized()
			if out.dot((a + b) * 0.5 - center) < 0.0:
				out = -out
			var steps := int(len_px * 2.0) + 1
			for k in steps + 1:
				var base := a + edge * (float(k) / steps)
				for o in [0.4, 1.2, 2.0, 2.8, 3.6]:
					var x: Vector2 = base + out * (o / px_per_unit)
					var q := to_tex(x)
					var qx := int(floor(q.x))
					var qy := int(floor(q.y))
					if qx < 0 or qy < 0 or qx >= tex_w or qy >= tex_h:
						continue
					var di := qy * tex_w + qx
					if seen.has(di):
						continue
					seen[di] = true
					var pc := from_tex(Vector2(qx + 0.5, qy + 0.5))
					if Geometry2D.is_point_in_polygon(pc, wedge):
						continue   # 像素中心在扇区内：它本身就是纸，不要覆盖
					# 取镜像位置所在的像素；那个像素的中心必须在扇区内，否则往里挪一点
					var sp := inv * pc
					var src := to_tex(sp)
					for _t in 4:
						var sc := from_tex(Vector2(floor(src.x) + 0.5, floor(src.y) + 0.5))
						if Geometry2D.is_point_in_polygon(sc, wedge):
							break
						sp += (center - sp).normalized() * (0.7 / px_per_unit)
						src = to_tex(sp)
					var sx := clampi(int(floor(src.x)), 0, tex_w - 1)
					var sy := clampi(int(floor(src.y)), 0, tex_h - 1)
					_strip_dst.append(di)
					_strip_src.append(sy * tex_w + sx)


static func _has_vertex(poly: PackedVector2Array, v: Vector2) -> bool:
	for p in poly:
		if p.distance_to(v) < 0.5:
			return true
	return false


func _mirror_strips() -> void:
	if _strip_dst.is_empty():
		return
	var data := mask.get_data()
	for i in _strip_dst.size():
		data[_strip_dst[i]] = data[_strip_src[i]]
	mask.set_data(tex_w, tex_h, false, Image.FORMAT_L8, data)


# ---------------------------------------------------------------- 扫描线填充

## 在 img 上填充多边形 poly（像素坐标，奇偶规则），只填在凸多边形 clip 内
static func _fill(img: Image, poly: PackedVector2Array, clip: PackedVector2Array, value: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var keys := PackedFloat64Array()
	var np := poly.size()
	for i in np:
		var a := poly[i]
		var b := poly[(i + 1) % np]
		if a.y == b.y:
			continue
		var ylo := minf(a.y, b.y)
		var yhi := maxf(a.y, b.y)
		var ra := maxi(0, int(ceil(ylo - 0.5)))
		var rb := mini(h - 1, int(ceil(yhi - 0.5)) - 1)
		if rb < ra:
			continue
		var inv := (b.x - a.x) / (b.y - a.y)
		for y in range(ra, rb + 1):
			var yc := y + 0.5
			var x := clampf(a.x + (yc - a.y) * inv, -2000.0, 4000.0)
			keys.append(y * 8192.0 + x + 2048.0)
	if keys.size() < 2:
		return
	keys.sort()
	var col := Color(value, value, value)
	var count := keys.size()
	var i := 0
	while i < count:
		var row := int(keys[i] / 8192.0)
		var j := i
		while j < count and int(keys[j] / 8192.0) == row:
			j += 1
		var span := _clip_span(clip, row + 0.5)
		if span.x <= span.y:
			var base := row * 8192.0 + 2048.0
			var k := i
			while k + 1 < j:
				var l := maxf(keys[k] - base, span.x)
				var r := minf(keys[k + 1] - base, span.y)
				if r > l:
					var xa := clampi(int(ceil(l - 0.5)), 0, w)
					var xb := clampi(int(ceil(r - 0.5)), 0, w)
					if xb > xa:
						img.fill_rect(Rect2i(xa, row, xb - xa, 1), col)
				k += 2
		i = j


static func _clip_span(clip: PackedVector2Array, yc: float) -> Vector2:
	var l := INF
	var r := -INF
	var nc := clip.size()
	for i in nc:
		var a := clip[i]
		var b := clip[(i + 1) % nc]
		if (a.y <= yc and b.y >= yc) or (b.y <= yc and a.y >= yc):
			if absf(b.y - a.y) < 1e-6:
				l = minf(l, minf(a.x, b.x))
				r = maxf(r, maxf(a.x, b.x))
			else:
				var x := a.x + (yc - a.y) * (b.x - a.x) / (b.y - a.y)
				l = minf(l, x)
				r = maxf(r, x)
	return Vector2(l, r)
