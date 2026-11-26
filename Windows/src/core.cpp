#include "core.hpp"
#include <algorithm>
#include <windows.h>
#include <objbase.h>
#include <limits>

namespace dm {
std::string newId() {
	GUID id{}; if (FAILED(CoCreateGuid(&id))) throw std::runtime_error("Could not create identifier");
	wchar_t text[40]{}; StringFromGUID2(id, text, 40); std::string out;
	for (auto c : text) if (c) out += char(c); return out;
}
std::string trim(std::string s) {
	auto first = s.find_first_not_of(" \t\r\n"); if (first == s.npos) return {};
	return s.substr(first, s.find_last_not_of(" \t\r\n") - first + 1);
}
static void require(bool b, const std::string& why) { if (!b) throw std::runtime_error(why); }
static bool label(const std::string& s, size_t limit = 256) { return !trim(s).empty() && s.size() <= limit && s.find_first_of("\r\n") == s.npos && s.find('\0') == s.npos; }
void validate(const std::vector<Display>& ds) {
	require(!ds.empty() && ds.size() <= 32, "A preset needs between 1 and 32 displays.");
	std::set<std::string> ids; int main = 0;
	for (const auto& d : ds) {
		require(label(d.id, 2048) && ids.insert(d.id).second, "A display identifier is invalid or duplicated.");
		require(label(d.name), "A display name is invalid.");
		require(d.rotation == 0 || d.rotation == 90 || d.rotation == 180 || d.rotation == 270, "Choose a quarter-turn rotation.");
		require(d.x >= -100000 && d.x <= 100000 && d.y >= -100000 && d.y <= 100000, "Positions must be between -100,000 and 100,000.");
		require(d.mode.width > 0 && d.mode.width <= 32768 && d.mode.height > 0 && d.mode.height <= 32768 && d.mode.numerator >= 0 && d.mode.denominator > 0 && d.mode.denominator <= 1000000 && d.mode.hz() <= 1000, "Invalid display resolution or refresh rate.");
		if (!d.mirror.empty()) {
			auto source = std::find_if(ds.begin(), ds.end(), [&](const auto& s) { return s.id == d.mirror; });
			require(source != ds.end() && source->id != d.id && source->mirror.empty() && source->enabled && d.enabled, "A mirror must use another enabled, extended display as its source.");
		}
		if (d.enabled && d.mirror.empty() && d.x == 0 && d.y == 0) ++main;
	}
	require(main == 1, "Choose exactly one main display at position (0, 0).");
}
void validate(const Preset& p) {
	require(label(p.id, 128) && label(p.name), "Give the preset a name (up to 256 UTF-8 bytes)."); validate(p.displays);
	if (!p.receiver.empty()) {
		require(label(p.receiver), "Invalid wireless receiver name.");
		require(std::any_of(p.displays.begin(), p.displays.end(), [&](const auto& d) { return d.id == p.wirelessDisplay && d.enabled && d.wireless; }), "Choose the wireless display belonging to this receiver.");
	}
	for (auto id : {p.audio.output, p.audio.input}) require(id.empty() || label(id, 2048), "Invalid audio endpoint identifier.");
	for (const auto& name:{p.outputName,p.inputName}) require(name.empty() || label(name),"Invalid saved audio device name.");
}
void validate(const Settings& s) {
	require(s.schema == 1, "These Windows settings are from a newer DisplayMind. The file has been preserved.");
	require(s.presets.size() <= 1000 && s.rules.size() <= 1000 && s.known.size() <= 10000 && s.folders.size() <= 1000, "Settings contain too many entries.");
	std::set<std::string> folders;
	for (const auto& f : s.folders) require(label(f.id, 128) && label(f.name) && folders.insert(f.id).second, "Invalid or duplicate preset folder.");
	std::set<std::string> ids;
	for (const auto& p : s.presets) {
		validate(p);
		require(ids.insert(p.id).second, "Duplicate preset identifiers. The file has been preserved.");
		require(p.folder.empty() || folders.count(p.folder), "A preset refers to a missing folder.");
	}
	ids.clear();
	for (const auto& r : s.rules) {
		require(label(r.id, 128) && label(r.name) && ids.insert(r.id).second, "Invalid or duplicate rule identifier.");
		require(std::any_of(s.presets.begin(), s.presets.end(), [&](const auto& p) { return p.id == r.preset; }), "A connection rule refers to a missing preset.");
		require(!r.required.empty() || !r.absent.empty(), "Mark at least one device Connected or Absent.");
		std::set<std::string> conditions;
		for (const auto* group : {&r.required, &r.absent}) for (const auto& d : *group) require(label(d.id, 2048) && label(d.name) && conditions.insert(d.id).second, "A rule has duplicate or conflicting conditions.");
	}
	for (const auto& d : s.known) require(label(d.id, 2048) && label(d.name), "Invalid remembered device.");
}
bool sameLayout(const std::vector<Display>& a, const std::vector<Display>& b) {
	if (a.size() != b.size()) return false;
	for (auto d : a) {
		auto i = std::find_if(b.begin(), b.end(), [&](const auto& v) { return v.id == d.id; }); if (i == b.end()) return false;
		d.name = i->name; d.monitor = i->monitor; if (d != *i) return false;
	} return true;
}
bool matches(const std::vector<Display>& wanted, const std::vector<Display>& actual) {
	auto source = [](const Display& display) -> const std::string& { return display.mirror.empty() ? display.id : display.mirror; };
	std::set<std::string> roots;
	for (const auto& d : wanted) {
		auto i = std::find_if(actual.begin(), actual.end(), [&](const auto& a) { return d.id == a.id; });
		if (!d.enabled) {
			if (i != actual.end() && i->enabled) return false;
			continue;
		}
		if (i == actual.end() || !i->enabled) return false;
		// Windows can enumerate the destinations in a clone group in either order.
		if (!d.mirror.empty()) {
			auto root = std::find_if(actual.begin(), actual.end(), [&](const auto& a) { return a.id == d.mirror; });
			if (root == actual.end() || !root->enabled || source(*i) != source(*root)) return false;
			continue;
		}
		if (!roots.insert(source(*i)).second) return false;
		if (d.x != i->x || d.y != i->y || d.rotation != i->rotation || d.mode.width != i->mode.width || d.mode.height != i->mode.height || (d.mode.numerator && std::abs(d.mode.hz() - i->mode.hz()) > 1.01)) return false;
	} return true;
}
bool matchesEntireLayout(const std::vector<Display>& wanted, const std::vector<Display>& actual) {
	return matches(wanted, actual) && std::none_of(actual.begin(), actual.end(), [&](const Display& d) {
		return d.enabled && std::none_of(wanted.begin(), wanted.end(), [&](const Display& w) { return w.id == d.id; });
	});
}
static bool overlaps(const Display& a, const Display& b) {
	return a.x < b.x + b.mode.width && b.x < a.x + a.mode.width
		&& a.y < b.y + b.mode.height && b.y < a.y + a.mode.height;
}
static bool touches(const Display& a, const Display& b) {
	return a.x <= b.x + b.mode.width && b.x <= a.x + a.mode.width
		&& a.y <= b.y + b.mode.height && b.y <= a.y + a.mode.height;
}
std::string arrangementIssue(const std::vector<Display>& displays) {
	std::vector<const Display*> extended;
	for (const auto& d : displays) if (d.enabled && d.mirror.empty()) extended.push_back(&d);
	if (extended.size() < 2) return {};
	for (size_t i = 0; i < extended.size(); ++i) for (size_t j = i + 1; j < extended.size(); ++j)
		if (overlaps(*extended[i], *extended[j])) return extended[i]->name + " and " + extended[j]->name
			+ " overlap. Drag them apart or use Place beside so Windows can keep the saved arrangement.";
	std::set<size_t> seen{0};
	std::vector<size_t> queue{0};
	while (!queue.empty()) {
		auto i = queue.back(); queue.pop_back();
		for (size_t j = 0; j < extended.size(); ++j) if (!seen.contains(j) && touches(*extended[i], *extended[j])) {
			seen.insert(j); queue.push_back(j);
		}
	}
	for (size_t i = 0; i < extended.size(); ++i) if (!seen.contains(i)) return extended[i]->name
		+ " is separated from the other displays. Drag it against another display or use Place beside.";
	return {};
}
std::optional<std::pair<int, int>> snappedPosition(const std::vector<Display>& displays, const std::string& moving, int x, int y) {
	auto me = std::find_if(displays.begin(), displays.end(), [&](const Display& d) { return d.id == moving && d.enabled && d.mirror.empty(); });
	if (me == displays.end()) return std::pair{x, y};
	std::vector<const Display*> others;
	for (const auto& d : displays) if (d.id != moving && d.enabled && d.mirror.empty()) others.push_back(&d);
	if (others.empty()) return std::pair{x, y};
	std::optional<std::pair<int, int>> best;
	int64_t distance = std::numeric_limits<int64_t>::max();
	for (auto other : others) {
		int cy = std::clamp(y, other->y - me->mode.height, other->y + other->mode.height);
		int cx = std::clamp(x, other->x - me->mode.width, other->x + other->mode.width);
		for (auto [px, py] : {std::pair{other->x + other->mode.width, cy}, std::pair{other->x - me->mode.width, cy},
			std::pair{cx, other->y - me->mode.height}, std::pair{cx, other->y + other->mode.height}}) {
			if (px < -100000 || px > 100000 || py < -100000 || py > 100000) continue;
			auto candidate = *me; candidate.x = px; candidate.y = py;
			if (std::any_of(others.begin(), others.end(), [&](auto d) { return overlaps(candidate, *d); })) continue;
			int64_t dx = int64_t(px) - x, dy = int64_t(py) - y, d = dx * dx + dy * dy;
			if (d < distance) { best = {px, py}; distance = d; }
		}
	}
	return best;
}
std::vector<Display> layoutWithExtraDisplays(const std::vector<Display>& wanted, const std::vector<Display>& current) {
	auto layout = wanted;
	for (const auto& display : current) {
		if (std::any_of(wanted.begin(), wanted.end(), [&](const Display& d) { return d.id == display.id; })) continue;
		layout.push_back(display);
	}
	for (size_t i = wanted.size(); i < layout.size(); ++i) {
		auto& extra = layout[i];
		if (!extra.enabled || extra.mirror.empty()) continue;
		auto source = std::find_if(layout.begin(), layout.end(), [&](const Display& d) { return d.id == extra.mirror; });
		// A retained clone can follow its old source into a new clone group.
		// If that source is no longer enabled, extend this display independently.
		if (source == layout.end() || !source->enabled) extra.mirror.clear();
		else if (!source->mirror.empty()) extra.mirror = source->mirror;
	}
	for (size_t i = wanted.size(); i < layout.size(); ++i) {
		auto& extra = layout[i];
		if (!extra.enabled || !extra.mirror.empty()) continue;
		const Display* rightmost = nullptr;
		bool overlaps = false;
		for (size_t j = 0; j < i; ++j) {
			const auto& other = layout[j];
			if (!other.enabled || !other.mirror.empty()) continue;
			if (!rightmost || other.x + other.mode.width > rightmost->x + rightmost->mode.width) rightmost = &other;
			overlaps |= extra.x < other.x + other.mode.width && other.x < extra.x + extra.mode.width
				&& extra.y < other.y + other.mode.height && other.y < extra.y + extra.mode.height;
		}
		if (overlaps && rightmost) {
			extra.x = rightmost->x + rightmost->mode.width;
			extra.y = rightmost->y;
		}
	}
	return layout;
}
bool includesDisplays(const Preset& preset, const std::set<std::string>& ids, bool all) {
	if (ids.empty()) return true;
	auto has = [&](const std::string& id) {
		return std::any_of(preset.displays.begin(), preset.displays.end(), [&](const Display& display) { return display.id == id; });
	};
	return all ? std::all_of(ids.begin(), ids.end(), has) : std::any_of(ids.begin(), ids.end(), has);
}
std::map<std::string, std::string> reconnectMonitors(Settings& settings, const Hardware& hardware) {
	std::map<std::string, MonitorIdentity> saved, live;
	std::set<std::string> contradictory;
	auto sameIdentity = [](const MonitorIdentity& a, const MonitorIdentity& b) {
		return a.vendor == b.vendor && a.product == b.product && a.serial == b.serial;
	};
	auto remember = [&](const std::string& id, const MonitorIdentity& identity) {
		if (!identity.vendor || !identity.product) return;
		if (auto old = saved.find(id); old != saved.end() && !sameIdentity(old->second, identity)) contradictory.insert(id);
		else saved[id] = identity;
	};
	for (const auto& p : settings.presets) for (const auto& d : p.displays) {
		if (!d.wireless) remember(d.id, d.monitor);
	}
	for (const auto& r : settings.rules) for (const auto* group : {&r.required, &r.absent}) for (const auto& d : *group) {
		if (!d.usb && d.id.starts_with("display:")) remember(d.id.substr(8), d.monitor);
	}
	std::set<std::string> online;
	for (const auto& d : hardware.displays) {
		online.insert(d.id);
		if (!d.wireless) {
			if (live.contains(d.id)) contradictory.insert(d.id);
			else live[d.id] = d.monitor;
		}
	}
	std::map<std::string, std::string> rebound;
	for (const auto& [id, identity] : saved) {
		if (online.contains(id) || contradictory.contains(id)) continue;
		auto agrees = [&](const auto& item) {
			const auto& monitor = item.second;
			if (identity.vendor != monitor.vendor) return false;
			if (identity.serial.empty()) return identity.product == monitor.product;
			return identity.serial == monitor.serial && (identity.product == monitor.product
				|| (!identity.name.empty() && identity.name == monitor.name));
		};
		if (std::count_if(saved.begin(), saved.end(), agrees) != 1 || std::count_if(live.begin(), live.end(), agrees) != 1) continue;
		auto found = std::find_if(live.begin(), live.end(), agrees);
		if (!contradictory.contains(found->first) && !saved.contains(found->first)) rebound.emplace(id, found->first);
	}
	// A fallback match cannot claim a path that another saved monitor also matched.
	std::map<std::string, size_t> targetUses;
	for (const auto& [oldId, currentId] : rebound) ++targetUses[currentId];
	std::erase_if(rebound, [&](const auto& link) { return targetUses.at(link.second) != 1; });
	// A metadata-free reference at the new path must not merge with an old reference
	// in one preset or in a rule's Connected/Absent conditions.
	std::set<std::string> collisions;
	auto checkScope = [&](const std::vector<std::string>& ids) {
		std::map<std::string, std::set<std::string>> originals;
		for (const auto& id : ids) originals[rebound.contains(id) ? rebound.at(id) : id].insert(id);
		for (const auto& [target, sources] : originals) if (sources.size() > 1)
			for (const auto& id : sources) if (rebound.contains(id)) collisions.insert(id);
	};
	for (const auto& p : settings.presets) {
		std::vector<std::string> ids; for (const auto& d : p.displays) ids.push_back(d.id); checkScope(ids);
	}
	for (const auto& r : settings.rules) {
		std::vector<std::string> ids;
		for (const auto* group : {&r.required, &r.absent}) for (const auto& d : *group)
			if (!d.usb && d.id.starts_with("display:")) ids.push_back(d.id.substr(8));
		checkScope(ids);
	}
	for (const auto& id : collisions) rebound.erase(id);
	auto updateId = [&](std::string& id) { if (auto entry = rebound.find(id); entry != rebound.end()) id = entry->second; };
	auto learn = [&](const std::string& id, MonitorIdentity& identity) {
		if (contradictory.contains(id)) return;
		if (auto entry = live.find(id); entry != live.end() && entry->second.vendor && entry->second.product) {
			const auto& current = entry->second;
			bool physicalMatch = identity.vendor == current.vendor && !identity.serial.empty()
				&& identity.serial == current.serial && !identity.name.empty() && identity.name == current.name;
			if (!identity.vendor || sameIdentity(identity, current) || physicalMatch) identity = current;
		}
	};
	for (auto& p : settings.presets) for (auto& d : p.displays) {
		if (!d.wireless) { updateId(d.id); learn(d.id, d.monitor); }
		updateId(d.mirror);
	}
	auto updateDevice = [&](Device& device) {
		if (device.usb || !device.id.starts_with("display:")) return;
		auto id = device.id.substr(8);
		updateId(id); learn(id, device.monitor);
		device.id = "display:" + id;
	};
	for (auto& r : settings.rules) for (auto* group : {&r.required, &r.absent}) for (auto& d : *group) updateDevice(d);
	std::set<std::string> knownIds;
	for (auto& d : settings.known) updateDevice(d);
	std::erase_if(settings.known, [&](const Device& d) { return !knownIds.insert(d.id).second; });
	return rebound;
}
void makeMain(std::vector<Display>& ds, const std::string& id) {
	auto i = std::find_if(ds.begin(), ds.end(), [&](const auto& d) { return d.id == id && d.enabled && d.mirror.empty(); });
	if (i == ds.end()) return; const int x = i->x, y = i->y;
	for (auto& d : ds) { d.x -= x; d.y -= y; }
}
std::set<std::string> deviceIds(const Hardware& h) { std::set<std::string> ids; for (const auto& d : h.devices) ids.insert(d.id); return ids; }
std::string unavailable(const Preset& p, const Hardware& h) {
	std::string out;
	for (const auto& d : p.displays) if (d.enabled && std::none_of(h.displays.begin(), h.displays.end(), [&](const auto& c) { return c.id == d.id; }) && (p.receiver.empty() || p.wirelessDisplay != d.id)) { if (!out.empty()) out += ", "; out += d.name; }
	return out.empty() ? "" : "Connect " + out;
}
const Rule* matchRule(const Settings& s, const Hardware& h) {
	if (!s.automatic) return nullptr;
	auto ids = deviceIds(h);
	for (const auto& r : s.rules) {
		if (!r.enabled || (r.required.empty() && r.absent.empty())) continue;
		auto p = std::find_if(s.presets.begin(), s.presets.end(), [&](const auto& v) { return v.id == r.preset; });
		if (p == s.presets.end() || !p->confirmed || !unavailable(*p, h).empty()) continue;
		if (std::any_of(r.required.begin(), r.required.end(), [&](const auto& d) { return !ids.count(d.id); }) || std::any_of(r.absent.begin(), r.absent.end(), [&](const auto& d) { return ids.count(d.id); })) continue;
		if (r.exact) {
			std::set<std::string> have, need;
			for (const auto& d : h.displays) if (p->receiver.empty() || d.id != p->wirelessDisplay) have.insert(d.id);
			for (const auto& d : p->displays) if (p->receiver.empty() || d.id != p->wirelessDisplay) need.insert(d.id);
			if (have != need) continue;
		} return &r;
	} return nullptr;
}
bool ConnectionGate::evaluate(const std::set<std::string>& ids, int64_t now, int64_t settle) {
	if (!candidate || *candidate != ids) { candidate = ids; since = now; }
	if (candidate == consumed || now - since < settle) return false;
	consumed = candidate; return true;
}
static bool bluetooth(const std::string& id, const std::vector<AudioDevice>& ds) { return !id.empty() && std::any_of(ds.begin(), ds.end(), [&](const auto& d) { return d.id == id && d.bluetooth; }); }
Audio audioApplicable(const Audio& wanted, const Audio& current, const std::vector<AudioDevice>& ds) {
	auto a = wanted;
	if (bluetooth(current.output, ds) && wanted.output != current.output) a.output.clear();
	if (bluetooth(current.input, ds) && wanted.input != current.input) a.input.clear(); return a;
}
std::vector<Audio> audioRolesForSelection(const Audio& wanted, const Hardware& hardware, bool protectBluetooth) {
	auto defaults = hardware.roleAudio;
	if (defaults.empty()) defaults.push_back(hardware.audio);
	auto selection = protectBluetooth ? audioApplicable(wanted, hardware.audio, hardware.audioDevices) : wanted;
	std::vector<Audio> roles;
	for (const auto& role : defaults) roles.push_back(protectBluetooth ? audioApplicable(selection, role, hardware.audioDevices) : selection);
	return roles;
}
Audio audioTakeover(const Audio& wanted, const Audio& previous, const std::vector<AudioDevice>& previousDevices, const std::vector<AudioDevice>& now) {
	auto gone = [&](const auto& id) { return bluetooth(id, previousDevices) && std::none_of(now.begin(), now.end(), [&](const auto& d) { return d.id == id; }); };
	return {gone(previous.output) ? wanted.output : "", gone(previous.input) ? wanted.input : ""};
}
static Json encodeMonitor(const MonitorIdentity& m) { return Json::Object{{"vendor",m.vendor},{"product",m.product},{"serial",m.serial},{"name",m.name}}; }
static MonitorIdentity decodeMonitor(const Json& owner) {
	if (!owner.has("monitor")) return {};
	const auto& m = owner.at("monitor");
	MonitorIdentity identity{m.num("vendor"), m.num("product"), m.str("serial"), m.str("name")};
	require(identity.vendor >= 0 && identity.vendor <= 65535 && identity.product >= 0 && identity.product <= 65535
		&& (identity.serial.empty() || label(identity.serial, 64)) && (identity.name.empty() || label(identity.name)), "Invalid monitor identity.");
	return identity;
}
Json encode(const Display& d) { return Json::Object{{"id", d.id}, {"name", d.name}, {"width", d.mode.width}, {"height", d.mode.height}, {"refreshNumerator", d.mode.numerator}, {"refreshDenominator", d.mode.denominator}, {"rotation", d.rotation}, {"x", d.x}, {"y", d.y}, {"mirrorOf", d.mirror}, {"enabled", d.enabled}, {"wireless", d.wireless}, {"monitor", encodeMonitor(d.monitor)}}; }
Display decodeDisplay(const Json& j) {
	Display d; d.id = j.at("id").string(); d.name = j.at("name").string(); d.mode = {j.at("width").number(), j.at("height").number(), j.num("refreshNumerator", 60), j.num("refreshDenominator", 1)};
	d.rotation = j.num("rotation"); d.x = j.num("x"); d.y = j.num("y"); d.mirror = j.str("mirrorOf"); d.enabled = j.flag("enabled", true); d.wireless = j.flag("wireless"); d.monitor = decodeMonitor(j); return d;
}
static Json encDevices(const std::vector<Device>& ds) { Json::Array a; for (const auto& d : ds) a.push_back(Json::Object{{"id", d.id}, {"name", d.name}, {"usb", d.usb}, {"monitor",encodeMonitor(d.monitor)}}); return a; }
static std::vector<Device> decDevices(const Json& j) { std::vector<Device> ds; for (const auto& d : j.array()) ds.push_back({d.at("id").string(), d.at("name").string(), d.flag("usb"), decodeMonitor(d)}); return ds; }
Json encode(const Settings& s) {
	Json::Array ps, rs, folders;
	for (const auto& p : s.presets) {
		Json::Array ds; for (const auto& d : p.displays) ds.push_back(encode(d));
		ps.push_back(Json::Object{{"id", p.id}, {"name", p.name}, {"displays", ds}, {"confirmed", p.confirmed}, {"receiver", p.receiver}, {"wirelessDisplay", p.wirelessDisplay}, {"audioOutput", p.audio.output}, {"audioInput", p.audio.input},{"audioOutputName",p.outputName},{"audioInputName",p.inputName},{"folder",p.folder}});
	}
	for (const auto& r : s.rules) rs.push_back(Json::Object{{"id", r.id}, {"name", r.name}, {"preset", r.preset}, {"required", encDevices(r.required)}, {"absent", encDevices(r.absent)}, {"exactDisplays", r.exact}, {"enabled", r.enabled}});
	for (const auto& f : s.folders) folders.push_back(Json::Object{{"id",f.id},{"name",f.name},{"collapsed",f.collapsed}});
	return Json::Object{{"schemaVersion", s.schema}, {"platform", "windows"}, {"automationEnabled", s.automatic}, {"presets", ps}, {"rules", rs}, {"knownDevices", encDevices(s.known)}, {"folders",folders}};
}
Settings decodeSettings(const Json& j) {
	Settings s; s.schema = j.at("schemaVersion").number();
	require(j.str("platform") == "windows", "These are not Windows settings. Mac identifiers and display modes cannot be applied on Windows.");
	s.automatic = j.flag("automationEnabled", true);
	for (const auto& v : j.at("presets").array()) {
		Preset p; p.id = v.at("id").string(); p.name = v.at("name").string(); p.confirmed = v.flag("confirmed"); p.receiver = v.str("receiver"); p.wirelessDisplay = v.str("wirelessDisplay"); p.audio = {v.str("audioOutput"), v.str("audioInput")};
		p.outputName=v.str("audioOutputName"); p.inputName=v.str("audioInputName"); p.folder=v.str("folder");
		for (const auto& d : v.at("displays").array()) p.displays.push_back(decodeDisplay(d)); s.presets.push_back(p);
	}
	for (const auto& v : j.at("rules").array()) { Rule r; r.id = v.at("id").string(); r.name = v.at("name").string(); r.preset = v.at("preset").string(); r.required = decDevices(v.at("required")); r.absent = decDevices(v.at("absent")); r.enabled = v.flag("enabled", true); r.exact = v.flag("exactDisplays", true); s.rules.push_back(r); }
	if (j.has("knownDevices")) s.known = decDevices(j.at("knownDevices"));
	if (j.has("folders")) for (const auto& f : j.at("folders").array()) s.folders.push_back({f.at("id").string(), f.at("name").string(), f.flag("collapsed")});
	validate(s); return s;
}
Hardware demoHardware() {
	Hardware h;
	Display a; a.id = "fixture:studio"; a.name = "Studio Display"; a.mode = {2560, 1440, 60, 1};
	Display b; b.id = "fixture:portrait"; b.name = "Portrait display"; b.mode = {1080, 1920, 60, 1}; b.rotation = 90; b.x = 2560;
	Display c; c.id = "fixture:laptop"; c.name = "Built-in display"; c.mode = {1920, 1200, 120, 1}; c.x = 400; c.y = 1440;
	h.displays = {a, b, c}; for (auto& d : h.displays) { h.devices.push_back({"display:" + d.id, d.name, false}); h.modes[d.id] = {d.mode, {1920, 1080, 60, 1}, {1280, 720, 60, 1}}; }
	h.devices.push_back({"usb:fixture-dock", "Desk dock", true});
	h.audioDevices = {{"fixture:speakers", "Studio Display Speakers", false, false}, {"fixture:headphones", "Bluetooth Headphones", false, true}, {"fixture:mic", "Microphone Array", true, false}};
	h.audio = {"fixture:speakers", "fixture:mic"}; return h;
}
Settings demoSettings() {
	Settings s; auto h = demoHardware(); Preset p; p.id = "fixture:desk"; p.name = "At my desk"; p.displays = h.displays; p.audio = h.audio; p.outputName="Studio Display Speakers"; p.inputName="Microphone Array"; p.confirmed = true; s.presets.push_back(p);
	p.id = "fixture:present"; p.name = "Presentation"; p.displays[1].mirror = p.displays[0].id; s.presets.push_back(p);
	p.id = "fixture:laptop"; p.name = "Just the laptop"; p.displays = {h.displays[2]}; p.displays[0].x = p.displays[0].y = 0; s.presets.push_back(p);
	Rule r; r.id = "fixture:rule"; r.name = "When I dock"; r.preset = s.presets[0].id; r.required = {h.devices.back()}; s.rules = {r}; s.known = h.devices; return s;
}
void FixtureBackend::apply(const std::vector<Display>& layout, bool restore) {
	++writes; if (fails-- > 0) throw std::runtime_error("Fixture driver rejected layout");
	hardware.displays = restore ? layout : layoutWithExtraDisplays(layout, hardware.displays);
	if (wrongReads-- > 0) hardware.displays[0].x += 42;
}
std::string FixtureBackend::setAudio(const Audio& a, bool protect) {
	return restoreAudio(a, audioRolesForSelection(a, hardware, protect));
}
std::string FixtureBackend::restoreAudio(const Audio& a, const std::vector<Audio>& roles) {
	if (!audioFailure.empty()) throw std::runtime_error(audioFailure);
	std::string note;
	auto select = [&](Audio& current, const Audio& plan) {
		for (bool input : {false, true}) {
			const auto& id = input ? plan.input : plan.output;
			if (id.empty()) continue;
			if (std::any_of(hardware.audioDevices.begin(), hardware.audioDevices.end(), [&](const AudioDevice& d) { return d.id == id && d.input == input; })) (input ? current.input : current.output) = id;
			else note += input ? "Saved input is not connected. " : "Saved output is not connected. ";
		}
	};
	select(hardware.audio, roles.empty() ? a : roles.front());
	for (size_t i = 0; i < hardware.roleAudio.size(); ++i) select(hardware.roleAudio[i], i < roles.size() ? roles[i] : a);
	return trim(note);
}
void FixtureBackend::connect(const std::string& receiver, const std::string& display) {
	if (!display.starts_with("fixture:")) throw std::runtime_error("Fixture receiver only"); wirelessCalls.push_back("connect:"+receiver+":"+display);
	if (connectFailures-- > 0) throw std::runtime_error("Fixture wireless connection timed out");
	auto d=wirelessReceivers.find(display); if (d!=wirelessReceivers.end() && std::none_of(hardware.displays.begin(),hardware.displays.end(),[&](const auto& v) { return v.id==display; })) { hardware.displays.push_back(d->second); hardware.devices.push_back({"display:"+display,d->second.name,false}); }
}
void FixtureBackend::disconnect(const std::string& receiver, const std::string& display) {
	if (!display.starts_with("fixture:")) throw std::runtime_error("Fixture receiver only"); wirelessCalls.push_back("disconnect:"+receiver+":"+display);
	if (disconnectFailures-- > 0) throw std::runtime_error("Fixture wireless disconnection failed");
	std::erase_if(hardware.displays,[&](const auto& d) { return d.id==display; }); std::erase_if(hardware.devices,[&](const auto& d) { return d.id=="display:"+display; });
}
}
