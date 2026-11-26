/*
 * ReplicationTargetWindow.vala
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
 * Adds or edits a replication target. A copy of the target is edited, the
 * target itself is changed when OK is clicked.
 */
class ReplicationTargetWindow : Gtk.Window{

	public bool accepted = false;

	private ReplicationTarget target;
	private ReplicationTarget edit;

	private Gtk.Box vbox_main;
	private Gtk.SizeGroup sg_label;
	private Gtk.Entry entry_name;
	private Gtk.RadioButton opt_local;
	private Gtk.RadioButton opt_ssh;
	private Gtk.Box box_local;
	private Gtk.Box box_ssh;
	private Gtk.ComboBoxText cmb_device;
	private Gtk.Entry entry_local_dir;
	private Gtk.Entry entry_host;
	private Gtk.SpinButton spin_port;
	private Gtk.Entry entry_user;
	private Gtk.Entry entry_ssh_dir;
	private Gtk.CheckButton chk_sudo;
	private Gtk.Label lbl_key;
	private Gtk.Label lbl_test;
	private Gtk.CheckButton chk_enabled;
	private Gee.HashMap<string, Gtk.SpinButton> spin_keep = new Gee.HashMap<string, Gtk.SpinButton>();

	private bool thread_is_running = false;
	private string tested_location = ""; // the SSH location of the last successful test

	public ReplicationTargetWindow(Gtk.Window parent, ReplicationTarget _target, bool is_new) {

		log_debug("ReplicationTargetWindow: ReplicationTargetWindow()");

		target = _target;
		edit = target.copy();

		this.title = is_new ? _("Add Target") : _("Edit Target");
		this.transient_for = parent;
		this.window_position = WindowPosition.CENTER_ON_PARENT;
		this.modal = true;
		this.resizable = false;
		this.icon = IconManager.lookup("timeshift",16);

		this.delete_event.connect(()=>{
			return thread_is_running; // keep open while connecting
		});

		vbox_main = new Gtk.Box(Orientation.VERTICAL, 6);
		vbox_main.margin = 12;
		add(vbox_main);

		sg_label = new Gtk.SizeGroup(SizeGroupMode.HORIZONTAL);

		init_name();

		init_location();

		init_keep();

		init_actions();

		show_all();

		update_kind();

		log_debug("ReplicationTargetWindow: ReplicationTargetWindow(): exit");
	}

	private void init_name(){

		var hbox = add_row(vbox_main, _("Name"));

		entry_name = new Gtk.Entry();
		entry_name.text = edit.name;
		entry_name.hexpand = true;
		entry_name.activates_default = true;
		hbox.add(entry_name);
	}

	private void init_location(){

		var label = add_label_header(vbox_main, _("Location"));
		label.margin_top = 12;

		var hbox = new Gtk.Box(Orientation.HORIZONTAL, 12);
		vbox_main.add(hbox);

		opt_local = new Gtk.RadioButton.with_label_from_widget(null, _("Disk"));
		opt_local.set_tooltip_text(_("A BTRFS disk connected to this computer, e.g. a USB disk"));
		hbox.add(opt_local);

		opt_ssh = new Gtk.RadioButton.with_label_from_widget(opt_local, _("Remote Computer (SSH)"));
		opt_ssh.set_tooltip_text(_("A BTRFS filesystem on another computer, reached with SSH"));
		hbox.add(opt_ssh);

		opt_local.active = !edit.is_ssh;
		opt_ssh.active = edit.is_ssh;

		opt_local.toggled.connect(update_kind);

		init_local();

		init_ssh();
	}

	private void init_local(){

		box_local = new Gtk.Box(Orientation.VERTICAL, 6);
		vbox_main.add(box_local);

		var hbox = add_row(box_local, _("Device"));

		cmb_device = new Gtk.ComboBoxText();
		cmb_device.hexpand = true;
		hbox.add(cmb_device);

		var button = new Gtk.Button.from_icon_name("xsi-view-refresh-symbolic", IconSize.BUTTON);
		button.set_tooltip_text(_("Refresh the list of devices"));
		button.clicked.connect(refresh_devices);
		hbox.add(button);

		hbox = add_row(box_local, _("Directory"));

		entry_local_dir = new Gtk.Entry();
		entry_local_dir.text = edit.is_ssh ? "timeshift-replicas" : edit.path;
		entry_local_dir.hexpand = true;
		entry_local_dir.set_tooltip_text(_("Directory on the device, relative to its top level"));
		hbox.add(entry_local_dir);

		add_note(box_local, _("Only BTRFS devices are listed, encrypted devices must be unlocked first. The device is mounted while snapshots are sent."));

		refresh_devices();
	}

