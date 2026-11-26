/*
 * SubvolumeBox.vala
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

using Gtk;
using Gee;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

/*
 * Lists the BTRFS subvolumes of the system (settings and wizard) or of the
 * snapshot to restore (restore window) and lets the user select which
 * of them are included in snapshots or restored.
 */
class SubvolumeBox : Gtk.Box{

	private Gtk.TreeView treeview;
	private Gtk.Label lbl_message;
	private Gtk.Window parent_window;
	private bool restore_mode = false;

	public SubvolumeBox (Gtk.Window _parent_window, bool _restore_mode) {

		log_debug("SubvolumeBox: SubvolumeBox()");

		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6); // work-around
		parent_window = _parent_window;
		margin = 12;

		restore_mode = _restore_mode;

		add_label_header(this, _("Subvolumes"), true);

		string txt;
		if (restore_mode){
			txt = _("Select the subvolumes to restore. The root subvolume is always restored, the other subvolumes are left unchanged unless you select them.");
		}
		else{
			txt = _("Select the subvolumes to include in snapshots. The root subvolume is always included.");
		}

		lbl_message = add_label(this, txt, false, true);

		init_treeview();

		if (!restore_mode){
			add_note(_("Subvolumes that are not included are left unchanged when a snapshot is restored, e.g. a subvolume for logs or caches. Nested subvolumes inside the root subvolume (e.g. created by Docker) are never included."));
		}

		refresh();

