@tool
extends EditorPlugin

## Mesh Merge addon for Godot - merge selected meshes into a single mesh

var button: Button
var dialog: ConfirmationDialog
var normal_threshold_spinbox: SpinBox
var preserve_uvs_checkbox: CheckBox
var preserve_colors_checkbox: CheckBox
var merge_materials: CheckBox
var selected_meshes: Array[MeshInstance3D] = []

var threshold : float = 180.0
var preserve_uvs : bool = false
var preserve_colors : bool = false
var merge : bool = false


func _enter_tree():
	create_button()
	# Add button to the 3D editor top bar
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, button)
	
	# Listen for selection changes
	get_editor_interface().get_selection().selection_changed.connect(_update_button_visibility)
	
	# Create the dialog
	dialog = ConfirmationDialog.new()
	dialog.title = "Merge and smooth meshes"
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	dialog.min_size = Vector2i(350, 180)
	
	# Create options container
	var vbox = VBoxContainer.new()
	dialog.add_child(vbox)
	
	# Add normal threshold option
	var threshold_label = Label.new()
	threshold_label.text = "Normal Threshold (degrees, 0-180):"
	threshold_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(threshold_label)
	
	normal_threshold_spinbox = SpinBox.new()
	normal_threshold_spinbox.min_value = 0
	normal_threshold_spinbox.max_value = 180
	normal_threshold_spinbox.value = 180
	normal_threshold_spinbox.step = 1
	vbox.add_child(normal_threshold_spinbox)
	
	# Add a switch to decide if we discard the UVs
	preserve_uvs_checkbox = CheckBox.new()
	preserve_uvs_checkbox.text = "Preserve UV Seams"
	preserve_uvs_checkbox.button_pressed = false
	vbox.add_child(preserve_uvs_checkbox)
	
	# Similar for colours
	preserve_colors_checkbox = CheckBox.new()
	preserve_colors_checkbox.text = "Preserve Colour Seams"
	preserve_colors_checkbox.button_pressed = false
	vbox.add_child(preserve_colors_checkbox)
	
	# Option to merge materials
	merge_materials = CheckBox.new()
	merge_materials.text = "Merge all surface materials"
	merge_materials.button_pressed = false
	vbox.add_child(merge_materials)
	
	# Add some margin
	vbox.offset_left = 10
	vbox.offset_top = 10
	vbox.offset_right = -10
	vbox.offset_bottom = -10
	
	# Connect signals
	dialog.confirmed.connect(_on_process_confirmed)
	
	# Add dialog to editor
	get_editor_interface().get_base_control().add_child(dialog)
	
	# Add menu button
	add_tool_menu_item("Process Selected Meshes", _on_menu_pressed)

func _exit_tree():
	# Clean up
	remove_tool_menu_item("Process Selected Meshes")
	remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, button)
	
	if button:
		button.queue_free()	
	
	if dialog:
		dialog.queue_free()
		

func create_button():
	button = Button.new()
	button.text = "Combine Meshes"
	button.pressed.connect(_on_menu_pressed)


func _update_button_visibility():
	var selection = get_editor_interface().get_selection().get_selected_nodes()
	var mesh_count := 0

	for node in selection:
		if node is MeshInstance3D:
			mesh_count += 1

	# Show button only if 2 or more MeshInstance3D are selected
	button.visible = mesh_count >= 1

func _on_menu_pressed():
	# Get selected nodes
	selected_meshes.clear()
	var selection = get_editor_interface().get_selection()
	var selected_nodes = selection.get_selected_nodes()
	
	# Filter for MeshInstance3D nodes
	for node in selected_nodes:
		if node is MeshInstance3D and node.mesh:
			selected_meshes.append(node)
	
	if selected_meshes.is_empty():
		# Show error if no meshes selected
		var error_dialog = AcceptDialog.new()
		error_dialog.dialog_text = "No MeshInstance3D nodes selected!"
		get_editor_interface().get_base_control().add_child(error_dialog)
		error_dialog.popup_centered()
		error_dialog.confirmed.connect(error_dialog.queue_free)
		return
	
	# Show the dialog
	dialog.popup_centered()

func _on_process_confirmed():
	# Extract values from the dialog
	threshold = normal_threshold_spinbox.value
	preserve_uvs = preserve_uvs_checkbox.button_pressed
	preserve_colors = preserve_colors_checkbox.button_pressed
	merge = merge_materials.button_pressed

	# Try and combine everything
	combine_meshes()	
	
	# Report back
	print("Processed %d meshes" % selected_meshes.size())

