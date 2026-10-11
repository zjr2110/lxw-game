extends RefCounted
## 连通分析与评分。全部在扇区内、分析尺寸（遮罩的一半）上计算。
##
## 缩小时用“四个像素都是纸才算纸”的规则，所以剪刀缝一定会把两边隔开；
## 太细的纸桥也会被当作断开——和真剪纸一样，太细就连不住。

const PAPER_THRESHOLD := 240


## 找出扇区内所有纸片（4 邻接）。可在后台线程调用：只读传入的拷贝
static func components(mask_copy: Image, a_w: int, a_h: int, classmap: PackedByteArray) -> Dictionary:
	mask_copy.resize(a_w, a_h, Image.INTERPOLATE_BILINEAR)
	var data := mask_copy.get_data()
	var total := a_w * a_h
	var paper := PackedByteArray()
	paper.resize(total)
	for i in total:
		if data[i] > PAPER_THRESHOLD and classmap[i] == 2:
			paper[i] = 1
	var labels := PackedInt32Array()
	labels.resize(total)
	labels.fill(-1)
	var sizes := PackedInt32Array()
	var queue := PackedInt32Array()
	queue.resize(total)
	for start in total:
		if paper[start] == 0 or labels[start] != -1:
			continue
		var lab := sizes.size()
		var head := 0
		var tail := 1
		queue[0] = start
		labels[start] = lab
		while head < tail:
			var idx := queue[head]
			head += 1
			var x := idx % a_w
			if x > 0 and paper[idx - 1] == 1 and labels[idx - 1] == -1:
				labels[idx - 1] = lab
				queue[tail] = idx - 1
				tail += 1
			if x < a_w - 1 and paper[idx + 1] == 1 and labels[idx + 1] == -1:
				labels[idx + 1] = lab
				queue[tail] = idx + 1
				tail += 1
			if idx >= a_w and paper[idx - a_w] == 1 and labels[idx - a_w] == -1:
				labels[idx - a_w] = lab
				queue[tail] = idx - a_w
				tail += 1
			if idx < total - a_w and paper[idx + a_w] == 1 and labels[idx + a_w] == -1:
				labels[idx + a_w] = lab
				queue[tail] = idx + a_w
				tail += 1
		sizes.append(tail)
	return {"labels": labels, "sizes": sizes, "paper": paper, "a_w": a_w, "a_h": a_h}


## 主体以外要掉落的纸片 → 两张 LA8 图：drop（alpha=255 处掉落）、keep（alpha=255 处不掉）
static func build_drop(comp: Dictionary, keep_label: int, classmap: PackedByteArray) -> Dictionary:
	var labels: PackedInt32Array = comp["labels"]
	var paper: PackedByteArray = comp["paper"]
	var a_w: int = comp["a_w"]
	var a_h: int = comp["a_h"]
	var total := a_w * a_h
	var drop := PackedByteArray()
	drop.resize(total)
	var any := false
	for i in total:
		if labels[i] >= 0 and labels[i] != keep_label:
			drop[i] = 1
			any = true
	if not any:
		return {"any": false}
	# 碎片边缘那一圈“半张纸”的像素也一起清掉，免得留下细线。
	# 也包括紧贴折线、中心落在扇区外的分析像素：它们不参与连通分析，
	# 不清掉的话，扇区里贴着折线会留下一条细纸条，展开后变成放射状的细线
	var grown := drop.duplicate()
	for i in total:
		if drop[i] == 0 and paper[i] == 0:
			var x := i % a_w
			if (x > 0 and drop[i - 1] == 1) or (x < a_w - 1 and drop[i + 1] == 1) \
					or (i >= a_w and drop[i - a_w] == 1) or (i < total - a_w and drop[i + a_w] == 1):
				grown[i] = 1
	var d := PackedByteArray()
	d.resize(total * 2)
	var k := PackedByteArray()
	k.resize(total * 2)
	k.fill(255)
	for i in total:
		if grown[i] == 1:
			d[i * 2 + 1] = 255
			k[i * 2 + 1] = 0
	return {
		"any": true,
		"drop": Image.create_from_data(a_w, a_h, false, Image.FORMAT_LA8, d),
		"keep": Image.create_from_data(a_w, a_h, false, Image.FORMAT_LA8, k),
	}


