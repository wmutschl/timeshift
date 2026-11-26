/*
 * Replication.vala
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
using TeeJee.Misc;

/*
 * Replication: copies of BTRFS snapshots on another BTRFS filesystem, on a
 * local disk or on another computer (SSH), made with btrfs send/receive.
 *
 * Layout on the target:
 *   <path>/<hostname>/snapshots/<snapshot>/<subvolume>   (read-only, received)
 *   <path>/<hostname>/snapshots/<snapshot>/info.json     (copy of the snapshot's info.json)
 *   <path>/<hostname>/snapshots/<snapshot>/replica.json  (written last: the copy is complete)
 *
 * btrfs send needs read-only subvolumes, but Timeshift snapshots are
 * writable. Each snapshot is sent from a read-only snapshot of it that is
 * kept in <snapshot device>/timeshift-btrfs/send-cache/<target-id>/ for
 * the newest copy on the target, so that the next snapshot can be sent
 * incrementally (only the differences) even after the snapshot itself was
 * removed from the snapshot device.
 */

// a place where copies of the snapshots are stored ------------------------

public class ReplicationTarget : GLib.Object {

	public string id = "";
	public string name = "";
	public bool enabled = true;          // included in automatic runs
	public string kind = "local";        // "local" or "ssh"

	public string device_uuid = "";      // local: UUID of the BTRFS filesystem
	public string host = "";             // ssh
	public int port = 22;
	public string user = "root";
	public string identity_file = "";    // ssh private key, default: Timeshift's key
	public bool use_sudo = false;        // ssh: run btrfs with sudo on the remote host

	// local: directory relative to the top level of the filesystem
	// ssh: absolute directory on a BTRFS filesystem of the remote host
	public string path = "timeshift-replicas";

	public ReplicationPolicy policy = new ReplicationPolicy();

	public const string SSH_KEY = "/etc/timeshift/ssh/id_ed25519";
	public const string SSH_KNOWN_HOSTS = "/etc/timeshift/ssh/known_hosts";

	public ReplicationTarget(){
		id = "%08x".printf(Random.next_int());
	}

	public bool is_ssh {
		get { return kind == "ssh"; }
	}

	public string location {
		owned get {
			if (is_ssh){
				return "%s@%s:%s".printf(user, host, path);
			}
			var dev = Device.get_device_by_uuid(device_uuid);
			string dev_name = (dev != null) ? dev.device : "UUID=%s".printf(device_uuid);
			return "%s:%s".printf(dev_name, path);
		}
	}

	public string ssh_identity {
		owned get {
			return (identity_file.length > 0) ? identity_file : SSH_KEY;
		}
	}

	// returns an error message if the settings are not valid
	public string validate(){

		if (name.strip().length == 0){
			return _("Enter a name");
		}

		if (is_ssh){
			if (!Regex.match_simple("^[A-Za-z0-9._:-]+$", host) || host.has_prefix("-")){
				return _("Enter a valid host name");
			}
			if (!Regex.match_simple("^[A-Za-z0-9._][A-Za-z0-9._-]*$", user)){
				return _("Enter a valid user name");
			}
			if ((port < 1) || (port > 65535)){
				return _("Enter a valid port");
			}
			if (!path.has_prefix("/")){
				return _("The directory on the remote host must be an absolute path");
			}
		}
		else{
			if (device_uuid.length == 0){
				return _("Select a device");
			}
			if (path.has_prefix("/") || path.contains("..")){
				return _("The directory must be relative to the top level of the device");
			}
		}

		if (!Regex.match_simple("^[A-Za-z0-9@._+/-]*$", path)){
			return _("The directory name contains characters that are not supported");
		}

		return "";
	}

