/*
 * Snapshot.vala
 *
 * Copyright 2012-2018 Tony George <teejeetech@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301, USA.
 *
 *
 */


using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;
using Json;

public class Snapshot : GLib.Object{
	
	public string path = "";
	public string name = "";
	public DateTime date;
	public string sys_uuid = "";
	public string sys_distro = "";
	public string app_version = "";
	public string description = "";
	public int64 file_count = 0;
	public Tags tags;
	public Gee.ArrayList<string> exclude_list;
	public Gee.HashMap<string,Subvolume> subvolumes;
	public Gee.ArrayList<FsTabEntry> fstab_list;
	public Gee.ArrayList<CryptTabEntry> cryttab_list;
	public bool valid = true;
	public bool live = false;

	// comment written by the package manager hook; if the user changed the
	// comment, the snapshot is kept like other snapshots with comments
	public string package_comment = "";
	public bool marked_for_deletion = false;
	public LinuxDistro distro;
	public SnapshotRepo repo;
	
	//btrfs
	public bool btrfs_mode = false;
	public Gee.HashMap<string,string> paths; // for btrfs snapshots only
	public string mount_path_root = "";
	public string mount_path_home = "";
	
	public DeleteFileTask delete_file_task;

	public Snapshot(string dir_path, bool btrfs_snapshot, SnapshotRepo _repo){

		try{
			var f = File.new_for_path(dir_path);
			var info = f.query_info("*", FileQueryInfoFlags.NONE);

			path = dir_path;
			name = info.get_name();
			description = "";
			btrfs_mode = btrfs_snapshot;
			repo = _repo;
			
			date = new DateTime.from_unix_utc(0);
			tags = 0;
			exclude_list = new Gee.ArrayList<string>();
			fstab_list = new Gee.ArrayList<FsTabEntry>();
			delete_file_task = new DeleteFileTask();
			subvolumes = new Gee.HashMap<string,Subvolume>();
			paths = new Gee.HashMap<string,string>();
			
			read_control_file();
			read_exclude_list();
			read_fstab_file();
			read_crypttab_file();
		}
		catch(Error e){
			log_error (e.message);
		}
	}

	// properties
	
	public string date_formatted{
		owned get{
			return date.format(App.date_format);//.format("%Y-%m-%d %H:%M:%S");
		}
	}

	public string rsync_log_file{
		owned get {
			return path_combine(path, "rsync-log");
		}	
	}

	public string rsync_changes_log_file{
		owned get {
			return path_combine(path, "rsync-log-changes");
		}	
	}

	public string rsync_restore_log_file{
		owned get {
			return path_combine(path, "rsync-log-restore");
		}	
	}

	public string rsync_restore_changes_log_file{
		owned get {
			return path_combine(path, "rsync-log-restore-changes");
		}	
	}
	
	public string exclude_file_for_backup {
		owned get {
			return path_combine(path, "exclude.list");
		}	
	}

	public string exclude_file_for_restore {
		owned get {
			return path_combine(path, "exclude-restore.list");
		}	
	}
	
	// manage tags
	
	// tags written by a newer version, e.g. "quarterly": they are kept and
	// written back, so that the snapshot is not removed as untagged and the
	// newer version still finds them
	public string unknown_tags = "";

	// info.json doesn't protect the tags against older versions yet, see SnapshotTags
	public bool needs_tags_update = false;

	public string taglist{
		owned get{
			return SnapshotTags.to_list(this.tags, unknown_tags);
		}
		set{
			string unknown;
			this.tags = SnapshotTags.parse(value, out unknown);
			unknown_tags = unknown;
		}
	}

	/* if at_least_on_demand is true and no tags are set, set Tags.OnDemand */
	public void add_tag(Tags tag, bool at_least_on_demand = false){
		if (!(tag in this.tags) || at_least_on_demand){
			this.tags |= tag;
			if (at_least_on_demand && this.tags == 0){
				this.tags |= Tags.OnDemand;
			}
			update_control_file();
		}
	}

