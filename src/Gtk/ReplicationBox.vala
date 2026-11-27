/*
 * ReplicationBox.vala
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
 * Settings tab (BTRFS mode): the targets that receive copies of the
 * snapshots, see Replication.vala.
 */
class ReplicationBox : Gtk.Box{

	private Gtk.TreeView treeview;
	private Gtk.Window parent_window;

	public ReplicationBox (Gtk.Window _parent_window) {

		log_debug("ReplicationBox: ReplicationBox()");

		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6); // work-around
		parent_window = _parent_window;
		margin = 12;

		add_label_header(this, _("Replication"), true);

		add_label(this, escape_html(_("Send copies of the snapshots to another BTRFS disk or to another computer (SSH). The copies remain available if this disk fails.")), false, true);

		init_treeview();

		init_actions();

		add_note(_("Scheduled targets receive new snapshots every hour while they are connected. Each target keeps its own number of snapshots, older copies are removed from the target."));

		refresh();

		log_debug("ReplicationBox: ReplicationBox(): exit");
	}

	private void init_treeview(){

		treeview = new TreeView();
		treeview.get_selection().mode = SelectionMode.SINGLE;
		treeview.headers_visible = true;
		treeview.reorderable = false;

		treeview.row_activated.connect((path, column)=>{
			edit_clicked();
		});

		var scrolled = new ScrolledWindow(null, null);
		scrolled.set_shadow_type (ShadowType.ETCHED_IN);
		scrolled.add (treeview);
		scrolled.expand = true;
		add(scrolled);

		// column: scheduled -------------------------------------

		var col = new TreeViewColumn();
		col.title = _("Scheduled");
		treeview.append_column(col);

		var cell_toggle = new Gtk.CellRendererToggle();
		cell_toggle.xpad = 2;
		cell_toggle.activatable = true;
		col.pack_start (cell_toggle, false);

		col.set_cell_data_func (cell_toggle, (cell_layout, cell, model, iter)=>{
			ReplicationTarget target;
			model.get(iter, 0, out target);
			((Gtk.CellRendererToggle) cell).active = target.enabled;
		});

		cell_toggle.toggled.connect((cell, path)=>{
			var model = (Gtk.ListStore) treeview.model;
			TreeIter iter;
			model.get_iter_from_string (out iter, path);
			ReplicationTarget target;
			model.get(iter, 0, out target);
			target.enabled = !target.enabled;
			treeview.queue_draw();
			save_changes();
		});

		// column: name -------------------------------------

		col = new TreeViewColumn();
		col.title = _("Name");
		col.resizable = true;
		col.min_width = 120;
		treeview.append_column(col);

		var cell_text = new CellRendererText();
		cell_text.ellipsize = Pango.EllipsizeMode.END;
		col.pack_start (cell_text, true);

		col.set_cell_data_func (cell_text, (cell_layout, cell, model, iter)=>{
			ReplicationTarget target;
			model.get(iter, 0, out target);
			((Gtk.CellRendererText) cell).text = target.name;
		});

		// column: location -------------------------------------

		col = new TreeViewColumn();
		col.title = _("Location");
		col.resizable = true;
		col.expand = true;
		treeview.append_column(col);

		cell_text = new CellRendererText();
		cell_text.ellipsize = Pango.EllipsizeMode.MIDDLE;
		col.pack_start (cell_text, true);

		col.set_cell_data_func (cell_text, (cell_layout, cell, model, iter)=>{
			ReplicationTarget target;
			model.get(iter, 0, out target);
			((Gtk.CellRendererText) cell).text = target.location;
		});

		// column: last run -------------------------------------

		col = new TreeViewColumn();
		col.title = _("Last Run");
		treeview.append_column(col);

		var cell_icon = new CellRendererPixbuf();
		col.pack_start (cell_icon, false);

		cell_text = new CellRendererText();
		col.pack_start (cell_text, false);

		col.set_cell_data_func (cell_icon, (cell_layout, cell, model, iter)=>{
			ReplicationStatus status;
			model.get(iter, 1, out status);
			string icon_name = "";
			if (status.time > 0){
				icon_name = status.ok ? "xsi-emblem-ok-symbolic" : "xsi-dialog-warning-symbolic";
			}
			((Gtk.CellRendererPixbuf) cell).icon_name = icon_name;
		});

		col.set_cell_data_func (cell_text, (cell_layout, cell, model, iter)=>{
			ReplicationStatus status;
			model.get(iter, 1, out status);
			string txt = _("Never");
			if (status.time > 0){
				txt = new DateTime.from_unix_local(status.time).format(App.date_format);
			}
			((Gtk.CellRendererText) cell).text = txt;
		});

		treeview.has_tooltip = true;
		treeview.query_tooltip.connect(treeview_query_tooltip);
	}

	private bool treeview_query_tooltip(int x, int y, bool keyboard_tooltip, Tooltip tooltip){

		TreeModel model;
		TreePath path;
		TreeIter iter;

		if (!treeview.get_tooltip_context(ref x, ref y, keyboard_tooltip, out model, out path, out iter)){
			return false;
		}

		ReplicationTarget target;
		ReplicationStatus status;
		model.get(iter, 0, out target, 1, out status);

		string txt = "<b>%s</b>\n%s".printf(escape_html(target.name), escape_html(target.location));

		if (status.time == 0){
			txt += "\n\n" + escape_html(_("No snapshots were sent yet"));
		}
		else if (status.ok){
			txt += "\n\n" + escape_html(_("Snapshots sent in the last run") + ": %d".printf(status.sent));
		}
		else{
			txt += "\n\n" + escape_html(_("The last run failed") + ": %s".printf(status.message));
		}

		if (status.newest.length > 0){
			txt += "\n" + escape_html(_("Newest copy") + ": %s".printf(status.newest));
		}

		tooltip.set_markup(txt);
		treeview.set_tooltip_row(tooltip, path);
		return true;
	}

	private void init_actions(){

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		add(hbox);

		var size_group = new Gtk.SizeGroup(SizeGroupMode.HORIZONTAL);

		var button = add_button(hbox, _("Add"), _("Add a target"), size_group, null);
		button.clicked.connect(add_clicked);

		button = add_button(hbox, _("Edit"), _("Edit the selected target"), size_group, null);
		button.clicked.connect(edit_clicked);

		button = add_button(hbox, _("Remove"), _("Remove the selected target"), size_group, null);
		button.clicked.connect(remove_clicked);

		var label = new Gtk.Label("");
		label.hexpand = true;
		hbox.add(label);

		button = add_button(hbox, _("Send Now"), _("Send the snapshots to the selected target now"), size_group, null);
		button.clicked.connect(send_clicked);
	}

	public void refresh(){

		var model = new Gtk.ListStore(2, typeof(ReplicationTarget), typeof(ReplicationStatus));

		foreach(var target in App.replication_targets){
			TreeIter iter;
			model.append(out iter);
			model.set(iter, 0, target, 1, ReplicationStatus.load(target));
		}

		treeview.set_model(model);
	}

	private ReplicationTarget? get_selected(){

		TreeModel model;
		TreeIter iter;

		if (!treeview.get_selection().get_selected(out model, out iter)){
			gtk_messagebox(_("No Target Selected"), _("Select a target from the list"), parent_window, true);
			return null;
		}

		ReplicationTarget target;
		model.get(iter, 0, out target);
		return target;
	}

	// actions -------------------------------------

	private void add_clicked(){

		var target = new ReplicationTarget();
		target.name = (App.replication_targets.size == 0) ? _("Backup Disk") : "";

		var win = new ReplicationTargetWindow(parent_window, target, true);

		win.destroy.connect(()=>{
			if (win.accepted){
				App.replication_targets.add(target);
				save_changes();
				refresh();
			}
		});
	}

	private void edit_clicked(){

		var target = get_selected();
		if (target == null){
			return;
		}

		var win = new ReplicationTargetWindow(parent_window, target, false);

		win.destroy.connect(()=>{
			if (win.accepted){
				save_changes();
				refresh();
			}
		});
	}

	private void remove_clicked(){

		var target = get_selected();
		if (target == null){
			return;
		}

		string msg = _("The copies that were already sent are not removed from the target.");

		var dlg = new CustomMessageDialog(_("Remove target '%s'?").printf(target.name), escape_html(msg),
			Gtk.MessageType.QUESTION, parent_window, Gtk.ButtonsType.YES_NO);
		var response = dlg.run();
		dlg.destroy();

		if (response != Gtk.ResponseType.YES){
			return;
		}

		// the read-only snapshots kept for incremental transfers take up space
		Replication.remove_cache(target);

		App.replication_targets.remove(target);
		save_changes();
		refresh();
	}

	// the targets are saved right away, the cron job when the settings are closed
	private void save_changes(){
		ReplicationTarget.save_all(App.replication_targets, App.replication_conf_path);
		Replication.remove_orphaned_caches(App.replication_targets);
	}

	private void send_clicked(){

		var target = get_selected();
		if (target == null){
			return;
		}

		var win = new ReplicationWindow(parent_window, target);

		win.destroy.connect(()=>{
			save_changes(); // e.g. the filesystem of an SSH target was recorded
			refresh();
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
}
