/*
 * PackageTransaction.vala
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

/*
 * Describes a package manager transaction that is about to run, so that the
 * snapshot taken before it gets a meaningful comment, e.g. "apt install vlc"
 * or "install vlc, upgrade 12 packages".
 *
 * This class has no dependencies on the rest of Timeshift so that it can be
 * tested on its own.
 */
public class PackageTransaction : GLib.Object {

	// command line of the program that started the transaction, e.g.
	// "apt install vlc"; empty if unknown (e.g. a graphical package manager)
	public string command_line = "";

	public Gee.ArrayList<string> installs = new Gee.ArrayList<string>();
	public Gee.ArrayList<string> upgrades = new Gee.ArrayList<string>();
	public Gee.ArrayList<string> downgrades = new Gee.ArrayList<string>();
	public Gee.ArrayList<string> reinstalls = new Gee.ArrayList<string>();
	public Gee.ArrayList<string> removes = new Gee.ArrayList<string>();

	// options that only make the command line longer
	private const string[] NOISE_OPTIONS = {
		"-y", "--yes", "--assume-yes", "-q", "-qq", "--quiet", "--assumeyes"
	};

	// programs whose command line describes the transaction well
	private const string[] COMMAND_LINE_PROGRAMS = {
		"apt", "apt-get", "aptitude", "nala", "dnf", "dnf5", "yum"
	};

	/*
	 * Parses the input of an APT DPkg::Pre-Install-Pkgs hook that uses version 3
	 * of the hook protocol: a "VERSION 3" line, the APT configuration as
	 * key=value lines (values are URL-encoded), an empty line and then one line
	 * per package action:
	 *
	 *   name old-version old-arch old-multiarch direction new-version new-arch new-multiarch action
	 *
	 * where the versions are "-" if the package is (or will be) not installed,
	 * direction is "<", ">" or "=" and action is the path of the .deb file,
	 * **CONFIGURE**, **REMOVE** or **PURGE**.
	 */
	public static PackageTransaction from_apt_hook_input(string input){

		var trans = new PackageTransaction();

		bool in_packages = false;
		bool first = true;

		foreach(string line in input.split("\n")){

			if (first){
				first = false;
				if (line.has_prefix("VERSION ")){
					continue;
				}
			}

			if (!in_packages){
				if (line.strip().length == 0){
					in_packages = true;
				}
				else if (line.has_prefix("CommandLine::AsString=")){
					string value = line.substring("CommandLine::AsString=".length);
					string? decoded = Uri.unescape_string(value);
					trans.command_line = (decoded != null) ? decoded.strip() : value.strip();
				}
				continue;
			}

			trans.parse_apt_package_line(line);
		}

		return trans;
	}

	private void parse_apt_package_line(string line){

		var fields = new Gee.ArrayList<string>();
		foreach(string field in line.strip().split(" ")){
			if (field.length > 0){
				fields.add(field);
			}
		}

		if (fields.size < 9){
			return;
		}

		string name = fields[0];
		string old_version = fields[1];
		string direction = fields[4];
		string action = fields[8];

		if (action == "**CONFIGURE**"){
			return; // repeats a package that is installed in the same transaction
		}

		if ((action == "**REMOVE**") || (action == "**PURGE**")){
			add_unique(removes, name);
		}
		else if (old_version == "-"){
			add_unique(installs, name);
		}
		else if (direction == "<"){
			add_unique(upgrades, name);
		}
		else if (direction == ">"){
			add_unique(downgrades, name);
		}
		else{
			add_unique(reinstalls, name);
		}
	}

	/*
	 * Creates a transaction from the command line of the package manager
	 * process (arguments separated by spaces), e.g. read from /proc/<pid>/cmdline.
	 */
	public static PackageTransaction from_command_line(string cmdline){
		var trans = new PackageTransaction();
		trans.command_line = cmdline.strip();
		return trans;
	}

	private static void add_unique(Gee.ArrayList<string> list, string name){
		if (!list.contains(name)){
			list.add(name);
		}
	}

	public bool is_empty(){
		return (installs.size + upgrades.size + downgrades.size + reinstalls.size + removes.size) == 0;
	}

	/*
	 * Returns a short description of the transaction for the snapshot comment:
	 * the command line if it was started by a command line program, otherwise
	 * a summary of the package actions.
	 */
	public string get_description(int max_length = 80){

		string cmd = get_short_command_line();

		if (cmd.length > 0){
			return truncate(cmd, max_length);
		}

		string summary = get_summary();

		if (summary.length > 0){
			return truncate(summary, max_length);
		}

		return "";
	}

	// the command line without the path of the program and without noise options
	public string get_short_command_line(){

		var args = new Gee.ArrayList<string>();
		foreach(string arg in command_line.split(" ")){
			if (arg.length > 0){
				args.add(arg);
			}
		}

		if (args.size == 0){
			return "";
		}

		string program = Path.get_basename(args[0]);

		// "python3 /usr/bin/unattended-upgrade" and similar: not a command line program
		bool known = false;
		foreach(string p in COMMAND_LINE_PROGRAMS){
			if (program == p){
				known = true;
				break;
			}
		}

		if (!known){
			return "";
		}

		string txt = program;

		for(int i = 1; i < args.size; i++){
			bool noise = false;
			foreach(string opt in NOISE_OPTIONS){
				if (args[i] == opt){
					noise = true;
					break;
				}
			}
			if (!noise){
				txt += " " + args[i];
			}
		}

		return txt;
	}

	// e.g. "install vlc, upgrade 12 packages, remove foo"
	public string get_summary(){

		string txt = "";
		txt = append_summary(txt, "install", installs);
		txt = append_summary(txt, "upgrade", upgrades);
		txt = append_summary(txt, "downgrade", downgrades);
		txt = append_summary(txt, "reinstall", reinstalls);
		txt = append_summary(txt, "remove", removes);
		return txt;
	}

	private static string append_summary(string txt, string verb, Gee.ArrayList<string> names){

		if (names.size == 0){
			return txt;
		}

		string part;
		if (names.size <= 3){
			part = verb;
			foreach(string name in names){
				part += " " + name;
			}
		}
		else{
			part = "%s %d packages".printf(verb, names.size);
		}

		return (txt.length > 0) ? txt + ", " + part : part;
	}

	private static string truncate(string txt, int max_length){
		if ((max_length <= 3) || (txt.char_count() <= max_length)){
			return txt;
		}
		return txt.substring(0, txt.index_of_nth_char(max_length - 3)) + "...";
	}
}
