extends Node

# NOTE: deliberately NO `class_name` — main.gd is loaded headless via the `-s` script
# path (draw_smoke / border_flicker tests), where the global class-name cache isn't
# populated, so a `class_name` reference fails to resolve at parse time. main.gd
# preloads this script as a const instead (same pattern as updater.gd).

# Sound layer for Reach. From-scratch, zero asset files: every sound is SYNTHESISED
# procedurally into an AudioStreamWAV at startup. But each name also has a DROP-IN path —
# if res://assets/audio/<name>.ogg (or .wav) exists it is used instead of the synth, so
# real recorded sfx can replace any sound later with no code change.
#
# Headless-safe: under the dummy display/audio driver the whole thing disables itself
# (no synth, no players), so the headless test runs that instantiate main.tscn
# (draw_smoke, border_flicker) stay fast and silent.
#
# Bus tree (all three sub-buses feed the built-in Master bus):
#   - Master : the global trim; one slider scales everything, and mute cuts it here.
#   - Ambient: one looping drone (the "background" bed).
#   - Effects: gameplay sfx — the combat bed + construct/fleet/alert/colony cues.
#   - Menu   : UI feedback — select clicks, move orders, refused buzzes.
# Effects and Menu are split so map-event noise and interaction chatter tune separately.
#
# Players: _music (Ambient), _combat (one looping bed on Effects, swapped between a
# battle hum and a bombardment rumble via set_combat()), and a shared one-shot pool
# whose voice bus is picked per cue (Menu for UI cues, Effects for everything else).

const MIX := 32000                 # synth sample rate
const SFX_VOICES := 6              # one-shot pool size
const CFG_PATH := "user://audio.cfg"
# Cues that belong on the Menu bus; everything else plays on Effects.
const MENU_CUES := ["ui_click", "move_order", "refused"]

var _enabled := false
var _streams := {}                 # name -> AudioStream
var _music: AudioStreamPlayer
var _combat: AudioStreamPlayer
var _sfx: Array[AudioStreamPlayer] = []
var _sfx_next := 0
var _combat_kind := -1             # -1 none / 0 battle / 1 bombard (current combat bed)
var _master_vol := 0.9
var _ambient_vol := 0.6
var _effects_vol := 0.8
var _menu_vol := 0.7
var _muted := false
var _master_idx := 0               # built-in Master bus
var _ambient_idx := -1
var _effects_idx := -1
var _menu_idx := -1


func _ready() -> void:
	# No audio under the headless driver (tests, CI). Everything below is skipped and
	# every public call early-returns, so callers never need to null-check.
	if DisplayServer.get_name() == "headless":
		return
	_enabled = true
	_load_cfg()
	_ambient_idx = _ensure_bus("Ambient")
	_effects_idx = _ensure_bus("Effects")
	_menu_idx = _ensure_bus("Menu")
	_build_sounds()
	_music = AudioStreamPlayer.new()
	_music.bus = "Ambient"
	_music.stream = _streams.get("ambient")
	add_child(_music)
	_combat = AudioStreamPlayer.new()
	_combat.bus = "Effects"
	add_child(_combat)
	for i in SFX_VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "Effects"
		_sfx.append(p)
		add_child(p)
	_apply_volumes()


# --- public API ----------------------------------------------------------------

func start_ambient() -> void:
	if _enabled and _music != null and not _music.playing:
		_music.play()


# Play a one-shot cue by name on the next free voice (round-robin). The voice is routed
# to the Menu bus for UI cues, Effects for everything else, so the two tune separately.
func play(name: String) -> void:
	if not _enabled:
		return
	var s = _streams.get(name)
	if s == null:
		return
	# Prefer an idle voice; else steal the round-robin one so cues never queue.
	var voice := _sfx[_sfx_next]
	for p in _sfx:
		if not p.playing:
			voice = p
			break
	_sfx_next = (_sfx_next + 1) % _sfx.size()
	voice.bus = "Menu" if name in MENU_CUES else "Effects"
	voice.stream = s
	voice.play()


# Drive the combat bed from selection. kind: -1 none, 0 battle, 1 bombardment. Only acts
# on a CHANGE, so holding a selected fleet in battle doesn't restart the loop every frame.
func set_combat(kind: int) -> void:
	if not _enabled or kind == _combat_kind:
		return
	_combat_kind = kind
	if kind == -1:
		_combat.stop()
		return
	_combat.stream = _streams.get("bombard_loop" if kind == 1 else "battle_loop")
	_combat.play()


func set_master_volume(v: float) -> void:
	_master_vol = clampf(v, 0.0, 1.0)
	_apply_volumes(); _save_cfg()


func set_ambient_volume(v: float) -> void:
	_ambient_vol = clampf(v, 0.0, 1.0)
	_apply_volumes(); _save_cfg()


func set_effects_volume(v: float) -> void:
	_effects_vol = clampf(v, 0.0, 1.0)
	_apply_volumes(); _save_cfg()


func set_menu_volume(v: float) -> void:
	_menu_vol = clampf(v, 0.0, 1.0)
	_apply_volumes(); _save_cfg()