	private void refresh_devices(){

		string selected = cmb_device.active_id ?? edit.device_uuid;

		cmb_device.remove_all();

		var added = new Gee.HashSet<string>();

		foreach(var dev in Device.get_filesystems()){

			if ((dev.fstype != "btrfs") || (dev.uuid.length == 0) || added.contains(dev.uuid)){
				continue;
			}

			// the snapshots are already on this device
			if ((App.repo != null) && (App.repo.device != null) && (App.repo.device.uuid == dev.uuid)){
				continue;
			}

			added.add(dev.uuid);
			cmb_device.append(dev.uuid, device_description(dev));
		}

		if ((selected.length > 0) && !added.contains(selected)){
			cmb_device.append(selected, "UUID=%s (%s)".printf(selected, _("not connected")));
		}

		if (!cmb_device.set_active_id(selected) && (added.size > 0)){
			cmb_device.active = 0;
		}
	}

	private void init_ssh(){

		box_ssh = new Gtk.Box(Orientation.VERTICAL, 6);
		vbox_main.add(box_ssh);

		var hbox = add_row(box_ssh, _("Host"));

		entry_host = new Gtk.Entry();
		entry_host.text = edit.host;
		entry_host.hexpand = true;
		entry_host.placeholder_text = "nas.local";
		hbox.add(entry_host);

		var label = new Gtk.Label(_("Port"));
		hbox.add(label);

		spin_port = new Gtk.SpinButton.with_range(1, 65535, 1);
		spin_port.value = edit.port;
		hbox.add(spin_port);

		hbox = add_row(box_ssh, _("User"));

		entry_user = new Gtk.Entry();
		entry_user.text = edit.user;
		entry_user.hexpand = true;
		hbox.add(entry_user);

		hbox = add_row(box_ssh, _("Directory"));

		entry_ssh_dir = new Gtk.Entry();
		entry_ssh_dir.text = edit.is_ssh ? edit.path : "";
		entry_ssh_dir.hexpand = true;
		entry_ssh_dir.placeholder_text = "/mnt/backup/timeshift";
		entry_ssh_dir.set_tooltip_text(_("Absolute path of a directory on a BTRFS filesystem of the remote computer"));
		hbox.add(entry_ssh_dir);

		chk_sudo = new Gtk.CheckButton.with_label(_("Use sudo on the remote computer"));
		chk_sudo.set_tooltip_text(_("Needed if the user is not root. The user must be allowed to run btrfs with sudo without a password."));
		chk_sudo.active = edit.use_sudo;
		box_ssh.add(chk_sudo);

		// public key

		hbox = add_row(box_ssh, _("Key"));
		hbox.valign = Align.START;

		lbl_key = new Gtk.Label("");
		lbl_key.xalign = (float) 0.0;
		lbl_key.selectable = true;
		lbl_key.wrap = true;
		lbl_key.wrap_mode = Pango.WrapMode.CHAR;
		lbl_key.max_width_chars = 50;
		lbl_key.hexpand = true;
		hbox.add(lbl_key);

		var button = new Gtk.Button.from_icon_name("xsi-edit-copy-symbolic", IconSize.BUTTON);
		button.set_tooltip_text(_("Copy the key"));
		button.valign = Align.START;
		hbox.add(button);

		button.clicked.connect(()=>{
			var clipboard = Gtk.Clipboard.get_for_display(get_display(), Gdk.SELECTION_CLIPBOARD);
			clipboard.set_text(lbl_key.label, -1);
		});

		add_note(box_ssh, _("Add this key to ~/.ssh/authorized_keys of the user on the remote computer, e.g. with:") + "\nsudo ssh-copy-id -i %s.pub user@host".printf(ReplicationTarget.SSH_KEY));

		// test

		hbox = new Gtk.Box(Orientation.HORIZONTAL, 6);
		box_ssh.add(hbox);

		button = new Gtk.Button.with_label(_("Test Connection"));
		button.valign = Align.START;
		button.clicked.connect(test_clicked);
		hbox.add(button);

		lbl_test = new Gtk.Label("");
		lbl_test.xalign = (float) 0.0;
		lbl_test.use_markup = true;
		lbl_test.wrap = true;
		lbl_test.wrap_mode = Pango.WrapMode.WORD_CHAR;
		lbl_test.max_width_chars = 50;
		lbl_test.selectable = true;
		lbl_test.hexpand = true;
		hbox.add(lbl_test);
	}

