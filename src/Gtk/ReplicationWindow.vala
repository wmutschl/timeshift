/*
 * ReplicationWindow.vala
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
 * Sends the snapshots to one target and shows the progress.
 */
class ReplicationWindow : Gtk.Window{

	private Gtk.Label lbl_status;
	private Gtk.Label lbl_details;
	private Gtk.ProgressBar progressbar;
	private Gtk.Button btn_cancel;
	private Gtk.Button btn_close;

	private ReplicationTarget target;
	private Replication replication;
	private AppLock replication_lock;
	private bool thread_is_running = false;
	private bool success = false;
	private uint tmr_init = 0;

	// transfer rate
	private GLib.Timer timer;
	private double last_time = 0;
	private int64 last_bytes = 0;
	private double rate = 0;

	public ReplicationWindow(Gtk.Window parent, ReplicationTarget _target) {

		log_debug("ReplicationWindow: ReplicationWindow()");

		target = _target;
		replication = new Replication(target);

		this.title = _("Send Snapshots");
		this.transient_for = parent;
		this.window_position = WindowPosition.CENTER_ON_PARENT;
		this.modal = true;
		this.set_default_size(500, -1);
		this.icon = IconManager.lookup("timeshift",16);

		this.delete_event.connect(()=>{
			if (thread_is_running){
				cancel();
				return true; // closed when the thread has stopped
			}
			return false;
		});

		var vbox = new Gtk.Box(Orientation.VERTICAL, 6);
		vbox.margin = 12;
		add(vbox);

		var header = add_label_header(vbox, _("Sending snapshots to '%s'").printf(target.name), true);
		header.wrap = false; // a wrapping label makes the window taller than needed
		header.ellipsize = Pango.EllipsizeMode.END;

		var label = new Gtk.Label(target.location);
		label.xalign = (float) 0.0;
		label.ellipsize = Pango.EllipsizeMode.MIDDLE;
		label.margin_bottom = 12;
		vbox.add(label);

		progressbar = new Gtk.ProgressBar();
		progressbar.show_text = true;
		progressbar.text = "";
		vbox.add(progressbar);

		lbl_status = new Gtk.Label("");
		lbl_status.xalign = (float) 0.0;
		lbl_status.ellipsize = Pango.EllipsizeMode.MIDDLE;
		vbox.add(lbl_status);

		// one line while running, the size of the window must not change
		lbl_details = new Gtk.Label("");
		lbl_details.xalign = (float) 0.0;
		lbl_details.use_markup = true;
		lbl_details.ellipsize = Pango.EllipsizeMode.END;
		vbox.add(lbl_details);

		var bbox = new Gtk.ButtonBox(Gtk.Orientation.HORIZONTAL);
		bbox.set_layout(Gtk.ButtonBoxStyle.END);
		bbox.margin_top = 12;
		vbox.add(bbox);

		btn_cancel = new Gtk.Button.with_label(_("Cancel"));
		bbox.add(btn_cancel);
		btn_cancel.clicked.connect(cancel);

		btn_close = new Gtk.Button.with_label(_("Close"));
		bbox.add(btn_close);
		btn_close.clicked.connect(()=>{
			this.destroy();
		});

		show_all();

		btn_close.visible = false;

		tmr_init = Timeout.add(100, init_delayed);

		log_debug("ReplicationWindow: ReplicationWindow(): exit");
	}

	private bool init_delayed(){

		if (tmr_init > 0){
			Source.remove(tmr_init);
			tmr_init = 0;
		}

		run_replication();

		return false;
	}

	private void run_replication(){

		// scheduled runs (timeshift --replicate) use the same lock
		replication_lock = new AppLock();
		if (!replication_lock.create("timeshift-replicate", "replicate")){
			finish(false, _("Snapshots are being sent in the background. Try again later."));
			return;
		}

		try{
			thread_is_running = true;
			new Thread<void>.try ("replication", () => {
				success = replication.run();
				thread_is_running = false;
			});
		}
		catch (Error e){
			log_error(e.message);
			thread_is_running = false;
			replication_lock.remove();
			finish(false, e.message);
			return;
		}

		timer = new GLib.Timer();
		Timeout.add(200, update_progress);
	}

	// called every 200 ms while the thread is running
	private bool update_progress(){

		if (!thread_is_running){
			replication_lock.remove();
			finish(success, replication.error_message);
			return false;
		}

		int total = replication.snapshots_to_send;
		int sent = replication.snapshots_sent;

		if (total > 0){
			progressbar.fraction = (double) sent / total;
			progressbar.text = _("%d of %d snapshots").printf(sent, total);
		}
		else{
			progressbar.pulse();
		}

		lbl_status.label = replication.status_line;

		// transfer rate, updated every 2 seconds
		double now = timer.elapsed();
		int64 bytes = replication.bytes_transferred;
		if (now - last_time >= 2.0){
			rate = (bytes - last_bytes) / (now - last_time);
			last_time = now;
			last_bytes = bytes;
		}

		if (bytes > 0){
			lbl_details.label = escape_html(_("Transferred") + ": %s (%s/s)".printf(
				format_file_size(bytes), format_file_size((uint64) rate)));
		}

		#if XAPP
		XApp.set_window_progress(this, (int) (progressbar.fraction * 100));
		#endif

		return true;
	}

	private void cancel(){
		btn_cancel.sensitive = false;
		lbl_status.label = _("Cancelling...");
		replication.cancel();
	}

	private void finish(bool ok, string message){

		btn_cancel.visible = false;
		btn_close.visible = true;
		btn_close.grab_focus();

		if (ok){
			progressbar.fraction = 1.0;
			progressbar.text = _("%d of %d snapshots").printf(replication.snapshots_sent, replication.snapshots_to_send);
			lbl_status.label = (replication.snapshots_to_send == 0) ? _("The target is up to date") : _("Completed");

			// average rate of the whole run
			int64 bytes = replication.bytes_transferred;
			double seconds = (timer != null) ? timer.elapsed() : 0;
			if ((bytes > 0) && (seconds > 0)){
				lbl_details.label = escape_html(_("Transferred") + ": %s (%s/s)".printf(
					format_file_size(bytes), format_file_size((uint64) (bytes / seconds))));
			}
		}
		else if (replication.was_cancelled){
			lbl_status.label = _("Cancelled");
			lbl_details.label = "";
		}
		else{
			progressbar.fraction = 0.0;
			progressbar.text = "";
			lbl_status.label = _("Failed");
			lbl_details.ellipsize = Pango.EllipsizeMode.NONE;
			lbl_details.wrap = true;
			lbl_details.wrap_mode = Pango.WrapMode.WORD_CHAR;
			lbl_details.max_width_chars = 60;
			lbl_details.selectable = true;
			lbl_details.label = "<b>%s</b>".printf(escape_html(message));
		}

		#if XAPP
		XApp.set_window_progress(this, 0);
		#endif
	}
}