	public void remove_tag(Tags tag){
		if (tag in this.tags){
			this.tags ^= tag;
			update_control_file();
		}
	}

	// control files
	
	public void read_control_file(){
		
		//log_debug("read_control_file()");
		
		string ctl_file = path + "/info.json";

		var f = File.new_for_path(ctl_file);
		
		if (f.query_exists()) {
			
			var parser = new Json.Parser();
			
			try{
				parser.load_from_file(ctl_file);
			} catch (Error e) {
				log_error (e.message);
			}
			
			var node = parser.get_root();
			var config = node.get_object();

			if ((node == null)||(config == null)){
				valid = false;
				return;
			}

			string val = json_get_string(config,"created","");
			if (val.length > 0) {
				DateTime date_utc = new DateTime.from_unix_utc(int64.parse(val));
				date = date_utc.to_local();
			}

			sys_uuid = json_get_string(config,"sys-uuid","");
			sys_distro = json_get_string(config,"sys-distro","");
			taglist = SnapshotTags.read(config);
			needs_tags_update = SnapshotTags.needs_update(config);
			description = json_get_string(config,"comments","");
			app_version = json_get_string(config,"app-version","");
			file_count = (int64) json_get_uint64(config,"file_count",file_count);
			live = json_get_bool(config,"live",false);
			package_comment = config.get_string_member_with_default("package-comment", "") ?? "";
			string type = config.get_string_member_with_default("type", "rsync");

			//log_debug("repo.mount_path: %s".printf(repo.mount_path));

			if (type == "btrfs"){
				read_subvolumes(config);
			}

			string extension = (type == "btrfs") ? root_subvolume_name : "localhost";
			distro = LinuxDistro.get_dist_info(path_combine(path, extension));
			
			string delete_trigger_file = path + "/delete";
			if (file_exists(delete_trigger_file)){
				marked_for_deletion = true;
			}
		}
		else{
			valid = false;
		}
		
		//log_debug("read_control_file(): exit");
	}

	private void read_subvolumes(Json.Object config){

		/* The subvolumes of a snapshot are read from its own info.json, never
		 * from the current configuration, so that snapshots taken with another
		 * subvolume layout can still be listed, restored and deleted.
		 * 'subvolumes' lists name, id, sizes and device for each subvolume.
		 * 'mount-points' maps each subvolume to the path where it was mounted
		 * in the system (written since subvolumes other than / and /home are
		 * supported). */

		var names = new Gee.ArrayList<string>();
		var mount_points = new Gee.HashMap<string,string>();
		Json.Object? subvols = null;

		if (config.has_member("subvolumes")){
			subvols = config.get_object_member("subvolumes");
			foreach(string subvol_name in subvols.get_members()){
				names.add(subvol_name);
			}
		}

		if (config.has_member("mount-points")){
			var mps = config.get_object_member("mount-points");
			foreach(string subvol_name in mps.get_members()){
				mount_points[subvol_name] = mps.get_string_member(subvol_name);
				if (!names.contains(subvol_name)){
					names.add(subvol_name); // dropped by an older version
				}
			}
		}

		foreach(string subvol_name in names){

			if (!Main.is_valid_subvolume_name(subvol_name)){ continue; }

			paths[subvol_name] = path.replace(repo.mount_path, repo.get_mount_path(subvol_name));

			var subvol_path = path_combine(paths[subvol_name], subvol_name);

			if (!dir_exists(subvol_path)){ continue; }

			//log_debug("subvol_path: %s".printf(subvol_path));

			var subvolume = new Subvolume(subvol_name, subvol_path, "", repo);
			subvolumes.set(subvol_name, subvolume);

			if (mount_points.has_key(subvol_name)){
				subvolume.mount_point = mount_points[subvol_name];
			}
			else{
				subvolume.mount_point = guess_mount_point(subvol_name);
			}

			if ((subvols == null) || !subvols.has_member(subvol_name)){ continue; }

			int index = -1;

			foreach(Json.Node jnode in subvols.get_array_member(subvol_name).get_elements()) {

				string item = jnode.get_string();
				switch (++index){
					case 0:
						// name, same as the key
						break;
					case 1:
						subvolume.id = long.parse(item);
						break;
					case 2:
						subvolume.total_bytes = int64.parse(item);
						break;
					case 3:
						subvolume.unshared_bytes = int64.parse(item);
						break;
					case 4:
						subvolume.device_uuid = item.strip();
						break;
				}
			}
		}
	}

