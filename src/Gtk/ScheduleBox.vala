/*
 * ScheduleBox.vala
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

using Gtk;
using Gee;

using TeeJee.Logging;
using TeeJee.FileSystem;
using TeeJee.JsonHelper;
using TeeJee.ProcessHelper;
using TeeJee.GtkHelper;
using TeeJee.System;
using TeeJee.Misc;

class ScheduleBox : Gtk.Box{
	
	private Gtk.Image img_shield;
	private Gtk.Label lbl_shield;
	private Gtk.Label lbl_shield_subnote;
	private Gtk.SizeGroup sg_title;
	private Gtk.SizeGroup sg_subtitle;
	private Gtk.SizeGroup sg_count;

	private Gtk.CheckButton chk_cron;
	private Gtk.CheckButton chk_package;
	private Gtk.SpinButton spin_package;
	private Gtk.Label lbl_package;
	
	private Gtk.Window parent_window;
	
	public ScheduleBox (Gtk.Window _parent_window) {

		log_debug("ScheduleBox: ScheduleBox()");
		
		//base(Gtk.Orientation.VERTICAL, 6); // issue with vala
		GLib.Object(orientation: Gtk.Orientation.VERTICAL, spacing: 6); // work-around
		parent_window = _parent_window;
		margin = 12;
		
		add_label_header(this, _("Select Snapshot Levels"), true);

		Gtk.CheckButton chk_m, chk_w, chk_d, chk_h, chk_b = null;
		Gtk.SpinButton spin_m, spin_w, spin_d, spin_h, spin_b;

		// monthly
		
		add_schedule_option(this, Tags.Monthly, _("Create one per month"), out chk_m, out spin_m);

		spin_m.set_value(App.count_monthly);
		//spin_m.sensitive = chk_m.active;
		spin_m.value_changed.connect(()=>{
			App.count_monthly = (int) spin_m.get_value();
		});
		
		// weekly
		
		add_schedule_option(this, Tags.Weekly, _("Create one per week"), out chk_w, out spin_w);

		spin_w.set_value(App.count_weekly);
		//spin_w.sensitive = chk_w.active;
		spin_w.value_changed.connect(()=>{
			App.count_weekly = (int) spin_w.get_value();
		});

		// daily
		
		add_schedule_option(this, Tags.Daily, _("Create one per day"), out chk_d, out spin_d);

		spin_d.set_value(App.count_daily);
		//spin_d.sensitive = chk_d.active;
		spin_d.value_changed.connect(()=>{
			App.count_daily = (int) spin_d.get_value();
		});

		// hourly
		
		add_schedule_option(this, Tags.Hourly, _("Create one per hour"), out chk_h, out spin_h);

		spin_h.set_value(App.count_hourly);
		//spin_h.sensitive = chk_h.active;
		spin_h.value_changed.connect(()=>{
			App.count_hourly = (int) spin_h.get_value();
		});

		// boot
		
		add_schedule_option(this, Tags.Boot, _("Create one per boot"), out chk_b, out spin_b);

		spin_b.set_value(App.count_boot);
		//spin_b.sensitive = chk_b.active;
		spin_b.value_changed.connect(()=>{
			App.count_boot = (int) spin_b.get_value();
		});

		// package manager

		add_schedule_option(this, Tags.Package, _("Create one before packages are installed, upgraded or removed"), out chk_package, out spin_package);

		spin_package.set_value(App.count_package);
		spin_package.value_changed.connect(()=>{
			App.count_package = (int) spin_package.get_value();
		});

		lbl_package = new Gtk.Label("");
		lbl_package.set_use_markup(true);
		lbl_package.xalign = 0.0f;
		lbl_package.wrap = true;
		lbl_package.wrap_mode = Pango.WrapMode.WORD;
		lbl_package.margin_start = 30;
		lbl_package.margin_end = 6;
		add(lbl_package);

		// cron emails --------------------------------------------------------------------
		
		chk_cron = add_checkbox(this, _("Stop cron emails for scheduled tasks"));
		//chk_cron.hexpand = true;
		chk_cron.set_tooltip_text(_("The cron service sends the output of scheduled tasks as an email to the current user. Select this option to suppress the emails for cron tasks created by Timeshift."));

		chk_cron.margin = 6;
		chk_cron.margin_top = 12;	
		
		chk_cron.active = App.stop_cron_emails;
		chk_cron.toggled.connect(()=>{
			App.stop_cron_emails = chk_cron.active;
		});

		var msg = "<i>• %s\n• %s\n• %s</i>".printf(
			_("Snapshots are not scheduled at fixed times."),
			_("A maintenance task runs once every hour and creates snapshots as needed."),
			_("Boot snapshots are created with a delay of 10 minutes after system startup."));

		// buffer
		var label = new Gtk.Label("");
		label.vexpand = true;
		add(label);
		
		// message area -------------------------------------------------------------------
		
		var scrolled = new Gtk.ScrolledWindow(null, null);
		scrolled.set_shadow_type (ShadowType.ETCHED_IN);
		scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
		scrolled.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
		scrolled.set_size_request(-1, 100);
		scrolled.margin_top = 6;
		scrolled.margin_bottom = 6;
		this.add(scrolled);

		label = new Gtk.Label(msg);
		label.set_use_markup(true);
		label.xalign = 0.0f;
		label.wrap = true;
		label.wrap_mode = Pango.WrapMode.WORD;
		label.margin = 6;
		scrolled.add(label);

		// status area --------------------------------------------------------------------
		
		scrolled = new Gtk.ScrolledWindow(null, null);
		scrolled.set_shadow_type (ShadowType.ETCHED_IN);
		scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
		scrolled.vscrollbar_policy = Gtk.PolicyType.NEVER;
		scrolled.set_size_request(-1, 100);
		add(scrolled);
		
		// hbox
		var hbox = new Gtk.Box(Orientation.HORIZONTAL, 6);
		hbox.margin = 6;
		hbox.margin_bottom = 12;
		scrolled.add (hbox);

        // img_shield
		img_shield = new Gtk.Image();
		img_shield.surface = IconManager.lookup_surface(IconManager.SHIELD_HIGH, IconManager.SHIELD_ICON_SIZE, img_shield.scale_factor);
		img_shield.margin_bottom = 6;
        hbox.add(img_shield);

		var vbox = new Gtk.Box(Orientation.VERTICAL, 6);
		vbox.margin_top = 6;
        hbox.add (vbox);
        
		// lbl_shield
		lbl_shield = add_label(vbox, "");
        lbl_shield.yalign = 0.5f;
        //lbl_shield.hexpand = true;

        // lbl_shield_subnote
		lbl_shield_subnote = add_label(vbox, "");
		lbl_shield_subnote.yalign = 0.5f;
		//lbl_shield_subnote.hexpand = true;

		lbl_shield_subnote.wrap = true;
		lbl_shield_subnote.wrap_mode = Pango.WrapMode.WORD;

		update_statusbar();

		log_debug("ScheduleBox: ScheduleBox(): exit");
    }

    private void set_shield_label(
		string text, bool is_bold = true, bool is_italic = false, bool is_large = true){
			
		string msg = "<span%s%s%s>%s</span>".printf(
			(is_bold ? " weight=\"bold\"" : ""),
			(is_italic ? " style=\"italic\"" : ""),
			(is_large ? " size=\"x-large\"" : ""),
			escape_html(text));
			
		lbl_shield.label = msg;
	}

	private void set_shield_subnote(
		string text, bool is_bold = false, bool is_italic = true, bool is_large = false){
			
		string msg = "<span%s%s%s>%s</span>".printf(
			(is_bold ? " weight=\"bold\"" : ""),
			(is_italic ? " style=\"italic\"" : ""),
			(is_large ? " size=\"x-large\"" : ""),
			escape_html(text));
			
		lbl_shield_subnote.label = msg;
	}

	private void add_schedule_option(
		Gtk.Box box, Tags period, string period_desc,
		out Gtk.CheckButton chk, out Gtk.SpinButton spin){

		var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
		hbox.margin = 6;
		hbox.margin_top = 1;
		hbox.margin_bottom = 1;
		box.add(hbox);

		if (sg_title == null){
			sg_title = new Gtk.SizeGroup(Gtk.SizeGroupMode.HORIZONTAL);
			sg_subtitle = new Gtk.SizeGroup(Gtk.SizeGroupMode.HORIZONTAL);
			sg_count = new Gtk.SizeGroup(Gtk.SizeGroupMode.HORIZONTAL);
		}
		
        var txt = "<b>%s</b>".printf(period.localized_name());
		Gtk.CheckButton check = add_checkbox(hbox, txt);
		check.set_tooltip_text(period_desc);
		chk = check;
		sg_title.add_widget(chk);

		check.active = period in App.schedule;
		check.toggled.connect(()=>{
			if(check.active) {
				App.schedule |= period; // add
			} else {
				App.schedule &= ~ period; // remove
			}
			chk_cron.sensitive = App.scheduled;
			update_statusbar();
		});
		
		var tt = _("Number of snapshots to keep.\nOlder snapshots will be removed once this limit is exceeded.");
		var label = add_label(hbox, "     " + _("Keep"));
		label.set_tooltip_text(tt);

		var spin2 = add_spin(hbox, 1, 999, 10);
		spin2.set_tooltip_text(tt);
		sg_count.add_widget(spin2);
		
		spin2.notify["sensitive"].connect(()=>{
			label.sensitive = spin2.sensitive;
		});

		spin = spin2;
	}

	// the package manager option is only available in BTRFS mode
	public void refresh_package_option(){

		string pm = PackageManagerHooks.get_package_manager();
		string msg = "";
		bool available = App.btrfs_mode && (pm.length > 0);

		if (!App.btrfs_mode){
			msg = _("Only available in BTRFS mode");
		}
		else if (pm == "apt"){
			msg = _("Snapshots are created when APT is used, e.g. by apt, the software updater or the software manager. The comment shows the package operation.");
		}
		else if ((pm == "dnf") && PackageManagerHooks.dnf_actions_plugin_installed()){
			msg = _("Snapshots are created when DNF is used, e.g. by dnf or GNOME Software. The comment shows the package operation.");
		}
		else if (pm == "dnf"){
			msg = _("Install the package libdnf5-plugin-actions to create snapshots before DNF transactions.");
		}
		else{
			msg = _("No supported package manager (APT or DNF) was found");
		}

		chk_package.sensitive = available;
		spin_package.sensitive = available;
		lbl_package.label = "<i>%s</i>".printf(escape_html(msg));
	}

	public void update_statusbar(){

		refresh_package_option();
		
		if (App.scheduled){

			img_shield.surface = IconManager.lookup_surface(IconManager.SHIELD_HIGH,
				IconManager.SHIELD_ICON_SIZE, img_shield.scale_factor);
			
			set_shield_label(_("Scheduled snapshots are enabled"));
			set_shield_subnote(_("Snapshots will be created at selected intervals if snapshot disk has enough space (> 1 GB)"));
		}
		else if (App.btrfs_mode && (Tags.Package in App.schedule)){

			img_shield.surface = IconManager.lookup_surface(IconManager.SHIELD_MED,
				IconManager.SHIELD_ICON_SIZE, img_shield.scale_factor);

			set_shield_label(_("Snapshots before package operations are enabled"));
			set_shield_subnote(_("Select the intervals for creating scheduled snapshots"));
		}
		else{
			img_shield.surface = IconManager.lookup_surface(IconManager.SHIELD_LOW,
				IconManager.SHIELD_ICON_SIZE, img_shield.scale_factor);
			
			set_shield_label(_("Scheduled snapshots are disabled"));
			set_shield_subnote(_("Select the intervals for creating snapshots"));
		}

		chk_cron.sensitive = App.scheduled;
	}
}
