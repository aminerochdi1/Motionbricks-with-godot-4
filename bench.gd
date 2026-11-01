extends Control
# Thread-count benchmark: loads the model once per setting and times 8 replans (advance 16 + plan).

const MbPaths := preload("res://mb_paths.gd")
var WEIGHTS := MbPaths.weights_dir()
const THREAD_COUNTS := [1, 2, 4, 6, 8, 0] # 0 = all cores
const REPLANS := 8

var lib_path := MbPaths.library_path()
var label: Label


func _ready() -> void:
	label = Label.new()
	label.position = Vector2(16, 12)
	label.add_theme_font_size_override("font_size", 18)
	add_child(label)
	_say("Benchmark running, please wait (about 1 minute)...\nCPU cores reported: %d\n" % OS.get_processor_count())
	await get_tree().process_frame
	await get_tree().process_frame

	var report := "CPU cores: %d\n" % OS.get_processor_count()
	var best_threads := -1
	var best_avg := INF
	for threads in THREAD_COUNTS:
		var line := _run(threads)
		report += line.text + "\n"
		_say(report + "\n(running...)")
		await get_tree().process_frame
		if line.avg > 0.0 and line.avg < best_avg:
			best_avg = line.avg
			best_threads = threads
	report += "\nFastest: threads=%d (avg %.0f ms). Budget per replan: 533 ms." % [best_threads, best_avg]
	_say(report)
	print(report)


func _run(threads: int) -> Dictionary:
	var mb := MotionBricksG1.new()
	var label_text := "all cores" if threads == 0 else "%d thread(s)" % threads
	if not mb.load_library(lib_path) or not mb.load_model(WEIGHTS + "/g1-f32", threads):
		return {"text": "threads=%s: FAILED %s" % [label_text, mb.get_last_error()], "avg": -1.0}
	for style in ["idle", "walk"]:
		mb.load_style(WEIGHTS + "/styles/" + style + ".mbstyle")
	mb.reset("idle")
	var forward := Vector3(0, 0, 1)
	var warmup := mb.plan("walk", forward, forward, -1.0, 1)
	if warmup.is_empty():
		return {"text": "threads=%s: FAILED %s" % [label_text, mb.get_last_error()], "avg": -1.0}
	var total := 0.0
	var worst := 0.0
	for i in REPLANS:
		mb.advance(16)
		var r := mb.plan("walk", forward, forward, -1.0, 2 + i)
		if r.is_empty():
			return {"text": "threads=%s: FAILED %s" % [label_text, mb.get_last_error()], "avg": -1.0}
		total += r["plan_ms"]
		worst = maxf(worst, r["plan_ms"])
	var avg := total / REPLANS
	return {"text": "threads=%-10s avg %4.0f ms   worst %4.0f ms   first %4.0f ms" % [label_text, avg, worst, warmup["plan_ms"]], "avg": avg}


func _say(t: String) -> void:
	label.text = t
