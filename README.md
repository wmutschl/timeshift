# Timeshift for Fedora 33 BTRFS

This is a fork of Timeshift, where I changed the BTRFS layout to the flat one as in Fedora 33, i.e. root and home subvolumes. To install it do the following;

## Install for Fedora 33 with BTRFS
Requirements
```sh
sudo dnf install -y make vala libvala libgee-devel vte291-devel json-glib-devel

# maybe these packages are also needed, but probably not
# sudo dnf install libgee vte vte-devel vte291 vala-devel libvala-devel
```
Clone and make:
```bash
git clone https://github.com/wmutschl/timeshift.git
cd timeshift
make all
sudo make install
```

Currently, only the cli version of timeshift works with the subvolumes defined in your `/etc/timeshift/timeshift.json`. So make sure you set `btrfs_name_root` and `btrfs_name_home` correctly, e.g.:
```sh
{
  "backup_device_uuid" : "3681350c-08e5-4037-9ccc-12a79cf920fb",
  "parent_device_uuid" : "e7e7dc7d-70bb-49a3-a2bf-3179acb8cc0b",
  "do_first_run" : "false",
  "btrfs_mode" : "true",
  "include_btrfs_home_for_backup" : "true",
  "include_btrfs_home_for_restore" : "false",
  "stop_cron_emails" : "true",
  "btrfs_use_qgroup" : "true",
  "btrfs_name_root" : "root",
  "btrfs_name_home" : "home",
  "schedule_monthly" : "true",
  "schedule_weekly" : "true",
  "schedule_daily" : "true",
  "schedule_hourly" : "true",
  "schedule_boot" : "false",
  "count_monthly" : "2",
  "count_weekly" : "3",
  "count_daily" : "5",
  "count_hourly" : "6",
  "count_boot" : "5",
  "snapshot_size" : "0",
  "snapshot_count" : "0",
  "date_format" : "%Y-%m-%d %H:%M:%S",
  "exclude" : [],
  "exclude-apps" : []
}⏎ 
```

## To Do

- interface where one can define the names of the subvolumes
- autosnap functionality as in timeshift-autosnap-apt[https://github.com/wmutschl/timeshift-autosnap-apt]
