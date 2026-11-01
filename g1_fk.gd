extends RefCounted
# Forward kinematics for the MotionBricks G1 skeleton.
# Same maths as the reference demo: every joint sits at (neutral[joint] - neutral[parent]) from its
# parent, rotated by the parent's accumulated rotation; the root joint is placed at the root translation.

static func make_offsets(neutral: PackedVector3Array, parents: PackedInt32Array) -> PackedVector3Array:
	var offsets := PackedVector3Array()
	offsets.resize(neutral.size())
	for j in neutral.size():
		if parents[j] < 0:
			offsets[j] = Vector3.ZERO
		else:
			offsets[j] = neutral[j] - neutral[parents[j]]
	return offsets


# rotations: frames * joints * 4 floats, local quaternions as x, y, z, w.
# adds:   joint index -> Quaternion multiplied onto that joint's local rotation (extra bend).
# blends: joint index -> [Quaternion target, weight] the local rotation is slerped towards (after adds).
static func pose(root: Vector3, rotations: PackedFloat32Array, frame: int, parents: PackedInt32Array, offsets: PackedVector3Array, adds: Dictionary = {}, blends: Dictionary = {}) -> PackedVector3Array:
	var n := parents.size()
	var positions := PackedVector3Array()
	positions.resize(n)
	var world: Array[Quaternion] = []
	world.resize(n)
	for j in n:
		var b := (frame * n + j) * 4
		var q := Quaternion(rotations[b], rotations[b + 1], rotations[b + 2], rotations[b + 3])
		if adds.has(j):
			q = q * (adds[j] as Quaternion)
		if blends.has(j):
			var blend: Array = blends[j]
			q = q.slerp(blend[0] as Quaternion, float(blend[1]))
		var p := parents[j]
		if p < 0:
			positions[j] = root
			world[j] = q
		else:
			positions[j] = positions[p] + world[p] * offsets[j]
			world[j] = world[p] * q
	return positions
