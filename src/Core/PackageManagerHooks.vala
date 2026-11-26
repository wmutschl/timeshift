/*
 * PackageManagerHooks.vala
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
using TeeJee.ProcessHelper;

/*
 * Snapshots before package manager transactions.
 *
 * Timeshift writes a hook for APT and for the DNF5 actions plugin while
 * the option is enabled (like the cron files for scheduled snapshots) and
 * removes the hooks when it is disabled. The hooks run
 * 'timeshift --package-hook apt|dnf', which creates a snapshot tagged
 * 'package' with a description of the transaction.
 *
 * The hooks must never break the package manager: the APT hook ignores the
 * exit status, the DNF5 actions plugin ignores it by default, and Timeshift
 * itself exits with status 0 in hook mode.
 */
public class PackageManagerHooks : GLib.Object {

	public const string APT_HOOK_FILE = "/etc/apt/apt.conf.d/80timeshift";
	public const string DNF_ACTIONS_DIR = "/etc/dnf/libdnf5-plugins/actions.d";
	public const string DNF_HOOK_FILE = "/etc/dnf/libdnf5-plugins/actions.d/timeshift.actions";
	public const string DNF_ACTIONS_PLUGIN_CONF = "/etc/dnf/libdnf5-plugins/actions.conf";

	private const string HOOK_MARKER = "Created by Timeshift";
	private const string STATE_FILE = "/run/lock/timeshift/package-hook";

	// another snapshot is skipped if the same process (e.g. apt running dpkg
	// several times, or unattended-upgrades) triggers the hook again within
	// this many seconds
	private const int64 DEDUP_SECONDS = 300;

	// "apt", "dnf" or "" if neither is used on this system
	public static string get_package_manager(){

		if (dir_exists("/etc/apt/apt.conf.d") && cmd_exists("apt-get")){
			return "apt";
		}

		if (dir_exists("/etc/dnf") && (cmd_exists("dnf5") || cmd_exists("dnf"))){
			return "dnf";
		}

		return "";
	}

	public static bool dnf_actions_plugin_installed(){
		return file_exists(DNF_ACTIONS_PLUGIN_CONF);
	}

	/*
	 * Writes the hook files if enabled, removes them otherwise. Files that
	 * were not created by Timeshift are never touched.
	 */
	public static void update(bool enabled){

		string pm = get_package_manager();

		string bin = get_timeshift_binary();

		if (enabled && (pm == "apt")){

			string txt = "// %s: take a snapshot before packages are installed, upgraded or removed.\n".printf(HOOK_MARKER);
			txt += "// Disable \"Packages\" on the Schedule page of Timeshift's settings to remove this file.\n";
			txt += "DPkg::Pre-Install-Pkgs { \"%s --package-hook apt || true\"; };\n".printf(bin);
			txt += "DPkg::Tools::Options::%s::Version \"3\";\n".printf(bin);

			write_hook_file(APT_HOOK_FILE, txt);
		}
		else{
			remove_hook_file(APT_HOOK_FILE);
		}

		if (enabled && (pm == "dnf") && dir_exists("/etc/dnf/libdnf5-plugins")){

			// the actions plugin parses everything a command writes to stdout,
			// Timeshift writes its messages to stderr in hook mode
			string txt = "# %s: take a snapshot before packages are installed, upgraded or removed.\n".printf(HOOK_MARKER);
			txt += "# Disable \"Packages\" on the Schedule page of Timeshift's settings to remove this file.\n";
			txt += "pre_transaction::::%s --package-hook dnf ${pid}\n".printf(bin);

			dir_create(DNF_ACTIONS_DIR);
			write_hook_file(DNF_HOOK_FILE, txt);
		}
		else{
			remove_hook_file(DNF_HOOK_FILE);
		}
	}

	// the console binary next to the running binary (timeshift or timeshift-gtk)
	private static string get_timeshift_binary(){
		try{
			string exe = FileUtils.read_link("/proc/self/exe");
			string bin = path_combine(file_parent(exe), "timeshift");
			if (file_exists(bin)){
				return bin;
			}
		}
		catch (Error e){
			log_debug(e.message);
		}
		return "/usr/bin/timeshift";
	}