	public Json.Object to_json(){

		var obj = new Json.Object();
		obj.set_string_member("id", id);
		obj.set_string_member("name", name);
		obj.set_string_member("enabled", enabled.to_string());
		obj.set_string_member("kind", kind);
		obj.set_string_member("device_uuid", device_uuid);
		obj.set_string_member("host", host);
		obj.set_string_member("port", port.to_string());
		obj.set_string_member("user", user);
		obj.set_string_member("identity_file", identity_file);
		obj.set_string_member("use_sudo", use_sudo.to_string());
		obj.set_string_member("path", path);
		foreach(string level in ReplicationPolicy.LEVELS){
			obj.set_string_member("keep_" + level, policy.get_keep(level).to_string());
		}
		return obj;
	}

	public static ReplicationTarget from_json(Json.Object obj){

		var target = new ReplicationTarget();
		target.id = json_get_string(obj, "id", target.id);
		target.name = json_get_string(obj, "name", "");
		target.enabled = json_get_bool(obj, "enabled", true);
		target.kind = (json_get_string(obj, "kind", "local") == "ssh") ? "ssh" : "local";
		target.device_uuid = json_get_string(obj, "device_uuid", "");
		target.host = json_get_string(obj, "host", "");
		target.port = json_get_int(obj, "port", 22);
		target.user = json_get_string(obj, "user", "root");
		target.identity_file = json_get_string(obj, "identity_file", "");
		target.use_sudo = json_get_bool(obj, "use_sudo", false);
		target.path = json_get_string(obj, "path", target.path);
		foreach(string level in ReplicationPolicy.LEVELS){
			target.policy.set_keep(level, json_get_int(obj, "keep_" + level, target.policy.get_keep(level)));
		}
		return target;
	}

	public ReplicationTarget copy(){
		return from_json(to_json());
	}
}

// access to a target: a mounted local filesystem or a remote host ----------

public abstract class ReplicationConnection : GLib.Object {

	public string error_message = "";

	// absolute directory on the target that holds the copies of this computer
	public string root = "";

	public abstract bool open();
	public abstract void close();

	public abstract bool mkdir(string path);
	public abstract Gee.ArrayList<string> list_dirs(string path);
	public abstract bool exists(string path);
	public abstract string? read_file(string path);
	public abstract bool write_file(string path, string text);
	public abstract bool remove_file(string path);
	public abstract BtrfsSubvolumeInfo? subvolume_info(string path);
	public abstract bool delete_subvolume(string path);
	public abstract bool remove_empty_dir(string path);
	public abstract string[] receive_command(string dir);

	public string snapshots_dir {
		owned get { return path_combine(root, "snapshots"); }
	}

	public static string hostname(){
		string name = Environment.get_host_name();
		return Regex.match_simple("^[A-Za-z0-9._-]+$", name) ? name : "localhost";
	}
}

public class LocalReplicationConnection : ReplicationConnection {

	private ReplicationTarget target;
	private string mount_point = "";

	public LocalReplicationConnection(ReplicationTarget target){
		this.target = target;
	}

	public override bool open(){

		var dev = Device.get_device_by_uuid(target.device_uuid);

		if (dev == null){
			error_message = _("Device not found") + ": UUID=%s".printf(target.device_uuid);
			return false;
		}

		if (dev.fstype != "btrfs"){
			error_message = _("The device is not formatted with BTRFS") + ": %s".printf(dev.device);
			return false;
		}

		if ((App.repo != null) && (App.repo.device != null) && (App.repo.device.uuid == target.device_uuid)){
			error_message = _("The target must be another device than the snapshot device");
			return false;
		}

		mount_point = path_combine(App.mount_point_app, "replica-" + target.id);

		if (!Device.mount(dev.uuid, mount_point, "subvolid=5", true)){
			error_message = _("Failed to mount device") + ": %s".printf(dev.device);
			return false;
		}

		// make sure that the right filesystem is mounted, so that nothing is
		// received on the wrong one
		var mounted = Device.get_device_by_path(mount_point);
		if ((mounted == null) || (mounted.uuid != target.device_uuid)){
			error_message = _("The device could not be mounted") + ": %s".printf(dev.device);
			close();
			return false;
		}

		root = path_combine(path_combine(mount_point, target.path), hostname());

		if (!mkdir(path_combine(root, "snapshots"))){
			close();
			return false;
		}

		return true;
	}

