class_name AsobiDatagram
extends RefCounted

## The datagram plane's client state machine.
##
## [codeblock]
## off -> minting -> probing -> active -> degraded -> off
## [/codeblock]
##
## [b]The WebSocket carries everything in every state.[/b] There is no state in
## which correctness depends on this plane, which is what makes a web export's
## permanent exclusion an asymmetry rather than a wound, and what makes "the
## player's network blocks UDP" a shrug rather than a support ticket.
##
## The states:
## [codeblock]
## off       Nothing minted. The only terminal state, and a fine place to live.
## minting   asobi.datagram.open is in flight over the WebSocket.
## probing   Credentials in hand, hello sent, waiting for the challenge.
## active    Bound. Pose is arriving and transform fields come from it.
## degraded  Bound once, but no pose for 2s. Transforms go back to world.tick
##           and a fresh hello goes out.
## [/codeblock]
##
## [b]Why probing gives up.[/b] A client that retried forever would sit behind a
## firewall that will never pass UDP, burning a little battery on every retry and
## reporting nothing. Three attempts over three seconds is enough for a path that
## works and short enough that a path that does not is discovered while the
## player is still on the loading screen.
##
## [b]Why the keepalive is the client's job.[/b] With a NAT anywhere in the path
## a quiet client loses its mapping and the downlink is blackholed with no signal
## at all. Only a client-originated packet recreates it, so server heartbeats
## cannot fix this.

enum State { OFF, MINTING, PROBING, ACTIVE, DEGRADED }

## ADR 0012, decision 13. Seconds.
const PROBE_BACKOFF := [0.2, 0.4, 0.8]
const PROBE_GIVE_UP := 3.0
const KEEPALIVE := 10.0
const DEGRADE_AFTER := 2.0

var state: State = State.OFF
var conn_id: int = 0
var epoch: int = 0
## The transform manifest: an array of {name, scale}, in canonical order. The
## wire carries no field names, so this is what makes a pose readable at all.
var fields: Array = []

var _key := PackedByteArray()
var _cseq: int = 0
var _last_pose_at: float = 0.0
var _probe_started_at: float = 0.0
var _probe_attempt: int = 0
var _next_probe_at: float = -1.0
var _next_ping_at: float = -1.0

## Called with each datagram to put on the wire. Injected so the state machine is
## testable without a socket.
var send: Callable = func(_bytes: PackedByteArray) -> void: pass


## Marks the plane as being minted, so nothing starts a second one.
func begin_mint() -> void:
	state = State.MINTING


## Records the mint reply and moves to `probing`.
func on_mint(conn: int, kup: PackedByteArray, mint_epoch: int, manifest: Array, now: float) -> bool:
	if conn <= 0 or kup.is_empty():
		# A mint that does not parse is not worth probing against.
		stop()
		return false
	conn_id = conn
	_key = kup
	epoch = mint_epoch
	fields = manifest
	state = State.PROBING
	_probe_attempt = 0
	_probe_started_at = now
	_next_probe_at = now
	return true


## Returns to `off` and forgets every credential.
##
## Called on any WebSocket reconnect, and that is not caution: the credential is
## bound to a session, so carrying one across a reconnect means authenticating
## against a binding the server has already revoked.
func stop() -> void:
	state = State.OFF
	conn_id = 0
	epoch = 0
	_key = PackedByteArray()
	_next_probe_at = -1.0
	_next_ping_at = -1.0
	_probe_attempt = 0


## Whether transform fields should currently come from the datagram plane.
##
## The one question the rest of the SDK asks. False in every state but `active`,
## so world.tick's transform fields are applied unconditionally the moment the
## plane stops delivering - the whole fallback, in one predicate.
func pose_authoritative() -> bool:
	return state == State.ACTIVE


## Drives every timer. Call once per frame with monotonic seconds.
func update(now: float) -> void:
	match state:
		State.PROBING:
			_update_probing(now)
		State.ACTIVE, State.DEGRADED:
			_update_bound(now)
		_:
			pass


