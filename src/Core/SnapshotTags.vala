/*
 * SnapshotTags.vala
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
 * The tags of a snapshot in its info.json.
 *
 * Timeshift 26.11.0 to 26.11.2 drop the tags they don't know when they read
 * info.json, remove snapshots without tags, and write back only the tags
 * they know (the other keys are kept). So that a snapshot with tags these
 * versions don't know ("package", or the tags of a newer version) survives a
 * downgrade, info.json has:
 *   "tags"        all tags, plus "ondemand" as a stand-in if it is not a
 *                 real tag (on-demand snapshots are never removed automatically)
 *   "extra-tags"  the real tags that these versions don't know
 *   "compat-tags" "ondemand" if it was only added as a stand-in
 * The tags of a snapshot are "tags" without "compat-tags", plus "extra-tags".
 *
 * The stand-in exists only in info.json, never in Snapshot.tags or
 * Snapshot.taglist: the retention, the tag symlinks, the scheduler and the
 * replication rely on that.
 */
public class SnapshotTags : GLib.Object {

	public const string EXTRA = "extra-tags";
	public const string COMPAT = "compat-tags";

	// splits a list of tag names into the known tags and the unknown names
	public static Tags parse(string list, out string unknown){

		Tags tags = 0;
		unknown = "";

		foreach(string tag in list.split(" ")){

			string name = tag.strip();
			if (name.length == 0){
				continue;
			}

			Tags? parsed = Tags.parse(name);
			if ((parsed != null) && (parsed.name() == name.down())){
				tags |= parsed;
			}
			else if (!(name in unknown.split(" "))){
				unknown = (unknown + " " + name).strip();
			}
		}

		return tags;
	}

	// the list as Snapshot.taglist returns it: the known tags in their order, then the unknown names
	public static string to_list(Tags tags, string unknown){
		return (tags.as_config_string() + " " + unknown).strip();
	}

	// the tags of a snapshot from its info.json (also of copies on replication targets)
	public static string read(Json.Object config){

		string unknown;
		Tags tags = parse(get_member(config, "tags"), out unknown);

		string compat = get_member(config, COMPAT);
		string extra = get_member(config, EXTRA);

		// the first version of this format had no "extra-tags", the stand-in was only used for "package"
		if ((compat.length > 0) && !config.has_member(EXTRA)){
			extra = Tags.Package.name();
		}

		string names;
		tags &= ~ parse(compat, out names);
		foreach(string name in names.split(" ")){
			unknown = remove_name(unknown, name);
		}

		tags |= parse(extra, out names);
		foreach(string name in names.split(" ")){
			if ((name.length > 0) && !(name in unknown.split(" "))){
				unknown = (unknown + " " + name).strip();
			}
		}

		return to_list(tags, unknown);
	}

	// writes the tags to info.json, see above
	public static void write(Json.Object config, Tags tags, string unknown){

		// the real tags that 26.11.0 to 26.11.2 don't know
		string extra = to_list(tags & ~ (Tags.Timed | Tags.OnDemand), unknown);

		if (extra.length == 0){
			config.set_string_member("tags", to_list(tags, unknown));
			remove_member(config, EXTRA);
			remove_member(config, COMPAT);
		}
		else if (Tags.OnDemand in tags){
			config.set_string_member("tags", to_list(tags, unknown));
			config.set_string_member(EXTRA, extra);
			remove_member(config, COMPAT);
		}
		else{
			config.set_string_member("tags", to_list(tags | Tags.OnDemand, unknown));
			config.set_string_member(EXTRA, extra);
			config.set_string_member(COMPAT, Tags.OnDemand.name());
		}
	}

	// true if info.json doesn't protect the tags the way write() does, e.g. a
	// snapshot before package operations written by a build before this format
	public static bool needs_update(Json.Object config){

		string unknown;
		Tags tags = parse(read(config), out unknown);

		var expected = new Json.Object();
		write(expected, tags, unknown);

		// the order of the names in "tags" doesn't matter
		if ((get_member(expected, EXTRA) != get_member(config, EXTRA))
			|| (get_member(expected, COMPAT) != get_member(config, COMPAT))){
			return true;
		}

		string names;
		return (get_member(expected, COMPAT).length > 0)
			&& !(Tags.OnDemand in parse(get_member(config, "tags"), out names));
	}

	// json_get_string() would log every member that is missing
	private static string get_member(Json.Object config, string name){
		string? val = config.get_string_member_with_default(name, "");
		return val ?? "";
	}

	private static void remove_member(Json.Object config, string name){
		if (config.has_member(name)){
			config.remove_member(name);
		}
	}

	private static string remove_name(string list, string name){
		string result = "";
		foreach(string item in list.split(" ")){
			if ((item.length > 0) && (item != name)){
				result += " " + item;
			}
		}
		return result.strip();
	}
}
