class_name AsobiEntities
extends RefCounted

## An entity registry that folds both carriers into one view.
##
## Optional. Bind [signal AsobiRealtime.world_tick] and keep your own state if
## that suits you - nothing here changes what that signal carries. This exists
## because the datagram plane needs somewhere for the two-carrier merge rule to
## live, and pushing that rule onto every game author would be handing out a
## subtle correctness problem and calling it an API.
##
## [b]Key everything on zone.[/b] A player is subscribed to an interest ring of
## several zones at once, each an independent server process, and messages are
## ordered per sender only. Crossing a boundary emits [code]op:"r"[/code] from
## the zone being left and [code]op:"a"[/code] from the zone being entered, from
## two different senders, so they can arrive in either order. Applied into one
## flat table the removal can land last and delete the entity for good. Recording
## which zone owns each id makes both orders converge.
##
## ## The merge rule
##
## Two carriers describe the same entity and they can disagree, so:
##
## - [code]op:"a"[/code] creates or replaces wholesale and always wins.
## - [code]op:"r"[/code] deletes and always wins.
## - [code]op:"u"[/code] applies non-transform fields unconditionally, because
##   [code]world.tick[/code] is their only carrier and it is reliable and
##   ordered. Transform fields apply only if the frame is not older than the last
##   pose applied to that entity.
## - a pose applies only if it is not older than the last pose, and can never
##   create or remove an entity - it carries a slot and a bitmask and has nowhere
##   to say otherwise.
##
## [b]A keyframe must not rewind the pose clock.[/b] Join and resync keyframes
## carry [code]tick: 0[/code], so setting the pose clock from every add would let
## a stale in-flight pose apply over fresher state for one interval on every
## subscribe. A keyframe therefore only ever moves it forward.

## An entity appeared, with its full state.
signal entity_added(id: String, state: Dictionary)

## An entity changed. [param changed] names only the fields that actually moved,
## so a listener can skip work rather than diffing.
signal entity_updated(id: String, state: Dictionary, changed: PackedStringArray)

## An entity went away.
signal entity_removed(id: String)

var _entities: Dictionary = {}
var _zone_of: Dictionary = {}
var _pose_tick: Dictionary = {}
## Names the manifest declares as transform-class, for the merge rule. Empty
## until the plane mints, and an empty set means world.tick owns everything -
## which is exactly right for a client that never opens the plane.
var _transform: Dictionary = {}


## Every entity currently known, id to state. The returned dictionary is the
## registry's own, so treat it as read-only.
func all() -> Dictionary:
	return _entities


## One entity's state, or an empty dictionary.
func get_entity(id: String) -> Dictionary:
	return _entities.get(id, {})


## Declares which field names are transform-class, from the mint manifest.
func set_transform_fields(names: PackedStringArray) -> void:
	_transform = {}
	for name in names:
		_transform[name] = true


## Folds one [code]world.tick[/code] payload in.
func apply_tick(payload: Dictionary) -> void:
	var zone_val: Variant = payload.get("zone")
	if not (zone_val is Array) or (zone_val as Array).size() < 2:
		# match.state, or a server predating the zone field. One namespace, which
		# is what match mode has always had.
		_apply_updates(payload, "@match", int(payload.get("tick", 0)), false)
		return
	var zone_arr: Array = zone_val
	var zkey := "%d:%d" % [int(zone_arr[0]), int(zone_arr[1])]
	var kf := bool(payload.get("kf", false))
	_apply_updates(payload, zkey, int(payload.get("tick", 0)), kf)
	if kf:
		_reconcile_keyframe(zkey, payload.get("updates", []))