		log_debug("SubvolumeBox: SubvolumeBox(): exit");
	}

	private void init_treeview(){

		treeview = new TreeView();
		treeview.get_selection().mode = SelectionMode.SINGLE;
		treeview.headers_visible = true;
		treeview.reorderable = false;
		treeview.has_tooltip = true;
		treeview.query_tooltip.connect(treeview_query_tooltip);

		var scrolled = new ScrolledWindow(null, null);
		scrolled.set_shadow_type (ShadowType.ETCHED_IN);
		scrolled.add (treeview);
		scrolled.expand = true;
		add(scrolled);

		// column: include -------------------------------------

		var col = new TreeViewColumn();
		col.title = restore_mode ? _("Restore") : _("Include");
		treeview.append_column(col);

		var cell_toggle = new Gtk.CellRendererToggle();
		cell_toggle.xpad = 2;
		cell_toggle.activatable = true;
		col.pack_start (cell_toggle, false);

		col.set_cell_data_func (cell_toggle, (cell_layout, cell, model, iter)=>{
			Subvolume subvol;
			model.get(iter, 0, out subvol);
			var toggle = (Gtk.CellRendererToggle) cell;
			toggle.active = is_selected(subvol);
			toggle.sensitive = can_change(subvol);
		});

		cell_toggle.toggled.connect((cell, path)=>{

			var model = (Gtk.ListStore) treeview.model;
			TreeIter iter;
			model.get_iter_from_string (out iter, path);

			Subvolume subvol;
			model.get(iter, 0, out subvol);

			if (!can_change(subvol)){ return; }

			App.set_btrfs_subvolume_included(subvol.mount_point, restore_mode, !is_selected(subvol));

			treeview.queue_draw();
		});

		// column: name ----------------------------------------

		col = new TreeViewColumn();
		col.title = _("Subvolume");
		col.expand = true;
		treeview.append_column(col);

		var cell_icon = new CellRendererPixbuf ();
		col.pack_start (cell_icon, false);

		col.set_cell_data_func (cell_icon, (cell_layout, cell, model, iter)=>{
			Subvolume subvol;
			model.get(iter, 0, out subvol);
			((Gtk.CellRendererPixbuf) cell).icon_name = (get_problem(subvol).length > 0) ? "xsi-dialog-warning-symbolic" : "";
		});

		var cell_text = new CellRendererText ();
		cell_text.ellipsize = Pango.EllipsizeMode.END;
		col.pack_start (cell_text, false);

		col.set_cell_data_func (cell_text, (cell_layout, cell, model, iter)=>{
			Subvolume subvol;
			model.get(iter, 0, out subvol);
			((Gtk.CellRendererText) cell).text = subvol.name;
			((Gtk.CellRendererText) cell).sensitive = (get_problem(subvol).length == 0);
		});

		// column: mount point ---------------------------------

		col = new TreeViewColumn();
		col.title = _("Mount Point");
		col.expand = true;
		treeview.append_column(col);

		cell_text = new CellRendererText ();
		cell_text.ellipsize = Pango.EllipsizeMode.END;
		col.pack_start (cell_text, false);

		col.set_cell_data_func (cell_text, (cell_layout, cell, model, iter)=>{
			Subvolume subvol;
			model.get(iter, 0, out subvol);
			((Gtk.CellRendererText) cell).text = (subvol.mount_point.length > 0) ? subvol.mount_point : _("Unknown");
			((Gtk.CellRendererText) cell).sensitive = (get_problem(subvol).length == 0);
		});
	}

	private void add_note(string text){

		var label = new Gtk.Label("<i>%s</i>".printf(escape_html(text)));
		label.set_use_markup(true);
		label.xalign = (float) 0.0;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD;
		label.max_width_chars = 60;
		add(label);
	}

	private bool treeview_query_tooltip(int x, int y, bool keyboard_tooltip, Tooltip tooltip){

		TreeModel model;
		TreePath path;
		TreeIter iter;

		if (!treeview.get_tooltip_context(ref x, ref y, keyboard_tooltip, out model, out path, out iter)){
			return false;
		}

		Subvolume subvol;
		model.get(iter, 0, out subvol);

		string txt = get_problem(subvol);

		if ((txt.length == 0) && is_root(subvol)){
			txt = restore_mode ? _("The root subvolume is always restored") : _("The root subvolume is always included");
		}

		if (txt.length == 0){
			return false;
		}

		tooltip.set_text(txt);
		treeview.set_tooltip_row(tooltip, path);
		return true;
	}

	// helpers

	private bool is_root(Subvolume subvol){
		if (restore_mode){
			return (App.snapshot_to_restore != null) && (subvol.name == App.snapshot_to_restore.root_subvolume_name);
		}
		return (subvol.name == App.root_subvolume_name);
	}

	private string get_problem(Subvolume subvol){

		if (is_root(subvol)){
			return "";
		}

		if (restore_mode){
			if ((subvol.mount_point.length == 0) || (subvol.mount_point == "/")){
				return _("The mount point of this subvolume is unknown, it can't be restored");
			}
			return "";
		}

		if ((subvol.mount_point == "/home") && (subvol.name != App.home_subvolume_name)){
			return _("Only subvolumes on the system partition are supported");
		}

		return App.get_btrfs_subvolume_problem(subvol);
	}

	private bool is_selected(Subvolume subvol){
		if (is_root(subvol)){
			return true;
		}
		if (get_problem(subvol).length > 0){
			return false;
		}
		return App.is_btrfs_subvolume_included(subvol.mount_point, restore_mode);
	}

	private bool can_change(Subvolume subvol){
		return !is_root(subvol) && (get_problem(subvol).length == 0);
	}

	public void refresh(){

		var model = new Gtk.ListStore(1, typeof(Subvolume));
		treeview.model = model;

		TreeIter iter;

		if (restore_mode){
			if (App.snapshot_to_restore != null){
				foreach(var subvol in get_snapshot_subvolumes_sorted()){
					model.append(out iter);
					model.set (iter, 0, subvol);
				}
			}
		}
		else{
			foreach(var subvol in App.get_btrfs_system_subvolumes()){
				model.append(out iter);
				model.set (iter, 0, subvol);
			}
		}

		show_all();
	}

	// subvolumes of the snapshot to restore, the root subvolume first and
	// the others by mount point, like the subvolumes of the system
	private Gee.ArrayList<Subvolume> get_snapshot_subvolumes_sorted(){

		var list = App.snapshot_to_restore.subvolumes_sorted;

		list.sort((a, b) => {
			if (is_root(a) != is_root(b)){
				return is_root(a) ? -1 : 1;
			}
			if ((a.mount_point.length == 0) != (b.mount_point.length == 0)){
				return (a.mount_point.length == 0) ? 1 : -1;
			}
			int res = strcmp(a.mount_point, b.mount_point);
			return (res != 0) ? res : strcmp(a.name, b.name);
		});

		return list;
	}

	// true if the snapshot to restore contains subvolumes besides the root subvolume
	public static bool snapshot_has_optional_subvolumes(){

		if (App.snapshot_to_restore == null){
			return false;
		}

		string root_name = App.snapshot_to_restore.root_subvolume_name;

		foreach(var subvol in App.snapshot_to_restore.subvolumes.values){
			if (subvol.name != root_name){
				return true;
			}
		}

		return false;
	}
}
