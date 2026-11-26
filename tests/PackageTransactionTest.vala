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
	assert(trans.get_summary() == "install cowsay sl");
	assert(trans.get_description() == "apt-get install cowsay sl");
}

void test_apt_remove(){
	var trans = PackageTransaction.from_apt_hook_input(APT_REMOVE);
	assert(trans.removes.size == 1);
	assert(trans.removes[0] == "sl");
	assert(trans.get_description() == "apt-get remove sl");
}

void test_apt_gui(){
	var trans = PackageTransaction.from_apt_hook_input(APT_UPGRADE_GUI);
	assert(trans.command_line == "");
	assert(trans.upgrades.size == 4);
	assert(trans.downgrades.size == 1);
	assert(trans.reinstalls.size == 1);
	assert(trans.installs.size == 1);
	assert(trans.removes.size == 1);
	assert(trans.get_description(200) == "install new, upgrade 4 packages, downgrade old, reinstall same, remove gone");
}

void test_command_line(){
	assert(PackageTransaction.from_command_line("dnf install -y vlc").get_description() == "dnf install vlc");
	assert(PackageTransaction.from_command_line("/usr/bin/dnf5 upgrade --assumeyes").get_description() == "dnf5 upgrade");
	// not a command line program: no description from the command line
	assert(PackageTransaction.from_command_line("/usr/bin/python3 /usr/bin/unattended-upgrade").get_description() == "");
	assert(PackageTransaction.from_command_line("").get_description() == "");
}

void test_truncate(){
	var trans = PackageTransaction.from_command_line("apt install " + string.nfill(100, 'x'));
	string txt = trans.get_description(20);
	assert(txt.char_count() == 20);
	assert(txt.has_suffix("..."));
}

int main(string[] args){
	Test.init(ref args);
	Test.add_func("/package-transaction/apt-install", test_apt_install);
	Test.add_func("/package-transaction/apt-remove", test_apt_remove);
	Test.add_func("/package-transaction/apt-gui", test_apt_gui);
	Test.add_func("/package-transaction/command-line", test_command_line);
	Test.add_func("/package-transaction/truncate", test_truncate);
	return Test.run();
}
