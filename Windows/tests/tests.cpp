#include "../src/recovery.hpp"
#include <iostream>
#include <thread>
#include <chrono>
#include <algorithm>
#include <shellapi.h>
#include <objbase.h>

using namespace dm;
struct Tests {
	int passed=0, failed=0;
	Json::Array results;
	std::string filter;
	void test(const std::string& name,const std::function<void()>& body) {
		if (!filter.empty() && name.find(filter)==name.npos) return;
		try { body(); ++passed; std::cout<<"PASS "<<name<<"\n"; results.push_back(Json::Object{{"name",name},{"passed",true}}); }
		catch (const std::exception& e) { ++failed; std::cout<<"FAIL "<<name<<": "<<e.what()<<"\n"; results.push_back(Json::Object{{"name",name},{"passed",false},{"error",e.what()}}); }
	}
};
static void expect(bool b,const std::string& why="Assertion failed") { if (!b) throw std::runtime_error(why); }
static void rejects(const std::function<void()>& body) { bool threw=false; try { body(); } catch (const std::exception&) { threw=true; } expect(threw,"Expected an error"); }
static fs::path temp() { auto dir=fs::temp_directory_path()/L"DisplayMind-tests"/wide(newId()); fs::create_directories(dir); return dir; }
static Journal journal() { Journal j; j.id=newId(); j.owner=GetCurrentProcessId(); j.ownerCreated=processCreation(j.owner); j.deadline=utcMillis()+10000; j.fixture=true; j.previous=demoHardware().displays; return j; }
static Json resultOf(const fs::path& dir,int wait=6000) {
	auto until=GetTickCount64()+wait; while (GetTickCount64()<until) { if (fs::exists(dir/L"recovery-result.json")) return Json::parse(readText(dir/L"recovery-result.json")); std::this_thread::sleep_for(std::chrono::milliseconds(20)); } throw std::runtime_error("Watchdog did not produce its result within the deadline");
}
static Route route(std::string id,UINT32 source,UINT32 target,bool active=true) {
	Route r; r.id=id; r.path.sourceInfo.adapterId={1,0}; r.path.sourceInfo.id=source; r.path.targetInfo.adapterId={1,0}; r.path.targetInfo.id=target; r.path.targetInfo.targetAvailable=TRUE; r.path.flags=active ? DISPLAYCONFIG_PATH_ACTIVE : 0; return r;
}
static void codecTests(Tests& t) {
	t.test("json round trip nested Unicode",[]{ auto j=Json::parse("{\"hello\":\"日本語 🎛\",\"array\":[true,false,null,-123]}"); expect(Json::parse(j.dump())==j); });
	t.test("json surrogate pair",[]{ expect(Json::parse("\"\\ud83d\\ude00\"").string()=="😀"); });
	for (auto [name,text]:std::vector<std::pair<std::string,std::string>>{{"duplicate keys","{\"x\":1,\"x\":2}"},{"leading zero","01"},{"fractional integer","1.2"},{"trailing data","true false"},{"missing colon","{\"a\" 1}"},{"lone surrogate","\"\\ud800\""},{"low surrogate","\"\\udc00\""},{"invalid UTF8",std::string("\"")+char(-64)+char(-128)+"\""},{"overflow","9223372036854775808"},{"array trailing comma","[1,]"},{"control character","\"line\nline\""}}) t.test("json rejects "+name,[text]{ rejects([&]{ Json::parse(text); }); });
	t.test("json depth limit",[]{ rejects([]{ Json::parse(std::string(70,'[')+"0"+std::string(70,']')); }); });
	t.test("json integer conversion range",[]{ rejects([]{ Json(int64_t(5000000000)).number(); }); });
	t.test("UTF16 conversion round trip",[]{ expect(narrow(wide("A 日本語 😀"))=="A 日本語 😀"); });
	t.test("settings round trip preserves identifiers and refresh",[]{ auto s=demoSettings(); s.presets[0].displays[0].mode={2560,1440,60000,1001}; auto decoded=decodeSettings(Json::parse(encode(s).dump())); expect(s==decoded); });
	t.test("settings reject Mac schema",[]{ auto j=encode(demoSettings()); std::get<Json::Object>(j.value)["platform"]="macos"; rejects([&]{ decodeSettings(j); }); });
	t.test("settings reject future schema",[]{ auto s=demoSettings(); s.schema=99; rejects([&]{ decodeSettings(encode(s)); }); });
	t.test("settings reject duplicate presets",[]{ auto s=demoSettings(); s.presets.push_back(s.presets[0]); rejects([&]{ validate(s); }); });
	t.test("settings reject dangling rule",[]{ auto s=demoSettings(); s.rules[0].preset="missing"; rejects([&]{ validate(s); }); });
	t.test("settings reject conflicting device conditions",[]{ auto s=demoSettings(); s.rules[0].absent=s.rules[0].required; rejects([&]{ validate(s); }); });
	t.test("settings reject unconditional rule",[]{ auto s=demoSettings(); s.rules[0].required.clear(); rejects([&]{ validate(s); }); });
}
static void layoutTests(Tests& t) {
	t.test("apply reconciles a monitor that moved docks before its refresh notification", [] {
		auto s = demoSettings(); FixtureBackend backend;
		backend.hardware.displays[0].monitor = {123, 456, "text:A", "Studio Display"};
		reconnectMonitors(s, backend.hardware);
		backend.hardware.displays[0].id = "fixture:just-reconnected";
		auto directory = temp(); Recovery recovery(directory);
		auto result = applyPreset(backend, recovery, s.presets[0], true, s.presets);
		expect(result.id.empty() && backend.writes == 0 && !recovery.pending(), "A matching dock-reconnected layout was not recognized");
	});
	t.test("arrangement accepts connected extended displays and ignores mirror geometry", [] {
		expect(arrangementIssue(demoHardware().displays).empty());
		auto ds = demoSettings().presets[1].displays; ds[1].x = -90000;
		expect(arrangementIssue(ds).empty());
		ds[1].mirror.clear(); ds[1].enabled = false; expect(arrangementIssue(ds).empty());
	});
	t.test("arrangement explains overlapping displays", [] {
		auto ds = demoHardware().displays; ds[1].x = 2000;
		auto issue = arrangementIssue(ds); expect(issue.find("overlap") != issue.npos && issue.find(ds[1].name) != issue.npos);
	});
	t.test("arrangement rejects a separated cluster even when each display has a neighbour", [] {
		auto ds = demoHardware().displays; ds[2].x = 20000; ds[2].y = 0;
		auto extra = ds[2]; extra.id = "fixture:fourth"; extra.x += extra.mode.width; ds.push_back(extra);
		expect(arrangementIssue(ds).find("separated") != std::string::npos);
	});
	t.test("arrangement snaps to the nearest touching position without overlap", [] {
		auto ds = demoHardware().displays;
		auto p = snappedPosition(ds, ds[1].id, 2300, 20);
		expect(p == std::pair{2560, 20}); ds[1].x = p->first; ds[1].y = p->second;
		expect(arrangementIssue(ds).empty());
	});
	t.test("arrangement snapping handles distant negative coordinates without integer overflow", [] {
		auto ds = demoHardware().displays; ds.resize(2);
		auto p = snappedPosition(ds, ds[1].id, -100000, -100000);
		expect(p.has_value()); ds[1].x = p->first; ds[1].y = p->second;
		expect(arrangementIssue(ds).empty());
	});
	t.test("arrangement leaves single and mirrored displays unchanged", [] {
		auto ds = demoHardware().displays; ds.resize(1);
		expect(snappedPosition(ds, ds[0].id, 50, 60) == std::pair{50, 60});
		ds = demoSettings().presets[1].displays;
		expect(snappedPosition(ds, ds[1].id, 50, 60) == std::pair{50, 60});
	});
	t.test("monitor rebind recognizes a unique model without an EDID serial", [] {
		auto s = demoSettings(); auto h = demoHardware();
		h.displays[0].monitor = {123, 456, "", "Pen display"}; reconnectMonitors(s, h);
		h.displays[0].id = "fixture:other-dock";
		expect(reconnectMonitors(s, h).at("fixture:studio") == "fixture:other-dock");
		expect(s.presets[0].confirmed);
	});
	t.test("monitor rebind refuses a serial-less model shared by two connected displays", [] {
		auto s = demoSettings(); auto h = demoHardware();
		h.displays[0].monitor = {123, 456, "", "Pen display"}; reconnectMonitors(s, h);
		h.displays[0].id = "fixture:other-dock"; h.displays[1].monitor = h.displays[0].monitor;
		expect(reconnectMonitors(s, h).empty());
	});
	t.test("monitor rebind preserves contradictory identities across saved presets", [] {
		auto s = demoSettings(); auto h = demoHardware();
		s.presets[0].displays[0].monitor = {123, 456, "text:A", "Monitor"};
		s.presets[1].displays[0].monitor = {123, 456, "text:B", "Monitor"};
		h.displays[0].id = "fixture:other-dock"; h.displays[0].monitor = s.presets[1].displays[0].monitor;
		expect(reconnectMonitors(s, h).empty());
		expect(s.presets[0].displays[0].monitor.serial == "text:A");
	});
	t.test("monitor rebind does not overwrite a different physical identity at the same path", [] {
		auto s = demoSettings(); auto h = demoHardware();
		h.displays[0].monitor = {123, 456, "text:A", "Monitor"}; reconnectMonitors(s, h);
		h.displays[0].monitor.serial = "text:B"; reconnectMonitors(s, h);
		expect(s.presets[0].displays[0].monitor.serial == "text:A");
	});
	t.test("monitor rebind cannot merge metadata-free display references within one preset", [] {
		auto s = demoSettings(); auto h = demoHardware();
		h.displays[0].monitor = {123, 456, "text:A", "Monitor"}; reconnectMonitors(s, h);
		h.displays[0].id = "fixture:new-path";
		auto extra = h.displays[0]; extra.monitor = {}; s.presets[0].displays.push_back(extra);
		expect(reconnectMonitors(s, h).empty());
	});
	t.test("monitor rebind cannot merge Connected and Absent rule conditions", [] {
		auto s = demoSettings(); auto h = demoHardware();
		h.displays[0].monitor = {123, 456, "text:A", "Monitor"}; reconnectMonitors(s, h);
		s.rules[0].required.push_back({"display:fixture:studio", "Monitor"});
		s.rules[0].absent.push_back({"display:fixture:new-path", "Monitor"});
		h.displays[0].id = "fixture:new-path";
		expect(reconnectMonitors(s, h).empty()); validate(s);
	});
	t.test("layout validates captured extended and mirror",[]{ auto s=demoSettings(); for (const auto& p:s.presets) validate(p); });
	for (auto [name,change]:std::vector<std::pair<std::string,std::function<void(std::vector<Display>&)>>> {
		{"empty",[](auto& d){ d.clear(); }},{"duplicates",[](auto& d){ d.push_back(d[0]); }},{"missing primary",[](auto& d){ d[0].x=1; }},{"two primary",[](auto& d){ d[1].x=0; }},{"unsupported rotation",[](auto& d){ d[0].rotation=45; }},{"zero resolution",[](auto& d){ d[0].mode.width=0; }},{"negative refresh",[](auto& d){ d[0].mode.numerator=-1; }},{"zero refresh denominator",[](auto& d){ d[0].mode.denominator=0; }},{"position overflow",[](auto& d){ d[1].x=100001; }},{"mirror self",[](auto& d){ d[1].mirror=d[1].id; }},{"mirror chain",[](auto& d){ d[1].mirror=d[0].id; d[2].mirror=d[1].id; }},{"disabled mirror source",[](auto& d){ d[0].enabled=false; d[1].mirror=d[0].id; }}}) t.test("layout rejects "+name,[change]{ auto ds=demoHardware().displays; change(ds); rejects([&]{ validate(ds); }); });
	t.test("layout make-main translates every origin",[]{ auto ds=demoHardware().displays; makeMain(ds,ds[1].id); expect(ds[1].x==0 && ds[0].x==-2560 && ds[2].x==-2160); validate(ds); });
	t.test("layout make-main ignores a mirror",[]{ auto ds=demoSettings().presets[1].displays; auto before=ds; makeMain(ds,ds[1].id); expect(ds==before); });
	t.test("layout same layout ignores names and ordering",[]{ auto a=demoHardware().displays,b=a; std::reverse(b.begin(),b.end()); b[0].name="Renamed"; expect(sameLayout(a,b)); });
	t.test("layout matches fractional refresh within tolerance",[]{ auto a=demoHardware().displays,b=a; b[0].mode.numerator=59940; b[0].mode.denominator=1000; expect(matches(a,b)); b[0].mode.numerator=50000; expect(!matches(a,b)); });
	t.test("layout mode zero means driver default refresh",[]{ auto a=demoHardware().displays,b=a; a[0].mode.numerator=0; b[0].mode.numerator=144; expect(matches(a,b)); });
	t.test("layout verifies rotation position mirror and resolution",[]{ auto a=demoHardware().displays; for (int field=0;field<4;++field) { auto b=a; if(field==0)b[1].x++; if(field==1)b[1].rotation=0; if(field==2)b[1].mode.width++; if(field==3)b[1].mirror=b[0].id; expect(!matches(a,b)); } });
	t.test("layout ignores inherited mirror modes",[]{ auto a=demoSettings().presets[1].displays,b=a; b[1].mode.width=640; b[1].rotation=180; b[1].x=900; expect(matches(a,b)); });
	t.test("layout verifies clone groups independent of Windows path order", [] {
		auto wanted = demoSettings().presets[1].displays;
		auto actual = wanted;
		actual[0].mirror = actual[1].id;
		actual[1].mirror.clear();
		std::swap(actual[0], actual[1]);
		expect(matches(wanted, actual));
		expect(!matches(demoHardware().displays, actual));
	});
	t.test("preset folders and monitor metadata round trip with legacy settings", [] {
		auto s = demoSettings();
		s.folders.push_back({"fixture:work", "Work", true});
		s.presets[0].folder = s.folders[0].id;
		s.presets[0].displays[0].monitor = {123, 456, "number:789", "Studio Display"};
		expect(decodeSettings(encode(s)) == s);
		s.folders.clear();
		rejects([&] { validate(s); });
	});
	t.test("monitor rebind updates mirrors and rule conditions for a unique physical monitor", [] {
		auto s = demoSettings();
		auto h = demoHardware();
		auto oldId = h.displays.front().id;
		auto newId = "fixture:new-port";
		MonitorIdentity identity{123, 456, "text:ABC", "Studio Display"};
		for (auto& p : s.presets) for (auto& d : p.displays) if (d.id == oldId) d.monitor = identity;
		s.rules.front().required.push_back({"display:" + oldId, "Studio Display"});
		h.displays.front().id = newId;
		h.displays.front().monitor = {123, 567, "text:ABC", "Studio Display"};
		expect(reconnectMonitors(s, h).at(oldId) == newId);
		expect(s.presets[1].displays.front().id == newId && s.presets[1].displays[1].mirror == newId);
		expect(s.rules.front().required.back().id == std::string("display:") + newId);
		expect(s.presets[0].confirmed && s.presets[0].displays.front().monitor.product == 567);
	});
	t.test("monitor rebind learns older presets and ignores an ambiguous serial", [] {
		auto s = demoSettings();
		auto h = demoHardware();
		MonitorIdentity identity{123, 456, "number:789", "Studio Display"};
		h.displays[0].monitor = identity;
		expect(reconnectMonitors(s, h).empty() && s.presets[0].displays[0].monitor == identity);
		h.displays[0].id = "fixture:new-port";
		h.displays[1].monitor = identity;
		expect(reconnectMonitors(s, h).empty() && s.presets[0].displays[0].id == "fixture:studio");
	});
	t.test("monitor identity reads EDID descriptors and rejects invalid checksums", [] {
		std::vector<BYTE> edid(128);
		std::fill(edid.begin()+1, edid.begin()+7, BYTE{255});
		edid[8]=0x12; edid[9]=0x34; edid[10]=0x78; edid[11]=0x56;
		edid[54+3]=0xff;
		std::string serial="ABC123\n";
		for (size_t i = 0; i < serial.size(); ++i) edid[59+i] = static_cast<BYTE>(serial[i]);
		for (size_t i=0; i<127; ++i) edid[127]=static_cast<BYTE>(edid[127]-edid[i]);
		expect(monitorIdentity(edid,"Display") == MonitorIdentity{0x1234,0x5678,"text:ABC123","Display"});
		++edid[12];
		expect(monitorIdentity(edid,"Display").vendor == 0);
	});
	t.test("extra displays keep working when the preset overlaps their old position", [] {
		auto current = demoHardware().displays;
		auto main = current[0];
		main.mode.width = 3840;
		auto result = layoutWithExtraDisplays({main}, current);
		expect(result[1].enabled && result[1].x == 3840 && result[1].y == 0);
		expect(result[2] == current[2]);
	});
	t.test("an extra clone is extended if its old source is disabled", [] {
		auto current = demoSettings().presets[1].displays;
		auto main = current[2];
		main.x = main.y = 0;
		auto disabled = current[0];
		disabled.enabled = false;
		auto result = layoutWithExtraDisplays({main, disabled}, current);
		expect(result.back().enabled && result.back().mirror.empty());
		validate(result);
	});
	t.test("layout required missing display blocks",[]{ auto h=demoHardware(); auto p=demoSettings().presets[0]; h.displays.pop_back(); expect(!unavailable(p,h).empty()); });
	t.test("layout offline saved wireless can connect",[]{ auto h=demoHardware(); auto p=demoSettings().presets[0]; p.receiver="Living room"; p.wirelessDisplay=p.displays.back().id; p.displays.back().wireless=true; h.displays.pop_back(); validate(p); expect(unavailable(p,h).empty()); });
	t.test("planner assigns distinct sources and primary path first",[]{ auto h=demoHardware(); auto p=planLayout({h.displays[0],h.displays[1]},h,{route(h.displays[0].id,0,10),route(h.displays[1].id,1,11),route(h.displays[2].id,2,12)},false); expect(p.paths.size()==3 && p.modes.size()==3 && p.paths[0].targetInfo.id==10); });
	t.test("planner resolves constrained source assignments",[]{ auto h=demoHardware(); h.displays.resize(2); auto ds=h.displays; auto p=planLayout(ds,h,{route(ds[0].id,0,10),route(ds[0].id,1,10,false),route(ds[1].id,0,11)},true); expect(p.paths[0].sourceInfo.id==1 && p.paths[1].sourceInfo.id==0); });
	t.test("planner clones share source mode index",[]{ auto h=demoHardware(); h.displays.resize(2); auto ds=h.displays; ds[1].mirror=ds[0].id; auto p=planLayout(ds,h,{route(ds[0].id,0,10),route(ds[0].id,1,10,false),route(ds[1].id,1,11)},true); expect(p.paths.size()==2 && p.modes.size()==1 && p.paths[0].sourceInfo.id==1 && p.paths[0].sourceInfo.modeInfoIdx==p.paths[1].sourceInfo.modeInfoIdx); });
	t.test("planner rejects impossible GPU clone path",[]{ auto h=demoHardware(); h.displays.resize(2); auto ds=h.displays; ds[1].mirror=ds[0].id; rejects([&]{ planLayout(ds,h,{route(ds[0].id,0,10),route(ds[1].id,1,11)},true); }); });
	t.test("planner preserves disabled target without active path",[]{ auto h=demoHardware(); h.displays.resize(2); auto ds=h.displays; ds[1].enabled=false; auto p=planLayout(ds,h,{route(ds[0].id,0,10),route(ds[1].id,1,11)},true); expect(p.paths.size()==1); });
	t.test("planner keeps extra primary usable at right edge",[]{ auto h=demoHardware(); auto ds=std::vector<Display>{h.displays[1]}; ds[0].x=0; ds[0].y=0; auto p=planLayout(ds,h,{route(h.displays[0].id,0,10),route(h.displays[1].id,1,11),route(h.displays[2].id,2,12)},false); expect(p.paths.size()==3); int primary=0; for(auto m:p.modes) if(!m.sourceMode.position.x && !m.sourceMode.position.y) ++primary; expect(primary==1); });
	t.test("planner restoration removes post-snapshot extra paths",[]{ auto h=demoHardware(); auto ds=std::vector<Display>{h.displays[0]}; auto p=planLayout(ds,h,{route(h.displays[0].id,0,10),route(h.displays[1].id,1,11)},true); expect(p.paths.size()==1); });
	t.test("planner explicit refresh supplies concrete scan-line order",[]{ auto h=demoHardware(); h.displays.resize(1); auto p=planLayout(h.displays,h,{route(h.displays[0].id,0,10)},true); expect(p.paths[0].targetInfo.refreshRate.Numerator==60 && p.paths[0].targetInfo.scanLineOrdering==DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE); });
	t.test("planner automatic refresh uses zero over zero and unspecified order",[]{ auto h=demoHardware(); h.displays.resize(1); h.displays[0].mode.numerator=0; auto p=planLayout(h.displays,h,{route(h.displays[0].id,0,10)},true); expect(!p.paths[0].targetInfo.refreshRate.Numerator && !p.paths[0].targetInfo.refreshRate.Denominator && p.paths[0].targetInfo.scanLineOrdering==DISPLAYCONFIG_SCANLINE_ORDERING_UNSPECIFIED); });
}
static void ruleTests(Tests& t) {
	t.test("rules match first eligible rule",[]{ auto s=demoSettings(); auto second=s.rules[0]; second.id="fixture:second"; s.rules.push_back(second); expect(matchRule(s,demoHardware())->id==s.rules[0].id); });
	t.test("rules ignore unconfirmed preset",[]{ auto s=demoSettings(); s.presets[0].confirmed=false; expect(!matchRule(s,demoHardware())); });
	t.test("rules pause automation",[]{ auto s=demoSettings(); s.automatic=false; expect(!matchRule(s,demoHardware())); });
	t.test("rules skip disabled rule",[]{ auto s=demoSettings(); s.rules[0].enabled=false; expect(!matchRule(s,demoHardware())); });
	t.test("rules all required devices must match",[]{ auto s=demoSettings(); s.rules[0].required.push_back({"usb:missing","Missing dock",true}); expect(!matchRule(s,demoHardware())); });
	t.test("rules absent conditions",[]{ auto s=demoSettings(); s.rules[0].absent={demoHardware().devices[0]}; expect(!matchRule(s,demoHardware())); s.rules[0].absent={{"usb:missing","Missing",true}}; expect(matchRule(s,demoHardware())); });
	t.test("rules exact display set and allow extras",[]{ auto s=demoSettings(); auto h=demoHardware(); auto extra=h.displays[0]; extra.id="fixture:extra"; h.displays.push_back(extra); expect(!matchRule(s,h)); s.rules[0].exact=false; expect(matchRule(s,h)); });
	t.test("rules changed labels do not change device identity",[]{ auto s=demoSettings(); auto h=demoHardware(); h.devices.back().name="A different name"; expect(matchRule(s,h)); });
	t.test("rules explicit wireless required still requires connection",[]{ auto s=demoSettings(); auto h=demoHardware(); auto id=s.presets[0].displays.back().id; s.presets[0].displays.back().wireless=true; s.presets[0].receiver="Receiver"; s.presets[0].wirelessDisplay=id; h.displays.pop_back(); std::erase_if(h.devices,[&](auto& d){return d.id=="display:"+id;}); expect(matchRule(s,h)); s.rules[0].required.push_back({"display:"+id,"Wireless",false}); expect(!matchRule(s,h)); });
	t.test("gate waits 3 seconds then fires once",[]{ ConnectionGate g; std::set<std::string> a={"one"}; expect(!g.evaluate(a,0)); expect(!g.evaluate(a,2999)); expect(g.evaluate(a,3000)); expect(!g.evaluate(a,9000)); });
	t.test("gate coalesces connection bursts",[]{ ConnectionGate g; expect(!g.evaluate({"one"},0)); expect(!g.evaluate({"one","two"},2500)); expect(!g.evaluate({"one","two"},5000)); expect(g.evaluate({"one","two"},5500)); });
	t.test("gate manual override remains until connections change",[]{ ConnectionGate g; g.consume({"one"},0); expect(!g.evaluate({"one"},10000)); expect(!g.evaluate({"two"},10000)); expect(g.evaluate({"two"},13000)); });
	t.test("gate reset re-evaluates on wake or rule change",[]{ ConnectionGate g; g.consume({"one"},0); g.reset(); expect(!g.evaluate({"one"},10000)); expect(g.evaluate({"one"},13000)); });
	t.test("gate own wireless change consumed",[]{ ConnectionGate g; g.consume({"dock","wireless"},0); expect(!g.evaluate({"dock","wireless"},10000)); });
}
static void audioTests(Tests& t) {
	t.test("audio preserves Bluetooth defaults",[]{ auto h=demoHardware(); h.audio.output="fixture:headphones"; auto a=audioApplicable({"fixture:speakers","fixture:mic"},h.audio,h.audioDevices); expect(a.output.empty() && a.input=="fixture:mic"); });
	t.test("audio normal defaults can change",[]{ auto h=demoHardware(); auto a=audioApplicable({"fixture:headphones",""},h.audio,h.audioDevices); expect(a.output=="fixture:headphones" && a.input.empty()); });
	t.test("audio takeover when Bluetooth disconnects",[]{ auto h=demoHardware(),now=h; h.audio.output="fixture:headphones"; std::erase_if(now.audioDevices,[](auto& d){return d.bluetooth;}); auto a=audioTakeover({"fixture:speakers","fixture:mic"},h.audio,h.audioDevices,now.audioDevices); expect(a.output=="fixture:speakers" && a.input.empty()); });
	t.test("audio explicit user choice while Bluetooth remains is retained",[]{ auto h=demoHardware(); auto a=audioTakeover({"fixture:speakers","fixture:mic"},h.audio,h.audioDevices,h.audioDevices); expect(a.output.empty() && a.input.empty()); });
	t.test("audio disconnected non-Bluetooth device is left to Windows",[]{ auto h=demoHardware(); auto a=audioTakeover({"fixture:speakers","fixture:mic"},h.audio,h.audioDevices,{}); expect(a.output.empty() && a.input.empty()); });
}
static void storageTests(Tests& t) {
	t.test("storage atomic settings round trip",[]{ auto dir=temp(); auto s=demoSettings(); saveSettings(dir,s); expect(loadSettings(dir)==s); });
	t.test("storage preserves corrupt settings bytes",[]{ auto dir=temp(); std::string broken="{this is corrupt"; atomicWrite(dir/L"settings.json",broken); rejects([&]{ loadSettings(dir); }); expect(readText(dir/L"settings.json")==broken); });
	t.test("storage future version preserved",[]{ auto dir=temp(); auto s=demoSettings(); s.schema=9; auto text=encode(s).dump(); atomicWrite(dir/L"settings.json",text); rejects([&]{ loadSettings(dir); }); expect(readText(dir/L"settings.json")==text); });
	t.test("storage invalid settings cannot overwrite valid settings",[]{ auto dir=temp(); auto s=demoSettings(); saveSettings(dir,s); auto old=readText(dir/L"settings.json"); s.presets[0].displays[0].rotation=33; rejects([&]{ saveSettings(dir,s); }); expect(readText(dir/L"settings.json")==old); });
	t.test("storage duplicate preset rejected on read",[]{ auto dir=temp(); auto s=demoSettings(); s.presets.push_back(s.presets[0]); atomicWrite(dir/L"settings.json",encode(s).dump()); rejects([&]{ loadSettings(dir); }); });
	t.test("command quoting handles spaces quotes trailing slash",[]{ auto input=L"C:\\folder with space\\\"quoted\"\\"; auto command=quoteArg(L"test.exe")+L" "+quoteArg(input); int argc=0; auto argv=CommandLineToArgvW(command.c_str(),&argc); expect(argc==2 && std::wstring(argv[1])==input); LocalFree(argv); });
}
static void recoveryTests(Tests& t) {
	t.test("recovery journal round trip",[]{ auto j=journal(); j.stopped={{"TV","fixture:tv"}}; auto copy=decodeJournal(Json::parse(encode(j).dump())); expect(encode(copy)==encode(j)); });
	t.test("recovery fixture refuses real identities",[]{ auto j=journal(); j.previous[0].id="real:device"; rejects([&]{ decodeJournal(encode(j)); }); });
	t.test("recovery journal prevents path traversal",[]{ auto j=journal(); j.id="../outside"; rejects([&]{ decodeJournal(encode(j)); }); });
	t.test("recovery incomplete apply expires to rollback",[]{ auto j=journal(); expect(recoveryAction(j,j.deadline+1,true)==RecoveryAction::restore); });
	t.test("recovery incomplete apply rolls back after owner dies",[]{ auto j=journal(); expect(recoveryAction(j,j.deadline-100,false)==RecoveryAction::restore); });
	t.test("recovery verified apply stays after 10 seconds",[]{ auto j=journal(); j.state="verified"; expect(recoveryAction(j,j.deadline+1,true)==RecoveryAction::keep); });
	t.test("recovery verified apply stays after app exits",[]{ auto j=journal(); j.state="verified"; expect(recoveryAction(j,j.deadline-1,false)==RecoveryAction::keep); });
	t.test("recovery explicit Revert wins verified state",[]{ auto j=journal(); j.state="revert"; expect(recoveryAction(j,0,true)==RecoveryAction::restore); });
	t.test("recovery stable process identity rejects reused pid",[]{ expect(processAlive(GetCurrentProcessId(),processCreation(GetCurrentProcessId()))); expect(!processAlive(GetCurrentProcessId(),1)); });
	t.test("recovery cannot keep unverified change",[]{ auto dir=temp(); Recovery r(dir); auto j=journal(); r.begin(j); rejects([&]{ r.keep(j.id); }); expect(fs::exists(r.journalPath())); });
	t.test("recovery cannot overwrite another pending change",[]{ auto dir=temp(); Recovery r(dir); r.begin(journal()); rejects([&]{ r.begin(journal()); }); });
	t.test("recovery update checks transaction ownership",[]{ auto dir=temp(); Recovery r(dir); auto j=journal(); r.begin(j); rejects([&]{ r.verified("wrong-id",utcMillis()); }); expect(r.pending()->state=="applying"); });
	t.test("watchdog separate process restores expired apply",[]{ auto dir=temp(); Recovery r(dir); auto j=journal(); j.deadline=utcMillis()-1; r.begin(j); r.watch(true); auto result=resultOf(dir); expect(result.str("id")==j.id && !result.flag("kept") && result.str("error").empty()); expect(fs::exists(dir/L"fixture-restored.json") && !fs::exists(r.journalPath())); });
	t.test("watchdog separate process keeps verified apply",[]{ auto dir=temp(); Recovery r(dir); auto j=journal(); j.state="verified"; j.deadline=utcMillis()-1; r.begin(j); r.watch(true); auto result=resultOf(dir); expect(result.flag("kept") && !fs::exists(dir/L"fixture-restored.json")); });
	t.test("watchdog separate process recovers dead owner",[]{ auto dir=temp(); Recovery r(dir); auto j=journal(); j.owner=0; j.ownerCreated=0; r.begin(j); r.watch(true); expect(!resultOf(dir).flag("kept")); });
	t.test("watchdog separate process honors explicit Revert",[]{ auto dir=temp(); Recovery r(dir); auto j=journal(); j.state="verified"; r.begin(j); r.watch(true); r.revert(j.id); expect(!resultOf(dir).flag("kept")); });
	t.test("watchdog resumes an interrupted claimed restore",[]{ auto dir=temp(); auto j=journal(); j.state="revert"; atomicWrite(dir/(L"restoring-"+wide(j.id)+L".json"),encode(j).dump()); Recovery r(dir); r.watch(true); expect(resultOf(dir).str("error").empty()); expect(fs::exists(dir/L"fixture-restored.json")); });
	t.test("watchdog refuses live journal in fixture mode",[]{ auto dir=temp(); auto j=journal(); j.fixture=false; Recovery r(dir); r.begin(j); rejects([&]{r.watch(true);}); expect(fs::exists(r.journalPath())); });
	t.test("apply unchanged layout avoids display writes and watchdog",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; auto p=demoSettings().presets[0]; auto outcome=applyPreset(b,r,p,true,{p}); expect(outcome.id.empty() && b.writes==0 && !r.pending()); });
	t.test("apply retries rejected driver calls then verifies",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; b.fails=2; auto p=demoSettings().presets[0]; p.displays[1].rotation=270; auto outcome=applyPreset(b,r,p,true,{p}); expect(b.writes==3 && r.pending()->state=="verified"); r.keep(outcome.id); });
	t.test("apply retries an accepted but incorrect layout",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; b.wrongReads=1; auto p=demoSettings().presets[0]; p.displays[1].rotation=270; auto outcome=applyPreset(b,r,p,true,{p}); expect(b.writes==2); r.keep(outcome.id); });
	t.test("apply failure requests independent rollback",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; b.fails=3; auto p=demoSettings().presets[0]; p.displays[1].rotation=270; rejects([&]{ applyPreset(b,r,p,true,{p}); }); auto result=resultOf(dir); expect(!result.flag("kept") && result.str("error").empty()); });
	t.test("apply captures only overwritten audio sides",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; auto p=demoSettings().presets[0]; p.displays[1].rotation=270; p.audio.input.clear(); auto outcome=applyPreset(b,r,p,true,{p}); auto j=r.pending(); expect(j->audio.input.empty() && j->audio.output==b.hardware.audio.output); r.keep(outcome.id); });
	t.test("apply missing display fails before opening a journal",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; auto p=demoSettings().presets[0]; b.hardware.displays.pop_back(); rejects([&]{ applyPreset(b,r,p,true,{p}); }); expect(!r.pending() && b.writes==0); });
	t.test("recovery rejects Keep after an independent rollback",[]{ auto dir=temp(); Recovery r(dir); auto j=journal(); j.deadline=utcMillis()-1; r.begin(j); expect(runWatchdog(dir,true)==0); rejects([&]{r.keep(j.id);}); });
	t.test("recovery accepts Keep after watchdog kept verified layout",[]{ auto dir=temp(); Recovery r(dir); auto j=journal(); j.state="verified"; j.preset="fixture:desk"; j.deadline=utcMillis()-1; r.begin(j); expect(runWatchdog(dir,true)==0); r.keep(j.id); expect(Json::parse(readText(r.resultPath())).str("preset")=="fixture:desk"); });
	t.test("recovery failure preserves snapshot and supports explicit retry",[]{ auto dir=temp(); Recovery r(dir); auto j=journal(); j.deadline=utcMillis()-1; r.begin(j); FixtureBackend b; b.hardware.displays[1].rotation=270; b.fails=3; expect(runWatchdog(dir,true,&b)==1); auto snapshot=dir/(L"restoring-"+wide(j.id)+L".json"); expect(r.inFlight()->id==j.id && fs::exists(snapshot) && !resultOf(dir).str("error").empty()); rejects([&]{r.keep(j.id);}); expect(r.retryFailed(true)==j.id); expect(runWatchdog(dir,true,&b)==0 && !fs::exists(snapshot)); expect(fs::exists(dir/(L"recovery-history-"+wide(j.id)+L".json"))); });
	t.test("audio-only apply opens a revert window without changing display paths", [] {
		auto dir = temp(); Recovery r(dir); FixtureBackend b;
		auto p = demoSettings().presets[0];
		p.audio.output = "fixture:headphones";
		auto outcome = applyPreset(b, r, p, true, {p});
		auto j = r.pending();
		expect(j && !j->restoreDisplay && outcome.until == j->deadline && b.writes == 0);
		expect(b.hardware.audio.output == p.audio.output && j->audio.output == "fixture:speakers");
		r.keep(outcome.id);
	});
	t.test("audio-only rollback restores defaults and leaves external display changes alone", [] {
		auto dir = temp(); Recovery r(dir); FixtureBackend b;
		auto j = journal();
		j.state = "revert";
		j.restoreDisplay = false;
		j.roleAudio = {b.hardware.audio, b.hardware.audio, {"fixture:headphones", ""}};
		b.hardware.audio.output = "fixture:headphones";
		b.hardware.roleAudio.resize(3, b.hardware.audio);
		b.hardware.displays[1].rotation = 270;
		r.begin(j);
		expect(runWatchdog(dir, true, &b) == 0 && b.writes == 0);
		expect(b.hardware.audio.output == "fixture:speakers" && b.hardware.roleAudio[2].output == "fixture:headphones");
		expect(b.hardware.displays[1].rotation == 270);
	});
	t.test("apply retains separate Windows audio roles for rollback",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; b.hardware.roleAudio={b.hardware.audio,b.hardware.audio,{"fixture:headphones","fixture:mic"}}; auto p=demoSettings().presets[0]; p.displays[1].rotation=270; auto outcome=applyPreset(b,r,p,true,{p}); auto j=r.pending(); expect(j->roleAudio.size()==3 && j->roleAudio[0].output=="fixture:speakers" && j->roleAudio[2].output.empty()); r.keep(outcome.id); });
	t.test("apply audio failure reports warning while verified layout stays",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; b.audioFailure="Fixture audio service failed"; auto p=demoSettings().presets[0]; p.displays[1].rotation=270; auto outcome=applyPreset(b,r,p,true,{p}); expect(outcome.note=="Sound selection failed: Fixture audio service failed" && r.pending()->state=="verified" && matches(p.displays,b.hardware.displays)); r.keep(outcome.id); });
	t.test("apply unavailable audio is skipped without reverting displays",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; std::erase_if(b.hardware.audioDevices,[](const auto& d){return d.id=="fixture:speakers";}); auto p=demoSettings().presets[0]; p.displays[1].rotation=270; auto outcome=applyPreset(b,r,p,true,{p}); expect(outcome.note.find("not connected")!=std::string::npos && r.pending()->state=="verified"); r.keep(outcome.id); });
	t.test("wireless connects the exact saved offline receiver",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; auto p=demoSettings().presets[0]; p.displays[1].wireless=true; p.receiver="Exact living room receiver"; p.wirelessDisplay=p.displays[1].id; b.wirelessReceivers[p.wirelessDisplay]=p.displays[1]; std::erase_if(b.hardware.displays,[&](const auto& d){return d.id==p.wirelessDisplay;}); auto outcome=applyPreset(b,r,p,true,{p}); expect(b.wirelessCalls==std::vector<std::string>{"connect:"+p.receiver+":"+p.wirelessDisplay}); expect(r.pending()->startedDisplay==p.wirelessDisplay && matches(p.displays,b.hardware.displays)); r.keep(outcome.id); });
	t.test("wireless reuses an already connected receiver",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; auto p=demoSettings().presets[0]; p.displays[1].wireless=true; b.hardware.displays=p.displays; p.receiver="Exact receiver"; p.wirelessDisplay=p.displays[1].id; auto outcome=applyPreset(b,r,p,true,{p}); expect(outcome.id.empty() && b.wirelessCalls.empty()); });
	t.test("wireless saves stopped stream before switching away",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; auto previous=demoSettings().presets[0]; previous.displays[1].wireless=true; previous.receiver="Exact receiver"; previous.wirelessDisplay=previous.displays[1].id; b.hardware.displays=previous.displays; auto p=previous; p.id="fixture:without-wireless"; p.receiver.clear(); p.wirelessDisplay.clear(); p.displays.erase(p.displays.begin()+1); auto outcome=applyPreset(b,r,p,true,{previous,p}); expect(b.wirelessCalls==std::vector<std::string>{"disconnect:"+previous.receiver+":"+previous.wirelessDisplay}); expect(r.pending()->stopped==std::vector<std::pair<std::string,std::string>>{{previous.receiver,previous.wirelessDisplay}}); r.keep(outcome.id); });
	t.test("wireless connection failure rolls back independently",[]{ auto dir=temp(); Recovery r(dir); FixtureBackend b; b.connectFailures=1; auto p=demoSettings().presets[0]; p.displays[1].wireless=true; p.receiver="Exact receiver"; p.wirelessDisplay=p.displays[1].id; std::erase_if(b.hardware.displays,[&](const auto& d){return d.id==p.wirelessDisplay;}); rejects([&]{applyPreset(b,r,p,true,{p});}); auto result=resultOf(dir); expect(!result.flag("kept") && result.str("error").empty()); });
	t.test("wireless unknown stream remains connected during other layout changes", [] {
		auto dir = temp(); Recovery r(dir); FixtureBackend b;
		b.hardware.displays[1].wireless = true;
		auto p = demoSettings().presets[0];
		p.displays.erase(p.displays.begin() + 1);
		p.displays.front().mode.width = 3840;
		auto outcome = applyPreset(b, r, p, true, {p});
		expect(b.wirelessCalls.empty() && b.hardware.displays.size() == 3);
		expect(b.hardware.displays.back().wireless && b.hardware.displays.back().enabled);
		r.keep(outcome.id);
	});
}
int wmain(int argc,wchar_t** argv) {
	CoInitializeEx(nullptr,COINIT_MULTITHREADED);
	if (argc>2 && std::wstring(argv[1])==L"--watchdog") { int result=runWatchdog(argv[2],argc>3 && std::wstring(argv[3])==L"--fixture"); CoUninitialize(); return result; }
	Tests t; fs::path report; for(int i=1;i<argc;++i) { if(std::wstring(argv[i])==L"--filter" && i+1<argc)t.filter=narrow(argv[++i]); else if(std::wstring(argv[i])==L"--report" && i+1<argc)report=argv[++i]; }
	codecTests(t); layoutTests(t); ruleTests(t); audioTests(t); storageTests(t); recoveryTests(t);
	std::cout<<t.passed<<" passed, "<<t.failed<<" failed\n";
	if(!report.empty())atomicWrite(report,Json(Json::Object{{"passed",t.passed},{"failed",t.failed},{"results",t.results},{"liveDisplayWrites",0},{"fixtureBackendsOnly",true}}).dump()+"\n");
	CoUninitialize(); return t.failed ? 1 : 0;
}