## Folds one decoded pose frame in.
##
## [param slots] is the slot-to-id table for this zone, which the binary
## [code]world.tick[/code] wire already maintains. A slot with no binding is
## skipped: an add introduces every entity, so the frame that binds it is on its
## way and a pose has no business inventing one.
func apply_pose(pose: Dictionary, slots: Dictionary, fields: Array) -> void:
	var zone: Array = pose.get("zone", [])
	if zone.size() < 2:
		return
	var zkey := "%d:%d" % [int(zone[0]), int(zone[1])]
	var tick := int(pose.get("tick", 0))

	for record in pose.get("records", []):
		var slot: int = int(record["slot"])
		if not slots.has(slot):
			continue
		var id: String = str(slots[slot])
		if not _entities.has(id) or _zone_of.get(id, "") != zkey:
			continue
		if tick < int(_pose_tick.get(id, -1)):
			continue
		_pose_tick[id] = tick

		var state: Dictionary = _entities[id]
		var changed := PackedStringArray()
		var values: Array = record["values"]
		for i in fields.size():
			if i >= values.size() or values[i] == null:
				continue
			var field: Dictionary = fields[i]
			# The inverse of the server's quantisation. Two multiplies, which is
			# why the wire carries int16 and a scale rather than float32.
			var scaled: float = float(values[i]) / float(field["scale"])
			var name: String = str(field["name"])
			if state.get(name) != scaled:
				state[name] = scaled
				changed.append(name)
		if not changed.is_empty():
			entity_updated.emit(id, state, changed)


## Forgets everything. For a reconnect, where every binding is stale.
func reset() -> void:
	_entities.clear()
	_zone_of.clear()
	_pose_tick.clear()


func _apply_updates(payload: Dictionary, zkey: String, tick: int, kf: bool) -> void:
	for update in payload.get("updates", []):
		if not (update is Dictionary):
			continue
		var u: Dictionary = update
		var id_val: Variant = u.get("id")
		if id_val == null:
			continue
		var id := str(id_val)
		var op := str(u.get("op", "u"))

		# A remove or update from a zone that no longer owns this id is stale:
		# the entity has crossed and another zone has claimed it, so honouring
		# the old zone's word would undo the crossing. Adds always win.
		if op != "a" and _zone_of.has(id) and _zone_of[id] != zkey:
			continue

		match op:
			"a":
				_add(id, u, zkey, tick, kf)
			"u":
				_update(id, u, zkey, tick)
			"r":
				_remove(id)


func _add(id: String, u: Dictionary, zkey: String, tick: int, kf: bool) -> void:
	var state := {}
	for k in u:
		if k != "op" and k != "id" and k != "gen":
			state[k] = u[k]
	_entities[id] = state
	_zone_of[id] = zkey
	# Only ever forward. A keyframe carries tick 0, so taking it verbatim would
	# let a stale in-flight pose apply over fresher state on every subscribe.
	if kf:
		_pose_tick[id] = maxi(int(_pose_tick.get(id, 0)), tick)
	else:
		_pose_tick[id] = tick
	entity_added.emit(id, state)


func _update(id: String, u: Dictionary, zkey: String, tick: int) -> void:
	if not _entities.has(id):
		# An update for something never added. The add is either lost or still on
		# its way; either way the resync that a frame_seq gap triggers is what
		# repairs it, and inventing an entity here would invent one that never
		# gets removed.
		return
	_zone_of[id] = zkey
	var state: Dictionary = _entities[id]
	var changed := PackedStringArray()
	var pose_at := int(_pose_tick.get(id, -1))

	for k in u:
		if k == "op" or k == "id" or k == "gen":
			continue
		# Transform fields lose to a fresher pose; everything else applies
		# unconditionally, because world.tick is its only carrier.
		if _transform.has(k) and tick < pose_at:
			continue
		if state.get(k) != u[k]:
			state[k] = u[k]
			changed.append(k)

	if not changed.is_empty():
		entity_updated.emit(id, state, changed)


func _remove(id: String) -> void:
	if not _entities.has(id):
		return
	_entities.erase(id)
	_zone_of.erase(id)
	_pose_tick.erase(id)
	entity_removed.emit(id)


## A keyframe lists every entity its zone holds, so anything still attributed to
## that zone and absent from the frame went away while we were not listening.
func _reconcile_keyframe(zkey: String, updates: Array) -> void:
	var present := {}
	for update in updates:
		if update is Dictionary and update.get("id") != null:
			present[str(update["id"])] = true
	var stale: Array = []
	for id in _zone_of:
		if _zone_of[id] == zkey and not present.has(id):
			stale.append(id)
	for id in stale:
		_remove(id)
