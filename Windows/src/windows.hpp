#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <filesystem>
#include <memory>
#include <span>
#include "core.hpp"

namespace dm {
namespace fs = std::filesystem;
std::wstring wide(const std::string& text);
std::string narrow(const std::wstring& text);
std::string systemError(DWORD code);
void checkWin(LONG result, const char* operation);
int64_t utcMillis();
fs::path executable();
fs::path dataFolder();
std::string readText(const fs::path& path);
void atomicWrite(const fs::path& path, const std::string& text);
Settings loadSettings(const fs::path& folder);
void saveSettings(const fs::path& folder, const Settings& settings);
void startProcess(const fs::path& program, const std::vector<std::wstring>& args, bool detached = true);
std::wstring quoteArg(const std::wstring& argument);
bool loginEnabled();
void setLoginEnabled(bool enabled);
class Mutex {
	HANDLE handle = nullptr;
public:
	explicit Mutex(const std::wstring& name, DWORD timeout = 10000);
	~Mutex();
	Mutex(const Mutex&) = delete;
	Mutex& operator=(const Mutex&) = delete;
};
struct Route {
	DISPLAYCONFIG_PATH_INFO path{};
	std::string id;
	std::wstring gdi;
};
struct DisplayPlan {
	std::vector<DISPLAYCONFIG_PATH_INFO> paths;
	std::vector<DISPLAYCONFIG_MODE_INFO> modes;
};
DisplayPlan planLayout(const std::vector<Display>& layout, const Hardware& current, const std::vector<Route>& routes, bool restore);
MonitorIdentity monitorIdentity(std::span<const BYTE> edid, const std::string& name);
class WindowsBackend : public Backend {
public:
	Hardware read() override;
	std::vector<Display> readLayout() override;
	void apply(const std::vector<Display>& layout, bool restore = false) override;
	std::string setAudio(const Audio& selection, bool protectBluetooth = true) override;
	std::string restoreAudio(const Audio& selection, const std::vector<Audio>& roles) override;
	void connect(const std::string& receiver, const std::string& display) override;
	void disconnect(const std::string& receiver, const std::string& display) override;
};
// CoreAudio notifications are posted to the UI; callbacks never mutate settings.
class AudioWatcher {
	struct Impl;
	std::unique_ptr<Impl> impl;
public:
	AudioWatcher(HWND target, UINT message);
	~AudioWatcher();
};
void openCastFlyout();
Json diagnostics(Backend& backend);
}