	private void init_keep(){

		var label = add_label_header(vbox_main, _("Keep on the Target"));
		label.margin_top = 12;

		var grid = new Gtk.Grid();
		grid.column_spacing = 6;
		grid.row_spacing = 6;
		vbox_main.add(grid);

		Tags[] levels = { Tags.Monthly, Tags.Weekly, Tags.Daily, Tags.Hourly, Tags.Boot, Tags.OnDemand, Tags.Package };

		string tt = _("Number of snapshots to keep on the target.\nSnapshots of this level are not sent if the number is 0.");

		int index = 0;
		foreach(var level in levels){

			int col = (index < 4) ? 0 : 2;
			int row = (index < 4) ? index : index - 4;

			label = new Gtk.Label(level.localized_name());
			label.xalign = (float) 0.0;
			label.margin_start = (col == 0) ? 0 : 18;
			label.set_tooltip_text(tt);
			grid.attach(label, col, row, 1, 1);

			var spin = new Gtk.SpinButton.with_range(0, 999, 1);
			spin.value = edit.policy.get_keep(level.name());
			spin.set_tooltip_text(tt);
			grid.attach(spin, col + 1, row, 1, 1);

			spin_keep[level.name()] = spin;
			index++;
		}

		chk_enabled = new Gtk.CheckButton.with_label(_("Send new snapshots every hour (scheduled)"));
		chk_enabled.active = edit.enabled;
		chk_enabled.margin_top = 12;
		vbox_main.add(chk_enabled);
	}

	private void init_actions(){

		var bbox = new Gtk.ButtonBox(Gtk.Orientation.HORIZONTAL);
		bbox.set_layout(Gtk.ButtonBoxStyle.END);
		bbox.spacing = 6;
		bbox.margin_top = 12;
		vbox_main.add(bbox);

		var btn_cancel = new Gtk.Button.with_label(_("Cancel"));
		bbox.add(btn_cancel);

		btn_cancel.clicked.connect(()=>{
			if (!thread_is_running){
				this.destroy();
			}
		});

		var btn_ok = new Gtk.Button.with_label(_("OK"));
		btn_ok.can_default = true;
		bbox.add(btn_ok);
		this.set_default(btn_ok);

		btn_ok.clicked.connect(ok_clicked);
	}

	private void update_kind(){

		box_local.visible = opt_local.active;
		box_ssh.visible = opt_ssh.active;

		if (opt_ssh.active && (lbl_key.label.length == 0)){
			refresh_key();
		}

		this.resize(1, 1); // shrink to the visible widgets
	}

	private void refresh_key(){

		string error = "";

		if ((edit.identity_file.length == 0) && !ReplicationTarget.create_ssh_key(out error)){
			lbl_key.label = _("The SSH key could not be created") + ": " + error;
			return;
		}

		string pub = edit.ssh_identity + ".pub";
		lbl_key.label = file_exists(pub) ? file_read(pub).strip() : _("File not found") + ": " + pub;
	}

	private void read_fields(){

		edit.name = entry_name.text.strip();
		edit.kind = opt_ssh.active ? "ssh" : "local";
		edit.device_uuid = cmb_device.active_id ?? "";
		edit.host = entry_host.text.strip();
		edit.port = (int) spin_port.value;
		edit.user = entry_user.text.strip();
		edit.use_sudo = chk_sudo.active;
		edit.path = (edit.is_ssh ? entry_ssh_dir.text : entry_local_dir.text).strip();
		edit.enabled = chk_enabled.active;

		foreach(string level in spin_keep.keys){
			edit.policy.set_keep(level, (int) spin_keep[level].value);
		}

		// the recorded filesystem belongs to the location it was recorded for
		if (edit.is_ssh && (location_key(edit) != location_key(target)) && (location_key(edit) != tested_location)){
			edit.fs_uuid = "";
		}
	}

