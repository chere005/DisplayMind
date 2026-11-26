#pragma once
#include "json.hpp"
#include <optional>
#include <set>
#include <functional>

namespace dm {
struct Mode {
	int width = 1920, height = 1080, numerator = 60, denominator = 1;
	double hz() const { return denominator ? double(numerator) / denominator : 0; }
	bool operator==(const Mode&) const = default;
};
struct MonitorIdentity {
	int vendor = 0, product = 0;
	std::string serial, name;
	bool operator==(const MonitorIdentity&) const = default;
};
struct Display {
	std::string id, name, mirror;
	Mode mode;
	int rotation = 0, x = 0, y = 0;
	bool enabled = true, wireless = false;
	MonitorIdentity monitor;
	bool operator==(const Display&) const = default;
};
struct AudioDevice {
	std::string id, name;
	bool input = false, bluetooth = false;
	bool operator==(const AudioDevice&) const = default;
};
struct Audio {
	std::string output, input;
	bool operator==(const Audio&) const = default;
};
struct Preset {
	std::string id, name;
	std::vector<Display> displays;
	bool confirmed = false;
	std::string receiver, wirelessDisplay;
	Audio audio;
	std::string outputName, inputName;
	std::string folder;
	bool operator==(const Preset&) const = default;
};
struct Device {
	std::string id, name;
	bool usb = false;
	MonitorIdentity monitor;
	bool operator==(const Device&) const = default;
};
struct Rule {
	std::string id, name, preset;
	std::vector<Device> required, absent;
	bool exact = true, enabled = true;
	bool operator==(const Rule&) const = default;
};
struct PresetFolder {
	std::string id, name;
	bool collapsed = false;
	bool operator==(const PresetFolder&) const = default;
};
struct Settings {
	int schema = 1;
	bool automatic = true;
	std::vector<Preset> presets;
	std::vector<Rule> rules;
	std::vector<Device> known;
	std::vector<PresetFolder> folders;
	bool operator==(const Settings&) const = default;
};
struct Hardware {
	std::vector<Display> displays;
	std::vector<Device> devices;
	std::vector<AudioDevice> audioDevices;
	Audio audio;
	std::vector<Audio> roleAudio;
	std::string audioError;
	std::map<std::string, std::vector<Mode>> modes;
};
std::string newId();
std::string trim(std::string s);
void validate(const std::vector<Display>& displays);
void validate(const Preset& preset);
void validate(const Settings& settings);
bool sameLayout(const std::vector<Display>& a, const std::vector<Display>& b);
bool matches(const std::vector<Display>& wanted, const std::vector<Display>& actual);
bool matchesEntireLayout(const std::vector<Display>& wanted, const std::vector<Display>& actual);
std::string arrangementIssue(const std::vector<Display>& displays);
std::optional<std::pair<int, int>> snappedPosition(const std::vector<Display>& displays, const std::string& moving, int x, int y);
std::vector<Display> layoutWithExtraDisplays(const std::vector<Display>& wanted, const std::vector<Display>& current);
std::map<std::string, std::string> reconnectMonitors(Settings& settings, const Hardware& hardware);
bool includesDisplays(const Preset& preset, const std::set<std::string>& ids, bool all);
void makeMain(std::vector<Display>& displays, const std::string& id);
std::string unavailable(const Preset& preset, const Hardware& hardware);
const Rule* matchRule(const Settings& settings, const Hardware& hardware);
std::set<std::string> deviceIds(const Hardware& hardware);
Audio audioApplicable(const Audio& wanted, const Audio& current, const std::vector<AudioDevice>& devices);
std::vector<Audio> audioRolesForSelection(const Audio& wanted, const Hardware& hardware, bool protectBluetooth);
Audio audioTakeover(const Audio& wanted, const Audio& previous, const std::vector<AudioDevice>& previousDevices, const std::vector<AudioDevice>& now);
class ConnectionGate {
	std::optional<std::set<std::string>> candidate, consumed;
	int64_t since = 0;
public:
	void reset() { candidate.reset(); consumed.reset(); }
	void consume(const std::set<std::string>& ids, int64_t now) { candidate = consumed = ids; since = now; }
	bool evaluate(const std::set<std::string>& ids, int64_t now, int64_t settle = 3000);
	bool pending() const { return candidate != consumed; }
};
Json encode(const Display& d);
Json encode(const Settings& s);
Display decodeDisplay(const Json& j);
Settings decodeSettings(const Json& j);
Settings demoSettings();
Hardware demoHardware();
struct Backend {
	virtual ~Backend() = default;
	virtual Hardware read() = 0;
	virtual std::vector<Display> readLayout() { return read().displays; }
	virtual void apply(const std::vector<Display>& layout, bool restore = false) = 0;
	virtual std::string setAudio(const Audio& selection, bool protectBluetooth = true) = 0;
	virtual std::string restoreAudio(const Audio& selection, const std::vector<Audio>& roles) = 0;
	virtual void connect(const std::string& receiver, const std::string& display) = 0;
	virtual void disconnect(const std::string& receiver, const std::string& display) = 0;
};
class FixtureBackend : public Backend {
public:
	Hardware hardware = demoHardware();
	int writes = 0, fails = 0, wrongReads = 0;
	int connectFailures = 0, disconnectFailures = 0;
	std::string audioFailure;
	std::map<std::string,Display> wirelessReceivers;
	std::vector<std::string> wirelessCalls;
	Hardware read() override { return hardware; }
	void apply(const std::vector<Display>& layout, bool = false) override;
	std::string setAudio(const Audio& selection, bool protectBluetooth = true) override;
	std::string restoreAudio(const Audio& selection, const std::vector<Audio>& roles) override;
	void connect(const std::string& receiver, const std::string& display) override;
	void disconnect(const std::string& receiver, const std::string& display) override;
};
}
