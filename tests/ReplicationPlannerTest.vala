/*
 * ReplicationPlannerTest.vala
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 */

const int64 DAY = 86400;

ReplicationPolicy policy(int daily, int weekly, int monthly, int ondemand){
	var p = new ReplicationPolicy();
	p.keep_daily = daily;
	p.keep_weekly = weekly;
	p.keep_monthly = monthly;
	p.keep_ondemand = ondemand;
	p.keep_hourly = 0;
	p.keep_boot = 0;
	p.keep_package = 0;
	return p;
}

string names(Gee.ArrayList<ReplicationItem> list){
	string txt = "";
	foreach(var item in list){
		txt += ((txt.length > 0) ? "," : "") + item.name;
	}
	return txt;
}

// first run: nothing on the target yet, the newest snapshots per level are sent oldest first
void test_first_run(){
	var items = new Gee.ArrayList<ReplicationItem>();
	items.add(new ReplicationItem("d1", 1 * DAY, "daily", true, false));
	items.add(new ReplicationItem("d2", 2 * DAY, "daily weekly", true, false));
	items.add(new ReplicationItem("d3", 3 * DAY, "daily", true, false));
	items.add(new ReplicationItem("b1", 3 * DAY + 10, "boot", true, false));
	items.add(new ReplicationItem("o1", 4 * DAY, "ondemand", true, false));

	var sends = ReplicationPlanner.plan_sends(items, policy(2, 1, 0, 5));
	assert(names(sends) == "d2,d3,o1"); // d1: not among the 2 newest daily, b1: boot not kept
	assert(ReplicationPlanner.plan_deletes(items, policy(2, 1, 0, 5)).size == 0);
}

// the target keeps more history than the snapshot device
void test_target_keeps_longer(){
	var items = new Gee.ArrayList<ReplicationItem>();
	// only on the target: removed from the snapshot device already
	items.add(new ReplicationItem("d1", 1 * DAY, "daily", false, true));
	items.add(new ReplicationItem("d2", 2 * DAY, "daily", false, true));
	// on both
	items.add(new ReplicationItem("d3", 3 * DAY, "daily", true, true));
	// new
	items.add(new ReplicationItem("d4", 4 * DAY, "daily", true, false));

	var p = policy(3, 0, 0, 0);
	assert(names(ReplicationPlanner.plan_sends(items, p)) == "d4");
	assert(names(ReplicationPlanner.plan_deletes(items, p)) == "d1");
}

// catch up after the target was not connected for a while
void test_catch_up(){
	var items = new Gee.ArrayList<ReplicationItem>();
	items.add(new ReplicationItem("d1", 1 * DAY, "daily", true, true));
	items.add(new ReplicationItem("d2", 2 * DAY, "daily", true, false));
	items.add(new ReplicationItem("d3", 3 * DAY, "daily", true, false));
	items.add(new ReplicationItem("d4", 4 * DAY, "daily", true, false));

	var p = policy(7, 0, 0, 0);
	assert(names(ReplicationPlanner.plan_sends(items, p)) == "d2,d3,d4");
	assert(ReplicationPlanner.plan_deletes(items, p).size == 0);
}

// the newest copy on the target is the base for incremental transfers and is never removed
void test_keep_base(){
	var items = new Gee.ArrayList<ReplicationItem>();
	items.add(new ReplicationItem("o1", 1 * DAY, "ondemand", true, true));
	items.add(new ReplicationItem("x1", 2 * DAY, "hourly", true, false)); // level not kept on the target

	var p = policy(0, 0, 0, 0);
	assert(ReplicationPlanner.plan_sends(items, p).size == 0);
	assert(ReplicationPlanner.plan_deletes(items, p).size == 0);
	assert(ReplicationPlanner.select_kept(items, p).contains("o1"));
}

int main(string[] args){
	Test.init(ref args);
	Test.add_func("/replication-planner/first-run", test_first_run);
	Test.add_func("/replication-planner/target-keeps-longer", test_target_keeps_longer);
	Test.add_func("/replication-planner/catch-up", test_catch_up);
	Test.add_func("/replication-planner/keep-base", test_keep_base);
	return Test.run();
}
