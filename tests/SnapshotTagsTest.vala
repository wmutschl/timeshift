/*
 * SnapshotTagsTest.vala
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 */

Json.Object parse_json(string txt){
	var parser = new Json.Parser();
	try{
		parser.load_from_data(txt);
	}
	catch (Error e){
		assert_not_reached();
	}
	return parser.get_root().get_object();
}

string member(Json.Object config, string name){
	return config.has_member(name) ? config.get_string_member(name) : "<none>";
}

// writes the tags like Snapshot does and returns the resulting info.json values
string written(Tags tags, string unknown){
	var config = new Json.Object();
	SnapshotTags.write(config, tags, unknown);
	return "%s | %s | %s".printf(member(config, "tags"), member(config, "extra-tags"), member(config, "compat-tags"));
}

void test_parse(){
	string unknown;
	assert(SnapshotTags.parse("ondemand daily", out unknown) == (Tags.OnDemand | Tags.Daily));
	assert(unknown == "");
	assert(SnapshotTags.parse("  Daily  quarterly pinned quarterly ", out unknown) == Tags.Daily);
	assert(unknown == "quarterly pinned"); // "pinned" is not "package", duplicates are dropped
	assert(SnapshotTags.parse("", out unknown) == 0);
	assert(SnapshotTags.to_list(Tags.Package | Tags.Daily | Tags.OnDemand, "quarterly") == "daily ondemand package quarterly");
}

void test_write(){
	// tags that every version knows: no extra keys
	assert(written(Tags.OnDemand, "") == "ondemand | <none> | <none>");
	assert(written(Tags.Daily | Tags.Weekly, "") == "daily weekly | <none> | <none>");
	// package without ondemand: the stand-in
	assert(written(Tags.Package, "") == "ondemand package | package | ondemand");
	assert(written(Tags.Daily | Tags.Package, "") == "daily ondemand package | package | ondemand");
	// a real ondemand tag needs no stand-in, but package must still survive a write-back
	assert(written(Tags.OnDemand | Tags.Package, "") == "ondemand package | package | <none>");
	// tags of a newer version are protected the same way
	assert(written(Tags.Daily, "quarterly") == "daily ondemand quarterly | quarterly | ondemand");
	// no tags
	assert(written(0, "") == " | <none> | <none>");
}

void test_write_removes_keys(){
	var config = new Json.Object();
	SnapshotTags.write(config, Tags.Daily | Tags.Package, "");
	assert(config.has_member("extra-tags") && config.has_member("compat-tags"));
	// the package tag is removed by the retention
	SnapshotTags.write(config, Tags.Daily, "");
	assert(member(config, "tags") == "daily");
	assert(!config.has_member("extra-tags") && !config.has_member("compat-tags"));
}

void test_round_trip(){
	Tags[] cases = { Tags.OnDemand, Tags.Package, Tags.Daily | Tags.Package, Tags.OnDemand | Tags.Package, Tags.Boot | Tags.Hourly };
	foreach(var tags in cases){
		var config = new Json.Object();
		SnapshotTags.write(config, tags, "quarterly");
		assert(SnapshotTags.read(config) == SnapshotTags.to_list(tags, "quarterly"));
		assert(!SnapshotTags.needs_update(config));
	}
}

// what 26.11.0 to 26.11.2 write back: only the tags they know, the other keys are kept
void test_old_version_write_back(){
	// package only, then tagged hourly by the old version's scheduler
	var config = parse_json("""{ "tags" : "hourly ondemand", "extra-tags" : "package", "compat-tags" : "ondemand" }""");
	assert(SnapshotTags.read(config) == "hourly package");
	// daily and package, daily removed by the old version's retention
	config = parse_json("""{ "tags" : "ondemand", "extra-tags" : "package", "compat-tags" : "ondemand" }""");
	assert(SnapshotTags.read(config) == "package");
	// a real ondemand tag and package
	config = parse_json("""{ "tags" : "ondemand", "extra-tags" : "package" }""");
	assert(SnapshotTags.read(config) == "ondemand package");
	// a tag of a newer version
	config = parse_json("""{ "tags" : "daily ondemand", "extra-tags" : "quarterly", "compat-tags" : "ondemand" }""");
	assert(SnapshotTags.read(config) == "daily quarterly");
	// versions up to 26.09 keep all names, in their own order
	config = parse_json("""{ "tags" : "ondemand package hourly", "extra-tags" : "package", "compat-tags" : "ondemand" }""");
	assert(SnapshotTags.read(config) == "hourly package");
}

// info.json written by builds before this format
void test_earlier_formats(){
	// the first version of the stand-in, without extra-tags
	var config = parse_json("""{ "tags" : "ondemand package", "compat-tags" : "ondemand" }""");
	assert(SnapshotTags.read(config) == "package");
	assert(SnapshotTags.needs_update(config));
	config = parse_json("""{ "tags" : "hourly ondemand", "compat-tags" : "ondemand" }""");
	assert(SnapshotTags.read(config) == "hourly package");
	// no stand-in at all
	config = parse_json("""{ "tags" : "package" }""");
	assert(SnapshotTags.read(config) == "package");
	assert(SnapshotTags.needs_update(config));
	// ordinary snapshots, also in the order of old versions, are left alone
	config = parse_json("""{ "tags" : "ondemand daily" }""");
	assert(SnapshotTags.read(config) == "daily ondemand");
	assert(!SnapshotTags.needs_update(config));
}

void test_unusual_input(){
	assert(SnapshotTags.read(parse_json("""{ "comments" : "no tags" }""")) == "");
	assert(SnapshotTags.read(parse_json("""{ "tags" : 5 }""")) == "");
	assert(!SnapshotTags.needs_update(parse_json("""{ }""")));
}

int main(string[] args){
	Test.init(ref args);
	Test.add_func("/snapshot-tags/parse", test_parse);
	Test.add_func("/snapshot-tags/write", test_write);
	Test.add_func("/snapshot-tags/write-removes-keys", test_write_removes_keys);
	Test.add_func("/snapshot-tags/round-trip", test_round_trip);
	Test.add_func("/snapshot-tags/old-version-write-back", test_old_version_write_back);
	Test.add_func("/snapshot-tags/earlier-formats", test_earlier_formats);
	Test.add_func("/snapshot-tags/unusual-input", test_unusual_input);
	return Test.run();
}