	public override void close(){
		if (mount_point.length > 0){
			Device.unmount(mount_point);
			dir_empty_delete(mount_point);
			mount_point = "";
		}
	}

	public override bool mkdir(string path){
		if (!dir_exists(path) && !dir_create(path)){
			error_message = _("Failed to create directory") + ": %s".printf(path);
			return false;
		}
		return true;
	}

	public override Gee.ArrayList<string> list_dirs(string path){
		var list = new Gee.ArrayList<string>();
		if (!dir_exists(path)){
			return list;
		}
		foreach(string name in dir_list_names(path)){
			if (dir_exists(path_combine(path, name))){
				list.add(name);
			}
		}
		return list;
	}

	public override bool exists(string path){
		return FileUtils.test(path, FileTest.EXISTS);
	}

	public override string? read_file(string path){
		return file_exists(path) ? file_read(path) : null;
	}

	public override bool write_file(string path, string text){
		return file_write(path, text);
	}

	public override bool remove_file(string path){
		return !file_exists(path) || file_delete(path);
	}

	public override BtrfsSubvolumeInfo? subvolume_info(string path){
		return BtrfsSubvolumeInfo.query(path);
	}

	public override bool delete_subvolume(string path){
		string std_out, std_err;
		if (exec_argv_sync({ "btrfs", "subvolume", "delete", "--commit-after", path }, out std_out, out std_err) != 0){
			error_message = std_err.strip();
			return false;
		}
		return true;
	}

	public override bool remove_empty_dir(string path){
		return dir_empty_delete(path);
	}

	public override string[] receive_command(string dir){
		return { "btrfs", "receive", dir };
	}
}

public class SshReplicationConnection : ReplicationConnection {

	private ReplicationTarget target;

	public SshReplicationConnection(ReplicationTarget target){
		this.target = target;
	}

	// ssh with options that never ask questions, followed by the remote command;
	// the remote command is run by the remote shell, so every word is quoted
	private string[] ssh_command(string[] remote, bool use_sudo = false){

		string[] argv = {
			"ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
			"-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
			"-o", "StrictHostKeyChecking=accept-new",
			"-o", "UserKnownHostsFile=" + ReplicationTarget.SSH_KNOWN_HOSTS,
			"-o", "Compression=no",
			"-i", target.ssh_identity,
			"-p", target.port.to_string(),
			"-l", target.user,
			"--", target.host
		};

		string cmd = "";
		if (use_sudo && target.use_sudo){
			cmd = "sudo -n ";
		}
		foreach(string word in remote){
			cmd += ((cmd.length > 0) && !cmd.has_suffix(" ") ? " " : "") + Shell.quote(word);
		}
		argv += cmd;

		return argv;
	}

	private int run(string[] remote, bool use_sudo, out string std_out, out string std_err){
		string[] argv = ssh_command(remote, use_sudo);
		log_debug(argv_to_string(argv));
		return exec_argv_sync(argv, out std_out, out std_err);
	}

	public override bool open(){

		dir_create(file_parent(ReplicationTarget.SSH_KNOWN_HOSTS));

		string std_out, std_err;

		// the directory must be on BTRFS
		if (run({ "stat", "-f", "-c", "%T", target.path }, false, out std_out, out std_err) != 0){
			error_message = (std_err.strip().length > 0) ? std_err.strip() : _("Could not connect to %s").printf(target.host);
			return false;
		}

		if (std_out.strip() != "btrfs"){
			error_message = _("The directory on the remote host is not on a BTRFS filesystem") + ": %s".printf(target.path);
			return false;
		}

		root = path_combine(target.path, hostname());

		return mkdir(path_combine(root, "snapshots"));
	}

	public override void close(){
	}

	public override bool mkdir(string path){
		string std_out, std_err;
		if (run({ "mkdir", "-p", path }, true, out std_out, out std_err) != 0){
			error_message = _("Failed to create directory") + ": %s (%s)".printf(path, std_err.strip());
			return false;
		}
		return true;
	}