	private static string guess_mount_point(string subvol_name){

		// snapshots taken by older versions don't record mount points,
		// they only contain the subvolumes mounted at / and /home

		if ((subvol_name == "@") || (subvol_name == App.root_subvolume_name)){
			return "/";
		}
		else if ((subvol_name == "@home") || (subvol_name == App.home_subvolume_name)){
			return "/home";
		}

		return "";
	}

	// name of the subvolume that was mounted at /
	public string root_subvolume_name {
		owned get {
			var subvol = get_subvolume_by_mount_point("/");
			return (subvol != null) ? subvol.name : App.root_subvolume_name;
		}
	}

	public Subvolume? get_subvolume_by_mount_point(string mount_point){
		foreach(var subvol in subvolumes.values){
			if (subvol.mount_point == mount_point){
				return subvol;
			}
		}
		return null;
	}

	public void read_exclude_list(){
		
		string list_file = path + "/exclude.list";

		exclude_list.clear();

		var f = File.new_for_path(list_file);
		
		if (f.query_exists()) {
			
			foreach(string path in file_read(list_file).split("\n")){
				
				path = path.strip();
				
				if (!exclude_list.contains(path) && path.length > 0){
					exclude_list.add(path);
				}
			}
		}
		else{
			if (!btrfs_mode){
				valid = false;
			}
		}
	}

	public void read_fstab_file(){
		
		string fstab_path = path_combine(path, "/localhost/etc/fstab");
		
		if (btrfs_mode){
			fstab_path = path_combine(path_combine(path, root_subvolume_name), "etc/fstab");
		}
		
		fstab_list = FsTabEntry.read_file(fstab_path);
	}

	public void read_crypttab_file(){
		
		string crypttab_path = path_combine(path, "/localhost/etc/crypttab");
		
		if (btrfs_mode){
			crypttab_path = path_combine(path_combine(path, root_subvolume_name), "etc/crypttab");
		}
		
		cryttab_list = CryptTabEntry.read_file(crypttab_path);
	}

	public void update_control_file(){
		/* Updates tag and comments */
		
		try{
			string ctl_file = path + "/info.json";
			var f = File.new_for_path(ctl_file);

			if (f.query_exists()) {

				var parser = new Json.Parser();
				try{
					parser.load_from_file(ctl_file);
				} catch (Error e) {
					log_error (e.message);
				}
				var node = parser.get_root();
				var config = node.get_object();

				SnapshotTags.write(config, tags, unknown_tags);
				config.set_string_member("comments", description);
				config.set_string_member("live", live.to_string());

				if (btrfs_mode){
					write_subvolumes(config);
				}
				
				var json = new Json.Generator();
				json.pretty = true;
				json.indent = 2;
				node.set_object(config);
				json.set_root(node);
				// replaces the file atomically, never delete it first: a snapshot
				// without info.json is considered invalid and gets removed
				json.to_file(ctl_file);
			}
		} catch (Error e) {
			log_error (e.message);
		}
	}

	private void write_subvolumes(Json.Object config){

		// update the entries of the loaded subvolumes and keep the others,
		// e.g. a subvolume on a device that is currently not available

		Json.Object subvols = config.has_member("subvolumes") ?
			config.get_object_member("subvolumes") : new Json.Object();

		Json.Object mount_points = config.has_member("mount-points") ?
			config.get_object_member("mount-points") : new Json.Object();

		foreach(var subvol in subvolumes.values){
			Json.Array arr = new Json.Array();
			arr.add_string_element(subvol.name);
			arr.add_string_element(subvol.id.to_string());
			arr.add_string_element(subvol.total_bytes.to_string());
			arr.add_string_element(subvol.unshared_bytes.to_string());
			arr.add_string_element(subvol.device_uuid);
			subvols.set_array_member(subvol.name, arr);

			if (subvol.mount_point.length > 0){
				mount_points.set_string_member(subvol.name, subvol.mount_point);
			}
		}

		config.set_object_member("subvolumes", subvols);
		config.set_object_member("mount-points", mount_points);
	}