func set_muted(m: bool) -> void:
	_muted = m
	_apply_volumes(); _save_cfg()


func master_volume() -> float: return _master_vol
func ambient_volume() -> float: return _ambient_vol
func effects_volume() -> float: return _effects_vol
func menu_volume() -> float: return _menu_vol
func is_muted() -> bool: return _muted


# --- volume / buses --------------------------------------------------------------

# Master carries the mute (one cut silences everything); the three sub-buses hold their
# own level regardless, so unmuting restores the mix the player set.
func _apply_volumes() -> void:
	if not _enabled:
		return
	AudioServer.set_bus_volume_db(_master_idx, (-80.0 if _muted else _lin_db(_master_vol)))
	AudioServer.set_bus_volume_db(_ambient_idx, _lin_db(_ambient_vol))
	AudioServer.set_bus_volume_db(_effects_idx, _lin_db(_effects_vol))
	AudioServer.set_bus_volume_db(_menu_idx, _lin_db(_menu_vol))


func _lin_db(v: float) -> float:
	return -80.0 if v <= 0.001 else linear_to_db(v)


func _ensure_bus(bus_name: String) -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
	return idx


func _load_cfg() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) != OK:
		return
	# Migrate the old two-slider layout: music -> ambient, sfx -> effects (+ menu).
	var old_music = cf.get_value("audio", "music", _ambient_vol)
	var old_sfx = cf.get_value("audio", "sfx", _effects_vol)
	_master_vol = clampf(cf.get_value("audio", "master", _master_vol), 0.0, 1.0)
	_ambient_vol = clampf(cf.get_value("audio", "ambient", old_music), 0.0, 1.0)
	_effects_vol = clampf(cf.get_value("audio", "effects", old_sfx), 0.0, 1.0)
	_menu_vol = clampf(cf.get_value("audio", "menu", old_sfx), 0.0, 1.0)
	_muted = bool(cf.get_value("audio", "muted", _muted))


func _save_cfg() -> void:
	var cf := ConfigFile.new()
	cf.set_value("audio", "master", _master_vol)
	cf.set_value("audio", "ambient", _ambient_vol)
	cf.set_value("audio", "effects", _effects_vol)
	cf.set_value("audio", "menu", _menu_vol)
	cf.set_value("audio", "muted", _muted)
	cf.save(CFG_PATH)


# --- sound bank: drop-in file, else synth ----------------------------------------

func _build_sounds() -> void:
	for name in ["ambient", "construct", "fleet_build", "battle_loop", "bombard_loop",
			"alert", "colony_activate", "ui_click", "move_order", "refused"]:
		var f := _load_file(name)
		_streams[name] = f if f != null else _synth(name)


func _load_file(name: String) -> AudioStream:
	for ext in [".ogg", ".wav"]:
		var p := "res://assets/audio/%s%s" % [name, ext]
		if ResourceLoader.exists(p):
			var r = load(p)
			if r is AudioStream:
				return r
	return null


func _synth(name: String) -> AudioStreamWAV:
	match name:
		"ambient":          return _synth_ambient()
		"construct":        return _synth_construct()
		"fleet_build":      return _synth_fleet_build()
		"battle_loop":      return _synth_battle()
		"bombard_loop":     return _synth_bombard()
		"alert":            return _synth_alert()
		"colony_activate":  return _synth_colony()
		"ui_click":         return _synth_click()
		"move_order":       return _synth_move()
		"refused":          return _synth_refused()
	return _synth_click()


# --- synthesis primitives --------------------------------------------------------

func _buf(dur: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(dur * MIX))
	return b


# Add a (optionally gliding) tone into buf. wave 0=sine, 1=square. atk/rel are fractions
# of the tone's own length for a simple attack/release envelope.
func _tone(buf: PackedFloat32Array, f0: float, f1: float, amp: float, t0: float,
		dur: float, atk := 0.02, rel := 0.3, wave := 0) -> void:
	var start := int(t0 * MIX)
	var dn := int(dur * MIX)
	if dn <= 0:
		return
	for j in dn:
		var i := start + j
		if i < 0 or i >= buf.size():
			continue
		var fr := float(j) / float(dn)
		var freq: float = lerpf(f0, f1, fr)
		var ph := TAU * freq * (float(j) / MIX)
		var s := sin(ph) if wave == 0 else (1.0 if sin(ph) >= 0.0 else -1.0)
		buf[i] += s * amp * _adsr(fr, atk, rel)


func _noise(buf: PackedFloat32Array, amp: float, t0: float, dur: float,
		atk := 0.05, rel := 0.4, seed := 1) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var start := int(t0 * MIX)
	var dn := int(dur * MIX)
	for j in dn:
		var i := start + j
		if i < 0 or i >= buf.size():
			continue
		buf[i] += rng.randf_range(-1.0, 1.0) * amp * _adsr(float(j) / float(dn), atk, rel)


func _adsr(fr: float, atk: float, rel: float) -> float:
	if atk > 0.0 and fr < atk:
		return fr / atk
	if rel > 0.0 and fr > 1.0 - rel:
		return (1.0 - fr) / rel
	return 1.0