	public override Gee.ArrayList<string> list_dirs(string path){
		var list = new Gee.ArrayList<string>();
		string std_out, std_err;
		if (run({ "find", path, "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-printf", "%f\\n" }, false, out std_out, out std_err) == 0){
			foreach(string line in std_out.split("\n")){
				if (line.strip().length > 0){
					list.add(line.strip());
				}
			}
		}
		return list;
	}

	public override bool exists(string path){
		string std_out, std_err;
		return run({ "test", "-e", path }, false, out std_out, out std_err) == 0;
	}

	public override string? read_file(string path){
		string std_out, std_err;
		if (run({ "cat", path }, false, out std_out, out std_err) != 0){
			return null;
		}
		return std_out;
	}

	public override bool write_file(string path, string text){
		try{
			string[] argv = ssh_command({ "tee", path }, true);
			var proc = new Subprocess.newv(argv, SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
			string? std_err;
			proc.communicate_utf8(text, null, null, out std_err);
			if (!proc.get_successful()){
				error_message = (std_err != null) ? std_err.strip() : "";
				return false;
			}
			return true;
		}
		catch (Error e){
			error_message = e.message;
			return false;
		}
	}

	public override bool remove_file(string path){
		string std_out, std_err;
		return run({ "rm", "-f", path }, true, out std_out, out std_err) == 0;
	}

	public override BtrfsSubvolumeInfo? subvolume_info(string path){
		string std_out, std_err;
		if (run({ "btrfs", "subvolume", "show", path }, true, out std_out, out std_err) != 0){
			return null;
		}
		var info = BtrfsSubvolumeInfo.parse(std_out);
		info.path = path;
		return info;
	}

	public override bool delete_subvolume(string path){
		string std_out, std_err;
		if (run({ "btrfs", "subvolume", "delete", "--commit-after", path }, true, out std_out, out std_err) != 0){
			error_message = std_err.strip();
			return false;
		}
		return true;
	}

	public override bool remove_empty_dir(string path){
		string std_out, std_err;
		return run({ "rmdir", path }, true, out std_out, out std_err) == 0;
	}

	public override string[] receive_command(string dir){
		return ssh_command({ "btrfs", "receive", dir }, true);
	}
}

// one replication run for one target ------------------------------------

public class Replication : GLib.Object {

	public ReplicationTarget target;
	public bool dry_run = false;

	// progress, read by the GUI
	public string status_line = "";
	public int64 bytes_transferred = 0;
	public int snapshots_sent = 0;
	public int snapshots_to_send = 0;
	public string error_message = "";

	private ReplicationConnection? conn = null;
	private BtrfsSendTask? task = null;
	private bool cancelled = false;

	public Replication(ReplicationTarget target){
		this.target = target;
	}

	public void cancel(){
		cancelled = true;
		if (task != null){
			task.cancel();
		}
	}

	private string cache_dir {
		owned get {
			return path_combine(App.repo.mount_path, "timeshift-btrfs/send-cache/" + target.id);
		}
	}

	private string cache_dir_for(string subvol_name){
		// subvolumes on another device (home) have their cache on that device
		return path_combine(App.repo.get_mount_path(subvol_name), "timeshift-btrfs/send-cache/" + target.id);
	}

	private void set_status(string txt){
		status_line = txt;
		log_msg(txt);
	}

	/*
	 * Sends the snapshots that the target should hold and removes the copies
	 * that are not kept anymore. Returns false on errors.
	 */
	public bool run(){

		log_msg(string.nfill(78, '-'));
		set_status(_("Replication to") + " '%s' (%s)".printf(target.name, target.location));

		if ((App.repo == null) || !App.repo.available() || !App.btrfs_mode){
			error_message = _("Replication requires BTRFS snapshots");
			log_error(error_message);
			return false;
		}

		conn = target.is_ssh ? (ReplicationConnection) new SshReplicationConnection(target) : new LocalReplicationConnection(target);

		if (!conn.open()){
			error_message = conn.error_message;
			log_error(error_message);
			return false;
		}

		bool ok = replicate();

		conn.close();

		if (ok){
			set_status(_("Replication completed") + ": %d %s".printf(snapshots_sent, _("snapshots sent")));
		}
		else{
			log_error(error_message);
		}

		return ok;
	}