	/*
	 * Records which kernels the snapshot can boot, for restoring and for
	 * boot entries of snapshots: the running kernel, the kernel versions with
	 * modules in the snapshot (usr/lib/modules of the root subvolume) and
	 * whether /boot (kernels and initramfs) is part of the snapshot.
	 */
	public void write_boot_info(string kernel_running, bool boot_in_snapshot){

		var kernels = new Gee.ArrayList<string>();

		string root_path = path_combine(paths.has_key(root_subvolume_name) ? paths[root_subvolume_name] : path, root_subvolume_name);

		foreach(string modules_dir in new string[] { "usr/lib/modules", "lib/modules" }){
			string dir = path_combine(root_path, modules_dir);
			if (!dir_exists(dir)){ continue; }
			foreach(string name in dir_list_names(dir)){
				if (!kernels.contains(name)){
					kernels.add(name);
				}
			}
			break;
		}

		kernels.sort();

		try{
			string ctl_file = path + "/info.json";
			var parser = new Json.Parser();
			parser.load_from_file(ctl_file);
			var node = parser.get_root();
			var config = node.get_object();

			var arr = new Json.Array();
			foreach(string kernel in kernels){
				arr.add_string_element(kernel);
			}

			config.set_string_member("kernel-running", kernel_running);
			config.set_array_member("kernels", arr);
			config.set_string_member("boot-in-snapshot", boot_in_snapshot.to_string());

			var json = new Json.Generator();
			json.pretty = true;
			json.indent = 2;
			node.set_object(config);
			json.set_root(node);
			json.to_file(ctl_file);
		}
		catch (Error e){
			log_error(e.message);
		}
	}

	public void write_package_comment(string comment){

		package_comment = comment;

		try{
			string ctl_file = path + "/info.json";
			var parser = new Json.Parser();
			parser.load_from_file(ctl_file);
			var node = parser.get_root();
			var config = node.get_object();
			config.set_string_member("package-comment", comment);
			var json = new Json.Generator();
			json.pretty = true;
			json.indent = 2;
			node.set_object(config);
			json.set_root(node);
			json.to_file(ctl_file);
		}
		catch (Error e){
			log_error(e.message);
		}
	}

	// a snapshot before a package operation whose comment the user changed is
	// kept by the retention; a comment that was only cleared doesn't count
	public bool package_comment_edited {
		get {
			return (package_comment.length > 0) && (description.strip().length > 0) && (description != package_comment);
		}
	}

	// a comment that the user wrote or changed, not the one generated for a
	// package operation
	public bool has_user_comment {
		get {
			return (description.strip().length > 0) && ((package_comment.length == 0) || (description != package_comment));
		}
	}

	public void remove_control_file(){
		
		string ctl_file = path + "/info.json";
		file_delete(ctl_file);
	}
	
	public static Snapshot write_control_file(
		string snapshot_path, DateTime dt_created, string root_uuid, string distro_full_name, 
		Tags tags, string comments, int64 item_count, bool is_btrfs, bool is_live, SnapshotRepo repo, bool silent = false){
			
		var ctl_path = snapshot_path + "/info.json";
		var config = new Json.Object();

		config.set_string_member("created", dt_created.to_utc().to_unix().to_string());
		config.set_string_member("sys-uuid", root_uuid);
		config.set_string_member("sys-distro", distro_full_name);
		config.set_string_member("app-version", AppVersion);
		config.set_string_member("file_count", item_count.to_string());
		SnapshotTags.write(config, tags, "");
		config.set_string_member("comments", comments);
		config.set_string_member("live", is_live.to_string());
		config.set_string_member("type", (is_btrfs ? "btrfs" : "rsync"));

		var json = new Json.Generator();
		json.pretty = true;
		json.indent = 2;
		var node = new Json.Node(NodeType.OBJECT);
		node.set_object(config);
		json.set_root(node);

		try{
			// replaces an existing file atomically
			json.to_file(ctl_path);
		} catch (Error e) {
	        log_error (e.message);
	    }

		if (!silent){
			log_msg(_("Created control file") + ": %s".printf(ctl_path));
		}

	    return (new Snapshot(snapshot_path, is_btrfs, repo));
	}