	private static string location_key(ReplicationTarget t){
		return "%s@%s:%d:%s".printf(t.user, t.host, t.port, t.path);
	}

	private void test_clicked(){

		if (thread_is_running){
			return;
		}

		read_fields();

		string msg = edit.validate();
		if (msg.length > 0){
			lbl_test.label = escape_html(msg);
			return;
		}

		lbl_test.label = escape_html(_("Connecting..."));

		var tested = edit.copy();
		var conn = new SshReplicationConnection(tested);
		bool ok = false;

		try{
			thread_is_running = true;
			new Thread<void>.try ("ssh-test", () => {
				ok = conn.open(false);
				thread_is_running = false;
			});
		}
		catch (Error e){
			log_error(e.message);
			thread_is_running = false;
		}

		gtk_set_busy(true, this);

		while (thread_is_running){
			gtk_do_events();
			sleep(100);
		}

		gtk_set_busy(false, this);

		if (!ok && conn.fs_mismatch){
			string question = _("The directory is on another filesystem than before. Snapshots are only sent to the filesystem that was found at the first connection, so that nothing is sent to the wrong disk. Use the new filesystem from now on?");
			var dlg = new CustomMessageDialog(_("Another Filesystem"), escape_html(question), Gtk.MessageType.QUESTION, this, Gtk.ButtonsType.YES_NO);
			var response = dlg.run();
			dlg.destroy();
			if (response == Gtk.ResponseType.YES){
				tested.fs_uuid = conn.found_fs_uuid;
				ok = true;
			}
		}

		if (ok){
			edit.fs_uuid = tested.fs_uuid;
			tested_location = location_key(edit);

			string txt = "<b>%s</b>".printf(escape_html(_("Connected")));
			string fingerprint = edit.get_host_key_fingerprint();
			if (fingerprint.length > 0){
				txt += "\n" + escape_html(_("Host key") + ": " + fingerprint);
			}
			lbl_test.label = txt;
		}
		else{
			lbl_test.label = "<b>%s</b>\n%s".printf(escape_html(_("Connection failed")), escape_html(conn.error_message));
		}
	}

	private void ok_clicked(){

		if (thread_is_running){
			return;
		}

		read_fields();

		string msg = edit.validate();

		if (msg.length == 0){
			// names are used on the command line (--replication-target)
			foreach(var other in App.replication_targets){
				if ((other != target) && (other.name == edit.name)){
					msg = _("Another target has the same name");
				}
			}
		}

		if (msg.length > 0){
			gtk_messagebox(_("Invalid Settings"), escape_html(msg), this, true);
			return;
		}

		target.copy_from(edit);
		accepted = true;
		this.destroy();
	}

	// helpers ----------------------------

	// e.g. "Backup (sdb1, 2 TB, Portable SSD T7)": the label and the model
	// make it easy to recognize a USB disk
	private static string device_description(Device dev){

		string txt = dev.short_name_with_parent;

		if (dev.size_bytes > 0){
			txt += ", " + format_file_size(dev.size_bytes, false, "", true, 0);
		}

		var disk = dev;
		while (disk.has_parent()){
			disk = disk.parent;
		}
		if (disk.model.strip().length > 0){
			txt += ", " + disk.model.strip();
		}

		return (dev.label.length > 0) ? "%s (%s)".printf(dev.label, txt) : txt;
	}

	private Gtk.Box add_row(Gtk.Box box, string text){

		var hbox = new Gtk.Box(Orientation.HORIZONTAL, 6);
		box.add(hbox);

		var label = new Gtk.Label(text);
		label.xalign = (float) 0.0;
		label.valign = Align.CENTER;
		sg_label.add_widget(label);
		hbox.add(label);

		return hbox;
	}

	private void add_note(Gtk.Box box, string text){

		var label = new Gtk.Label("<i>%s</i>".printf(escape_html(text)));
		label.set_use_markup(true);
		label.xalign = (float) 0.0;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD_CHAR;
		label.max_width_chars = 60;
		label.selectable = true;
		box.add(label);
	}
}