	private bool replicate(){

		// copies on the target; incomplete ones (interrupted transfers) are removed
		var replicas = new Gee.HashMap<string, Json.Object>(); // name -> replica.json
		var replica_info = new Gee.HashMap<string, Json.Object>(); // name -> info.json

		foreach(string name in conn.list_dirs(conn.snapshots_dir)){

			if (!Regex.match_simple("^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$", name)){
				continue; // not ours
			}

			string dir = path_combine(conn.snapshots_dir, name);
			var marker = parse_json(conn.read_file(path_combine(dir, "replica.json")));
			var info = parse_json(conn.read_file(path_combine(dir, "info.json")));

			if ((marker == null) || (info == null)){
				remove_incomplete_replica(dir);
				continue;
			}

			replicas[name] = marker;
			replica_info[name] = info;
		}

		// what should be sent and removed

		var items = new Gee.ArrayList<ReplicationItem>();
		var sources = new Gee.HashMap<string, Snapshot>();

		foreach(var snap in App.repo.snapshots){
			if (!snap.valid || snap.live || snap.marked_for_deletion || (snap.subvolumes.size == 0)){
				continue;
			}
			sources[snap.name] = snap;
			items.add(new ReplicationItem(snap.name, snap.date.to_unix(), snap.taglist, true, replicas.has_key(snap.name)));
		}

		foreach(string name in replicas.keys){
			if (!sources.has_key(name)){
				var info = replica_info[name];
				int64 created = int64.parse(json_get_string(info, "created", "0"));
				items.add(new ReplicationItem(name, created, json_get_string(info, "tags", ""), false, true));
			}
		}

		var sends = ReplicationPlanner.plan_sends(items, target.policy);
		snapshots_to_send = sends.size;

		if (sends.size == 0){
			log_msg(_("The target is up to date"));
		}

		foreach(var item in sends){

			if (cancelled){
				error_message = _("Cancelled");
				return false;
			}

			if (dry_run){
				log_msg(_("Would send") + ": %s".printf(item.name));
				continue;
			}

			if (!send_snapshot(sources[item.name], replicas)){
				return false; // never remove anything after an error
			}

			snapshots_sent++;

			foreach(var it in items){
				if (it.name == item.name){
					it.on_target = true;
				}
			}
		}

		// update the tags of copies whose snapshot still exists (snapshots can
		// get more tags later, e.g. a daily snapshot becomes a weekly one)
		if (!dry_run){
			foreach(string name in replicas.keys){
				if (sources.has_key(name) && (replica_info.has_key(name))){
					if (json_get_string(replica_info[name], "tags", "") != sources[name].taglist){
						copy_info_json(sources[name], path_combine(conn.snapshots_dir, name));
					}
				}
			}
		}

		// remove the copies that are not kept anymore

		foreach(var item in ReplicationPlanner.plan_deletes(items, target.policy)){
			if (dry_run){
				log_msg(_("Would remove") + ": %s".printf(item.name));
				continue;
			}
			remove_replica(item.name);
		}

		if (!dry_run){
			clean_cache(items);
		}

		return true;
	}