func combine_meshes() -> void:
	var combined = MeshInstance3D.new()
	var final_mesh = ArrayMesh.new()
	var surface_map : Dictionary[RID, SurfaceTool] = {}
	var material_map : Dictionary[RID, Material] = {}
	
	# --- Build combined mesh in world space ---
	for mi in selected_meshes:
		if mi is not MeshInstance3D:
			continue
		if mi == null or mi.mesh == null:
			continue
		
		var merge_rid : RID
		var count : int = 0
		
		var world_xform = mi.global_transform
		for s in range(mi.mesh.get_surface_count()):
			var mat : Material = mi.mesh.surface_get_material(s)
			var rid : RID = mat.get_rid()
			
			if count == 0:
				merge_rid = rid
				
			count += 1
			
			# If we are merging materials, just keep using the first one
			if merge:
				rid = merge_rid
			
			# Do we already have this material in our set?
			if surface_map.has(rid):
				var smooth_arrays = mi.mesh.surface_get_arrays(s)

				# Convert additional arrays to a temporary mesh
				var temp_mesh = ArrayMesh.new()
				temp_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, process_vertex_arrays(smooth_arrays))

				# Append it
				surface_map[rid].append_from(temp_mesh, 0, world_xform)
			else:				
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				st.set_material(mat)
				var smooth_arrays = mi.mesh.surface_get_arrays(s)
				st.create_from_arrays(process_vertex_arrays(smooth_arrays))
				surface_map[rid] = st
				material_map[rid] = mat

	# now we need to go through each unique material
	# and add its geometry to the final mesh
	var importer = ImporterMesh.new()
	for rid in surface_map:
		var st : SurfaceTool = surface_map[rid]
		var mat : Material = material_map[rid]
		var arrays = st.commit_to_arrays()
		print("Material: ", rid)
		print("final vertex count ", arrays[Mesh.ARRAY_VERTEX].size())
		print("triangles ", arrays[Mesh.ARRAY_INDEX].size() / 3.0)
		importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, mat)

	# Now generate the LODs
	var normal_merge_angle = 25    # degrees, tweak as neede
	var legacy = normal_merge_angle
	importer.generate_lods(normal_merge_angle, legacy, [])

	# Get the final mesh with LODs
	var lod_mesh : ArrayMesh = importer.get_mesh()

	# assign the mesh and add it to the tree
	combined.mesh = lod_mesh
	combined.lod_bias = 0.1   # <1 = more
	combined.global_transform = Transform3D.IDENTITY
	combined.name = "CombinedMesh"
	get_tree().edited_scene_root.add_child(combined,true)
	combined.owner = get_tree().edited_scene_root
	get_editor_interface().edit_node(combined)
	print("Meshes have been combined!")


# Helper function to create a unique key
func make_key(pos: Vector3, uv: Vector2, color: Color) -> String:
	var uv_str = "" #if uv == null else "_%f_%f" % [uv.x, uv.y]
	var color_str = "" #if color == null else "_%f_%f_%f_%f" % [color.r, color.g, color.b, color.a]
	return "%f_%f_%f%s%s" % [pos.x, pos.y, pos.z, uv_str, color_str]

func make_uv_color_key(uv: Vector2, color: Color) -> String:
	var uv_str = "" if uv == null else "_%f_%f" % [uv.x, uv.y]
	var color_str = "" if color == null else "_%f_%f_%f_%f" % [color.r, color.g, color.b, color.a]
	return uv_str + color_str


