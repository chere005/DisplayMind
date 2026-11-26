#include "recovery.hpp"
#include <thread>
#include <chrono>

namespace dm {
int64_t processCreation(DWORD pid) {
	HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid); if (!h) return 0;
	FILETIME created{}, exited{}, kernel{}, user{}; bool ok = GetProcessTimes(h, &created, &exited, &kernel, &user) != 0; CloseHandle(h);
	ULARGE_INTEGER n{}; n.LowPart = created.dwLowDateTime; n.HighPart = created.dwHighDateTime; return ok ? static_cast<int64_t>(n.QuadPart) : 0;
}
bool processAlive(DWORD pid, int64_t created) {
	HANDLE h = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid); if (!h) return false;
	bool alive = WaitForSingleObject(h, 0) == WAIT_TIMEOUT; CloseHandle(h); return alive && created != 0 && processCreation(pid) == created;
}
std::wstring recoveryLockName(const fs::path& folder) {
	// Stable FNV hash, independent of the C++ library's randomized hash behavior.
	uint64_t hash = 14695981039346656037ull; auto s = fs::absolute(folder).lexically_normal().wstring();
	for (auto c : s) { hash ^= static_cast<uint64_t>(towlower(c)); hash *= 1099511628211ull; }
	return L"Local\\DisplayMind.Recovery." + std::to_wstring(hash);
}
Json encode(const Journal& j) {
	Json::Array ds, stopped, audioRoles; for (const auto& d : j.previous) ds.push_back(encode(d));
	for (const auto& role:j.roleAudio) audioRoles.push_back(Json::Object{{"output",role.output},{"input",role.input}});
	for (const auto& [receiver, display] : j.stopped) stopped.push_back(Json::Object{{"receiver", receiver}, {"display", display}});
	return Json::Object{{"schemaVersion", j.schema}, {"id", j.id}, {"state", j.state}, {"preset", j.preset}, {"deadline", j.deadline}, {"owner", static_cast<int64_t>(j.owner)}, {"ownerCreated", j.ownerCreated}, {"fixture", j.fixture}, {"restoreDisplay", j.restoreDisplay}, {"previous", ds}, {"audioOutput", j.audio.output}, {"audioInput", j.audio.input}, {"audioRoles",audioRoles}, {"startedReceiver", j.startedReceiver}, {"startedDisplay", j.startedDisplay}, {"stopped", stopped}};
}
Journal decodeJournal(const Json& v) {
	Journal j; j.schema = v.at("schemaVersion").number(); j.id = v.at("id").string(); j.state = v.at("state").string(); j.preset = v.str("preset"); j.deadline = v.at("deadline").integer(); j.owner = static_cast<DWORD>(v.at("owner").integer()); j.ownerCreated = v.at("ownerCreated").integer(); j.fixture = v.flag("fixture");
	j.restoreDisplay = v.flag("restoreDisplay", true);
	for (const auto& d : v.at("previous").array()) j.previous.push_back(decodeDisplay(d)); j.audio = {v.str("audioOutput"), v.str("audioInput")}; j.startedReceiver = v.str("startedReceiver"); j.startedDisplay = v.str("startedDisplay");
	for (const auto& s : v.at("stopped").array()) j.stopped.emplace_back(s.at("receiver").string(), s.at("display").string());
	if (v.has("audioRoles")) for (const auto& a:v.at("audioRoles").array()) j.roleAudio.push_back({a.str("output"),a.str("input")});
	if (j.schema != 1 || j.id.empty() || j.id.size() > 128 || j.id.find_first_of("/\\:") != j.id.npos || (j.state != "applying" && j.state != "verified" && j.state != "revert")) throw std::runtime_error("Invalid recovery journal. It has been preserved.");
	validate(j.previous);
	if (j.fixture) for (const auto& d : j.previous) if (!d.id.starts_with("fixture:")) throw std::runtime_error("Fixture recovery contains a real display identity");
	return j;
}
RecoveryAction recoveryAction(const Journal& j, int64_t now, bool alive) {
	if (j.state == "revert") return RecoveryAction::restore;
	if (j.state == "verified") return now >= j.deadline || !alive ? RecoveryAction::keep : RecoveryAction::wait;
	return !alive || now >= j.deadline ? RecoveryAction::restore : RecoveryAction::wait;
}
std::optional<Journal> Recovery::pending() const {
	Mutex lock(recoveryLockName(folder)); if (!fs::exists(journalPath())) return {}; return decodeJournal(Json::parse(readText(journalPath())));
}
std::optional<Journal> Recovery::inFlight() const {
	Mutex lock(recoveryLockName(folder));
	if (fs::exists(journalPath())) return decodeJournal(Json::parse(readText(journalPath())));
	if (fs::exists(folder)) for (const auto& entry : fs::directory_iterator(folder)) {
		if (entry.path().filename().wstring().starts_with(L"restoring-") && entry.path().extension() == L".json") return decodeJournal(Json::parse(readText(entry.path())));
	}
	return {};
}
void Recovery::begin(Journal j) {
	Mutex lock(recoveryLockName(folder)); if (fs::exists(journalPath())) throw std::runtime_error("A previous display change is still being recovered");
	for (const auto& e : fs::directory_iterator(folder)) if (e.path().filename().wstring().starts_with(L"restoring-") && e.path().extension() == L".json") throw std::runtime_error("A previous rollback needs recovery. Open the data folder for its saved snapshot.");
	(void)decodeJournal(encode(j)); atomicWrite(journalPath(), encode(j).dump());
}
void Recovery::update(const std::string& id, const std::function<void(Journal&)>& change) {
	Mutex lock(recoveryLockName(folder)); if (!fs::exists(journalPath())) throw std::runtime_error("The recovery process has already claimed this change");
	auto j = decodeJournal(Json::parse(readText(journalPath()))); if (j.id != id) throw std::runtime_error("Recovery change identifier does not match"); change(j); atomicWrite(journalPath(), encode(j).dump());
}
void Recovery::verified(const std::string& id, int64_t until) { update(id, [&](auto& j) { if (j.state != "applying") throw std::runtime_error("This change is already being reverted"); j.state = "verified"; j.deadline = until; }); }
void Recovery::keep(const std::string& id) {
	Mutex lock(recoveryLockName(folder)); if (!fs::exists(journalPath())) {
		if (fs::exists(resultPath())) { auto result=Json::parse(readText(resultPath())); if (result.str("id")==id && result.flag("kept")) return; }
		throw std::runtime_error("This display change is being reverted or has already been restored");
	} auto j = decodeJournal(Json::parse(readText(journalPath())));
	if (j.id != id || j.state != "verified") throw std::runtime_error("Only a verified layout can be kept");
	atomicWrite(resultPath(), Json(Json::Object{{"id", id}, {"preset",j.preset}, {"kept", true}, {"error", ""}}).dump());
	if (!DeleteFileW(journalPath().c_str())) throw std::runtime_error("Cannot close recovery journal");
}
void Recovery::revert(const std::string& id) { update(id, [](auto& j) { j.state = "revert"; }); }
void Recovery::watch(bool fixture, const fs::path& program, bool awaitReady) {
	auto j = inFlight();
	if (!j) return;
	if (j->fixture != fixture) throw std::runtime_error("Refusing to mix fixture and live recovery");
	startProcess(program, {L"--watchdog", folder.wstring(), fixture ? L"--fixture" : L"--live"});
	if (!awaitReady || !fs::exists(journalPath())) return;
	const auto until = GetTickCount64() + 6000;
	while (GetTickCount64()<until) {
		const auto ready=folder/L"watchdog-ready.json";
		if (fs::exists(ready)) { auto r=Json::parse(readText(ready)); if (r.str("id")==j->id && r.flag("fixture")==fixture) return; }
		std::this_thread::sleep_for(std::chrono::milliseconds(20));
	} throw std::runtime_error("The independent recovery process did not become ready; the layout has not been changed");
}
std::optional<std::string> Recovery::result(const std::string& id) const {
	Mutex lock(recoveryLockName(folder)); if (!fs::exists(resultPath())) return {}; auto j = Json::parse(readText(resultPath())); if (j.str("id") != id) return {}; return j.str("error");
}
std::string Recovery::retryFailed(bool fixture) {
	Mutex lock(recoveryLockName(folder));
	if (fs::exists(journalPath())) throw std::runtime_error("A display change is still pending");
	for (const auto& entry:fs::directory_iterator(folder)) if (entry.path().filename().wstring().starts_with(L"restoring-") && entry.path().extension()==L".json") {
		auto j=decodeJournal(Json::parse(readText(entry.path()))); if (j.fixture!=fixture) throw std::runtime_error("Recovery mode does not match this app");
		if (fs::exists(resultPath())) {
			auto result=Json::parse(readText(resultPath())); if (result.str("id")==j.id) { atomicWrite(folder/(L"recovery-history-"+wide(j.id)+L".json"),result.dump()); if (!DeleteFileW(resultPath().c_str())) throw std::runtime_error("Cannot prepare recovery retry"); }
		} return j.id;
	} throw std::runtime_error("There is no failed recovery snapshot to retry");
}
ApplyOutcome applyPreset(Backend& backend, Recovery& recovery, const Preset& requested, bool fixture, const std::vector<Preset>& known, const fs::path& program, int revertMs) {
	validate(requested);
	auto before = backend.read();
	Settings snapshot; snapshot.presets = known; snapshot.presets.push_back(requested);
	reconnectMonitors(snapshot, before);
	const auto p = snapshot.presets.back();
	auto missing = unavailable(p, before); if (!missing.empty()) throw std::runtime_error(missing);
	std::vector<std::pair<std::string, std::string>> stopWireless;
	for (const auto& d : before.displays) {
		if (!d.wireless || std::any_of(p.displays.begin(), p.displays.end(), [&](const Display& wanted) { return d.id == wanted.id && wanted.enabled; })) continue;
		std::set<std::string> receivers;
		for (const auto& saved : known) if (saved.wirelessDisplay == d.id && !saved.receiver.empty()) receivers.insert(saved.receiver);
		if (receivers.size() > 1) throw std::runtime_error("More than one receiver name is saved for " + d.name + ". Use the same Windows Cast name in its presets.");
		if (!receivers.empty()) stopWireless.emplace_back(*receivers.begin(), d.id);
	}
	bool startWireless = !p.receiver.empty() && std::none_of(before.displays.begin(), before.displays.end(), [&](const Display& d) { return d.id == p.wirelessDisplay && d.wireless; });
	bool layoutChanges = !matches(p.displays, before.displays) || startWireless || !stopWireless.empty();
	auto applyAudio = [&] {
		try { return backend.setAudio(p.audio); }
		catch (const std::exception& e) { return std::string("Sound selection failed: ") + e.what(); }
	};
	auto defaults = before.roleAudio;
	if (defaults.empty()) defaults.push_back(before.audio);
	auto audioPlan = audioRolesForSelection(p.audio, before, true);
	bool audioChanges = false;
	std::vector<Audio> restoreRoles;
	for (size_t role = 0; role < defaults.size(); ++role) {
		Audio restore;
		for (bool input : {false, true}) {
			const auto& desired = input ? audioPlan[role].input : audioPlan[role].output;
			const auto& current = input ? defaults[role].input : defaults[role].output;
			bool changes = !desired.empty() && desired != current && std::any_of(before.audioDevices.begin(), before.audioDevices.end(), [&](const AudioDevice& d) { return d.input == input && d.id == desired; });
			audioChanges |= changes;
			if (changes || (layoutChanges && !desired.empty())) (input ? restore.input : restore.output) = current;
		}
		restoreRoles.push_back(restore);
	}
	if (!layoutChanges && !audioChanges) {
		if (p.audio != Audio{} && !before.audioError.empty()) return {"", "Sound selection failed: " + before.audioError};
		std::string note;
		for (bool input : {false, true}) {
			const auto& id = input ? p.audio.input : p.audio.output;
			if (!id.empty() && std::none_of(before.audioDevices.begin(), before.audioDevices.end(), [&](const AudioDevice& d) { return d.input == input && d.id == id; })) note += input ? "Saved input is not connected. " : "Saved output is not connected. ";
		}
		return {"", trim(note)};
	}
	Journal j; j.id = newId(); j.preset = p.id; j.deadline = utcMillis() + 120000; j.owner = GetCurrentProcessId(); j.ownerCreated = processCreation(j.owner); j.fixture = fixture; j.previous = before.displays;
	j.restoreDisplay = layoutChanges;
	j.audio = restoreRoles.front();
	if (!before.roleAudio.empty()) j.roleAudio = std::move(restoreRoles);
	fs::create_directories(recovery.journalPath().parent_path()); recovery.begin(j);
	try { recovery.watch(fixture, program); } catch (...) { recovery.verified(j.id,utcMillis()); recovery.keep(j.id); throw; }
	try {
		// Only disconnect streams with a saved exact receiver identity. Record intent
		// before touching Windows so the watchdog owns partial wireless changes too.
		for (const auto& [receiver, display] : stopWireless) {
			recovery.update(j.id, [&](auto& state) { state.stopped.emplace_back(receiver, display); });
			backend.disconnect(receiver, display);
		}
		if (startWireless) {
			recovery.update(j.id, [&](auto& state) { state.startedReceiver = p.receiver; state.startedDisplay = p.wirelessDisplay; }); backend.connect(p.receiver, p.wirelessDisplay);
		}
		std::string last;
		for (int attempt = 0; layoutChanges && attempt < 3; ++attempt) {
			recovery.update(j.id,[](auto& state) { if (state.state!="applying" || state.deadline<=utcMillis()) throw std::runtime_error("Recovery has taken ownership of this display change"); });
			try {
				auto expected = layoutWithExtraDisplays(p.displays, backend.readLayout());
				backend.apply(expected);
				for (int check = 0; check < 4; ++check) { if (matches(expected, backend.readLayout())) { last.clear(); break; } last = "Windows did not keep the requested layout"; std::this_thread::sleep_for(std::chrono::milliseconds(fixture ? 1 : 350)); }
				if (last.empty()) break;
			} catch (const std::exception& e) { last = e.what(); }
			if (attempt == 2) throw std::runtime_error(last);
		}
		auto note = applyAudio();
		auto until = utcMillis() + revertMs;
		recovery.verified(j.id, until);
		return {j.id, note, until};
	} catch (...) { try { recovery.revert(j.id); } catch (...) {} throw; }
}
static void restoreJournal(Backend& backend, const Journal& j) {
	std::string errors;
	if (!j.startedReceiver.empty()) try { backend.disconnect(j.startedReceiver, j.startedDisplay); } catch (const std::exception& e) { errors += e.what(); errors += "; "; }
	for (const auto& [receiver, display] : j.stopped) try { backend.connect(receiver, display); } catch (const std::exception& e) { errors += e.what(); errors += "; "; }
	if (j.restoreDisplay) try {
		auto current = backend.read();
		Settings snapshot;
		Preset saved;
		saved.displays = j.previous;
		snapshot.presets.push_back(std::move(saved));
		reconnectMonitors(snapshot, current);
		const auto& previous = snapshot.presets.front().displays;
		bool verified = matchesEntireLayout(previous, current.displays);
		std::string last;
		for (int attempt = 0; attempt < 3 && !verified; ++attempt) {
			try {
				backend.apply(previous, true);
				for (int check = 0; check < 4 && !verified; ++check) {
					verified = matchesEntireLayout(previous, backend.readLayout());
					if (!verified) std::this_thread::sleep_for(std::chrono::milliseconds(j.fixture ? 1 : 350));
				}
			} catch (const std::exception& e) { last = e.what(); }
			if (!verified) std::this_thread::sleep_for(std::chrono::milliseconds(j.fixture ? 1 : 350));
		}
		if (!verified) throw std::runtime_error(last.empty() ? "Windows did not verify the restored layout" : last);
	} catch (const std::exception& e) { errors += e.what(); errors += "; "; }
	try { errors += backend.restoreAudio(j.audio,j.roleAudio); } catch (const std::exception& e) { errors += e.what(); }
	if (!errors.empty()) throw std::runtime_error(errors);
}
int runWatchdog(const fs::path& folder, bool fixture, FixtureBackend* testBackend) {
	if (testBackend && !fixture) throw std::runtime_error("Injected backends require fixture recovery");
	std::unique_ptr<Backend> ownedBackend = fixture ? std::unique_ptr<Backend>(new FixtureBackend) : std::unique_ptr<Backend>(new WindowsBackend);
	Backend* backend=testBackend ? testBackend : ownedBackend.get();
	// Only one watchdog may run per data folder, even after an app restart.
	try {
		Mutex single(recoveryLockName(folder) + L".Watchdog", 5000);
		for (;;) {
			std::optional<Journal> claimed; fs::path restorePath;
			{
				Mutex lock(recoveryLockName(folder)); auto pending = folder / L"pending-change.json";
				if (fs::exists(pending)) {
					auto j = decodeJournal(Json::parse(readText(pending))); if (j.fixture != fixture) throw std::runtime_error("Refusing to mix fixture and live recovery");
					auto ready=folder/L"watchdog-ready.json";
					if (!fs::exists(ready) || Json::parse(readText(ready)).str("id")!=j.id) atomicWrite(ready,Json(Json::Object{{"id",j.id},{"fixture",fixture}}).dump());
					auto action = recoveryAction(j, utcMillis(), processAlive(j.owner, j.ownerCreated));
					if (action == RecoveryAction::keep) { atomicWrite(folder / L"recovery-result.json", Json(Json::Object{{"id", j.id}, {"preset",j.preset}, {"kept", true}, {"error", ""}}).dump()); if (!DeleteFileW(pending.c_str())) throw std::runtime_error("Cannot close recovery journal"); return 0; }
					if (action == RecoveryAction::restore) { restorePath = folder / (L"restoring-" + wide(j.id) + L".json"); checkWin(MoveFileExW(pending.c_str(), restorePath.c_str(), MOVEFILE_WRITE_THROUGH) ? ERROR_SUCCESS : GetLastError(), "Claim recovery journal"); claimed = j; }
				} else {
					for (const auto& entry : fs::directory_iterator(folder)) {
						if (!entry.path().filename().wstring().starts_with(L"restoring-") || entry.path().extension() != L".json") continue;
						auto j = decodeJournal(Json::parse(readText(entry.path()))); if (j.fixture != fixture) continue;
						// A recorded failure remains for inspection; an interrupted restore is retried.
						auto result = folder / L"recovery-result.json"; if (fs::exists(result)) { auto r = Json::parse(readText(result)); if (r.str("id") == j.id && !r.str("error").empty()) continue; }
						claimed = j; restorePath = entry.path(); break;
					}
					if (!claimed) return 0;
				}
			}
			if (claimed) {
				std::string error; try { restoreJournal(*backend, *claimed); } catch (const std::exception& e) { error = e.what(); }
				Mutex lock(recoveryLockName(folder)); atomicWrite(folder / L"recovery-result.json", Json(Json::Object{{"id", claimed->id}, {"kept", false}, {"error", error}}).dump());
				if (fixture) atomicWrite(folder / L"fixture-restored.json", diagnostics(*backend).dump());
				if (error.empty() && !DeleteFileW(restorePath.c_str())) checkWin(GetLastError(), "Close recovery snapshot");
				return error.empty() ? 0 : 1;
			}
			std::this_thread::sleep_for(std::chrono::milliseconds(200));
		}
	} catch (const std::exception& e) {
		try { atomicWrite(folder / L"watchdog-error.txt", e.what()); } catch (...) {} return 2;
	}
}
}