## 作品统计：面积、边缘长度、孔洞数（都换算成整张纸）
static func stats(mask: Image, a_w: int, a_h: int, classmap: PackedByteArray, layers: int) -> Dictionary:
	var small := mask.duplicate() as Image
	small.resize(a_w, a_h, Image.INTERPOLATE_BILINEAR)
	var data := small.get_data()
	var total := a_w * a_h
	var paper := PackedByteArray()
	paper.resize(total)
	var area := 0
	for i in total:
		if data[i] > PAPER_THRESHOLD and classmap[i] == 2:
			paper[i] = 1
			area += 1

	# 边缘：纸面像素旁边是空白（扇区内剪掉的地方，或纸外）。与其它层相接的折线不算边
	var perimeter := 0
	for i in total:
		if paper[i] == 0:
			continue
		var x := i % a_w
		var edge := false
		for j in [i - 1 if x > 0 else -1, i + 1 if x < a_w - 1 else -1, i - a_w, i + a_w]:
			if j < 0 or j >= total:
				edge = true
			elif paper[j] == 0 and classmap[j] != 1:
				edge = true
		if edge:
			perimeter += 1

	# 孔洞：扇区内的空白区域，不与纸外相连
	var holes := 0
	var seen := PackedByteArray()
	seen.resize(total)
	var queue := PackedInt32Array()
	queue.resize(total)
	for start in total:
		if seen[start] == 1 or classmap[start] != 2 or paper[start] == 1:
			continue
		var head := 0
		var tail := 1
		queue[0] = start
		seen[start] = 1
		var outside := false
		while head < tail:
			var idx := queue[head]
			head += 1
			var x := idx % a_w
			if classmap[idx] == 0 or x == 0 or x == a_w - 1 or idx < a_w or idx >= total - a_w:
				outside = true
			for j in [idx - 1 if x > 0 else -1, idx + 1 if x < a_w - 1 else -1, idx - a_w, idx + a_w]:
				if j < 0 or j >= total or seen[j] == 1:
					continue
				if classmap[j] == 1 or paper[j] == 1:
					continue
				seen[j] = 1
				queue[tail] = j
				tail += 1
		if not outside and tail >= 3:
			holes += 1
	return {"area": area * layers, "perimeter": perimeter * layers, "holes": holes * layers}


## 自由创作评分
static func score_free(st: Dictionary, initial_area: int, layers: int, paper: Dictionary, fold: Dictionary) -> Dictionary:
	var a0 := float(maxi(1, initial_area * layers))
	var cut_ratio := clampf(1.0 - float(st["area"]) / a0, 0.0, 1.0)
	var edge := float(st["perimeter"]) / sqrt(a0)      # 没剪过的方纸约为 4
	var holes: int = st["holes"]

	var ratio_score := clampf(1.0 - absf(cut_ratio - 0.45) / 0.4, 0.0, 1.0)
	var hole_score := clampf(log(1.0 + holes) / log(61.0), 0.0, 1.0)
	var edge_score := clampf((edge - 4.0) / 16.0, 0.0, 1.0)
	var quality := ratio_score * 0.4 + (hole_score * 0.5 + edge_score * 0.5) * 0.6
	if cut_ratio < 0.03:
		quality *= 0.2
	quality = clampf(quality, 0.0, 1.0)

	var stars := clampi(int(ceil(quality * 5.0)), 1, 5)
	var value := 30.0 * float(paper.get("value", 1.0)) * float(fold.get("value", 1.0)) \
			* (0.4 + 1.0 * quality + 3.0 * quality * quality)
	var comments := ["刀工尚显生涩", "中规中矩", "颇见巧思", "玲珑剔透", "巧夺天工"]
	return {
		"mode": "free",
		"quality": quality,
		"stars": stars,
		"comment": comments[stars - 1],
		"cut_ratio": cut_ratio,
		"holes": holes,
		"fineness": edge_score,
		"value": maxi(5, int(round(value))),
	}
