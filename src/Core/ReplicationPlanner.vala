/*
 * ReplicationPlanner.vala
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
 * A snapshot that exists on the snapshot device, on a replication target,
 * or on both.
 */
public class ReplicationItem : GLib.Object {

	public string name = "";       // snapshot name, e.g. 2026-11-26_12-00-00
	public int64 created = 0;      // unix time
	public string tags = "";       // e.g. "daily weekly" (as stored in info.json)
	public bool on_source = false; // the snapshot exists on the snapshot device
	public bool on_target = false; // a complete copy exists on the target

	public ReplicationItem(string name, int64 created, string tags, bool on_source, bool on_target){
		this.name = name;
		this.created = created;
		this.tags = tags;
		this.on_source = on_source;
		this.on_target = on_target;
	}

	public bool has_tag(string tag){
		foreach(string t in tags.split(" ")){
			if (t == tag){
				return true;
			}
		}
		return false;
	}
}

/*
 * How many copies of each snapshot level are kept on a target, like the
 * "Keep" values for the snapshot levels on the snapshot device.
 */
public class ReplicationPolicy : GLib.Object {

	public int keep_monthly = 12;
	public int keep_weekly = 4;
	public int keep_daily = 7;
	public int keep_hourly = 0;
	public int keep_boot = 0;
	public int keep_ondemand = 10;
	public int keep_package = 0;

	public static string[] LEVELS = { "monthly", "weekly", "daily", "hourly", "boot", "ondemand", "package" };

	public int get_keep(string level){
		switch (level){
			case "monthly": return keep_monthly;
			case "weekly": return keep_weekly;
			case "daily": return keep_daily;
			case "hourly": return keep_hourly;
			case "boot": return keep_boot;
			case "ondemand": return keep_ondemand;
			case "package": return keep_package;
		}
		return 0;
	}

	public void set_keep(string level, int count){
		switch (level){
			case "monthly": keep_monthly = count; break;
			case "weekly": keep_weekly = count; break;
			case "daily": keep_daily = count; break;
			case "hourly": keep_hourly = count; break;
			case "boot": keep_boot = count; break;
			case "ondemand": keep_ondemand = count; break;
			case "package": keep_package = count; break;
		}
	}
}

/*
 * Decides which snapshots are sent to a target and which copies are removed
 * from it. Only works on names, dates and tags, so it can be tested on its own.
 */
public class ReplicationPlanner : GLib.Object {

	/*
	 * Returns the names of the snapshots that the target should hold: for every
	 * level the newest N snapshots with that tag, plus the newest copy that is
	 * already on the target (the base for the next incremental transfer).
	 */
	public static Gee.HashSet<string> select_kept(Gee.ArrayList<ReplicationItem> items, ReplicationPolicy policy){

		var kept = new Gee.HashSet<string>();

		var sorted = sort_newest_first(items);

		foreach(string level in ReplicationPolicy.LEVELS){
			int keep = policy.get_keep(level);
			int count = 0;
			foreach(var item in sorted){
				if (count >= keep){
					break;
				}
				if (item.has_tag(level)){
					kept.add(item.name);
					count++;
				}
			}
		}

		foreach(var item in sorted){
			if (item.on_target){
				kept.add(item.name);
				break;
			}
		}

		return kept;
	}

	// snapshots to send, oldest first, so that each one can be sent incrementally
	public static Gee.ArrayList<ReplicationItem> plan_sends(Gee.ArrayList<ReplicationItem> items, ReplicationPolicy policy){

		var kept = select_kept(items, policy);
		var list = new Gee.ArrayList<ReplicationItem>();

		foreach(var item in sort_newest_first(items)){
			if (item.on_source && !item.on_target && kept.contains(item.name)){
				list.insert(0, item);
			}
		}

		return list;
	}

	/*
	 * Copies to remove from the target once the planned snapshots have been
	 * sent: the ones that are not kept anymore. The newest copy is never
	 * removed.
	 */
	public static Gee.ArrayList<ReplicationItem> plan_deletes(Gee.ArrayList<ReplicationItem> items, ReplicationPolicy policy){

		// assume that the planned transfers succeed
		var after = new Gee.ArrayList<ReplicationItem>();
		var sends = plan_sends(items, policy);
		foreach(var item in items){
			bool sent = false;
			foreach(var s in sends){
				if (s.name == item.name){
					sent = true;
				}
			}
			after.add(new ReplicationItem(item.name, item.created, item.tags, item.on_source, item.on_target || sent));
		}

		var kept = select_kept(after, policy);
		var list = new Gee.ArrayList<ReplicationItem>();

		foreach(var item in items){
			if (item.on_target && !kept.contains(item.name)){
				list.add(item);
			}
		}

		return list;
	}

	private static Gee.ArrayList<ReplicationItem> sort_newest_first(Gee.ArrayList<ReplicationItem> items){
		var list = new Gee.ArrayList<ReplicationItem>();
		list.add_all(items);
		list.sort((a, b) => {
			if (a.created != b.created){
				return (a.created > b.created) ? -1 : 1;
			}
			return strcmp(b.name, a.name);
		});
		return list;
	}
}