	private static void write_hook_file(string path, string txt){

		if (file_exists(path)){
			string current = file_read(path);
			if (current == txt){
				return;
			}
			if ((current == null) || !current.contains(HOOK_MARKER)){
				log_error(_("File exists and was not created by Timeshift") + ": %s".printf(path));
				return;
			}
		}

		if (file_write(path, txt)){
			Posix.chmod(path, 0644);
			log_msg(_("Added package manager hook") + ": %s".printf(path));
		}
	}

	private static void remove_hook_file(string path){

		if (!file_exists(path)){
			return;
		}

		string current = file_read(path);
		if ((current != null) && current.contains(HOOK_MARKER)){
			file_delete(path);
			log_msg(_("Removed package manager hook") + ": %s".printf(path));
		}
	}

	// hook mode ----------------------------------------------------

	/*
	 * Reads the transaction that triggered the hook: from stdin for APT
	 * (Pre-Install-Pkgs, protocol version 3), from the command line of the
	 * dnf process for DNF5. Must be called before anything else, APT waits
	 * until the hook has read its input.
	 */
	public static PackageTransaction read_transaction(string package_manager, string pid_arg){

		if (package_manager == "apt"){
			var sb = new StringBuilder();
			string? line;
			while ((line = stdin.read_line()) != null){
				sb.append(line);
				sb.append_c('\n');
			}
			return PackageTransaction.from_apt_hook_input(sb.str);
		}

		int pid = int.parse(pid_arg);
		return PackageTransaction.from_command_line((pid > 0) ? read_cmdline(pid) : "");
	}

	// command line of a process, with spaces between the arguments
	public static string read_cmdline(int pid){

		try{
			uint8[] data;
			FileUtils.get_data("/proc/%d/cmdline".printf(pid), out data);
			for(int i = 0; i < data.length; i++){
				if (data[i] == 0){
					data[i] = ' ';
				}
			}
			return ((string) data).make_valid((ssize_t) data.length).strip();
		}
		catch (Error e){
			return "";
		}
	}

	/*
	 * The process that started the transaction: for APT the parent of the
	 * shell that runs the hook, for DNF5 the dnf process (pid_arg).
	 */
	public static int get_frontend_pid(string package_manager, string pid_arg){

		if (package_manager == "dnf"){
			return int.parse(pid_arg);
		}

		int shell_pid = (int) Posix.getppid();
		return get_parent_pid(shell_pid);
	}

	private static int get_parent_pid(int pid){

		// /proc/<pid>/stat: pid (comm) state ppid ...
		string? stat = file_read("/proc/%d/stat".printf(pid));
		if (stat == null){
			return 0;
		}

		int pos = stat.last_index_of(")");
		if (pos < 0){
			return 0;
		}

		string[] fields = stat.substring(pos + 1).strip().split(" ");
		return (fields.length > 1) ? int.parse(fields[1]) : 0;
	}

	private static string get_process_start_time(int pid){

		string? stat = file_read("/proc/%d/stat".printf(pid));
		if (stat == null){
			return "";
		}

		int pos = stat.last_index_of(")");
		if (pos < 0){
			return "";
		}

		// field 22 (starttime); fields after ')' start with field 3 (state)
		string[] fields = stat.substring(pos + 1).strip().split(" ");
		return (fields.length > 19) ? fields[19] : "";
	}

	/*
	 * Returns true if the same frontend process triggered a snapshot recently,
	 * and records this call otherwise.
	 */
	public static bool check_and_record_frontend(int frontend_pid){

		string id = "%d %s".printf(frontend_pid, get_process_start_time(frontend_pid));
		int64 now = new DateTime.now_utc().to_unix();

		string? txt = file_exists(STATE_FILE) ? file_read(STATE_FILE) : null;
		if (txt != null){
			string[] lines = txt.strip().split("\n");
			if ((lines.length == 2) && (lines[0] == id)){
				int64 last = int64.parse(lines[1]);
				if ((now - last) < DEDUP_SECONDS){
					return true;
				}
			}
		}

		file_write(STATE_FILE, id + "\n" + now.to_string() + "\n");
		return false;
	}

	// true if running in a chroot, e.g. while an installer or a package build runs
	public static bool in_chroot(){

		Posix.Stat st_root;
		if (Posix.stat("/", out st_root) != 0){
			return false;
		}

		Posix.Stat st_init_root;
		if (Posix.stat("/proc/1/root/.", out st_init_root) != 0){
			return false;
		}

		return (st_root.st_dev != st_init_root.st_dev) || (st_root.st_ino != st_init_root.st_ino);
	}
}
