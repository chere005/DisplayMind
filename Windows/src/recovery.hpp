#pragma once
#include "windows.hpp"

namespace dm {
struct Journal {
	int schema = 1;
	std::string id, state = "applying", preset;
	int64_t deadline = 0;
	DWORD owner = 0;
	int64_t ownerCreated = 0;
	bool fixture = false, restoreDisplay = true;
	std::vector<Display> previous;
	Audio audio;
	std::vector<Audio> roleAudio;
	std::string startedReceiver, startedDisplay;
	std::vector<std::pair<std::string, std::string>> stopped;
};
Json encode(const Journal& j);
Journal decodeJournal(const Json& j);
enum class RecoveryAction { wait, keep, restore };
RecoveryAction recoveryAction(const Journal& j, int64_t now, bool ownerAlive);
std::wstring recoveryLockName(const fs::path& folder);
class Recovery {
	fs::path folder;
public:
	explicit Recovery(fs::path directory) : folder(std::move(directory)) {}
	fs::path journalPath() const { return folder / L"pending-change.json"; }
	fs::path resultPath() const { return folder / L"recovery-result.json"; }
	std::optional<Journal> pending() const;
	std::optional<Journal> inFlight() const;
	void begin(Journal journal);
	void update(const std::string& id, const std::function<void(Journal&)>& change);
	void verified(const std::string& id, int64_t until);
	void keep(const std::string& id);
	void revert(const std::string& id);
	void watch(bool fixture, const fs::path& watchdogExecutable = executable(), bool awaitReady = true);
	std::string retryFailed(bool fixture);
	std::optional<std::string> result(const std::string& id) const;
};
struct ApplyOutcome { std::string id, note; int64_t until = 0; };
ApplyOutcome applyPreset(Backend& backend, Recovery& recovery, const Preset& preset, bool fixture, const std::vector<Preset>& knownPresets, const fs::path& watchdogExecutable = executable(), int revertMs = 10000);
int runWatchdog(const fs::path& folder, bool fixture, FixtureBackend* testBackend = nullptr);
int64_t processCreation(DWORD pid);
bool processAlive(DWORD pid, int64_t created);
}
