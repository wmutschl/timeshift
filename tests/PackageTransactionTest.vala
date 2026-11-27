/*
 * PackageTransactionTest.vala
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 */

// input recorded from a DPkg::Pre-Install-Pkgs hook with protocol version 3
// (apt-get install -y -q cowsay sl on Ubuntu 26.04, configuration shortened)
const string APT_INSTALL = """VERSION 3
binary=apt-get
Version::2.0::Dpkg::Lock::Timeout=120
APT::Architecture=amd64
CommandLine::AsString=apt-get%20install%20-y%20-q%20cowsay%20sl

cowsay - - none < 3.03+dfsg2-8build1 all none /var/cache/apt/archives/cowsay_3.03+dfsg2-8build1_all.deb
sl - - none < 5.02-1build1 amd64 none /var/cache/apt/archives/sl_5.02-1build1_amd64.deb
cowsay - - none < 3.03+dfsg2-8build1 all none **CONFIGURE**
sl - - none < 5.02-1build1 amd64 none **CONFIGURE**
""";

const string APT_REMOVE = """VERSION 3
binary=apt-get
CommandLine::AsString=apt-get%20remove%20-y%20-q%20sl

sl 5.02-1build1 amd64 none > - - none **REMOVE**
""";

// e.g. PackageKit: no command line of a command line program
const string APT_UPGRADE_GUI = """VERSION 3
APT::Architecture=amd64

libfoo 1.0 amd64 same < 1.1 amd64 same /var/cache/apt/archives/libfoo_1.1_amd64.deb
libbar 2.0 amd64 same < 2.1 amd64 same /var/cache/apt/archives/libbar_2.1_amd64.deb
baz 3.0 amd64 none < 3.1 amd64 none /var/cache/apt/archives/baz_3.1_amd64.deb
qux 4.0 amd64 none < 4.1 amd64 none /var/cache/apt/archives/qux_4.1_amd64.deb
old 1.0 amd64 none > 0.9 amd64 none /var/cache/apt/archives/old_0.9_amd64.deb
same 1.0 amd64 none = 1.0 amd64 none /var/cache/apt/archives/same_1.0_amd64.deb
new - - none < 1.0 all none /var/cache/apt/archives/new_1.0_all.deb
gone 1.0 amd64 none > - - none **REMOVE**
""";

void test_apt_install(){
	var trans = PackageTransaction.from_apt_hook_input(APT_INSTALL);
	assert(trans.command_line == "apt-get install -y -q cowsay sl");
	assert(trans.installs.size == 2);
	assert(trans.upgrades.size == 0);
	assert(!trans.alternate_root);
	assert(trans.get_summary() == "install cowsay, sl");
	assert(trans.get_comment() == "Before apt-get install cowsay sl");
}

void test_apt_remove(){
	var trans = PackageTransaction.from_apt_hook_input(APT_REMOVE);
	assert(trans.removes.size == 1);
	assert(trans.removes[0] == "sl");
	assert(trans.get_comment() == "Before apt-get remove sl");
}

void test_apt_gui(){
	var trans = PackageTransaction.from_apt_hook_input(APT_UPGRADE_GUI);
	assert(trans.command_line == "");
	assert(trans.upgrades.size == 4);
	assert(trans.downgrades.size == 1);
	assert(trans.reinstalls.size == 1);
	assert(trans.installs.size == 1);
	assert(trans.removes.size == 1);
	assert(trans.get_summary() == "install new; upgrade baz, libbar, libfoo +1 more; downgrade old; reinstall same; remove gone");
	assert(trans.get_comment() == "Before " + trans.get_summary());
}

void test_apt_frontends(){
	string packagekit = "VERSION 3\nCommandLine::AsString=/usr/libexec/packagekitd\n\nvlc - - none < 3.0 amd64 none /var/cache/apt/archives/vlc.deb\n";
	assert(PackageTransaction.from_apt_hook_input(packagekit).get_comment() == "Before PackageKit: install vlc");

	string alternate = "VERSION 3\nRootDir=/target\nCommandLine::AsString=apt-get%20install%20vlc\n\n";
	assert(PackageTransaction.from_apt_hook_input(alternate).alternate_root);

	string chroot = "VERSION 3\nDPkg::Chroot-Directory=/mnt\n\n";
	assert(PackageTransaction.from_apt_hook_input(chroot).alternate_root);

	string root = "VERSION 3\nRootDir=/\nDir=/\n\n";
	assert(!PackageTransaction.from_apt_hook_input(root).alternate_root);
}

void test_command_line(){
	assert(PackageTransaction.from_command_line("dnf install -y vlc").get_comment() == "Before dnf install vlc");
	assert(PackageTransaction.from_command_line("/usr/bin/dnf5 upgrade --assumeyes").get_comment() == "Before dnf5 upgrade");
	assert(PackageTransaction.from_command_line("/usr/bin/python3 /usr/bin/unattended-upgrade").get_comment() == "Before package changes (unattended-upgrades)");
	assert(PackageTransaction.from_command_line("/usr/libexec/dnf5daemon-server").get_comment() == "Before package changes (dnf5daemon)");
	assert(PackageTransaction.from_command_line("").get_comment() == "Before package changes");
}

void test_sanitize(){
	// grub-btrfs splits info.json lines on " : "; no control characters; no credentials
	assert(PackageTransaction.from_command_line("apt install a : b").get_comment() == "Before apt install a: b");
	assert(PackageTransaction.from_command_line("apt install a\tb").get_comment() == "Before apt install a b");
	assert(PackageTransaction.from_command_line("dnf install https://user:secret@example.com/x.rpm").get_comment() == "Before dnf install https://***@example.com/x.rpm");
	// grub-btrfs uses the comment in a single-quoted GRUB menu title and splits columns at '|'
	assert(PackageTransaction.from_command_line("apt install ./Bob's|tool.deb").get_comment() == "Before apt install ./Bob\u2019s\u00a6tool.deb");
}

void test_truncate(){
	var trans = PackageTransaction.from_command_line("apt install " + string.nfill(200, 'x'));
	string txt = trans.get_comment(20);
	assert(txt.char_count() == 20);
	assert(txt.has_suffix("..."));
	assert(trans.get_comment().char_count() == 120);
}

int main(string[] args){
	Test.init(ref args);
	Test.add_func("/package-transaction/apt-install", test_apt_install);
	Test.add_func("/package-transaction/apt-remove", test_apt_remove);
	Test.add_func("/package-transaction/apt-gui", test_apt_gui);
	Test.add_func("/package-transaction/apt-frontends", test_apt_frontends);
	Test.add_func("/package-transaction/sanitize", test_sanitize);
	Test.add_func("/package-transaction/command-line", test_command_line);
	Test.add_func("/package-transaction/truncate", test_truncate);
	return Test.run();
}
