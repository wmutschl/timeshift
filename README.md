# Timeshift

Timeshift for Linux is an application that provides functionality similar to the _System Restore_ feature in Windows and the _Time Machine_ tool in Mac OS. Timeshift protects your system by taking incremental snapshots of the file system at regular intervals. These snapshots can be restored at a later date to undo all changes to the system. 

In RSYNC mode, snapshots are taken using [rsync](https://rsync.samba.org) and [hard-links](https://en.wikipedia.org/wiki/Hard_link). Common files are shared between snapshots which saves disk space. Each snapshot is a full system backup that can be browsed with a file manager.

In BTRFS mode, snapshots are taken using the in-built features of the BTRFS filesystem. BTRFS snapshots are supported on BTRFS systems whose root filesystem is mounted from a subvolume (e.g. @ on Ubuntu and Linux Mint, root on Fedora). The home subvolume and other subvolumes can be included in snapshots.

Timeshift is similar to applications like [rsnapshot](https://www.rsnapshot.org), [BackInTime](https://github.com/bit-team/backintime) and [TimeVault](https://wiki.ubuntu.com/TimeVault) but with different goals. It is designed to protect only system files and settings. User files such as documents, pictures and music are excluded. This ensures that your files remain unchanged when you restore your system to an earlier date. If you need a tool to back up your documents and files please take a look at the excellent [BackInTime](https://github.com/bit-team/backintime) application which is more configurable and provides options for saving user files.  

![](images/main_window.png)

# History

Timeshift was originally developed and maintained by [Tony George](https://teejeetech.com/).

His original repository is still available on [Github](https://github.com/teejee2008/timeshift).

Nowadays Timeshift is part of the Xapp project which is a collection of cross-DE and cross-distributions applications which are maintained by [Linux Mint](https://www.linuxmint.com).

## Features

### Minimal Setup

*   Timeshift requires very little setup. Just install it, run it for the first time and take the first snapshot. Cron job can be enabled for taking automatic snapshots of the system at regular intervals. The backup levels can be selected from the _Settings_ window.

*   Snapshots are saved by default on the system (root) partition in path **/timeshift**. Other linux partitions can also be selected. For best results the snapshots should be saved to an external (non-system) partition.

![](images/settings_location.png)

### Multiple Snapshot Levels

*   Multiple levels of snapshots can be enabled - Hourly, Daily, Weekly, Monthly and Boot

*   Number of snapshots to retain can be specified for each level

*   Boot snapshots provide an additional level of backup and are created every time the system starts. Boot snapshots are created with a delay of 10 mins so that system startup is not affected.

*   Snapshots are tagged to indicate their time interval:
    - H: Hourly
    - D: Daily
    - W: Weekly
    - M: Monthly
    - B: Boot
    - O: On-demand (Manually created)
    - P: Packages (created before packages are installed, upgraded or removed, BTRFS only)

![](images/settings_schedule.png)

### Rsync & BTRFS Snapshots

* Supports rsync snapshots on all systems

* Supports BTRFS snapshots on BTRFS systems

It is strongly recommended to use BTRFS snapshots on systems that are installed on BTRFS partition. BTRFS snapshots are perfect byte-for-byte copies of the system. Nothing is excluded. BTRFS snapshots can be created and restored in seconds, and have very low overhead in terms of disk space.

  ![](images/settings_rsync.png)

  ![](images/settings_btrfs.png)

### Snapshots Before Package Operations (BTRFS)

* Select the level *Packages* in *Settings* > *Schedule* to create a snapshot before APT or DNF installs, upgrades or removes packages: from the terminal, the software updater or a software center (PackageKit, GNOME Software).

* The comment describes the operation, e.g. `Before apt install vlc` or `Before PackageKit: upgrade firefox, thunderbird +3 more`. The package manager shows one line, e.g. `Timeshift: Snapshot created before this package operation: 2026-11-26_20-24-02`.

* At most one snapshot is created every 5 minutes, so that a large upgrade or unattended-upgrades (which run dpkg several times) create one snapshot.

* The oldest snapshots are removed by the hourly task when there are more than the number to keep. A snapshot whose comment you changed is kept.

* To skip the snapshot for one operation: `sudo TIMESHIFT_SKIP_SNAPSHOT=1 apt install ...`

* The package manager never fails because of Timeshift. If no snapshot can be created, e.g. while the Timeshift window is open, the reason is printed and the operation continues. No snapshots are created in live sessions and in a chroot.

* APT: the hook is `/etc/apt/apt.conf.d/80timeshift`. DNF5 (Fedora 41 and later): the hook is `/etc/dnf/libdnf5-plugins/actions.d/timeshift.actions` and needs the package `libdnf5-plugin-actions`. Timeshift creates and removes these files when the option is changed.

* If *timeshift-autosnap-apt* is installed, remove it, otherwise two snapshots are created for each operation.

### Copies on Other Disks (BTRFS Replication)

* *Settings* > *Replication* sends copies of the snapshots to another BTRFS filesystem: a disk connected to this computer (e.g. a USB disk) or a directory on another computer (SSH). The copies are made with `btrfs send` and `btrfs receive`. After the first copy only the differences are sent.

* Each target keeps its own number of snapshots per level, e.g. 12 monthly, 4 weekly, 7 daily and 10 on-demand snapshots. Levels set to 0 are not sent. Older copies are removed from the target, the newest copy is always kept.

* Scheduled targets receive new snapshots every hour (`/etc/cron.d/timeshift-replicate`). A disk that is not connected or a computer that can't be reached is skipped, and nothing is mounted or connected when there are no new snapshots. *Send Now* sends to the selected target right away.

* The copies are stored like on the snapshot device: `<directory>/<hostname>_<uuid>/timeshift-btrfs/snapshots/<snapshot>/` with one read-only subvolume per snapshotted subvolume and the snapshot's `info.json`. They can be browsed to recover files.

* For incremental transfers Timeshift keeps a read-only snapshot of the newest copy of each target in `timeshift-btrfs/send-cache/` on the snapshot device. Removing a target removes its cache.

* Encrypted disks must be unlocked first, e.g. by the desktop when the disk is connected.

* SSH targets: Timeshift uses its own key, `/etc/timeshift/ssh/id_ed25519`, which is created by the target dialog. Add the public key to `~/.ssh/authorized_keys` of the user on the remote computer. The directory must be on a BTRFS filesystem. The commands on the remote computer must run as root: use the root account, or a user that may run `btrfs`, `mkdir`, `mv`, `rm`, `rmdir` and `tee` with sudo without a password (option *Use sudo on the remote computer*). Note that these commands give the user full access to the remote computer. The host key is accepted at the first connection (*Test Connection* shows its fingerprint). The filesystem of the directory is recorded at the first connection as well, nothing is sent if the directory is on another filesystem later, e.g. when the backup disk of the remote computer is not mounted.

* Command line: `timeshift --replicate` sends to all scheduled targets, `--replication-target <name>` to one target, `--dry-run` shows what would be sent and removed, `--list-targets` lists the targets with the result of their last run.

* The targets are stored in `/etc/timeshift/replication.json`.

### User Data is Excluded by Default
Timeshift is designed to protect system files and settings. It is NOT a backup tool and is not meant to protect user data. Entire contents of users' home directories are excluded by default. This has two advantages:

*   You don't need to worry about your documents getting overwritten when you restore a previous snapshot to recover the system.
*   Your music and video collection in your home directory will not waste space on the backup device.

You can selectively include items for backup from the ***Settings*** window. Selecting the option "*Include hidden items*" from the ***Users*** tab will back up and restore the .hidden files and directories in your home folder. These folders contain user-specific config files and can be included in snapshots if required.

*Note*: It is not recommended to include user data in backups as it will be overwritten when you restore the snapshot.

![](images/settings_users_rsync.png)

![](images/settings_filters.png)

*   Unlike similar tools that are scheduled to take backups at a fixed time of the day, Timeshift is designed to run once every hour and take snapshots only when a snapshot is due. This is more suitable for desktop users who keep their laptops and desktops switched on for few hours daily. Scheduling snapshots at a fixed time on such users will result in missed backups since the system may not be running when the snapshot is scheduled to run. By running once every hour and creating snapshots when due, Timeshift ensures that backups are not missed.
*   Applications like rsnapshot rotate a snapshot to the next level by creating a hard-linked copy. Creating a hard-linked copy may seem like a good idea but it is still a waste of disk space, since only files can be hard-linked and not directories. The duplicated directory structure can take up as much as 100 MB of space. Timeshift avoids this wastage by using tags for maintaining backup levels. Each snapshot will have only one copy on disk and is tagged as "daily", "monthly", etc. The snapshot location will have a set of folders for each backup level ("Monthly", "Daily", etc) with symbolic links pointing to the actual snapshots tagged with the level.

### System Restore
* Snapshots can be restored by selecting a snapshot from the main window and clicking *Restore* button on the toolbar. 

* Snapshots can be restored either from the running system (online restore) or from another system that has Timeshift installed on it (offline restore). 

* If the main system is not bootable, then it is possible to boot from an Ubuntu Live CD, install Timeshift on the live system, and restore a snapshot on the main system.

* Restoring backups from the running system requires a reboot to complete the restore process.

  ![](images/restore_summary.png)

### Incomplete snapshots

Incomplete snapshots don't show up in the restore list and are deleted when the next scheduled snapshot is taken.

### Cross-Distribution Restore

- You can also Timeshift across distributions. Let's say you are currently using Xubuntu and decide to try out Linux Mint. You install Linux Mint on your system and try it out for a week before deciding to go back to Xubuntu. Using Timeshift you can simply restore the last week's snapshot to get your Xubuntu system back. Timeshift will take care of things like reinstalling the bootloader and other details. 
- Since installing a new linux distribution also formats your root partition you need to save your snapshots on a separate linux partition for this to work.
- It is recommended to include hidden items in home directory by selecting the option "*Include  Hidden Items*" from *Settings* > *Users*.

### Post Restore Hooks

- Scripts can be run at the end of a restore job for anything that may need to be done prior to rebooting. The location for these scripts is `/etc/timeshift/restore-hooks.d`.  Note: the script(s) will be run from the restored filesystem.

## Supported System Configurations

- **Normal** - OS installed on non-encrypted partitions

- **LUKS Encrypted** - OS installed on LUKS-encrypted partitions

- **LVM2** - OS installed on LVM2 volumes (with or without LUKS)

- **BTRFS** - OS installed on BTRFS volumes (with or without LUKS)

  - The root filesystem must be mounted from a subvolume, e.g. **@** (Ubuntu, Linux Mint) or **root** (Fedora). The subvolumes are detected from the mount points, their names don't matter
  - The home subvolume and other subvolumes on the same BTRFS volume that are mounted from `/etc/fstab` (e.g. `/boot`, `/var` or `/var/log`) can be included in snapshots, and each of them can be selected for restore
  - The home subvolume may also be on a different BTRFS volume, and **/home** may be mounted on a non-BTRFS partition
  - If swap files are used they should not be located in a subvolume that is included in snapshots and could instead be stored in their own subvolume, eg **@swap**. Subvolumes with an active swap file are skipped
  - Separate partitions (e.g. `/boot`) can be handled via custom created hooks (placed in `/etc/timeshift/backup-hooks.d/` and `/etc/timeshift/restore-hooks.d/`). Script naming must match `run-parts` [requirements](https://manpages.ubuntu.com/manpages/noble/man8/run-parts.8.html). Current snapshot path is exported as `TS_SNAPSHOT_PATH`.
  - Layouts that run the system from the top-level subvolume (e.g. the default of the Ubuntu 24.04 desktop installer) or from nested subvolumes (e.g. openSUSE) are not supported

  - Default BTRFS subvolume must be /. You can make it using script below.

    ```shell
    MP="$(mktemp -d)"
    mount | awk '/on \/ type btrfs/{print $1}' | sudo xargs -I{} mount {} "$MP" && \
    sudo btrfs subvolume set-default 5 "$MP"; \
    sudo umount "$MP"
    ```

- **GRUB2** - Bootloader must be GRUB2. GRUB legacy and other bootloaders are not supported.

- **EFI** - EFI systems are supported. Make sure that ```/boot/efi``` partition is selected for mounting before restoring snapshots (application will do it automatically).


- **Encrypted Home** - For users with encrypted home, files in ```/home/.ecryptfs/$USER``` will be backed-up and restored. The decrypted contents in ```$HOME``` will be excluded. This avoids the security risk of decrypted contents becoming available outside the user's home directory.
- **Encrypted Private Directory** - For users with encrypted *Private* directory, the encrypted files in ```$HOME/.Private```, as well as the decrypted files in ```$HOME/Private```, will be excluded (as it contains user data). Filters added by user to include files from ```$HOME/.Private``` or ```$HOME/Private``` will be ignored.
- **Docker & Containers** - Docker and containerized systems are not supported. Running Timeshift on such systems will have unpredictable results.

## Installation

### Building and Installing from Source Code

You can find the exact instructions in the [development](/docs/development.md) docs.

### Debian-based Distributions

Debian, Ubuntu, Linux Mint, Elementary OS, etc.

Install Timeshift from the repositories:  

```sh
sudo apt-get update
sudo apt-get install timeshift
```

### Fedora

Fedora is not fully supported. BTRFS snapshots only support Ubuntu-specific layouts. 

```sh
sudo dnf update
sudo dnf install timeshift
```

### Arch

```sh
sudo pacman -S timeshift
```

### ALT

```sh
su -
apt-get update
apt-get install timeshift
```

## Removal

Run the following command in a terminal window:  

    sudo apt-get remove timeshift

or

    sudo dnf remove timeshift

or

    sudo pacman -R timeshift

or

    su - -c "apt-get remove timeshift"

depending on your package management system.

Remember to delete all snapshots before un-installing. Otherwise the snapshots continue to occupy space on your system.  To delete all snapshots, run the application, select all snapshots from the list (CTRL+A) and click the _Delete_ button on the toolbar. This will delete all snapshots and remove the _/timeshift_ folder in the root directory.     

In BTRFS mode, also uncheck *Packages* in *Settings* > *Schedule* and remove the targets in *Settings* > *Replication* before un-installing. Timeshift then removes the hook of the package manager (`/etc/apt/apt.conf.d/80timeshift` or `/etc/dnf/libdnf5-plugins/actions.d/timeshift.actions`) and `/etc/cron.d/timeshift-replicate`. The Debian package removes them as well.

## Known Issues & Limitations

#### BTRFS volumes
The root filesystem must be mounted from a subvolume (e.g. **@** or **root**). Systems that run from the top-level subvolume of the BTRFS volume are not supported. Systems having the root subvolume and having **/home** on a non-BTRFS partition are also supported.

`Text file busy / btrfs returned an error: 256 / Failed to create snapshot` can occur if you have a Linux swapfile mounted within a subvolume that is included in snapshots, which prevents snapshot from succeeding. Relocate the swapfile into its own subvolume, for example **@swap**.

#### grub-btrfs

*grub-btrfs* also lists the read-only snapshots that Timeshift keeps for replication. To hide them, add `"timeshift-btrfs/send-cache"` to `GRUB_BTRFS_IGNORE_PREFIX_PATH` in `/etc/default/grub-btrfs/config`.

#### Disk Space

Timeshift requires a lot of disk space to keep snapshot data. The device selected as snapshot device must have sufficient free space to store the snapshots that will be created. 

If the backup device is running out of space, try the following steps:

*   Reduce the number of backup levels - Uncheck the backup levels and keep only one selected
*   Reduce the number of snapshots that are kept - In the _Schedule_ tab set the number of snapshots to 5 or less.
*   You can also disable scheduled snapshots completely and create snapshots manually when required

#### Bootloader & EFI

* Only those systems are supported which use GRUB2 bootloader. Trying to create and restore snapshots on a system using older versions of GRUB will result in a non-bootable system.
* EFI systems are fully supported. Ensure that the ***/boot/efi*** partition is mapped while restoring a snapshot. It will be mapped automatically if detected.
* If you are restoring from Live CD/USB, and your installed system uses EFI mode, then you must boot from Live CD/USB in EFI mode.

## Contribute

You can contribute to this project in various ways:

- Submitting ideas, and reporting issues in the [tracker](https://github.com/linuxmint/timeshift/issues)
- Translating this application to other languages in [Launchpad](https://translations.launchpad.net/linuxmint/latest/+translations)
- Contributing code changes by fixing issues and submitting a pull request (do not modify translations, this is done in Launchpad)
- To get started with coding, see the [development](/docs/development.md) docs