	/*
	 * Sends all subvolumes of a snapshot. A subvolume is sent incrementally if
	 * the newest copy on the target has it and its read-only snapshot is still
	 * in the send cache.
	 */
	private bool send_snapshot(Snapshot snap, Gee.HashMap<string, Json.Object> replicas){

		set_status(_("Sending snapshot") + " %s (%d/%d)".printf(snap.name, snapshots_sent + 1, snapshots_to_send));

		string target_dir = path_combine(conn.snapshots_dir, snap.name);

		if (!conn.mkdir(target_dir)){
			error_message = conn.error_message;
			return false;
		}

		string base_name = get_newest_replica(replicas, snap.name);

		var marker = new Json.Object();
		marker.set_string_member("source-host", ReplicationConnection.hostname());
		marker.set_string_member("app-version", AppVersion);
		var marker_subvols = new Json.Object();

		foreach(var subvol in snap.subvolumes_sorted){

			// read-only snapshot of the snapshot's subvolume
			string cache = path_combine(path_combine(cache_dir_for(subvol.name), snap.name), subvol.name);

			if (!dir_exists(cache)){
				dir_create(file_parent(cache));
				string std_out, std_err;
				if (exec_argv_sync({ "btrfs", "subvolume", "snapshot", "-r", subvol.path, cache }, out std_out, out std_err) != 0){
					error_message = _("Failed to create a read-only snapshot") + ": %s (%s)".printf(cache, std_err.strip());
					return false;
				}
			}

			var cache_info = BtrfsSubvolumeInfo.query(cache);
			if ((cache_info == null) || !cache_info.readonly){
				error_message = _("Not a read-only subvolume") + ": %s".printf(cache);
				return false;
			}

			// parent for an incremental transfer: the cached copy of the newest
			// snapshot on the target, if the target really received it from there
			string parent = "";
			if (base_name.length > 0){
				string base_cache = path_combine(path_combine(cache_dir_for(subvol.name), base_name), subvol.name);
				var base_info = dir_exists(base_cache) ? BtrfsSubvolumeInfo.query(base_cache) : null;
				var base_replica = conn.subvolume_info(path_combine(path_combine(conn.snapshots_dir, base_name), subvol.name));
				if ((base_info != null) && base_info.readonly && (base_replica != null) && base_replica.readonly
					&& (base_replica.received_uuid == base_info.uuid)){
					parent = base_cache;
				}
			}

			string received = path_combine(target_dir, subvol.name);

			if (conn.exists(received)){
				// left over from an interrupted transfer
				conn.delete_subvolume(received);
			}

			set_status("%s: %s (%s)".printf(snap.name, subvol.name, (parent.length > 0) ? _("incremental") : _("full")));

			task = new BtrfsSendTask();
			task.progress.connect((bytes, seconds) => {
				bytes_transferred = bytes;
			});

			bool ok = task.run(cache, parent, conn.receive_command(target_dir));
			string task_error = task.error_message;
			task = null;

			if (!ok){
				error_message = _("Failed to send") + " %s/%s: %s".printf(snap.name, subvol.name, task_error);
				if (conn.exists(received)){
					conn.delete_subvolume(received);
				}
				conn.remove_empty_dir(target_dir);
				return false;
			}

			// verify the received subvolume
			var info = conn.subvolume_info(received);
			if ((info == null) || !info.readonly || (info.received_uuid != cache_info.uuid)){
				error_message = _("The received subvolume could not be verified") + ": %s".printf(received);
				if (info != null){
					conn.delete_subvolume(received);
				}
				return false;
			}

			marker_subvols.set_string_member(subvol.name, info.received_uuid);
		}

		// info.json, then the marker that says that the copy is complete
		if (!copy_info_json(snap, target_dir)){
			return false;
		}

		marker.set_object_member("subvolumes", marker_subvols);
		marker.set_string_member("completed", new DateTime.now_utc().to_unix().to_string());

		if (!conn.write_file(path_combine(target_dir, "replica.json"), json_to_string(marker))){
			error_message = _("Failed to write file") + ": %s".printf(conn.error_message);
			return false;
		}

		replicas[snap.name] = marker;

		return true;
	}

	private bool copy_info_json(Snapshot snap, string target_dir){

		string? txt = file_read(path_combine(snap.path, "info.json"));

		if ((txt == null) || !conn.write_file(path_combine(target_dir, "info.json"), txt)){
			error_message = _("Failed to write file") + ": %s".printf(conn.error_message);
			return false;
		}

		return true;
	}

	// the newest complete copy on the target that is older than the given snapshot
	private string get_newest_replica(Gee.HashMap<string, Json.Object> replicas, string before){
		string newest = "";
		foreach(string name in replicas.keys){
			if ((strcmp(name, before) < 0) && (strcmp(name, newest) > 0)){
				newest = name;
			}
		}
		return newest;
	}

