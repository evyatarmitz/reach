extends Node

# (No class_name — main.gd preloads this script, so it works even when the project's
# global class cache is stale, e.g. after adding the file in a headless build.)

# In-game self-update for the exported Windows build. Adapted from the spell-book entry
# `windows-self-update` (Rust): Windows won't let you overwrite a RUNNING exe, so we
# download the new build, write a tiny .bat that waits for THIS process to exit, then
# swaps the file, relaunches, and deletes itself. Here we fetch the latest GitHub
# release, download its win64 zip, extract Reach.exe, and run that same swap.
#
# No-ops (reports "not applicable") outside a real Windows build — e.g. in the editor —
# so it can't touch the editor binary or run on other platforms.

signal check_done(available: bool, latest: String, note: String)
signal apply_started()
signal apply_failed(msg: String)

const REPO := "evyatarmitz/reach"
# The installed build's version — keep in sync with the release tag (without the "v").
const CURRENT := "0.3.0-alpha"
const API_LATEST := "https://api.github.com/repos/%s/releases/latest" % REPO
const UA := "reach-updater"

var _http: HTTPRequest
var _mode := ""          # "check" | "download"
var _zip_url := ""       # asset URL of the latest build's zip
var _latest := ""        # latest release tag (without "v")
var _zip_path := ""      # temp path the zip streams to


func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


# Self-update only makes sense for the packaged Windows game, never the editor.
func supported() -> bool:
	return OS.get_name() == "Windows" and not OS.has_feature("editor")


func check_for_update() -> void:
	if not supported():
		check_done.emit(false, CURRENT, "updates apply to the installed Windows build only")
		return
	_mode = "check"
	_http.download_file = ""   # response comes back in-memory (JSON)
	var headers := ["User-Agent: " + UA, "Accept: application/vnd.github+json"]
	if _http.request(API_LATEST, headers) != OK:
		check_done.emit(false, CURRENT, "couldn't reach GitHub")


func apply_update() -> void:
	if _zip_url == "":
		apply_failed.emit("no update to apply — check first")
		return
	apply_started.emit()
	_mode = "download"
	_zip_path = OS.get_executable_path().get_base_dir().path_join("_reach_update.zip")
	_http.download_file = _zip_path   # stream the (large) zip straight to disk
	if _http.request(_zip_url, ["User-Agent: " + UA]) != OK:
		apply_failed.emit("couldn't start the download")


func _on_request_completed(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		var msg := "network error (%d)" % result
		if _mode == "check":
			check_done.emit(false, CURRENT, msg)
		else:
			apply_failed.emit(msg)
		return
	if _mode == "check":
		_handle_check(code, body)
	elif _mode == "download":
		_handle_download(code)


func _handle_check(code: int, body: PackedByteArray) -> void:
	if code != 200:
		check_done.emit(false, CURRENT, "GitHub returned %d" % code)
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		check_done.emit(false, CURRENT, "unexpected response")
		return
	_latest = str(data.get("tag_name", "")).lstrip("v")
	_zip_url = ""
	for a in data.get("assets", []):
		var n := str(a.get("name", ""))
		if n.to_lower().ends_with(".zip") and n.to_lower().contains("win"):
			_zip_url = str(a.get("browser_download_url", ""))
			break
	var available := _latest != "" and _latest != CURRENT and _zip_url != ""
	if available:
		check_done.emit(true, _latest, "")
	elif _latest == CURRENT:
		check_done.emit(false, _latest, "you're on the latest version")
	else:
		check_done.emit(false, _latest, "no downloadable build found for the latest release")


func _handle_download(code: int) -> void:
	if code != 200:
		apply_failed.emit("download failed (HTTP %d)" % code)
		return
	var exe := OS.get_executable_path()
	# Extract the exe from the downloaded zip into <exe>.new next to the running binary.
	var reader := ZIPReader.new()
	if reader.open(_zip_path) != OK:
		apply_failed.emit("the downloaded archive was unreadable")
		return
	var exe_name := exe.get_file()   # "Reach.exe"
	var data := PackedByteArray()
	var found := false
	for entry in reader.get_files():
		if entry.get_file() == exe_name or entry.to_lower().ends_with(".exe"):
			data = reader.read_file(entry)
			found = true
			break
	reader.close()
	DirAccess.remove_absolute(_zip_path)
	if not found or data.is_empty():
		apply_failed.emit("no game executable inside the update")
		return
	var new_exe := exe + ".new"
	var f := FileAccess.open(new_exe, FileAccess.WRITE)
	if f == null:
		apply_failed.emit("couldn't write the new build (no permission here?)")
		return
	f.store_buffer(data)
	f.close()
	_swap_and_relaunch(exe, new_exe)


# Write the wait-swap-relaunch batch, launch it detached, and quit so it can proceed.
func _swap_and_relaunch(exe: String, new_exe: String) -> void:
	var pid := OS.get_process_id()
	var bat := exe.get_base_dir().path_join("_reach_update.bat")
	var w_exe := exe.replace("/", "\\")
	var w_new := new_exe.replace("/", "\\")
	var script := "@echo off\r\n"
	script += ":wait\r\n"
	script += "tasklist /fi \"PID eq %d\" 2>nul | find \"%d\" >nul\r\n" % [pid, pid]
	script += "if not errorlevel 1 ( timeout /t 1 /nobreak >nul & goto wait )\r\n"
	script += "move /y \"%s\" \"%s\" >nul\r\n" % [w_new, w_exe]
	script += "start \"\" \"%s\"\r\n" % w_exe
	script += "del /f \"%%~f0\"\r\n"
	var bf := FileAccess.open(bat, FileAccess.WRITE)
	if bf == null:
		apply_failed.emit("couldn't write the updater script")
		return
	bf.store_string(script)
	bf.close()
	# Launch minimized and detached; then exit so the running exe unlocks for the swap.
	OS.create_process("cmd", ["/c", "start", "", "/min", bat.replace("/", "\\")])
	get_tree().quit()