	// check
	
	public bool has_subvolumes(){
		var entry = FsTabEntry.find_entry_by_mount_point(fstab_list, "/");
		return (entry != null) && (entry.subvolume_name().length > 0);
	}

	public Gee.ArrayList<Subvolume> subvolumes_sorted {
		owned get {
			var list = new Gee.ArrayList<Subvolume>();
			foreach(var subvol in subvolumes.values){
				list.add(subvol);
			}
			list.sort((a,b)=>{
				return strcmp(a.name, b.name);
			});
			return list;
		}
	}
	
	// actions

	public bool remove(bool wait){

		if (!dir_exists(path)){
			return true;
		}

		bool status = true;
		
		if (btrfs_mode){
			status = remove_btrfs();
		}
		else{
			status = remove_rsync(wait);
		}

		return status;
	}
	
	public bool remove_rsync(bool wait){

		log_msg(string.nfill(78, '-'));
		
		var message = _("Removing") + " '%s'...".printf(name);
		log_msg(message);
		
		delete_file_task.dest_path = "%s/".printf(path);
		delete_file_task.status_message = message;
		delete_file_task.prg_count_total = Main.first_snapshot_count;
		delete_file_task.execute();

		if (wait){
			
			while (delete_file_task.status == AppStatus.RUNNING){

				sleep(1000);
				gtk_do_events ();

				stdout.printf("%6.2f%% %s (%s %s)\r".printf(
					delete_file_task.progress * 100.0, _("complete"),
					delete_file_task.stat_time_remaining, _("remaining")));
				
				stdout.flush();
			}

			stdout.printf(string.nfill(80, ' ') + "\r");
			stdout.flush();

			message = "%s '%s'".printf(_("Removed"), name);	
			log_msg(message);
			log_msg(string.nfill(78, '-'));
		}

		return true;
	}

	public bool remove_btrfs(){

		log_msg(string.nfill(78, '-'));
		
		var message = _("Removing snapshot") + ": %s".printf(name);
		log_msg(message);
		
		// delete subvolumes
		
		foreach(var subvol in subvolumes.values){
			
			bool ok = subvol.remove();
			if (!ok) {
				log_error(_("Failed to remove snapshot") + ": %s".printf(name));
				log_msg(string.nfill(78, '-'));
				return false;
			}
		}

		// delete directories after **all** subvolumes have been deleted

		foreach(var subvol in subvolumes.values){
			
			bool ok = dir_delete(paths[subvol.name], true);
			if (!ok) {
				log_error(_("Failed to remove snapshot") + ": %s".printf(name));
				log_msg(string.nfill(78, '-'));
				return false;
			}
		}

		if (!dir_delete(path, true)){
			
			log_error(_("Failed to remove snapshot") + ": %s".printf(name));
			log_msg(string.nfill(78, '-'));
			return false;
		}

		log_msg(_("Removed snapshot") + ": %s".printf(name));
		log_msg(string.nfill(78, '-'));
		
		return true;
	}
	
	public void mark_for_deletion(){
		
		string delete_trigger_file = path + "/delete";
		
		if (!file_exists(delete_trigger_file)){
			file_write(delete_trigger_file, "");
			marked_for_deletion = true;
		} else {
			file_delete(delete_trigger_file);
			marked_for_deletion = false;
		}
	}

	public void parse_log_file(){
		/* Parses and archives rsync-log file, creates rsync-log-changes */
		var task = new RsyncTask();
		task.parse_log(rsync_log_file);
	}
}