	private void remove_replica(string name){

		set_status(_("Removing copy") + ": %s".printf(name));

		string dir = path_combine(conn.snapshots_dir, name);

		// the marker first, so that a half-removed copy counts as incomplete
		conn.remove_file(path_combine(dir, "replica.json"));
		delete_replica_dir(dir);
	}

	private void remove_incomplete_replica(string dir){
		log_msg(_("Removing incomplete copy") + ": %s".printf(Path.get_basename(dir)));
		delete_replica_dir(dir);
	}

	private void delete_replica_dir(string dir){

		foreach(string name in conn.list_dirs(dir)){
			string path = path_combine(dir, name);
			if (conn.subvolume_info(path) != null){
				conn.delete_subvolume(path);
			}
		}

		// the remaining files
		conn.remove_file(path_combine(dir, "replica.json"));
		conn.remove_file(path_combine(dir, "info.json"));

		conn.remove_empty_dir(dir);
	}

	/*
	 * Keeps the read-only snapshots of the newest copy on the target (the base
	 * for the next transfer) and removes the others from the send cache.
	 */
	private void clean_cache(Gee.ArrayList<ReplicationItem> items){

		string newest = "";
		foreach(var item in items){
			if (item.on_target && (strcmp(item.name, newest) > 0)){
				newest = item.name;
			}
		}

		var dirs = new Gee.HashSet<string>();
		dirs.add(cache_dir);
		foreach(var snap in App.repo.snapshots){
			foreach(var subvol in snap.subvolumes.values){
				dirs.add(cache_dir_for(subvol.name));
			}
		}

		foreach(string dir in dirs){
			if (!dir_exists(dir)){ continue; }
			foreach(string name in dir_list_names(dir)){
				if (name == newest){ continue; }
				string snap_dir = path_combine(dir, name);
				foreach(string subvol in dir_list_names(snap_dir)){
					string std_out, std_err;
					exec_argv_sync({ "btrfs", "subvolume", "delete", path_combine(snap_dir, subvol) }, out std_out, out std_err);
				}
				dir_empty_delete(snap_dir);
			}
		}
	}

	// removes the send cache of a target that is not used anymore
	public static void remove_cache(ReplicationTarget target){

		if ((App.repo == null) || (App.repo.mount_path.length == 0)){
			return;
		}

		var dirs = new Gee.HashSet<string>();
		dirs.add(path_combine(App.repo.mount_path, "timeshift-btrfs/send-cache/" + target.id));
		dirs.add(path_combine(App.repo.get_mount_path(App.home_subvolume_name), "timeshift-btrfs/send-cache/" + target.id));

		foreach(string dir in dirs){
			if (!dir_exists(dir)){ continue; }
			foreach(string name in dir_list_names(dir)){
				string snap_dir = path_combine(dir, name);
				foreach(string subvol in dir_list_names(snap_dir)){
					string std_out, std_err;
					exec_argv_sync({ "btrfs", "subvolume", "delete", path_combine(snap_dir, subvol) }, out std_out, out std_err);
				}
				dir_empty_delete(snap_dir);
			}
			dir_empty_delete(dir);
		}
	}

	private static Json.Object? parse_json(string? txt){
		if ((txt == null) || (txt.strip().length == 0)){
			return null;
		}
		try{
			var parser = new Json.Parser();
			parser.load_from_data(txt);
			var node = parser.get_root();
			return ((node != null) && (node.get_node_type() == Json.NodeType.OBJECT)) ? node.get_object() : null;
		}
		catch (Error e){
			return null;
		}
	}

	private static string json_to_string(Json.Object obj){
		var node = new Json.Node(Json.NodeType.OBJECT);
		node.set_object(obj);
		var gen = new Json.Generator();
		gen.pretty = true;
		gen.indent = 2;
		gen.set_root(node);
		return gen.to_data(null);
	}
}
