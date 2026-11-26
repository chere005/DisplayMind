#include "windows.hpp"
#include <setupapi.h>
#include <cfgmgr32.h>
#include <initguid.h>
#include <devpkey.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>
#include <propsys.h>
#include <propvarutil.h>
#include <shlobj.h>
#include <knownfolders.h>
#include <shellapi.h>
#include <wrl/client.h>
#include <UIAutomation.h>
#include <algorithm>
#include <array>
#include <numeric>
#include <thread>
#include <chrono>
#include <cwctype>

using Microsoft::WRL::ComPtr;
namespace dm {
std::wstring wide(const std::string& s) {
	if (s.empty()) return {}; int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), nullptr, 0);
	if (!size) throw std::runtime_error("Invalid UTF-8 text"); std::wstring out(size, 0); MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), out.data(), size); return out;
}
std::string narrow(const std::wstring& s) {
	if (s.empty()) return {}; int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
	if (!size) throw std::runtime_error("Invalid UTF-16 text"); std::string out(size, 0); WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), out.data(), size, nullptr, nullptr); return out;
}
std::string systemError(DWORD code) {
	wchar_t* text = nullptr; FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, code, 0, reinterpret_cast<wchar_t*>(&text), 0, nullptr);
	std::string out = text ? trim(narrow(text)) : "Windows error " + std::to_string(code); if (text) LocalFree(text); return out;
}
void checkWin(LONG result, const char* op) { if (result != ERROR_SUCCESS) throw std::runtime_error(std::string(op) + ": " + systemError(result)); }
static void checkHR(HRESULT hr, const char* op) { if (FAILED(hr)) throw std::runtime_error(std::string(op) + ": " + systemError(static_cast<DWORD>(hr))); }
int64_t utcMillis() { FILETIME t{}; GetSystemTimeAsFileTime(&t); ULARGE_INTEGER n{}; n.LowPart = t.dwLowDateTime; n.HighPart = t.dwHighDateTime; return int64_t(n.QuadPart / 10000); }
fs::path executable() { std::wstring p(32768, 0); DWORD n = GetModuleFileNameW(nullptr, p.data(), static_cast<DWORD>(p.size())); if (!n || n >= p.size()) throw std::runtime_error("Cannot locate executable"); p.resize(n); return p; }
fs::path dataFolder() { PWSTR p = nullptr; checkHR(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr, &p), "Locate app data"); fs::path out = fs::path(p) / L"DisplayMind"; CoTaskMemFree(p); return out; }
std::string readText(const fs::path& path) {
	HANDLE raw = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (raw == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot read " + narrow(path.wstring()) + ": " + systemError(GetLastError()));
	std::unique_ptr<void, decltype(&CloseHandle)> file(raw, CloseHandle);
	LARGE_INTEGER size{};
	if (!GetFileSizeEx(raw, &size) || size.QuadPart < 0 || size.QuadPart > 8 * 1024 * 1024) throw std::runtime_error("Cannot read file size or file is too large");
	std::string text(static_cast<size_t>(size.QuadPart), '\0');
	DWORD count = 0;
	if (!ReadFile(raw, text.data(), static_cast<DWORD>(text.size()), &count, nullptr) || count != text.size()) throw std::runtime_error("Incomplete file read");
	return text;
}
void atomicWrite(const fs::path& path, const std::string& text) {
	if (path.has_parent_path()) fs::create_directories(path.parent_path());
	const auto tmp = fs::path(path.wstring() + L"." + wide(newId()) + L".tmp");
	HANDLE h = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (h == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot create settings: " + systemError(GetLastError()));
	DWORD written = 0; bool ok = WriteFile(h, text.data(), static_cast<DWORD>(text.size()), &written, nullptr) && written == text.size() && FlushFileBuffers(h);
	DWORD error = GetLastError(); CloseHandle(h);
	if (!ok) { DeleteFileW(tmp.c_str()); throw std::runtime_error("Cannot write settings: " + systemError(error)); }
	if (!MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) { error = GetLastError(); DeleteFileW(tmp.c_str()); throw std::runtime_error("Cannot replace settings: " + systemError(error)); }
}
Settings loadSettings(const fs::path& folder) { auto path = folder / L"settings.json"; return fs::exists(path) ? decodeSettings(Json::parse(readText(path))) : Settings{}; }
void saveSettings(const fs::path& folder, const Settings& s) { validate(s); atomicWrite(folder / L"settings.json", encode(s).dump() + "\n"); }
std::wstring quoteArg(const std::wstring& arg) {
	std::wstring out = L"\""; size_t slash = 0;
	for (auto c : arg) {
		if (c == L'\\') { ++slash; continue; }
		if (c == L'"') { out.append(slash * 2 + 1, L'\\'); out += c; } else { out.append(slash, L'\\'); out += c; } slash = 0;
	} out.append(slash * 2, L'\\'); return out + L'"';
}
void startProcess(const fs::path& p, const std::vector<std::wstring>& args, bool detached) {
	std::wstring cmd = quoteArg(p.wstring()); for (const auto& a : args) cmd += L" " + quoteArg(a);
	STARTUPINFOW si{sizeof(si)}; PROCESS_INFORMATION pi{}; si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
	if (!CreateProcessW(p.c_str(), cmd.data(), nullptr, nullptr, FALSE, detached ? CREATE_NO_WINDOW : 0, nullptr, p.parent_path().c_str(), &si, &pi)) throw std::runtime_error("Cannot start recovery process: " + systemError(GetLastError()));
	CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
}
Mutex::Mutex(const std::wstring& name, DWORD timeout) {
	handle = CreateMutexW(nullptr, FALSE, name.c_str()); if (!handle) throw std::runtime_error("Cannot create recovery lock");
	auto r = WaitForSingleObject(handle, timeout); if (r != WAIT_OBJECT_0 && r != WAIT_ABANDONED) { CloseHandle(handle); handle = nullptr; throw std::runtime_error("Another recovery operation is busy"); }
}
Mutex::~Mutex() { if (handle) { ReleaseMutex(handle); CloseHandle(handle); } }
bool loginEnabled() {
	std::wstring command(32768, L'\0');
	DWORD bytes = static_cast<DWORD>(command.size() * sizeof(wchar_t));
	auto result = RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", L"DisplayMind", RRF_RT_REG_SZ, nullptr, command.data(), &bytes);
	return result == ERROR_SUCCESS && _wcsicmp(command.c_str(), (quoteArg(executable().wstring()) + L" --background").c_str()) == 0;
}
void setLoginEnabled(bool enabled) {
	HKEY k = nullptr; checkWin(RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, nullptr, 0, KEY_SET_VALUE, nullptr, &k, nullptr), "Open login settings");
	auto command = quoteArg(executable().wstring()) + L" --background";
	auto r = enabled ? RegSetValueExW(k, L"DisplayMind", 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t))) : RegDeleteValueW(k, L"DisplayMind"); RegCloseKey(k);
	if (r != ERROR_FILE_NOT_FOUND) checkWin(r, "Update login settings");
}
static std::string lower(std::wstring s) { std::transform(s.begin(), s.end(), s.begin(), [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); }); return narrow(s); }
static bool sameAdapter(LUID a, LUID b) { return a.LowPart == b.LowPart && a.HighPart == b.HighPart; }
static std::string sourceKey(const DISPLAYCONFIG_PATH_INFO& p) { return std::to_string(p.sourceInfo.adapterId.HighPart) + ":" + std::to_string(p.sourceInfo.adapterId.LowPart) + ":" + std::to_string(p.sourceInfo.id); }
struct Query { std::vector<Route> routes; std::vector<DISPLAYCONFIG_MODE_INFO> modes; };
static Query queryPaths() {
	for (int attempt = 0; attempt < 8; ++attempt) {
		UINT32 np = 0, nm = 0; checkWin(GetDisplayConfigBufferSizes(QDC_ALL_PATHS, &np, &nm), "Size display configuration");
		std::vector<DISPLAYCONFIG_PATH_INFO> paths(np); std::vector<DISPLAYCONFIG_MODE_INFO> modes(nm);
		auto r = QueryDisplayConfig(QDC_ALL_PATHS, &np, paths.data(), &nm, modes.data(), nullptr);
		if (r == ERROR_INSUFFICIENT_BUFFER) continue; checkWin(r, "Read display configuration"); paths.resize(np); modes.resize(nm);
		Query q; q.modes = std::move(modes);
		for (auto p : paths) {
			if (!p.targetInfo.targetAvailable && !(p.flags & DISPLAYCONFIG_PATH_ACTIVE)) continue;
			DISPLAYCONFIG_TARGET_DEVICE_NAME name{}; name.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(name), p.targetInfo.adapterId, p.targetInfo.id};
			if (DisplayConfigGetDeviceInfo(&name.header) != ERROR_SUCCESS || !name.monitorDevicePath[0]) continue;
			DISPLAYCONFIG_SOURCE_DEVICE_NAME source{}; source.header = {DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, sizeof(source), p.sourceInfo.adapterId, p.sourceInfo.id}; DisplayConfigGetDeviceInfo(&source.header);
			q.routes.push_back({p, lower(name.monitorDevicePath), source.viewGdiDeviceName});
		} return q;
	} throw std::runtime_error("Displays kept changing while reading their configuration");
}
static std::wstring deviceProperty(HDEVINFO info, SP_DEVINFO_DATA& data, const DEVPROPKEY& key) {
	wchar_t buffer[2048]{}; DEVPROPTYPE type{};
	if (SetupDiGetDevicePropertyW(info, &data, &key, &type, reinterpret_cast<BYTE*>(buffer), sizeof(buffer), nullptr, 0) && type == DEVPROP_TYPE_STRING) return buffer; return {};
}
static void readDevices(Hardware& h, std::set<std::wstring>& bluetoothContainers) {
	HDEVINFO info = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT); if (info == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot enumerate devices");
	SP_DEVINFO_DATA data{sizeof(data)};
	for (DWORD i = 0; SetupDiEnumDeviceInfo(info, i, &data); ++i) {
		auto enumerator = deviceProperty(info, data, DEVPKEY_Device_EnumeratorName);
		if (enumerator == L"USB") {
			wchar_t instance[2048]{}; if (!SetupDiGetDeviceInstanceIdW(info, &data, instance, 2048, nullptr)) continue;
			auto name = deviceProperty(info, data, DEVPKEY_Device_FriendlyName); if (name.empty()) name = deviceProperty(info, data, DEVPKEY_Device_DeviceDesc); if (name.empty()) name = L"USB device";
			h.devices.push_back({"usb:" + lower(instance), narrow(name), true});
		}
		// The local Bluetooth radio (BTH) can share the computer's container with
		// built-in/virtual audio. Only remote-device enumerators identify headsets.
		if (enumerator == L"BTHENUM" || enumerator == L"BTHHFENUM" || enumerator == L"BTHLEDEVICE") {
			GUID container{}; DEVPROPTYPE type{};
			if (SetupDiGetDevicePropertyW(info, &data, &DEVPKEY_Device_ContainerId, &type, reinterpret_cast<BYTE*>(&container), sizeof(container), nullptr, 0) && type == DEVPROP_TYPE_GUID && container != GUID{}) { wchar_t text[40]{}; StringFromGUID2(container, text, 40); bluetoothContainers.insert(text); }
		}
	} SetupDiDestroyDeviceInfoList(info);
}
static ComPtr<IMMDeviceEnumerator> audioEnumerator() { ComPtr<IMMDeviceEnumerator> e; checkHR(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&e)), "Open audio service"); return e; }
static std::string endpointId(IMMDevice* d) { LPWSTR text = nullptr; checkHR(d->GetId(&text), "Read audio identity"); std::string id = narrow(text); CoTaskMemFree(text); return id; }
static void readAudio(Hardware& h, const std::set<std::wstring>& bluetoothContainers) {
	auto e = audioEnumerator();
	h.roleAudio.resize(3);
	for (EDataFlow flow : {eRender, eCapture}) {
		for (auto role : {eConsole,eMultimedia,eCommunications}) {
			ComPtr<IMMDevice> current; if (SUCCEEDED(e->GetDefaultAudioEndpoint(flow,role,&current))) { auto id=endpointId(current.Get()); (flow==eRender ? h.roleAudio[role].output : h.roleAudio[role].input)=id; if (role==eConsole) (flow==eRender ? h.audio.output : h.audio.input)=id; }
		}
		ComPtr<IMMDeviceCollection> collection; checkHR(e->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &collection), "Read audio devices"); UINT count = 0; collection->GetCount(&count);
		for (UINT i = 0; i < count; ++i) {
			ComPtr<IMMDevice> d; if (FAILED(collection->Item(i, &d))) continue;
			ComPtr<IPropertyStore> props; if (FAILED(d->OpenPropertyStore(STGM_READ, &props))) continue;
			PROPVARIANT value{}; std::string name = "Audio device";
			if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &value))) { if (value.vt == VT_LPWSTR && value.pwszVal) name = narrow(value.pwszVal); PropVariantClear(&value); }
			bool bt = false;
			if (SUCCEEDED(props->GetValue(PKEY_Device_ContainerId, &value))) {
				if (value.vt == VT_CLSID && value.puuid) { wchar_t text[40]{}; StringFromGUID2(*value.puuid, text, 40); bt = bluetoothContainers.count(text) != 0; } PropVariantClear(&value);
			}
			if (SUCCEEDED(props->GetValue(PKEY_Device_EnumeratorName, &value))) { if (value.vt == VT_LPWSTR && value.pwszVal) bt = bt || std::wstring(value.pwszVal).starts_with(L"BTH"); PropVariantClear(&value); }
			h.audioDevices.push_back({endpointId(d.Get()), name, flow == eCapture, bt});
		}
	}
}
MonitorIdentity monitorIdentity(std::span<const BYTE> edid, const std::string& name) {
	constexpr std::array<BYTE, 8> header{0, 255, 255, 255, 255, 255, 255, 0};
	if (edid.size() < 128 || !std::equal(header.begin(), header.end(), edid.begin()) || std::accumulate(edid.begin(), edid.begin() + 128, 0) % 256) return {};
	MonitorIdentity identity{(edid[8] << 8) | edid[9], edid[10] | (edid[11] << 8), {}, name};
	if (!identity.vendor) return {};
	const auto serial = uint32_t(edid[12]) | (uint32_t(edid[13]) << 8) | (uint32_t(edid[14]) << 16) | (uint32_t(edid[15]) << 24);
	if (serial && serial != UINT32_MAX) identity.serial = "number:" + std::to_string(serial);
	for (size_t offset = 54; offset <= 108; offset += 18) {
		if (edid[offset] || edid[offset+1] || edid[offset+2] || edid[offset+4]) continue;
		std::string value;
		for (BYTE c : edid.subspan(offset+5, 13)) {
			if (!c || c == '\n') break;
			if (c < 32 || c > 126) { value.clear(); break; }
			value += static_cast<char>(c);
		}
		value = trim(value);
		if (value.empty()) continue;
		if (edid[offset+3] == 0xfc) identity.name = value;
		if (edid[offset+3] == 0xff && value.find_first_not_of('0') != value.npos && value != "N/A") identity.serial = "text:" + value;
	}
	return identity;
}
static MonitorIdentity readMonitorIdentity(const std::string& id, const std::string& name) {
	HDEVINFO info = SetupDiCreateDeviceInfoList(nullptr, nullptr);
	if (info == INVALID_HANDLE_VALUE) return {};
	std::unique_ptr<void, decltype(&SetupDiDestroyDeviceInfoList)> devices(info, SetupDiDestroyDeviceInfoList);
	SP_DEVICE_INTERFACE_DATA iface{sizeof(iface)};
	if (!SetupDiOpenDeviceInterfaceW(info, wide(id).c_str(), 0, &iface)) return {};
	DWORD bytes = 0;
	SetupDiGetDeviceInterfaceDetailW(info, &iface, nullptr, 0, &bytes, nullptr);
	if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) return {};
	std::vector<BYTE> buffer(bytes);
	auto detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(buffer.data());
	detail->cbSize = sizeof(*detail);
	SP_DEVINFO_DATA device{sizeof(device)};
	if (!SetupDiGetDeviceInterfaceDetailW(info, &iface, detail, bytes, nullptr, &device)) return {};
	auto raw = SetupDiOpenDevRegKey(info, &device, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_QUERY_VALUE);
	if (raw == INVALID_HANDLE_VALUE) return {};
	std::unique_ptr<std::remove_pointer_t<HKEY>, decltype(&RegCloseKey)> key(raw, RegCloseKey);
	std::array<BYTE, 32768> edid{};
	bytes = static_cast<DWORD>(edid.size());
	if (RegGetValueW(key.get(), nullptr, L"EDID", RRF_RT_REG_BINARY, nullptr, edid.data(), &bytes) != ERROR_SUCCESS) return {};
	return monitorIdentity(std::span(edid).first(bytes), name);
}
static Hardware readDisplays(const Query& q, bool enumerateModes) {
	Hardware h;
	std::set<std::string> seen;
	std::map<std::string, std::string> roots;
	for (const auto& r : q.routes) {
		if (!seen.insert(r.id).second) continue;
		auto p = r.path; bool active = (p.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0;
		DISPLAYCONFIG_TARGET_DEVICE_NAME n{}; n.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME, sizeof(n), p.targetInfo.adapterId, p.targetInfo.id}; DisplayConfigGetDeviceInfo(&n.header);
		Display d; d.id = r.id; d.name = n.monitorFriendlyDeviceName[0] ? narrow(n.monitorFriendlyDeviceName) : "Display " + std::to_string(h.displays.size() + 1); d.enabled = active; d.wireless = p.targetInfo.outputTechnology == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_MIRACAST;
		d.rotation = (int(p.targetInfo.rotation) - 1) * 90; if (d.rotation < 0) d.rotation = 0;
		d.mode.numerator = static_cast<int>(p.targetInfo.refreshRate.Numerator); d.mode.denominator = static_cast<int>(p.targetInfo.refreshRate.Denominator); if (!d.mode.denominator) { d.mode.numerator = 60; d.mode.denominator = 1; }
		if (active && p.sourceInfo.modeInfoIdx < q.modes.size() && q.modes[p.sourceInfo.modeInfoIdx].infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE) {
			auto m = q.modes[p.sourceInfo.modeInfoIdx].sourceMode; d.mode.width = static_cast<int>(m.width); d.mode.height = static_cast<int>(m.height); d.x = m.position.x; d.y = m.position.y;
			auto key = sourceKey(p); if (roots.count(key)) d.mirror = roots[key]; else roots[key] = d.id;
		} else {
			DISPLAYCONFIG_TARGET_PREFERRED_MODE preferred{}; preferred.header = {DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_PREFERRED_MODE, sizeof(preferred), p.targetInfo.adapterId, p.targetInfo.id};
			if (DisplayConfigGetDeviceInfo(&preferred.header) == ERROR_SUCCESS) { d.mode.width = static_cast<int>(preferred.width); d.mode.height = static_cast<int>(preferred.height); }
		}
		if (enumerateModes && !d.wireless) d.monitor = readMonitorIdentity(d.id, d.name);
		h.displays.push_back(d); h.devices.push_back({"display:" + d.id, d.name, false, d.monitor});
		if (!enumerateModes) continue;
		std::vector<Mode> modes; DEVMODEW mode{}; mode.dmSize = sizeof(mode);
		for (DWORD i = 0; !r.gdi.empty() && i < 10000 && EnumDisplaySettingsExW(r.gdi.c_str(), i, &mode, 0); ++i) {
			if (mode.dmBitsPerPel != 32 || mode.dmDisplayFrequency < 1 || int(mode.dmDisplayOrientation) * 90 != d.rotation) continue;
			Mode m{static_cast<int>(mode.dmPelsWidth), static_cast<int>(mode.dmPelsHeight), static_cast<int>(mode.dmDisplayFrequency), 1}; if (std::find(modes.begin(), modes.end(), m) == modes.end()) modes.push_back(m);
		}
		if (std::find(modes.begin(), modes.end(), d.mode) == modes.end()) modes.push_back(d.mode);
		std::sort(modes.begin(), modes.end(), [](const auto& a, const auto& b) { return std::tuple(a.width, a.height, a.hz()) > std::tuple(b.width, b.height, b.hz()); });
		h.modes[d.id] = std::move(modes);
	}
	return h;
}
std::vector<Display> WindowsBackend::readLayout() { return readDisplays(queryPaths(), false).displays; }
Hardware WindowsBackend::read() {
	auto h = readDisplays(queryPaths(), true);
	std::set<std::wstring> bluetoothContainers;
	readDevices(h, bluetoothContainers);
	try { readAudio(h, bluetoothContainers); }
	catch (const std::exception& e) {
		h.audio = {};
		h.roleAudio.clear();
		h.audioDevices.clear();
		h.audioError = e.what();
	}
	return h;
}
DisplayPlan planLayout(const std::vector<Display>& wanted, const Hardware& current, const std::vector<Route>& routes, bool restore) {
	validate(wanted);
	auto ds = restore ? wanted : layoutWithExtraDisplays(wanted, current.displays);
	validate(ds);
	DisplayPlan plan; std::map<std::string, Route> assigned; std::set<std::string> used;
	std::vector<std::pair<std::string,std::vector<Route>>> choices;
	for (const auto& d : ds) if (d.enabled && d.mirror.empty()) {
		std::vector<Route> options; std::set<std::string> unique;
		for (const auto& r : routes) if (r.id == d.id && unique.insert(sourceKey(r.path)).second) {
			bool compatible = true;
			for (const auto& mirror : ds) if (mirror.enabled && mirror.mirror == d.id) {
				if (std::none_of(routes.begin(), routes.end(), [&](const auto& other) { return other.id == mirror.id && sourceKey(other.path) == sourceKey(r.path); })) compatible = false;
			}
			if (compatible) options.push_back(r);
		}
		if (options.empty()) throw std::runtime_error("No compatible Windows display source or mirror path for " + d.name);
		choices.emplace_back(d.id,options);
	}
	std::stable_sort(choices.begin(),choices.end(),[](const auto& a,const auto& b) { return a.second.size()<b.second.size(); });
	int steps = 0;
	std::function<bool(size_t)> assign = [&](size_t index) {
		if (++steps > 100000) return false; if (index == choices.size()) return true;
		const auto& [id,options] = choices[index];
		for (const auto& r : options) { auto key = sourceKey(r.path); if (used.count(key)) continue; used.insert(key); assigned[id] = r; if (assign(index+1)) return true; assigned.erase(id); used.erase(key); }
		return false;
	};
	if (!assign(0)) throw std::runtime_error("The Windows display driver has no compatible source assignment for this layout");
	std::map<std::string, UINT32> modeIndices;
	for (const auto& d : ds) if (d.enabled && d.mirror.empty()) {
		auto r = assigned.at(d.id); DISPLAYCONFIG_MODE_INFO mode{}; mode.infoType = DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE; mode.id = r.path.sourceInfo.id; mode.adapterId = r.path.sourceInfo.adapterId;
		mode.sourceMode = {static_cast<UINT32>(d.mode.width), static_cast<UINT32>(d.mode.height), DISPLAYCONFIG_PIXELFORMAT_32BPP, {d.x, d.y}};
		modeIndices[d.id] = static_cast<UINT32>(plan.modes.size()); plan.modes.push_back(mode);
	}
	// Give the primary display first priority, then each extended source before its clone targets.
	auto priority = [](const Display& d) { return !d.mirror.empty() ? 2 : d.x == 0 && d.y == 0 ? 0 : 1; };
	std::stable_sort(ds.begin(), ds.end(), [&](const Display& a, const Display& b) { return priority(a) < priority(b); });
	for (const auto& d : ds) if (d.enabled) {
		const std::string root = d.mirror.empty() ? d.id : d.mirror; const auto& source = assigned.at(root);
		auto i = std::find_if(routes.begin(), routes.end(), [&](const auto& r) { return r.id == d.id && r.path.sourceInfo.id == source.path.sourceInfo.id && sameAdapter(r.path.sourceInfo.adapterId, source.path.sourceInfo.adapterId); });
		if (i == routes.end()) throw std::runtime_error("The display driver exposes no compatible mirroring path for " + d.name);
		auto p = i->path; p.flags = DISPLAYCONFIG_PATH_ACTIVE; p.sourceInfo.modeInfoIdx = modeIndices.at(root); p.targetInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
		const auto& rootDisplay = *std::find_if(ds.begin(), ds.end(), [&](const auto& a) { return a.id == root; });
		p.targetInfo.rotation = static_cast<DISPLAYCONFIG_ROTATION>(rootDisplay.rotation / 90 + 1);
		p.targetInfo.scaling = DISPLAYCONFIG_SCALING_PREFERRED;
		if (rootDisplay.mode.numerator) {
			p.targetInfo.refreshRate = {static_cast<UINT32>(rootDisplay.mode.numerator), static_cast<UINT32>(rootDisplay.mode.denominator)};
			// An explicit refresh needs a concrete scan-line order; unspecified
			// together with a nonzero refresh is rejected with ERROR_INVALID_PARAMETER.
			if (p.targetInfo.scanLineOrdering==DISPLAYCONFIG_SCANLINE_ORDERING_UNSPECIFIED) p.targetInfo.scanLineOrdering=DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
		} else { p.targetInfo.refreshRate={0,0}; p.targetInfo.scanLineOrdering=DISPLAYCONFIG_SCANLINE_ORDERING_UNSPECIFIED; }
		plan.paths.push_back(p);
	}
	return plan;
}
void WindowsBackend::apply(const std::vector<Display>& ds, bool restore) {
	auto q = queryPaths();
	auto hardware = readDisplays(q, false);
	auto plan = planLayout(ds, hardware, q.routes, restore);
	const UINT32 flags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES;
	auto validation = SetDisplayConfig(static_cast<UINT32>(plan.paths.size()), plan.paths.data(), static_cast<UINT32>(plan.modes.size()), plan.modes.data(), flags | SDC_VALIDATE);
	if (validation == ERROR_ACCESS_DENIED) throw std::runtime_error("Windows denied display control in this session. Open DisplayMind from the Windows desktop to apply layouts.");
	checkWin(validation, "Windows rejected this display arrangement");
	checkWin(SetDisplayConfig(static_cast<UINT32>(plan.paths.size()), plan.paths.data(), static_cast<UINT32>(plan.modes.size()), plan.modes.data(), flags | SDC_APPLY | SDC_SAVE_TO_DATABASE), "Apply display arrangement");
}
// Windows exposes endpoint enumeration publicly, but default-endpoint selection
// still uses the OS PolicyConfig COM interface. Keep its ABI isolated here.
MIDL_INTERFACE("f8679f50-850a-41cf-9c72-430f290290c8") IPolicyConfig : public IUnknown {
	virtual HRESULT STDMETHODCALLTYPE GetMixFormat(PCWSTR, void**) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetDeviceFormat(PCWSTR, INT, void**) = 0;
	virtual HRESULT STDMETHODCALLTYPE ResetDeviceFormat(PCWSTR) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetDeviceFormat(PCWSTR, void*, void*) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetProcessingPeriod(PCWSTR, INT, INT64*, INT64*) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetProcessingPeriod(PCWSTR, INT64*) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetShareMode(PCWSTR, void*) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetShareMode(PCWSTR, void*) = 0;
	virtual HRESULT STDMETHODCALLTYPE GetPropertyValue(PCWSTR, const PROPERTYKEY&, PROPVARIANT*) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetPropertyValue(PCWSTR, const PROPERTYKEY&, PROPVARIANT*) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetDefaultEndpoint(PCWSTR, ERole) = 0;
	virtual HRESULT STDMETHODCALLTYPE SetEndpointVisibility(PCWSTR, INT) = 0;
};
static std::string setAudioRoles(const Hardware& h, const std::vector<Audio>& roles) {
	std::vector<std::string> notes;
	ComPtr<IPolicyConfig> policy;
	for (size_t role = 0; role < roles.size() && role < h.roleAudio.size() && role < 3; ++role) for (bool input : {false, true}) {
		const auto& id = input ? roles[role].input : roles[role].output;
		if (id.empty()) continue;
		std::string note;
		if (std::none_of(h.audioDevices.begin(), h.audioDevices.end(), [&](const AudioDevice& d) { return d.id == id && d.input == input; })) {
			note = input ? "Saved input is not connected." : "Saved output is not connected.";
		} else if ((input ? h.roleAudio[role].input : h.roleAudio[role].output) != id) {
			if (!policy) {
				CLSID cls{};
				CLSIDFromString(L"{870af99c-171d-4f9e-af0d-e63df40c2bc9}", &cls);
				checkHR(CoCreateInstance(cls, nullptr, CLSCTX_ALL, __uuidof(IPolicyConfig), &policy), "Open default sound selection");
			}
			auto hr = policy->SetDefaultEndpoint(wide(id).c_str(), static_cast<ERole>(role));
			if (FAILED(hr)) note = std::string(input ? "Set default input: " : "Set default output: ") + systemError(hr);
		}
		if (!note.empty() && std::find(notes.begin(), notes.end(), note) == notes.end()) notes.push_back(note);
	}
	std::string summary;
	for (const auto& note : notes) { if (!summary.empty()) summary += " "; summary += note; }
	return summary;
}
static Hardware readSoundDevices() {
	Hardware h;
	std::set<std::wstring> bluetoothContainers;
	readDevices(h, bluetoothContainers);
	readAudio(h, bluetoothContainers);
	return h;
}
std::string WindowsBackend::setAudio(const Audio& wanted, bool protect) {
	if (wanted == Audio{}) return {};
	auto h = readSoundDevices();
	auto roles = audioRolesForSelection(wanted, h, protect);
	auto kept = std::any_of(roles.begin(), roles.end(), [&](const Audio& a) { return a != wanted; });
	return trim((kept ? "Bluetooth headphones in use were kept. " : "") + setAudioRoles(h, roles));
}
std::string WindowsBackend::restoreAudio(const Audio& selection, const std::vector<Audio>& roles) {
	auto restore = roles.empty() ? std::vector<Audio>(3, selection) : roles;
	if (std::all_of(restore.begin(), restore.end(), [](const Audio& a) { return a == Audio{}; })) return {};
	return setAudioRoles(readSoundDevices(), restore);
}
struct AudioWatcher::Impl : IMMNotificationClient {
	LONG references = 1; HWND target; UINT message; ComPtr<IMMDeviceEnumerator> enumerator;
	Impl(HWND w, UINT m) : target(w), message(m), enumerator(audioEnumerator()) { checkHR(enumerator->RegisterEndpointNotificationCallback(this), "Watch audio devices"); }
	~Impl() { if (enumerator) enumerator->UnregisterEndpointNotificationCallback(this); }
	ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&references)); }
	ULONG STDMETHODCALLTYPE Release() override { return static_cast<ULONG>(InterlockedDecrement(&references)); }
	HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override { if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMNotificationClient)) { *object = static_cast<IMMNotificationClient*>(this); AddRef(); return S_OK; } *object = nullptr; return E_NOINTERFACE; }
	HRESULT change() { PostMessageW(target, message, 1, 0); return S_OK; }
	HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { return change(); }
	HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return change(); }
	HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return change(); }
	HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow, ERole, LPCWSTR) override { return change(); }
	HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return change(); }
};
AudioWatcher::AudioWatcher(HWND w, UINT m) : impl(std::make_unique<Impl>(w, m)) {}
AudioWatcher::~AudioWatcher() = default;
void openCastFlyout() {
	INPUT input[4]{}; for (auto& i : input) i.type = INPUT_KEYBOARD;
	input[0].ki.wVk = VK_LWIN; input[1].ki.wVk = 'K'; input[2].ki.wVk = 'K'; input[2].ki.dwFlags = KEYEVENTF_KEYUP; input[3].ki.wVk = VK_LWIN; input[3].ki.dwFlags = KEYEVENTF_KEYUP;
	if (SendInput(4, input, sizeof(INPUT)) != 4) throw std::runtime_error("Windows could not open its Cast interface");
}
static bool invokeReceiver(const std::string& name, bool disconnect) {
	ComPtr<IUIAutomation> automation; checkHR(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation)), "Open wireless display controls");
	ComPtr<IUIAutomationElement> desktop; checkHR(automation->GetRootElement(&desktop), "Read Cast interface");
	VARIANT value{}; value.vt = VT_BSTR; value.bstrVal = SysAllocString(wide(name).c_str()); ComPtr<IUIAutomationCondition> condition;
	auto hr = automation->CreatePropertyCondition(UIA_NamePropertyId, value, &condition); VariantClear(&value); checkHR(hr, "Find saved receiver");
	ComPtr<IUIAutomationElementArray> matches; checkHR(desktop->FindAll(TreeScope_Descendants, condition.Get(), &matches), "Find saved receiver");
	int length = 0; matches->get_Length(&length); ComPtr<IUIAutomationElement> found;
	for (int i = 0; i < length; ++i) {
		ComPtr<IUIAutomationElement> e; matches->GetElement(i, &e); int pid = 0; e->get_CurrentProcessId(&pid);
		HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, static_cast<DWORD>(pid)); if (!process) continue;
		wchar_t path[32768]{}; DWORD size = 32768; bool ok = QueryFullProcessImageNameW(process, 0, path, &size) != 0; CloseHandle(process);
		auto file = lower(fs::path(path).filename().wstring());
		if (!ok || (file != "shellexperiencehost.exe" && file != "explorer.exe")) continue;
		BOOL offscreen = TRUE; e->get_CurrentIsOffscreen(&offscreen); if (offscreen) continue;
		// A similarly named file, notification or Bluetooth device is not a Cast
		// receiver. Never invoke Explorer results or controls outside Cast/Connect.
		if (file != "shellexperiencehost.exe") continue;
		ComPtr<IUIAutomationTreeWalker> walker; checkHR(automation->get_ControlViewWalker(&walker),"Inspect Cast receiver");
		bool cast = false; ComPtr<IUIAutomationElement> ancestor = e;
		for (int depth = 0; depth < 24 && ancestor; ++depth) {
			BSTR title = nullptr; if (SUCCEEDED(ancestor->get_CurrentName(&title))) { std::wstring text = title ? title : L""; SysFreeString(title); if (text == L"Cast" || text == L"Connect") { cast = true; break; } }
			ComPtr<IUIAutomationElement> parent; if (FAILED(walker->GetParentElement(ancestor.Get(),&parent))) break; ancestor = parent;
		}
		if (!cast) continue;
		ComPtr<IUIAutomationInvokePattern> actionable; ComPtr<IUIAutomationSelectionItemPattern> selectable;
		if (FAILED(e->GetCurrentPatternAs(UIA_InvokePatternId,IID_PPV_ARGS(&actionable))) && FAILED(e->GetCurrentPatternAs(UIA_SelectionItemPatternId,IID_PPV_ARGS(&selectable)))) continue;
		if (found) throw std::runtime_error("More than one wireless receiver has this name. Choose an unambiguous receiver in Windows."); found = e;
	}
	if (!found) return false;
	if (disconnect) {
		// The disconnect action must be inside the exact saved receiver's subtree.
		VARIANT v{}; v.vt = VT_BSTR; v.bstrVal = SysAllocString(L"Disconnect"); ComPtr<IUIAutomationCondition> c; automation->CreatePropertyCondition(UIA_NamePropertyId, v, &c); VariantClear(&v);
		ComPtr<IUIAutomationElement> button; found->FindFirst(TreeScope_Subtree, c.Get(), &button); if (!button) return false; found = button;
	}
	ComPtr<IUIAutomationInvokePattern> invoke;
	if (SUCCEEDED(found->GetCurrentPatternAs(UIA_InvokePatternId, IID_PPV_ARGS(&invoke)))) { checkHR(invoke->Invoke(), "Choose saved wireless receiver"); return true; }
	ComPtr<IUIAutomationSelectionItemPattern> select;
	if (SUCCEEDED(found->GetCurrentPatternAs(UIA_SelectionItemPatternId, IID_PPV_ARGS(&select)))) { checkHR(select->Select(), "Choose saved wireless receiver"); return true; }
	return false;
}
void WindowsBackend::connect(const std::string& receiver, const std::string& display) {
	if (receiver.empty() || display.empty()) throw std::runtime_error("The preset has no saved wireless receiver");
	auto initial = read(); if (std::any_of(initial.displays.begin(), initial.displays.end(), [&](const auto& d) { return d.id == display; })) return;
	openCastFlyout(); bool invoked = false; const auto until = GetTickCount64() + 30000;
	while (GetTickCount64() < until) {
		auto h = read(); if (std::any_of(h.displays.begin(), h.displays.end(), [&](const auto& d) { return d.id == display && d.wireless; })) return;
		if (!invoked) invoked = invokeReceiver(receiver, false); std::this_thread::sleep_for(std::chrono::milliseconds(400));
	} throw std::runtime_error("Windows did not connect the saved receiver within 30 seconds. Cast requires compatible Wi-Fi/display drivers; pairing stays in Windows.");
}
void WindowsBackend::disconnect(const std::string& receiver, const std::string& display) {
	auto h = read(); if (std::none_of(h.displays.begin(), h.displays.end(), [&](const auto& d) { return d.id == display && d.wireless; })) return;
	openCastFlyout(); bool invoked=false; auto until=GetTickCount64()+30000;
	while (GetTickCount64()<until) {
		auto current=read(); if (std::none_of(current.displays.begin(),current.displays.end(),[&](const auto& d) { return d.id==display && d.wireless; })) return;
		if (!invoked) invoked=invokeReceiver(receiver,true); std::this_thread::sleep_for(std::chrono::milliseconds(400));
	}
	throw std::runtime_error("Windows did not confirm disconnection of the saved receiver within 30 seconds. Cast control requires the supported Windows Cast/Connect interface.");
}
Json diagnostics(Backend& backend) {
	auto h = backend.read(); Json::Array displays, devices, audio;
	for (const auto& d : h.displays) {
		auto encoded=encode(d); Json::Array modes; for (const auto& m:h.modes[d.id]) modes.push_back(Json::Object{{"width",m.width},{"height",m.height},{"refreshNumerator",m.numerator},{"refreshDenominator",m.denominator}});
		std::get<Json::Object>(encoded.value)["availableModes"]=modes; displays.push_back(encoded);
	}
	for (const auto& d : h.devices) devices.push_back(Json::Object{{"id", d.id}, {"name", d.name}, {"kind", d.usb ? "usb" : "display"}});
	for (const auto& d : h.audioDevices) audio.push_back(Json::Object{{"id", d.id}, {"name", d.name}, {"input", d.input}, {"bluetooth", d.bluetooth}});
	Json validation;
	if (dynamic_cast<WindowsBackend*>(&backend) && !h.displays.empty()) {
		try {
			auto q=queryPaths(); auto plan=planLayout(h.displays,h,q.routes,true);
			auto code=SetDisplayConfig(static_cast<UINT32>(plan.paths.size()),plan.paths.data(),static_cast<UINT32>(plan.modes.size()),plan.modes.data(),SDC_VALIDATE | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES);
			validation=Json::Object{{"succeeded",code==ERROR_SUCCESS},{"blockedBySession",code==ERROR_ACCESS_DENIED},{"windowsError",static_cast<int64_t>(code)},{"message",code==ERROR_SUCCESS ? "Windows accepted the current native display plan (validation only; no apply)" : code==ERROR_ACCESS_DENIED ? "Windows denied display-control validation from this process/session; reading hardware remains available" : systemError(code)}};
			if (code!=ERROR_SUCCESS && code!=ERROR_ACCESS_DENIED) {
				Json::Array cases,raw;
				auto probe=[&](const char* name,DisplayPlan p) { auto result=SetDisplayConfig(static_cast<UINT32>(p.paths.size()),p.paths.data(),static_cast<UINT32>(p.modes.size()),p.modes.data(),SDC_VALIDATE | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES); cases.push_back(Json::Object{{"case",name},{"error",static_cast<int64_t>(result)}}); };
				auto original=DisplayPlan{}; original.modes=q.modes; for (const auto& route:q.routes) if (route.path.flags & DISPLAYCONFIG_PATH_ACTIVE) { original.paths.push_back(route.path); raw.push_back(Json::Object{{"flags",route.path.flags},{"source",route.path.sourceInfo.id},{"sourceMode",route.path.sourceInfo.modeInfoIdx},{"target",route.path.targetInfo.id},{"targetMode",route.path.targetInfo.modeInfoIdx},{"scanline",int(route.path.targetInfo.scanLineOrdering)},{"scaling",int(route.path.targetInfo.scaling)}}); }
				probe("original-active",original);
				auto optimal=plan; for (auto& path:optimal.paths) path.targetInfo.refreshRate={0,0}; probe("optimal-refresh",optimal);
				auto scanline=plan; for (auto& path:scanline.paths) path.targetInfo.scanLineOrdering=DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE; probe("explicit-progressive",scanline);
				auto scaling=plan; for (auto& path:scaling.paths) path.targetInfo.scaling=DISPLAYCONFIG_SCALING_IDENTITY; probe("identity-scaling",scaling);
				auto full=plan; for (auto& path:full.paths) { auto found=std::find_if(original.paths.begin(),original.paths.end(),[&](const auto& prior) { return prior.targetInfo.id==path.targetInfo.id && sameAdapter(prior.targetInfo.adapterId,path.targetInfo.adapterId); }); if (found!=original.paths.end() && found->targetInfo.modeInfoIdx<q.modes.size()) { path.targetInfo.modeInfoIdx=static_cast<UINT32>(full.modes.size()); full.modes.push_back(q.modes[found->targetInfo.modeInfoIdx]); } } probe("full-target-timings",full);
				std::get<Json::Object>(validation.value)["readOnlyProbes"]=cases; std::get<Json::Object>(validation.value)["originalPaths"]=raw;
			}
		} catch (const std::exception& e) { validation=Json::Object{{"succeeded",false},{"message",e.what()}}; }
	}
	return Json::Object{{"platform", "windows"}, {"version", "0.3.0"}, {"readOnly", true}, {"displays", displays}, {"devices", devices}, {"audioDevices", audio}, {"audioError",h.audioError}, {"defaultOutput", h.audio.output}, {"defaultInput", h.audio.input},{"displayConfigurationValidation",validation}};
}
}