func process_vertex_arrays(arrays: Array) -> Array:
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var normals = arrays[Mesh.ARRAY_NORMAL]
	var uvs = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] else null
	var colors = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] else null
	var indices = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] else null
		
	# Build index array if it doesn't exist
	if indices == null:
		indices = PackedInt32Array()
		for i in range(vertices.size()):
			indices.append(i)
	
	var threshold_cos = cos(deg_to_rad(threshold))
	
	# First pass: group vertices by position
	var position_groups = {}
	for i in range(indices.size()):
		var idx = indices[i]
		var pos = vertices[idx]
		var pos_key = "%f_%f_%f" % [pos.x, pos.y, pos.z]
		
		if not position_groups.has(pos_key):
			position_groups[pos_key] = []
		
		position_groups[pos_key].append({
			"index": idx,
			"normal": normals[idx] if normals else Vector3.UP,
			"uv": uvs[idx] if uvs else Vector2.ZERO,
			"color": colors[idx] if colors else Color.WHITE
		})
	
	# Second pass: cluster vertices by normal similarity, UV, and color
	var vertex_map = {}
	var new_vertices = PackedVector3Array()
	var new_normals = PackedVector3Array()
	var new_uvs = PackedVector2Array() if uvs else null
	var new_colors = PackedColorArray() if colors else null
	var new_indices = PackedInt32Array()
	var old_to_new_index = {}
	
	# Process each position group
	for pos_key in position_groups:
		var group = position_groups[pos_key]
		var pos = vertices[group[0].index]
		
		# Cluster vertices at this position by UV/color and normal similarity
		var clusters = []
		
		for vert_data in group:
			var found_cluster = false
			
			# Get a uv to cluster verts with
			var uv : Vector2 = Vector2.ZERO
			if preserve_uvs and uvs:
				uv = vert_data.uv
				
			# Similar for colour
			var col : Color = Color.WHITE
			if preserve_colors and colors:
				col = vert_data.color

			# Form a key that will be unique for unique pairs of UV / Colour			
			var uv_color_key = make_uv_color_key(uv, col)
			
			# Try to find a compatible cluster
			for cluster in clusters:
				# Must match UV and color exactly
				if cluster.uv_color_key != uv_color_key:
					continue
				
				# Check if normal is similar enough to average
				var similar = true
				for existing_normal in cluster.normals:
					if existing_normal.dot(vert_data.normal) < threshold_cos:
						similar = false
						break
				
				if similar:
					cluster.normals.append(vert_data.normal)
					cluster.old_indices.append(vert_data.index)
					found_cluster = true
					break
			
			# Create new cluster if no compatible one found
			if not found_cluster:
				clusters.append({
					"position": pos,
					"normals": [vert_data.normal],
					"uv": vert_data.uv,
					"color": vert_data.color,
					"uv_color_key": uv_color_key,
					"old_indices": [vert_data.index]
				})
		
		# Create a new vertex for each cluster
		for cluster in clusters:
			var new_index = new_vertices.size()
			
			# Average the normals in this cluster
			var avg_normal = Vector3.ZERO
			for n in cluster.normals:
				avg_normal += n
			avg_normal = avg_normal.normalized()
			
			# Add to output arrays
			new_vertices.append(cluster.position)
			new_normals.append(avg_normal)
			if new_uvs != null:
				new_uvs.append(cluster.uv)
			if new_colors != null:
				new_colors.append(cluster.color)
			
			# Map old indices to new index
			for old_idx in cluster.old_indices:
				old_to_new_index[old_idx] = new_index
	
	# Rebuild indices using the mapping
	for i in range(indices.size()):
		var old_idx = indices[i]
		new_indices.append(old_to_new_index[old_idx])
	
	# Build output arrays
	var output_arrays = []
	output_arrays.resize(Mesh.ARRAY_MAX)
	output_arrays[Mesh.ARRAY_VERTEX] = new_vertices
	output_arrays[Mesh.ARRAY_NORMAL] = new_normals
	output_arrays[Mesh.ARRAY_TEX_UV] = new_uvs if preserve_uvs else null
	output_arrays[Mesh.ARRAY_COLOR] = new_colors if preserve_colors else null
	output_arrays[Mesh.ARRAY_INDEX] = new_indices
	
	return output_arrays


func process_vertex_arrays_old(arrays: Array) -> Array:
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var normals = arrays[Mesh.ARRAY_NORMAL]
	#var uvs = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] else null
	#var colors = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] else null
	var indices = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] else null
	
	# Build index array if it doesn't exist
	if indices == null:
		indices = PackedInt32Array()
		for i in range(vertices.size()):
			indices.append(i)
	
	print("Input Surface: ")
	print("vertex count ", vertices.size())
	print("triangles ", indices.size() / 3.0)
	
	# Dictionary to store unique vertex data
	# Key: String hash of (position, uv, color)
	# Value: {position, normals_list, uv, color, new_index}
	var vertex_map = {}
	var new_vertices = PackedVector3Array()
	var new_normals = PackedVector3Array()
	#var new_uvs = PackedVector2Array() if uvs else null
	#var new_colors = PackedColorArray() if colors else null
	var new_indices = PackedInt32Array()
	
	# Process each vertex
	for i in range(indices.size()):
		var idx = indices[i]
		var pos = vertices[idx]
		var normal = normals[idx] if normals else Vector3.UP
		#var uv = uvs[idx] if uvs else Vector2.ZERO
		#var color = colors[idx] if colors else Color.WHITE
				
		var key = make_key(pos, Vector2.ZERO, Color.WHITE)
		
		if vertex_map.has(key):
			# Vertex exists - add normal to the list for averaging
			vertex_map[key].normals_list.append(normal)
			new_indices.append(vertex_map[key].new_index)
		else:
			# New unique vertex
			var new_index = new_vertices.size()
			vertex_map[key] = {
				"position": pos,
				"normals_list": [normal],
				#"uv": uv,
				#"color": color,
				"new_index": new_index
			}
			new_vertices.append(pos)
			#if new_uvs != null:
				#new_uvs.append(uv)
			#if new_colors != null:
				#new_colors.append(color)
			new_indices.append(new_index)
			
	# Average normals for each unique vertex
	for key in vertex_map:
		var data = vertex_map[key]
		var avg_normal = Vector3.ZERO
		for n in data.normals_list:
			avg_normal += n
		avg_normal = avg_normal.normalized()
		new_normals.append(avg_normal)
	
	# Build output arrays
	var output_arrays = []
	output_arrays.resize(Mesh.ARRAY_MAX)
	output_arrays[Mesh.ARRAY_VERTEX] = new_vertices
	output_arrays[Mesh.ARRAY_NORMAL] = new_normals
	output_arrays[Mesh.ARRAY_TEX_UV] = null
	output_arrays[Mesh.ARRAY_COLOR] = null
	output_arrays[Mesh.ARRAY_INDEX] = new_indices
	
	return output_arrays