## Handles one datagram. Returns the decoded pose frame, or an empty dictionary
## for anything that is not one.
func on_datagram(bytes: PackedByteArray, now: float) -> Dictionary:
	var frame := AsobiDgram.decode(bytes)
	if frame.is_empty():
		return {}
	# A datagram naming someone else is a stale mapping or a stray packet, and
	# applying it would be applying another player's world.
	if int(frame["conn_id"]) != conn_id:
		return {}

	var opcode := int(frame["opcode"])
	if opcode == AsobiDgram.OP_HELLO_OK:
		_send_confirm(frame["body"])
		return {}
	if opcode == AsobiDgram.OP_PONG:
		return {}
	if opcode != AsobiDgram.OP_POSE:
		return {}

	# The first pose is what proves the binding completed: the server sends none
	# until the challenge is echoed.
	if state != State.ACTIVE:
		_next_ping_at = now + KEEPALIVE
	state = State.ACTIVE
	_last_pose_at = now

	var pose := AsobiDgram.decode_pose(frame["body"], fields.size())
	if pose.is_empty():
		return {}
	if int(pose["epoch"]) != epoch:
		# A frame from before an engine restart. Dropping it rather than applying
		# it is what the epoch is for.
		return {}
	return pose


## Sends a world.input over the plane. False when it is not active, and the
## caller then sends it over the WebSocket exactly as before - an input must
## never be lost because the plane was between states.
func send_input(payload: PackedByteArray) -> bool:
	if state != State.ACTIVE:
		return false
	_cseq += 1
	send.call(AsobiDgram.encode_uplink(AsobiDgram.OP_INPUT, conn_id, _cseq, payload, _key, 0))
	return true


func _update_probing(now: float) -> void:
	if now - _probe_started_at >= PROBE_GIVE_UP:
		# A path that has not worked in three seconds is a path that does not
		# pass UDP. Stopping is the honest answer and costs nothing.
		stop()
		return
	if _next_probe_at >= 0.0 and now >= _next_probe_at:
		_probe_attempt += 1
		_send_hello()
		var i: int = mini(_probe_attempt - 1, PROBE_BACKOFF.size() - 1)
		_next_probe_at = now + float(PROBE_BACKOFF[i])


func _update_bound(now: float) -> void:
	if state == State.ACTIVE and now - _last_pose_at >= DEGRADE_AFTER:
		# Nothing for two seconds. The path may have changed under a rewriting
		# middlebox, which the server cannot see and this client can only assert.
		state = State.DEGRADED
		_send_hello()
		_next_probe_at = now + float(PROBE_BACKOFF[0])
	elif state == State.DEGRADED and _next_probe_at >= 0.0 and now >= _next_probe_at:
		_send_hello()
		_next_probe_at = now + float(PROBE_BACKOFF[PROBE_BACKOFF.size() - 1])
	if _next_ping_at >= 0.0 and now >= _next_ping_at:
		_send_ping(now)


func _send_hello() -> void:
	_cseq += 1
	send.call(
		AsobiDgram.encode_uplink(
			AsobiDgram.OP_HELLO, conn_id, _cseq, PackedByteArray(), _key, AsobiDgram.MIN_HELLO
		)
	)


func _send_confirm(challenge: PackedByteArray) -> void:
	_cseq += 1
	send.call(
		AsobiDgram.encode_uplink(AsobiDgram.OP_HELLO_CONFIRM, conn_id, _cseq, challenge, _key, 0)
	)


func _send_ping(now: float) -> void:
	_cseq += 1
	var stamp := PackedByteArray()
	stamp.resize(8)
	send.call(AsobiDgram.encode_uplink(AsobiDgram.OP_PING, conn_id, _cseq, stamp, _key, 0))
	_next_ping_at = now + KEEPALIVE