func _wav(buf: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var n := buf.size()
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(round(clampf(buf[i], -1.0, 1.0) * 32767.0)))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = MIX
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = n
	return w


# --- the sounds ------------------------------------------------------------------

# Low continuous space bed. Stacked low sines (no envelope → seamless loop) + a touch of
# air. Kept quiet; it's a bed, not a tune.
func _synth_ambient() -> AudioStreamWAV:
	var b := _buf(10.0)
	_tone(b, 55.0, 55.0, 0.13, 0.0, 10.0, 0.0, 0.0)
	_tone(b, 82.41, 82.41, 0.07, 0.0, 10.0, 0.0, 0.0)
	_tone(b, 110.0, 110.0, 0.05, 0.0, 10.0, 0.0, 0.0)
	_tone(b, 164.81, 164.81, 0.02, 0.0, 10.0, 0.0, 0.0)
	_noise(b, 0.015, 0.0, 10.0, 0.0, 0.0, 7)
	return _wav(b, true)


# A solid build "thunk": a pitch-dropping body + a gravel impact + a little clink.
func _synth_construct() -> AudioStreamWAV:
	var b := _buf(0.42)
	_tone(b, 160.0, 70.0, 0.5, 0.0, 0.26, 0.01, 0.6)
	_noise(b, 0.4, 0.0, 0.12, 0.004, 0.9, 11)
	_tone(b, 240.0, 240.0, 0.12, 0.02, 0.16, 0.02, 0.7, 1)
	return _wav(b)


# A bright ascending blip for a new ship/fleet.
func _synth_fleet_build() -> AudioStreamWAV:
	var b := _buf(0.38)
	_tone(b, 440.0, 880.0, 0.3, 0.0, 0.18, 0.01, 0.5)
	_tone(b, 660.0, 1320.0, 0.12, 0.0, 0.18, 0.01, 0.5)
	_tone(b, 1320.0, 1320.0, 0.1, 0.16, 0.2, 0.02, 0.85)
	return _wav(b)


# Battle bed (loop): low rumble + a tense mid + metallic clashes on a quick cadence.
func _synth_battle() -> AudioStreamWAV:
	var b := _buf(3.2)
	_tone(b, 70.0, 70.0, 0.12, 0.0, 3.2, 0.0, 0.0)
	_tone(b, 110.0, 110.0, 0.05, 0.0, 3.2, 0.0, 0.0, 1)
	var beats := 6
	for k in beats:
		var t := 3.2 * float(k) / float(beats)
		_noise(b, 0.22, t, 0.08, 0.02, 0.8, 100 + k)
		_tone(b, 900.0, 760.0, 0.07, t, 0.07, 0.01, 0.7, 1)
	return _wav(b, true)


# Bombard bed (loop): heavier and slower than battle — deep booms + crackle, no pings.
func _synth_bombard() -> AudioStreamWAV:
	var b := _buf(3.6)
	_tone(b, 60.0, 60.0, 0.1, 0.0, 3.6, 0.0, 0.0)
	_noise(b, 0.1, 0.0, 3.6, 0.0, 0.0, 23)
	for k in 4:
		var t := 0.9 * float(k)
		_tone(b, 52.0, 38.0, 0.42, t, 0.34, 0.01, 0.7)
		_noise(b, 0.18, t, 0.14, 0.01, 0.85, 200 + k)
	return _wav(b, true)


# Descending two-tone warning.
func _synth_alert() -> AudioStreamWAV:
	var b := _buf(0.46)
	_tone(b, 740.0, 740.0, 0.22, 0.0, 0.18, 0.01, 0.2, 1)
	_tone(b, 560.0, 560.0, 0.22, 0.22, 0.2, 0.01, 0.3, 1)
	return _wav(b)


# Rising major arpeggio bells — the "colony online" milestone.
func _synth_colony() -> AudioStreamWAV:
	var b := _buf(0.62)
	_tone(b, 523.25, 523.25, 0.24, 0.0, 0.3, 0.005, 0.9)
	_tone(b, 659.25, 659.25, 0.24, 0.12, 0.32, 0.005, 0.9)
	_tone(b, 783.99, 783.99, 0.24, 0.24, 0.34, 0.005, 0.9)
	_tone(b, 1046.5, 1046.5, 0.22, 0.36, 0.24, 0.005, 0.95)
	return _wav(b)


func _synth_click() -> AudioStreamWAV:
	var b := _buf(0.05)
	_tone(b, 800.0, 800.0, 0.12, 0.0, 0.045, 0.2, 0.6)
	return _wav(b)


func _synth_move() -> AudioStreamWAV:
	var b := _buf(0.11)
	_tone(b, 520.0, 640.0, 0.16, 0.0, 0.09, 0.05, 0.6)
	return _wav(b)


# Low buzz for a refused order.
func _synth_refused() -> AudioStreamWAV:
	var b := _buf(0.16)
	_tone(b, 150.0, 140.0, 0.17, 0.0, 0.13, 0.02, 0.3, 1)
	return _wav(b)
