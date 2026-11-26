#include "recovery.hpp"
#include <commctrl.h>
#include <uxtheme.h>
#include <dwmapi.h>
#include <objidl.h>
#include <gdiplus.h>
#include <dbt.h>
#include <shellapi.h>
#include <windowsx.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <algorithm>
#include <thread>
#include <atomic>
#include <sstream>
#include <iomanip>

using namespace Gdiplus;
using Microsoft::WRL::ComPtr;
namespace dm {
constexpr UINT WM_HARDWARE = WM_APP + 1, WM_WORK = WM_APP + 2, WM_TRAY = WM_APP + 3;
constexpr UINT ID_FALLBACK = 1, ID_DEBOUNCE = 2, ID_ATTENTION = 3;
constexpr int MenuCommand = -1;
enum Control {
	C_PRESETS = 100, C_CAPTURE, C_RULES, C_AUTOMATIC, C_LOGIN, C_FOLDER, C_REFRESH, C_SETTINGS,
	C_APPLY, C_EDIT, C_MORE, C_KEEP, C_REVERT, C_NEW_RULE, C_RULE_LIST, C_RULE_EDIT, C_RULE_DELETE, C_RULE_UP, C_RULE_DOWN,
	C_NAME, C_SAVE, C_CANCEL, C_DISPLAY, C_USE, C_ROTATION, C_MODE, C_X, C_Y, C_MAIN, C_PLACE, C_TABS,
	C_AUDIO_OUT, C_AUDIO_IN, C_RECEIVER, C_WIRELESS_DISPLAY, C_CAST, C_RULE_PRESET, C_DEVICES, C_CONDITION, C_EXACT, C_ENABLED, C_SEARCH,
	C_RENAME = 200, C_DUPLICATE, C_DELETE, C_QUIT, C_DISMISS, C_DIAGNOSTICS, C_SHOW, C_SYSTEM_DISPLAY, C_SYSTEM_SOUND,
	C_TAB_DISPLAY = 350, C_TAB_SOUND, C_TAB_WIRELESS, C_RETRY_RECOVERY, C_ERROR_DETAILS,
	C_FILTER, C_FILTER_DISPLAYS, C_FILTER_MODE, C_CLEAR_FILTER, C_ADD_FOLDER, C_INLINE_NAME, C_INLINE_SAVE, C_INLINE_CANCEL,
	C_FOLDER_RENAME, C_FOLDER_REMOVE, C_MOVE_PRESET = 2000
};
enum class Page { presets, rules, editor, ruleEditor };
enum class NameTarget { none, preset, newFolder, folder };
struct SidebarRow { std::string id; bool heading = false; };
struct Palette { COLORREF bg, side, card, border, text, secondary, accent, selection, button; };
static Palette palette(bool dark) { return dark ? Palette{RGB(29,29,31), RGB(35,35,37), RGB(40,40,43), RGB(61,61,65), RGB(239,239,242), RGB(164,164,174), RGB(103,207,230), RGB(43,70,80), RGB(56,56,60)} : Palette{RGB(247,248,250), RGB(239,241,244), RGB(255,255,255), RGB(218,222,229), RGB(30,34,43), RGB(99,107,122), RGB(0,111,148), RGB(216,235,243), RGB(232,235,240)}; }
static bool systemDark() { DWORD value = 1, size = sizeof(value); RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size); return value == 0; }
static std::wstring textOf(HWND w) { int n = GetWindowTextLengthW(w); std::wstring s(n + 1, 0); GetWindowTextW(w, s.data(), n + 1); s.resize(n); return s; }
static Color color(COLORREF c, BYTE alpha = 255) { return Color(alpha, GetRValue(c), GetGValue(c), GetBValue(c)); }
static std::wstring modeLabel(const Mode& m) { std::wostringstream s; s << m.width << L" × " << m.height << L"  ·  " << std::fixed << std::setprecision(m.denominator == 1 ? 0 : 2) << m.hz() << L" Hz"; return s.str(); }
static std::string identityHint(std::string id) { auto guid=id.rfind("#{"); if (guid!=id.npos) id.resize(guid); auto separator=id.find_last_of("#\\"); if (separator!=id.npos) id=id.substr(separator+1); if (id.size()>32) id=id.substr(id.size()-32); return id; }
static void roundPath(GraphicsPath& path, RectF r, float radius) {
	float d = radius * 2; path.AddArc(r.X,r.Y,d,d,180,90); path.AddArc(r.GetRight()-d,r.Y,d,d,270,90); path.AddArc(r.GetRight()-d,r.GetBottom()-d,d,d,0,90); path.AddArc(r.X,r.GetBottom()-d,d,d,90,90); path.CloseFigure();
}
static void rounded(Graphics& g, RectF rect, COLORREF fill, COLORREF edge, float radius = 12) { GraphicsPath p; roundPath(p,rect,radius); SolidBrush brush(color(fill)); Pen pen(color(edge)); g.FillPath(&brush, &p); g.DrawPath(&pen, &p); }
static void drawThumbnail(Graphics& g, const Preset& preset, RectF area, const Palette& colors) {
	RECT bounds{};
	for (const auto& d : preset.displays) if (d.enabled && d.mirror.empty()) {
		RECT screen{d.x, d.y, d.x + d.mode.width, d.y + d.mode.height};
		UnionRect(&bounds, &bounds, &screen);
	}
	if (IsRectEmpty(&bounds)) return;
	auto scale = std::min((area.Width-4)/(bounds.right-bounds.left), (area.Height-4)/(bounds.bottom-bounds.top));
	auto x = area.X + (area.Width-(bounds.right-bounds.left)*scale)/2;
	auto y = area.Y + (area.Height-(bounds.bottom-bounds.top)*scale)/2;
	for (const auto& d : preset.displays) if (d.enabled && d.mirror.empty()) {
		RectF rect(x+(d.x-bounds.left)*scale, y+(d.y-bounds.top)*scale, std::max(3.0f,d.mode.width*scale-1), std::max(3.0f,d.mode.height*scale-1));
		if (std::any_of(preset.displays.begin(), preset.displays.end(), [&](const Display& other) { return other.mirror == d.id; })) {
			rounded(g, RectF(rect.X+2,rect.Y-2,rect.Width,rect.Height), colors.card, colors.secondary, 1);
		}
		rounded(g, rect, d.x == 0 && d.y == 0 ? colors.accent : colors.selection, colors.secondary, 1);
	}
}
static void drawText(Graphics& g, const std::wstring& text, RectF rect, float size, COLORREF c, bool bold = false, bool center = false) {
	FontFamily family(L"Segoe UI"); Font font(&family, size, bold ? FontStyleBold : FontStyleRegular, UnitPixel); SolidBrush brush(color(c)); StringFormat f; f.SetTrimming(StringTrimmingEllipsisCharacter); f.SetFormatFlags(StringFormatFlagsLineLimit); if (center) { f.SetAlignment(StringAlignmentCenter); f.SetLineAlignment(StringAlignmentCenter); }
	g.DrawString(text.c_str(), -1, &font, rect, &f, &brush);
}
static HICON makeIcon() {
	HDC dc = GetDC(nullptr); BITMAPINFO bi{}; bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER); bi.bmiHeader.biWidth = 64; bi.bmiHeader.biHeight = -64; bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
	void* pixels = nullptr; HBITMAP bitmap = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &pixels, nullptr, 0); HDC mem = CreateCompatibleDC(dc); auto old = SelectObject(mem, bitmap);
	{ Graphics g(mem); g.SetSmoothingMode(SmoothingModeAntiAlias); g.Clear(Color(255, 28,28,30)); drawText(g, L"DM", RectF(0,0,64,64), 30, RGB(221,224,229), true, true); }
	auto data = static_cast<DWORD*>(pixels); for (int i = 0; i < 64 * 64; ++i) data[i] |= 0xff000000;
	HBITMAP mask = CreateBitmap(64,64,1,1,nullptr); ICONINFO info{TRUE,0,0,mask,bitmap}; HICON icon = CreateIconIndirect(&info);
	SelectObject(mem,old); DeleteDC(mem); ReleaseDC(nullptr,dc); DeleteObject(mask); DeleteObject(bitmap); return icon;
}
struct WorkResult { bool refresh = false, automatic = false; int64_t until = 0; Hardware hardware; std::string error, note, transaction, preset; };
class Window {
public:
	HWND hwnd = nullptr, canvas = nullptr;
	HINSTANCE instance;
	std::unique_ptr<Backend> backend;
	std::unique_ptr<AudioWatcher> audioWatcher;
	Settings settings;
	Hardware hardware;
	fs::path folder;
	Recovery recovery;
	Page page = Page::presets;
	bool fixture = false, dark = false, forceTheme = false, readOnly = false, busy = false, rebuilding = false, quitting = false;
	bool pendingRefresh = false, testMode = false, fixtureAutomation = false, recoveryFailed = false, trayReady = false;
	std::string selectedRule, ruleFilter, selectedCondition;
	bool filterOpen = false, matchAll = true;
	std::set<std::string> displayFilter;
	std::vector<Device> filterDevices;
	std::vector<SidebarRow> sidebarRows;
	NameTarget nameTarget = NameTarget::none;
	std::string nameId, nameDraft;
	std::string status = "Reading connected displays…", error, selected, active, pending, applyingPreset;
	int64_t pendingUntil = 0;
	Preset draft;
	Rule draftRule;
	int displayIndex = 0, tab = 0;
	std::vector<Mode> editModes;
	std::vector<std::string> useIds, outputIds, inputIds, wirelessIds;
	std::vector<Device> ruleDevices;
	std::vector<HWND> controls;
	std::map<int, HWND> byId;
	std::vector<HFONT> fonts;
	HBRUSH bgBrush = nullptr, cardBrush = nullptr, sideBrush = nullptr;
	HDEVNOTIFY deviceNotify = nullptr;
	NOTIFYICONDATAW tray{};
	UINT taskbarCreated = 0;
	HICON icon = nullptr;
	std::thread worker;
	int width = 1180, height = 820, scroll = 0, totalHeight = 0;
	float dpi = 1;
	std::vector<std::pair<int, RectF>> canvasRects;
	float canvasScale = 1;
	int dragIndex = -1; POINT dragStart{}; int dragX = 0, dragY = 0;
	Window(HINSTANCE h, fs::path dir, bool demo, bool useDark, bool forced) : instance(h), backend(demo ? std::unique_ptr<Backend>(new FixtureBackend) : std::unique_ptr<Backend>(new WindowsBackend)), folder(std::move(dir)), recovery(folder), fixture(demo), dark(useDark), forceTheme(forced) {}
	~Window() { if (worker.joinable()) worker.join(); audioWatcher.reset(); if (deviceNotify) UnregisterDeviceNotification(deviceNotify); if (bgBrush) DeleteObject(bgBrush); if (cardBrush) DeleteObject(cardBrush); if (sideBrush) DeleteObject(sideBrush); for (auto f : fonts) DeleteObject(f); if (icon) DestroyIcon(icon); }
	int px(int x) const { return int(std::round(x * dpi)); }
	Palette colors() const { return palette(dark); }
	HWND ctl(int id) const { auto i = byId.find(id); return i == byId.end() ? nullptr : i->second; }
	Preset* selectedPreset() { auto i = std::find_if(settings.presets.begin(), settings.presets.end(), [&](const auto& p) { return p.id == selected; }); return i == settings.presets.end() ? nullptr : &*i; }
	bool locked() const { return busy || !pending.empty(); }
	bool canApply() const { return !locked() && !readOnly && !recoveryFailed; }
	const Preset* activePreset() const {
		auto isMatch = [&](const Preset& p) { return matches(p.displays, hardware.displays); };
		auto found = std::find_if(settings.presets.begin(), settings.presets.end(), [&](const Preset& p) { return p.id == active && isMatch(p); });
		if (found == settings.presets.end()) found = std::find_if(settings.presets.begin(), settings.presets.end(), isMatch);
		return found == settings.presets.end() ? nullptr : &*found;
	}
	void fail(const std::string& message) { error = message; status = message; if (hwnd) { InvalidateRect(hwnd,nullptr,FALSE); if (!IsWindowVisible(hwnd)) notify(L"DisplayMind needs attention", wide(message)); } }
	void notify(const std::wstring& title, const std::wstring& message) {
		if (!trayReady) return; tray.uFlags = NIF_INFO; wcsncpy_s(tray.szInfoTitle,title.c_str(),_TRUNCATE); wcsncpy_s(tray.szInfo,message.c_str(),_TRUNCATE); tray.dwInfoFlags = NIIF_INFO; Shell_NotifyIconW(NIM_MODIFY,&tray); tray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
	}
	void addTray() { trayReady = Shell_NotifyIconW(NIM_ADD, &tray) != FALSE; }
	HFONT font(int size = 14, bool bold = false) {
		HFONT f = CreateFontW(-px(size),0,0,0,bold ? FW_SEMIBOLD : FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI"); fonts.push_back(f); return f;
	}
	HWND add(const wchar_t* cls, const std::wstring& title, int id, int x, int y, int w, int h, DWORD style = 0, DWORD ex = 0) {
		HWND child = CreateWindowExW(ex,cls,title.c_str(),WS_CHILD | WS_VISIBLE | style,px(x),px(y-scroll),px(w),px(h),hwnd,reinterpret_cast<HMENU>(INT_PTR(id)),instance,nullptr);
		if (!child) throw std::runtime_error("Cannot create a native window control"); controls.push_back(child); byId[id] = child; SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(font()),TRUE); SetWindowTheme(child,dark ? L"DarkMode_Explorer" : L"Explorer",nullptr); return child;
	}
	HWND button(const std::wstring& title, int id, int x, int y, int w, int h = 34) { return add(L"BUTTON",title,id,x,y,w,h,BS_OWNERDRAW | WS_TABSTOP); }
	HWND label(const std::wstring& title, int id, int x, int y, int w, int h = 24) { return add(L"STATIC",title,id,x,y,w,h,SS_LEFT); }
	HWND edit(const std::wstring& title, int id, int x, int y, int w, int h = 30) { auto c = add(L"EDIT",title,id,x,y,w,h,WS_TABSTOP | ES_AUTOHSCROLL,WS_EX_CLIENTEDGE); SendMessageW(c,EM_SETLIMITTEXT,2048,0); return c; }
	HWND combo(const std::vector<std::wstring>& titles, int selectedIndex, int id, int x, int y, int w) {
		auto c = add(WC_COMBOBOXW,L"",id,x,y,w,360,WS_TABSTOP | CBS_DROPDOWNLIST | CBS_OWNERDRAWFIXED | CBS_HASSTRINGS | WS_VSCROLL);
		SendMessageW(c,CB_SETITEMHEIGHT,static_cast<WPARAM>(-1),px(26)); SendMessageW(c,CB_SETITEMHEIGHT,0,px(26));
		for (const auto& title : titles) SendMessageW(c,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(title.c_str())); SendMessageW(c,CB_SETCURSEL,selectedIndex,0); SendMessageW(c,CB_SETDROPPEDWIDTH,px(std::max(w,320)),0); return c;
	}
	HWND check(const std::wstring& title, bool checked, int id, int x, int y, int w) { auto c = add(L"BUTTON",title,id,x,y,w,28,BS_AUTOCHECKBOX | WS_TABSTOP); SetWindowTheme(c,L"",L""); SendMessageW(c,BM_SETCHECK,checked ? BST_CHECKED : BST_UNCHECKED,0); return c; }
	bool checked(int id) const { return SendMessageW(ctl(id),BM_GETCHECK,0,0) == BST_CHECKED; }
	int selection(int id) const { return int(SendMessageW(ctl(id),CB_GETCURSEL,0,0)); }
	void persist(Settings next) { if (readOnly) throw std::runtime_error("Settings are read-only because the original file could not be loaded. It has been preserved."); if (!fixture) saveSettings(folder,next); settings = std::move(next); }
	void load() {
		try { settings = fixture ? demoSettings() : loadSettings(folder); } catch (const std::exception& e) { readOnly = true; settings.automatic = false; fail(e.what()); }
		try { hardware = backend->read(); if (error.empty()) status = std::to_string(hardware.displays.size()) + " displays connected"; } catch (const std::exception& e) { fail(e.what()); }
		if (!fixture) try { rememberHardware(false); } catch (const std::exception& e) { fail(e.what()); }
		if (!fixture && !readOnly && fs::exists(recovery.resultPath())) try {
			auto result=Json::parse(readText(recovery.resultPath()));
			if (result.flag("kept")) {
				auto next = settings;
				auto p = std::find_if(next.presets.begin(), next.presets.end(), [&](const Preset& saved) { return saved.id == result.str("preset") && matches(saved.displays, hardware.displays); });
				if (p != next.presets.end()) { active = p->id; if (!p->confirmed) { p->confirmed = true; persist(next); } }
			}
		} catch (const std::exception& e) { fail(e.what()); }
		if (!settings.presets.empty()) selected = settings.presets.front().id;
	}
	void build();
	void paint(HDC dc);
	void paintCanvas(HDC dc, HWND target);
	void command(int id, int code);
	void refresh(bool force = false);
	void finish(WorkResult* result);
	void apply(const Preset& p, bool automatic);
	void settle();
	void tick();
	void keep();
	void revert();
	void startEditor(const Preset& p);
	void saveDraft();
	void updateDisplay();
	void startRule(const Rule* r = nullptr);
	void updateRuleDevices();
	void deviceCondition();
	void populateSidebar();
	void rememberHardware(bool rememberNew);
	void startNameEdit(NameTarget target, const std::string& id, const std::string& name);
	void saveName();
	void menu(bool trayMenu = false, const std::string& folderId = {});
	void show() { ShowWindow(hwnd,SW_RESTORE); SetForegroundWindow(hwnd); }
	ConnectionGate gate;
	static LRESULT CALLBACK procedure(HWND w, UINT m, WPARAM a, LPARAM b);
	static LRESULT CALLBACK canvasProcedure(HWND w, UINT m, WPARAM a, LPARAM b);
};
void Window::build() {
	rebuilding = true;
	RECT actual{}; GetClientRect(hwnd,&actual); width=int(actual.right/dpi); height=int(actual.bottom/dpi);
	HWND focused = GetFocus(); int focusId = focused ? GetDlgCtrlID(focused) : 0;
	for (auto c : controls) DestroyWindow(c); controls.clear(); byId.clear(); canvas = nullptr;
	for (auto f : fonts) DeleteObject(f); fonts.clear();
	if (bgBrush) DeleteObject(bgBrush); if (cardBrush) DeleteObject(cardBrush); if (sideBrush) DeleteObject(sideBrush);
	bgBrush = CreateSolidBrush(colors().bg); cardBrush = CreateSolidBrush(colors().card); sideBrush = CreateSolidBrush(colors().side);
	BOOL theme = dark; DwmSetWindowAttribute(hwnd,20,&theme,sizeof(theme));
	int side = page == Page::presets || page == Page::rules ? 240 : 0;
	int left = side + 28, right = width - 28, content = right - left;
	int footer = std::max(height, 760) - 54; totalHeight = std::max(height, 760);
	if (side) {
		button(L"Includes displays", C_FILTER, 12, 81, 125, 31);
		button(L"New folder", C_ADD_FOLDER, 143, 81, 85, 31);
		int listTop = 124;
		if (filterOpen) {
			std::map<std::string, std::string> displays;
			for (const auto& d : hardware.displays) displays[d.id] = d.name;
			for (const auto& p : settings.presets) for (const auto& d : p.displays) displays.try_emplace(d.id, d.name);
			filterDevices.clear();
			for (const auto& [id, name] : displays) filterDevices.push_back({id, name});
			std::sort(filterDevices.begin(), filterDevices.end(), [](const Device& a, const Device& b) { return std::tie(a.name,a.id) < std::tie(b.name,b.id); });
			auto filters = add(WC_LISTVIEWW, L"Included displays", C_FILTER_DISPLAYS, 12, listTop, 216, 92, LVS_REPORT | LVS_NOCOLUMNHEADER | WS_TABSTOP | WS_BORDER);
			ListView_SetExtendedListViewStyle(filters, LVS_EX_CHECKBOXES | LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
			ListView_SetBkColor(filters, colors().card); ListView_SetTextBkColor(filters, colors().card); ListView_SetTextColor(filters, colors().text);
			LVCOLUMNW column{}; column.mask = LVCF_WIDTH; column.cx = px(194); ListView_InsertColumn(filters, 0, &column);
			for (size_t i = 0; i < filterDevices.size(); ++i) {
				const auto& display = filterDevices[i];
				auto name = wide(display.name);
				if (std::count_if(filterDevices.begin(), filterDevices.end(), [&](const Device& d) { return d.name == display.name; }) > 1) name += L" · " + wide(identityHint(display.id));
				LVITEMW row{}; row.mask = LVIF_TEXT; row.iItem = static_cast<int>(i); row.pszText = name.data(); ListView_InsertItem(filters, &row);
				ListView_SetCheckState(filters, row.iItem, displayFilter.contains(display.id));
			}
			combo({L"All selected", L"Any selected"}, matchAll ? 0 : 1, C_FILTER_MODE, 12, listTop+100, 144);
			button(L"Clear", C_CLEAR_FILTER, 162, listTop+100, 66, 31);
			listTop += 142;
		}
		if (nameTarget != NameTarget::none) {
			edit(wide(nameDraft), C_INLINE_NAME, 12, listTop, 216);
			button(L"Save name", C_INLINE_SAVE, 12, listTop+34, 106, 29);
			button(L"Cancel", C_INLINE_CANCEL, 130, listTop+34, 98, 29);
			listTop += 72;
		}
		add(L"LISTBOX",L"Saved presets",C_PRESETS,12,listTop,216,std::max(106,footer-listTop-259),LBS_NOTIFY | LBS_OWNERDRAWVARIABLE | LBS_HASSTRINGS | LBS_NOINTEGRALHEIGHT | WS_TABSTOP | WS_VSCROLL);
		populateSidebar();
		button(L"＋  Capture current layout",C_CAPTURE,16,footer-244,208);
		button(L"Connection rules  ·  " + std::to_wstring(settings.rules.size()),C_RULES,16,footer-192,208);
		check(L"Automatic switching",settings.automatic,C_AUTOMATIC,20,footer-140,204);
		check(L"Open at login",!fixture && loginEnabled(),C_LOGIN,20,footer-104,204);
		button(L"Open data folder",C_FOLDER,16,footer-58,208);
	}
	if (page == Page::presets) {
		auto p = selectedPreset();
		button(L"Apply preset",C_APPLY,right-356,25,122); button(L"Edit preset…",C_EDIT,right-224,25,156); button(L"•••",C_MORE,right-56,25,56);
		button(L"↻",C_REFRESH,right-36,footer+10,36,32);
		if (p) {
			canvas = add(L"DisplayMind.Canvas",L"Display arrangement",300,left,108,content,240);
			int y = 382;
			for (const auto& d : p->displays) { (void)d; y += 64; }
			y += 42; int audioRows = (!p->audio.output.empty() ? 1 : 0) + (!p->audio.input.empty() ? 1 : 0) + (!p->receiver.empty() ? 1 : 0); y += audioRows * 48;
			totalHeight = std::max(totalHeight,y+100);
		}
		if (!pending.empty() && pendingUntil) { button(L"Keep",C_KEEP,right-208,70,92,30); button(L"Revert",C_REVERT,right-106,70,106,30); }
		EnableWindow(ctl(C_APPLY), p && canApply() && unavailable(*p, hardware).empty());
		EnableWindow(ctl(C_EDIT), p && !locked() && !readOnly);
	} else if (page == Page::rules) {
		button(L"＋  New rule",C_NEW_RULE,right-142,26,142);
		auto list = add(WC_LISTVIEWW,L"Connection rules in priority order",C_RULE_LIST,left,122,content,footer-196,LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS | WS_TABSTOP | WS_BORDER);
		ListView_SetExtendedListViewStyle(list,LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_CHECKBOXES);
		ListView_SetBkColor(list,colors().card); ListView_SetTextBkColor(list,colors().card); ListView_SetTextColor(list,colors().text);
		for (auto [title,w] : std::vector<std::pair<std::wstring,int>>{{L"Rule",std::max(200,content/3)},{L"Applies preset",std::max(180,content/3)},{L"Conditions",std::max(160,content/3-18)}}) { LVCOLUMNW c{}; c.mask = LVCF_TEXT | LVCF_WIDTH; c.pszText = title.data(); c.cx = px(w); ListView_InsertColumn(list,Header_GetItemCount(ListView_GetHeader(list)),&c); }
		for (size_t i = 0; i < settings.rules.size(); ++i) {
			const auto& r = settings.rules[i]; auto name = wide(r.name); LVITEMW row{}; row.mask = LVIF_TEXT; row.iItem = int(i); row.pszText = name.data(); ListView_InsertItem(list,&row); ListView_SetCheckState(list,int(i),r.enabled);
			auto p = std::find_if(settings.presets.begin(),settings.presets.end(),[&](const auto& a) { return a.id == r.preset; }); auto title = p == settings.presets.end() ? L"Missing preset" : wide(p->name) + (p->confirmed ? L"" : L" · needs verification"); ListView_SetItemText(list,int(i),1,title.data());
			auto detail = std::to_wstring(r.required.size()+r.absent.size()) + (r.exact ? L" · exact display set" : L" · extra displays allowed"); ListView_SetItemText(list,int(i),2,detail.data());
		}
		button(L"Edit",C_RULE_EDIT,left,footer-58,90); button(L"Delete",C_RULE_DELETE,left+100,footer-58,90); button(L"Move up",C_RULE_UP,left+210,footer-58,110); button(L"Move down",C_RULE_DOWN,left+330,footer-58,122);
		auto selectedRow = std::find_if(settings.rules.begin(), settings.rules.end(), [&](const Rule& r) { return r.id == selectedRule; });
		if (!settings.rules.empty()) ListView_SetItemState(list, selectedRow == settings.rules.end() ? 0 : int(selectedRow - settings.rules.begin()), LVIS_SELECTED | LVIS_FOCUSED, LVIS_SELECTED | LVIS_FOCUSED);
	} else if (page == Page::editor) {
		edit(wide(draft.name),C_NAME,196,24,width-224,34);
		int panel = 406, split = width-panel-28;
		canvas = add(L"DisplayMind.Canvas",L"Select and drag displays to arrange them",300,28,100,split-50,footer-134);
		label(L"Click a display to select it. Drag to move; edges snap.\nUse Tab to reach the display and position controls.",310,28,footer-22,split-50,44);
		button(L"Display",C_TAB_DISPLAY,split+26,94,112); button(L"Sound",C_TAB_SOUND,split+144,94,112); button(L"Wireless",C_TAB_WIRELESS,split+262,94,112);
		int x = split+26, field = x+92, w = right-field;
		if (tab == 0 && !draft.displays.empty()) {
			displayIndex = std::clamp(displayIndex,0,int(draft.displays.size())-1); auto& d = draft.displays[displayIndex];
			std::vector<std::wstring> names; for (const auto& a : draft.displays) { auto duplicate=std::count_if(draft.displays.begin(),draft.displays.end(),[&](const auto& b) { return b.name==a.name; })>1; names.push_back(wide(a.name)+(duplicate ? L" · "+wide(identityHint(a.id)) : L"")); } combo(names,displayIndex,C_DISPLAY,x,148,right-x);
			label(L"Name",320,x,200,88); edit(wide(d.name),321,field,196,w);
			useIds = {""}; std::vector<std::wstring> uses = {L"Extended display"}; int use = 0;
			for (const auto& a : draft.displays) if (a.id != d.id && a.enabled && a.mirror.empty()) { useIds.push_back(a.id); uses.push_back(L"Mirror of " + wide(a.name)); if (d.mirror == a.id) use = int(uses.size())-1; }
			label(L"Use as",322,x,246,88); combo(uses,use,C_USE,field,242,w);
			label(L"Rotation",323,x,292,88); combo({L"0°",L"90°",L"180°",L"270°"},d.rotation/90,C_ROTATION,field,288,w);
			editModes.clear(); auto modes = hardware.modes.find(d.id);
			if (modes != hardware.modes.end()) { editModes = modes->second; auto current = std::find_if(hardware.displays.begin(),hardware.displays.end(),[&](const auto& a) { return a.id == d.id; }); if (current != hardware.displays.end() && current->rotation % 180 != d.rotation % 180) for (auto& mode : editModes) std::swap(mode.width,mode.height); }
			if (std::find(editModes.begin(),editModes.end(),d.mode) == editModes.end()) editModes.insert(editModes.begin(),d.mode);
			std::vector<std::wstring> titles; int mode = 0; for (size_t i = 0; i < editModes.size(); ++i) { titles.push_back(modeLabel(editModes[i])); if (editModes[i] == d.mode) mode = int(i); }
			label(L"Resolution",324,x,338,88); combo(titles,mode,C_MODE,field,334,w);
			label(L"Position",325,x,384,88); label(L"X",326,field,384,20); edit(std::to_wstring(d.x),C_X,field+22,380,(w-58)/2); label(L"Y",327,field+w/2+8,384,20); edit(std::to_wstring(d.y),C_Y,field+w/2+30,380,w/2-30);
			button(L"Place beside ▾",C_PLACE,field,430,w-120); button(L"Make main",C_MAIN,right-110,430,110);
			bool root = d.mirror.empty(); bool main = root && d.x == 0 && d.y == 0;
			EnableWindow(ctl(C_USE), d.enabled);
			for (auto id : {C_ROTATION,C_MODE}) EnableWindow(ctl(id),root && d.enabled);
			for (auto id : {C_X,C_Y,C_MAIN,C_PLACE}) EnableWindow(ctl(id),root && !main && d.enabled);
			label(root ? L"Resolution and refresh rates come from the Windows display driver. Unsupported changes are recovered automatically." : L"A mirrored display follows its source's resolution, rotation and position.",328,x,492,right-x,82);
			if (!d.enabled) label(L"Disabled in the captured layout; preserved.",329,x,586,right-x,50);
		} else if (tab == 1) {
			auto audioCombo = [&](bool input, int id, int y) {
				auto& ids = input ? inputIds : outputIds; ids = {""}; std::vector<std::wstring> names = {L"Don't change"}; const auto& saved = input ? draft.audio.input : draft.audio.output; int chosen = 0;
				for (const auto& a : hardware.audioDevices) if (a.input == input) { ids.push_back(a.id); bool duplicate=std::count_if(hardware.audioDevices.begin(),hardware.audioDevices.end(),[&](const auto& b) { return b.input==input && b.name==a.name; })>1; names.push_back(wide(a.name)+(a.bluetooth ? L" · Bluetooth" : L"")+(duplicate ? L" · "+wide(a.id.substr(a.id.size()>14 ? a.id.size()-14 : 0)) : L"")); if (a.id == saved) chosen = int(ids.size())-1; }
				if (!saved.empty() && std::find(ids.begin(),ids.end(),saved) == ids.end()) { ids.push_back(saved); const auto& name=input ? draft.inputName : draft.outputName; names.push_back((name.empty() ? L"Saved device" : wide(name))+L" · not connected"); chosen = int(ids.size())-1; }
				label(input ? L"Input" : L"Output",input ? 332 : 331,x,y,88); combo(names,chosen,id,field,y-4,w);
			}; audioCombo(false,C_AUDIO_OUT,160); audioCombo(true,C_AUDIO_IN,216);
			label(L"Sound is selected after the display layout verifies.\n\nBluetooth headphones in use stay selected. The preset takes over when those headphones disconnect.\n\nUnavailable audio endpoints are skipped and reported without reverting the layout.",333,x,286,right-x,224);
			button(L"Windows sound settings",C_SYSTEM_SOUND,x,544,right-x);
		} else if (tab == 2) {
			label(L"Connect a Miracast receiver in Windows Cast before capturing its display.",335,x,172,right-x,62);
			button(L"Open Windows Cast (Win+K)",C_CAST,x,242,right-x);
			label(L"Receiver",336,x,354,88); edit(wide(draft.receiver),C_RECEIVER,field,350,w);
			wirelessIds = {""}; std::vector<std::wstring> titles = {L"Connect manually"}; int index = 0;
			for (const auto& d : draft.displays) if (d.wireless && d.enabled) { wirelessIds.push_back(d.id); titles.push_back(wide(d.name)); if (d.id == draft.wirelessDisplay) index = int(wirelessIds.size())-1; }
			label(L"Its display",337,x,404,88); combo(titles,index,C_WIRELESS_DISPLAY,field,400,w);
			EnableWindow(ctl(C_RECEIVER), index > 0);
			label(L"Enter the exact receiver name shown in Windows Cast. Windows handles pairing.",338,x,462,right-x,68);
		}
		button(L"Cancel",C_CANCEL,right-220,footer+6,96); button(L"Save preset",C_SAVE,right-114,footer+6,114);
	} else if (page == Page::ruleEditor) {
		edit(wide(draftRule.name),C_NAME,196,24,width-224,34);
		label(L"Apply preset",340,28,106,120);
		std::vector<std::wstring> titles; int chosen = 0; for (size_t i = 0; i < settings.presets.size(); ++i) { titles.push_back(wide(settings.presets[i].name)); if (settings.presets[i].id == draftRule.preset) chosen = int(i); } combo(titles,chosen,C_RULE_PRESET,154,102,330);
		label(L"when all marked device conditions match",341,508,106,width-536);
		edit(wide(ruleFilter),C_SEARCH,28,152,width-56); SendMessageW(ctl(C_SEARCH),EM_SETCUEBANNER,TRUE,reinterpret_cast<LPARAM>(L"Filter displays and USB devices"));
		auto list = add(WC_LISTVIEWW,L"Display and USB conditions",C_DEVICES,28,198,width-56,footer-410,LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS | WS_BORDER | WS_TABSTOP);
		ListView_SetExtendedListViewStyle(list,LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
		ListView_SetBkColor(list,colors().card); ListView_SetTextBkColor(list,colors().card); ListView_SetTextColor(list,colors().text);
		int column = 0; for (auto [title,w] : std::vector<std::pair<std::wstring,int>>{{L"Display or USB device",width-480},{L"Now",170},{L"Condition",210}}) { LVCOLUMNW c{}; c.mask = LVCF_TEXT | LVCF_WIDTH; c.pszText = title.data(); c.cx = px(w); ListView_InsertColumn(list,column++,&c); }
		label(L"Selected device",342,28,footer-192,160); combo({L"Ignore",L"Connected",L"Absent"},0,C_CONDITION,198,footer-196,240); updateRuleDevices();
		check(L"Only when no other display is connected",draftRule.exact,C_EXACT,28,footer-144,width-56); check(L"Rule is on",draftRule.enabled,C_ENABLED,28,footer-108,width-56);
		label(L"The first eligible rule wins after connections settle for 3 seconds. A manually selected preset stays until the next connection change. Apply and keep an edited layout once before a rule can use it.",343,28,footer-66,width-56,52);
		button(L"Cancel",C_CANCEL,right-220,footer+6,96); button(L"Save rule",C_SAVE,right-114,footer+6,114);
	}
	if (locked()) for (auto id : {C_CAPTURE,C_RULES,C_AUTOMATIC,C_NEW_RULE,C_RULE_LIST,C_RULE_EDIT,C_RULE_DELETE,C_RULE_UP,C_RULE_DOWN}) if (ctl(id)) EnableWindow(ctl(id),FALSE);
	if (readOnly) for (auto id : {C_CAPTURE,C_AUTOMATIC,C_SAVE,C_NEW_RULE,C_RULE_LIST,C_RULE_EDIT,C_RULE_DELETE,C_RULE_UP,C_RULE_DOWN}) if (ctl(id)) EnableWindow(ctl(id),FALSE);
	if (hardware.displays.empty() && ctl(C_CAPTURE)) EnableWindow(ctl(C_CAPTURE), FALSE);
	if (ctl(C_ADD_FOLDER)) EnableWindow(ctl(C_ADD_FOLDER), !locked() && !readOnly);
	if (recoveryFailed && side) button(L"Retry recovery", C_RETRY_RECOVERY, right-262, footer+10, 130, 32);
	if (!error.empty() && side) button(L"Details",C_ERROR_DETAILS,right-124,footer+10,80,32);
	SCROLLINFO si{sizeof(si),SIF_RANGE | SIF_PAGE | SIF_POS,0,totalHeight,static_cast<UINT>(height),scroll,0}; SetScrollInfo(hwnd,SB_VERT,&si,TRUE);
	if (auto c = ctl(focusId)) SetFocus(c);
	rebuilding = false; InvalidateRect(hwnd,nullptr,TRUE);
}
void Window::paint(HDC dc) {
	RECT client{}; GetClientRect(hwnd,&client); HDC memory = CreateCompatibleDC(dc); HBITMAP bitmap = CreateCompatibleBitmap(dc,client.right,client.bottom); auto old = SelectObject(memory,bitmap);
	{
		Graphics g(memory); g.SetSmoothingMode(SmoothingModeAntiAlias); g.SetTextRenderingHint(TextRenderingHintClearTypeGridFit); g.ScaleTransform(dpi,dpi); g.TranslateTransform(0,-float(scroll)); auto c = colors(); g.Clear(color(c.bg));
		bool side = page == Page::presets || page == Page::rules;
		if (side) {
			SolidBrush b(color(c.side)); g.FillRectangle(&b,0,0,240,totalHeight); Pen line(color(c.border)); g.DrawLine(&line,240,0,240,totalHeight);
			rounded(g,RectF(22,26,38,38),RGB(19,19,21),RGB(19,19,21),9); drawText(g,L"DM",RectF(22,26,38,38),18,RGB(219,224,232),true,true); drawText(g,L"DisplayMind",RectF(74,28,160,34),24,c.text,true);
		}
		int left = side ? 268 : 28, right = width-28, content = right-left;
		Pen border(color(c.border)); g.DrawLine(&border,side ? 240.0f : 0.0f,84.0f,float(width),84.0f);
		if (page == Page::presets) {
			auto p = selectedPreset();
			if (!p) {
				drawText(g,L"Your displays, ready when you are",RectF(float(left+30),190,float(content-60),54),30,c.text,true,true);
				drawText(g,L"Capture the current layout to save a preset.\nThen choose layouts from here or the system tray,\nor let connection rules switch them for you.",RectF(float(left+60),270,float(content-120),130),17,c.secondary,false,true);
			} else {
				drawText(g,wide(p->name),RectF(float(left),18,float(content-390),40),28,c.text,true);
				bool current = p == activePreset(); auto unavailableText = unavailable(*p,hardware);
				std::wstring subtitle = current ? L"●  Active now" : unavailableText.empty() ? (p->confirmed ? L"Ready to apply" : L"Apply once to enable automatic rules") : wide(unavailableText);
				if (!pending.empty()) subtitle = pendingUntil ? L"Applied · Revert available for " + std::to_wstring(std::max<int64_t>(0,(pendingUntil-utcMillis()+999)/1000)) + L" seconds" : L"Restoring previous settings";
				drawText(g,subtitle,RectF(float(left),59,float(content-20),25),13,current ? c.accent : c.secondary);
				drawText(g,L"DISPLAYS",RectF(float(left),363,float(content),22),12,c.secondary,true);
				int y = 388;
				for (const auto& d : p->displays) {
					rounded(g,RectF(float(left),float(y),float(content),58),c.card,c.border,10);
					drawText(g,wide(d.name),RectF(float(left+20),float(y+7),float(content-220),25),16,c.text,true);
					drawText(g,modeLabel(d.mode)+(d.rotation ? L"  ·  rotated " + std::to_wstring(d.rotation)+L"°" : L""),RectF(float(left+20),float(y+32),float(content-220),20),12,c.secondary);
					auto role = !d.enabled ? L"Disabled" : !d.mirror.empty() ? L"Mirrored" : d.x == 0 && d.y == 0 ? L"Main display" : L"Extended"; drawText(g,role,RectF(float(right-168),float(y+18),148,24),14,c.secondary,false,true); y += 64;
				}
				y += 22; drawText(g,L"APPLIED WITH THE LAYOUT",RectF(float(left),float(y),float(content),22),12,c.secondary,true); y += 30;
				auto soundName = [&](const std::string& id) { auto i = std::find_if(hardware.audioDevices.begin(),hardware.audioDevices.end(),[&](const auto& a) { return a.id == id; }); const auto& name=id==p->audio.output ? p->outputName : p->inputName; return i == hardware.audioDevices.end() ? (name.empty() ? L"Saved device" : wide(name))+L" · not connected" : wide(i->name); };
				for (const auto& [title,id] : std::vector<std::pair<std::wstring,std::string>>{{L"Sound output",p->audio.output},{L"Sound input",p->audio.input},{L"Wireless display",p->receiver}}) if (!id.empty()) {
					rounded(g,RectF(float(left),float(y),float(content),42),c.card,c.border,8); drawText(g,title,RectF(float(left+16),float(y+11),160,24),14,c.text); drawText(g,title == L"Wireless display" ? wide(id) : soundName(id),RectF(float(left+194),float(y+11),float(content-210),24),14,c.secondary); y += 48;
				}
			}
		} else if (page == Page::rules) {
			drawText(g,L"Connection rules",RectF(float(left),22,float(content-200),40),28,c.text,true); drawText(g,L"Rules run in order. The first matching, verified preset wins.",RectF(float(left),93,float(content),24),14,c.secondary);
			if (settings.rules.empty()) drawText(g,L"Create a rule for your desk, dock or presentation display.",RectF(float(left+30),290,float(content-60),90),20,c.secondary,false,true);
		} else {
			drawText(g,page == Page::editor ? L"Edit preset" : L"Edit rule",RectF(28,26,160,36),24,c.text,true);
		}
		if (side) {
			float y = float(std::max(height,760)-54); g.DrawLine(&border,240.0f,y,float(width),y); std::string shown = !error.empty() ? error : status;
			if (fixture) shown = "Preview · fixture backend only · " + shown;
			drawText(g,wide(shown),RectF(float(left),y+15,float(content-60),31),12,error.empty() ? c.secondary : (dark ? RGB(255,174,143) : RGB(166,55,15)));
		}
	}
	BitBlt(dc,0,0,client.right,client.bottom,memory,0,0,SRCCOPY); SelectObject(memory,old); DeleteObject(bitmap); DeleteDC(memory);
}
void Window::paintCanvas(HDC dc, HWND target) {
	RECT cr{}; GetClientRect(target,&cr); HDC memory = CreateCompatibleDC(dc); HBITMAP bitmap = CreateCompatibleBitmap(dc,cr.right,cr.bottom); auto old = SelectObject(memory,bitmap);
	Graphics g(memory); g.SetSmoothingMode(SmoothingModeAntiAlias); g.SetTextRenderingHint(TextRenderingHintClearTypeGridFit); g.ScaleTransform(dpi,dpi); auto c = colors(); g.Clear(color(c.bg));
	float w = cr.right/dpi, h = cr.bottom/dpi; rounded(g,RectF(1,1,w-3,h-3),c.card,c.border,14);
	SolidBrush dots(color(c.border)); for (float x=16; x<w-10; x+=22) for (float y=16; y<h-10; y+=22) g.FillEllipse(&dots,x,y,1.5f,1.5f);
	const auto* p = page == Page::editor ? &draft : selectedPreset(); canvasRects.clear();
	if (p && !p->displays.empty()) {
		int x1 = 0,y1 = 0,x2 = 1,y2 = 1; bool first = true;
		for (const auto& d : p->displays) if (d.enabled && d.mirror.empty()) { if (first) { x1=d.x; y1=d.y; x2=d.x+d.mode.width; y2=d.y+d.mode.height; first=false; } else { x1=std::min(x1,d.x); y1=std::min(y1,d.y); x2=std::max(x2,d.x+d.mode.width); y2=std::max(y2,d.y+d.mode.height); } }
		canvasScale = std::min((w-70)/std::max(1,x2-x1),(h-64)/std::max(1,y2-y1)); canvasScale = std::max(0.0001f,canvasScale); float ox=(w-(x2-x1)*canvasScale)/2, oy=(h-(y2-y1)*canvasScale)/2;
		for (size_t i=0;i<p->displays.size();++i) {
			const auto& d = p->displays[i]; if (!d.enabled || !d.mirror.empty()) continue;
			RectF r(ox+(d.x-x1)*canvasScale,oy+(d.y-y1)*canvasScale,std::max(20.0f,d.mode.width*canvasScale-5),std::max(20.0f,d.mode.height*canvasScale-5)); canvasRects.emplace_back(int(i),r);
			GraphicsPath path; roundPath(path,r,9); bool primary=d.x==0 && d.y==0;
			LinearGradientBrush gradient(PointF(r.X,r.Y),PointF(r.GetRight(),r.GetBottom()),primary ? Color(255,37,149,176) : Color(255,91,121,163),primary ? Color(255,27,84,131) : Color(255,57,77,113)); g.FillPath(&gradient,&path);
			Pen border(Color(255,primary ? 114 : 143,primary ? 194 : 165,primary ? 215 : 195),page==Page::editor && displayIndex==int(i) ? 3.5f : 1.5f); g.DrawPath(&border,&path);
			if (primary && r.Width>60) { SolidBrush bar(Color(235,230,247,255)); g.FillRectangle(&bar,r.X+r.Width*.36f,r.Y+8,r.Width*.28f,4.0f); }
			std::wstring detail=std::to_wstring(d.mode.width)+L" × "+std::to_wstring(d.mode.height); int mirrored=0; for (const auto& a:p->displays) if (a.mirror==d.id) ++mirrored; if (mirrored) detail+=L" · mirrored";
			float size=std::clamp(r.Width/13.0f,10.0f,17.0f); drawText(g,wide(d.name),RectF(r.X+8,r.Y+r.Height/2-25,r.Width-16,42),size,RGB(255,255,255),true,true);
			if (r.Height>80) drawText(g,detail,RectF(r.X+6,r.Y+r.Height/2+15,r.Width-12,28),std::max(10.0f,size-3),RGB(211,230,247),false,true);
		}
	}
	g.Flush(); BitBlt(dc,0,0,cr.right,cr.bottom,memory,0,0,SRCCOPY); SelectObject(memory,old); DeleteObject(bitmap); DeleteDC(memory);
}
void Window::populateSidebar() {
	HWND list = ctl(C_PRESETS);
	if (!list) return;
	SendMessageW(list, WM_SETREDRAW, FALSE, 0);
	SendMessageW(list, LB_RESETCONTENT, 0, 0);
	sidebarRows.clear();
	int selectedRow = -1;
	auto append = [&](const std::string& id, const std::string& label, bool heading) {
		sidebarRows.push_back({id, heading});
		auto row = SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(wide(label).c_str()));
		if (!heading && id == selected) selectedRow = int(row);
	};
	for (const auto& group : settings.folders) {
		bool visible = std::any_of(settings.presets.begin(), settings.presets.end(), [&](const Preset& p) { return p.folder == group.id && includesDisplays(p, displayFilter, matchAll); });
		if (!visible && !displayFilter.empty()) continue;
		append(group.id, group.name, true);
		if (group.collapsed) continue;
		for (const auto& p : settings.presets) if (p.folder == group.id && includesDisplays(p, displayFilter, matchAll)) append(p.id, p.name, false);
	}
	bool hasUngrouped = std::any_of(settings.presets.begin(), settings.presets.end(), [&](const Preset& p) { return p.folder.empty() && includesDisplays(p, displayFilter, matchAll); });
	if (hasUngrouped && !settings.folders.empty()) append({}, "Ungrouped", true);
	for (const auto& p : settings.presets) if (p.folder.empty() && includesDisplays(p, displayFilter, matchAll)) append(p.id, p.name, false);
	SendMessageW(list, LB_SETCURSEL, selectedRow, 0);
	SendMessageW(list, WM_SETREDRAW, TRUE, 0);
	InvalidateRect(list, nullptr, TRUE);
	if (auto button = ctl(C_FILTER)) {
		auto count = std::count_if(settings.presets.begin(), settings.presets.end(), [&](const Preset& p) { return includesDisplays(p, displayFilter, matchAll); });
		auto label = displayFilter.empty() ? L"Includes displays" : std::to_wstring(count) + L" of " + std::to_wstring(settings.presets.size()) + L" presets";
		SetWindowTextW(button, label.c_str());
	}
}
void Window::rememberHardware(bool rememberNew) {
	if (readOnly) return;
	auto next = settings;
	// Include unsaved editor-only displays and conditions in identity matching.
	// Reconcile the draft and saved copy together so a dock change cannot restore
	// stale paths when Save is clicked, and ambiguity is checked across both.
	if (page == Page::editor) next.presets.push_back(draft);
	if (page == Page::ruleEditor) next.rules.push_back(draftRule);
	auto rebound = reconnectMonitors(next, hardware);
	if (page == Page::editor) { draft = next.presets.back(); next.presets.pop_back(); }
	if (page == Page::ruleEditor) { draftRule = next.rules.back(); next.rules.pop_back(); }
	if (rememberNew) for (const auto& d : hardware.devices) {
		auto found = std::find_if(next.known.begin(), next.known.end(), [&](const Device& a) { return a.id == d.id; });
		if (found == next.known.end()) next.known.push_back(d);
		else { found->name = d.name; if (d.monitor.vendor) found->monitor = d.monitor; }
	}
	if (next != settings) persist(std::move(next));
	for (const auto& [oldId, newId] : rebound) if (displayFilter.erase(oldId)) displayFilter.insert(newId);
	for (const auto& [oldId, newId] : rebound) if (selectedCondition == "display:" + oldId) selectedCondition = "display:" + newId;
}
void Window::startNameEdit(NameTarget target, const std::string& id, const std::string& name) {
	nameTarget = target;
	nameId = id;
	nameDraft = name;
	if (target == NameTarget::preset) page = Page::presets;
	scroll = 0;
	build();
	SetFocus(ctl(C_INLINE_NAME));
	SendMessageW(ctl(C_INLINE_NAME), EM_SETSEL, 0, -1);
}
void Window::saveName() {
	if (nameTarget == NameTarget::none || readOnly || locked()) return;
	auto next = settings;
	auto name = trim(nameDraft);
	if (nameTarget == NameTarget::newFolder) next.folders.push_back({newId(), name, false});
	else if (nameTarget == NameTarget::folder) {
		auto f = std::find_if(next.folders.begin(), next.folders.end(), [&](const PresetFolder& a) { return a.id == nameId; });
		if (f == next.folders.end()) return;
		f->name = name;
	} else {
		auto p = std::find_if(next.presets.begin(), next.presets.end(), [&](const Preset& a) { return a.id == nameId; });
		if (p == next.presets.end()) return;
		p->name = name;
		for (auto& f : next.folders) if (f.id == p->folder) f.collapsed = false;
		selected = p->id;
	}
	persist(std::move(next));
	nameTarget = NameTarget::none;
	error.clear();
	build();
}
void Window::refresh(bool force) {
	if (busy) { pendingRefresh = true; return; }
	if (worker.joinable()) worker.join();
	if (force) gate.reset();
	busy = true;
	auto previous = hardware;
	const auto* current = pending.empty() && !recoveryFailed && !readOnly ? activePreset() : nullptr;
	std::optional<Preset> audioPreset = current ? std::optional<Preset>(*current) : std::nullopt;
	worker = std::thread([this, previous, audioPreset] {
		CoInitializeEx(nullptr, COINIT_MULTITHREADED);
		auto result = std::make_unique<WorkResult>();
		result->refresh = true;
		try {
			result->hardware = backend->read();
			if (audioPreset && result->hardware.audioError.empty() && matches(audioPreset->displays, result->hardware.displays)) {
				auto takeover = audioTakeover(audioPreset->audio, previous.audio, previous.audioDevices, result->hardware.audioDevices);
				if (takeover != Audio{}) try {
					result->note = backend->setAudio(takeover);
					result->hardware = backend->read();
				} catch (const std::exception& e) { result->note = e.what(); }
			}
		} catch (const std::exception& e) { result->error = e.what(); }
		CoUninitialize();
		if (PostMessageW(hwnd, WM_WORK, 0, reinterpret_cast<LPARAM>(result.get()))) result.release();
	});
}
void Window::finish(WorkResult* raw) {
	std::unique_ptr<WorkResult> result(raw);
	bool editorHardwareChanged = hardware.displays != result->hardware.displays || hardware.modes != result->hardware.modes
		|| hardware.audioDevices != result->hardware.audioDevices;
	if (worker.joinable()) worker.join();
	busy = false;
	if (!result->error.empty()) {
		fail(result->error);
		if (!result->refresh) {
			applyingPreset.clear();
			try { if (auto j = recovery.inFlight()) { pending = j->id; pendingUntil = 0; } }
			catch (const std::exception& e) { fail(e.what()); }
			if (!pending.empty()) SetTimer(hwnd, ID_ATTENTION, 250, nullptr);
		}
	} else {
		hardware = std::move(result->hardware);
		if (!result->refresh) {
			pending = result->transaction;
			pendingUntil = result->until;
			applyingPreset = active = result->preset;
			status = (result->automatic ? "Automatically applied " : "Applied ") + result->note;
			if (result->automatic) notify(L"Automatically applied preset", wide(result->note));
			gate.consume(deviceIds(hardware), utcMillis());
			if (pending.empty() || result->automatic) keep();
			else SetTimer(hwnd, ID_ATTENTION, 200, nullptr);
		} else if (!result->note.empty()) status = result->note;
		if (result->refresh && pending.empty()) {
			try { rememberHardware(true); } catch (const std::exception& e) { fail(e.what()); }
		}
	}
	if (page == Page::presets || page == Page::rules) build();
	else if (page == Page::editor && result->refresh && result->error.empty() && editorHardwareChanged) build();
	else if (page == Page::ruleEditor && result->refresh) updateRuleDevices();
	if (pendingRefresh) { pendingRefresh = false; SetTimer(hwnd, ID_DEBOUNCE, 180, nullptr); }
	settle();
}
void Window::settle() {
	if ((fixture && !fixtureAutomation) || !canApply() || !settings.automatic || page == Page::editor || page == Page::ruleEditor || !error.empty()) return;
	if (gate.evaluate(deviceIds(hardware), utcMillis())) {
		if (auto rule = matchRule(settings, hardware)) {
			auto p = std::find_if(settings.presets.begin(), settings.presets.end(), [&](const Preset& a) { return a.id == rule->preset; });
			if (p != settings.presets.end()) apply(*p, true);
		}
	}
	if (gate.pending()) SetTimer(hwnd, ID_ATTENTION, 250, nullptr);
}
void Window::apply(const Preset& p, bool automatic) {
	if (!canApply()) return;
	if (worker.joinable()) worker.join();
	busy = true;
	error.clear();
	status = "Applying " + p.name + ".";
	applyingPreset = p.id;
	gate.consume(deviceIds(hardware), utcMillis());
	build();
	worker = std::thread([this, p, automatic, known=settings.presets, previous=hardware] {
		CoInitializeEx(nullptr, COINIT_MULTITHREADED);
		auto result = std::make_unique<WorkResult>();
		result->preset = p.id;
		result->automatic = automatic;
		try {
			auto outcome = applyPreset(*backend, recovery, p, fixture, known);
			result->transaction = outcome.id;
			result->until = outcome.until;
			result->note = p.name + (outcome.note.empty() ? "" : ". " + outcome.note);
			try { result->hardware = backend->read(); }
			catch (const std::exception& e) { result->hardware = previous; result->note += ". " + std::string(e.what()); }
		} catch (const std::exception& e) { result->error = e.what(); }
		CoUninitialize();
		if (PostMessageW(hwnd, WM_WORK, 0, reinterpret_cast<LPARAM>(result.get()))) result.release();
	});
}
void Window::keep() {
	if (applyingPreset.empty()) return;
	try {
		if (!pending.empty()) recovery.keep(pending);
		pending.clear();
		pendingUntil = 0;
		auto id = std::move(applyingPreset);
		applyingPreset.clear();
		auto next = settings;
		for (auto& p : next.presets) if (p.id == id && !p.confirmed) { p.confirmed = true; persist(next); break; }
		gate.consume(deviceIds(hardware), utcMillis());
		build();
	} catch (const std::exception& e) { fail(e.what()); }
}
void Window::revert() {
	if (pending.empty() || !pendingUntil) return;
	try {
		recovery.revert(pending);
		pendingUntil = 0;
		status = "Restoring previous settings.";
		active.clear();
		build();
		SetTimer(hwnd, ID_ATTENTION, 200, nullptr);
	} catch (const std::exception& e) { fail(e.what()); }
}
void Window::tick() {
	if (!pending.empty()) {
		try {
			if (pendingUntil && utcMillis() >= pendingUntil) keep();
			else if (!pendingUntil) if (auto result = recovery.result(pending)) {
				if (!result->empty()) {
					recoveryFailed = true;
					fail("Recovery failed: " + *result);
				} else {
					auto outcome = Json::parse(readText(recovery.resultPath()));
					status = outcome.flag("kept") ? "Verified settings kept" : "Previous settings restored";
					if (fixture && !outcome.flag("kept") && fs::exists(folder / L"fixture-restored.json")) {
						auto restored = Json::parse(readText(folder / L"fixture-restored.json"));
						auto& fake = dynamic_cast<FixtureBackend&>(*backend);
						fake.hardware.displays.clear();
						for (const auto& d : restored.at("displays").array()) fake.hardware.displays.push_back(decodeDisplay(d));
						fake.hardware.audio = {restored.str("defaultOutput"), restored.str("defaultInput")};
					}
				}
				pending.clear();
				applyingPreset.clear();
				refresh();
			}
		} catch (const std::exception& e) { fail(e.what()); }
		InvalidateRect(hwnd, nullptr, FALSE);
	}
	settle();
	if (pending.empty() && (!gate.pending() || !settings.automatic || !error.empty() || page == Page::editor || page == Page::ruleEditor)) KillTimer(hwnd, ID_ATTENTION);
}
void Window::startEditor(const Preset& p) { draft=p; displayIndex=0; tab=0; page=Page::editor; scroll=0; build(); SetFocus(ctl(C_NAME)); }
void Window::updateDisplay() {
	if (page!=Page::editor || tab!=0 || rebuilding || draft.displays.empty()) return; auto& d=draft.displays[displayIndex];
	d.name=narrow(textOf(ctl(321))); auto parse=[&](int id) { auto text=narrow(textOf(ctl(id))); int value=0; auto r=std::from_chars(text.data(),text.data()+text.size(),value); if (r.ec!=std::errc() || r.ptr!=text.data()+text.size()) throw std::runtime_error("Enter an integer display position"); return value; };
	if (IsWindowEnabled(ctl(C_X))) { d.x=parse(C_X); d.y=parse(C_Y); }
}
void Window::saveDraft() {
	bool editedRule = page == Page::ruleEditor;
	if (page==Page::editor) {
		updateDisplay(); draft.name=trim(narrow(textOf(ctl(C_NAME)))); if (draft.receiver.empty()) draft.wirelessDisplay.clear(); validate(draft);
		if (auto issue = arrangementIssue(draft.displays); !issue.empty()) throw std::runtime_error(issue);
		auto next=settings;
		auto previous=std::find_if(next.presets.begin(),next.presets.end(),[&](const auto& p) { return p.id==draft.id; });
		if (previous!=next.presets.end()) { draft.confirmed=previous->confirmed && sameLayout(previous->displays,draft.displays) && previous->receiver==draft.receiver && previous->wirelessDisplay==draft.wirelessDisplay; *previous=draft; }
		else { draft.confirmed=matches(draft.displays,hardware.displays); next.presets.push_back(draft); }
		persist(next); selected=draft.id; page=Page::presets;
	} else {
		draftRule.name=trim(narrow(textOf(ctl(C_NAME)))); auto i=selection(C_RULE_PRESET); if (i>=0 && i<int(settings.presets.size())) draftRule.preset=settings.presets[i].id; draftRule.exact=checked(C_EXACT); draftRule.enabled=checked(C_ENABLED);
		auto next=settings; auto previous=std::find_if(next.rules.begin(),next.rules.end(),[&](const auto& r) { return r.id==draftRule.id; }); if (previous==next.rules.end()) next.rules.push_back(draftRule); else *previous=draftRule; persist(next); page=Page::rules; selectedRule=draftRule.id;
	}
	error.clear(); scroll=0; rememberHardware(false); if (editedRule) gate.reset(); build(); settle();
}
void Window::startRule(const Rule* r) {
	if (settings.presets.empty()) throw std::runtime_error("Capture a preset before adding a connection rule");
	draftRule=r ? *r : Rule{}; if (!r) { draftRule.id=newId(); draftRule.name="New connection rule"; draftRule.preset=selectedPreset() ? selected : settings.presets.front().id; }
	page=Page::ruleEditor; scroll=0; ruleFilter.clear(); selectedCondition.clear(); build(); SetFocus(ctl(C_NAME));
}
void Window::updateRuleDevices() {
	auto list=ctl(C_DEVICES); if (!list) return; ListView_DeleteAllItems(list); ruleDevices.clear(); auto known=settings.known;
	for (const auto* group:{&hardware.devices,&draftRule.required,&draftRule.absent}) for (const auto& d:*group) if (std::none_of(known.begin(),known.end(),[&](const auto& a) { return a.id==d.id; })) known.push_back(d);
	std::sort(known.begin(),known.end(),[](const auto& a,const auto& b) { return std::tie(a.usb,a.name,a.id)<std::tie(b.usb,b.name,b.id); }); auto filter=wide(ruleFilter); std::transform(filter.begin(),filter.end(),filter.begin(),towlower);
	auto ids=deviceIds(hardware);
	int selectedRow = -1, selectedValue = 0;
	for (const auto& d:known) {
		auto search=wide(d.name+" "+d.id); std::transform(search.begin(),search.end(),search.begin(),towlower); if (!filter.empty() && search.find(filter)==search.npos) continue;
		int i=int(ruleDevices.size()); ruleDevices.push_back(d); bool duplicate=std::count_if(known.begin(),known.end(),[&](const auto& a) { return a.name==d.name; })>1; auto name=wide(d.name)+(d.usb ? L"  [USB]" : L"  [Display]")+(duplicate ? L" · "+wide(identityHint(d.id)) : L""); LVITEMW item{}; item.mask=LVIF_TEXT; item.iItem=i; item.pszText=name.data(); ListView_InsertItem(list,&item);
		std::wstring connected=ids.count(d.id) ? L"Connected" : L"Not connected"; ListView_SetItemText(list,i,1,connected.data());
		bool required=std::any_of(draftRule.required.begin(),draftRule.required.end(),[&](const auto& a) { return a.id==d.id; }), absent=std::any_of(draftRule.absent.begin(),draftRule.absent.end(),[&](const auto& a) { return a.id==d.id; });
		if (selectedCondition == d.id) { selectedRow = i; selectedValue = required ? 1 : absent ? 2 : 0; }
		std::wstring condition=required ? L"Must be connected" : absent ? L"Must be absent" : L"Ignore"; ListView_SetItemText(list,i,2,condition.data());
	}
	EnableWindow(ctl(C_CONDITION), selectedRow >= 0);
	SendMessageW(ctl(C_CONDITION), CB_SETCURSEL, selectedValue, 0);
	if (selectedRow >= 0) ListView_SetItemState(list, selectedRow, LVIS_SELECTED | LVIS_FOCUSED, LVIS_SELECTED | LVIS_FOCUSED);
}
void Window::deviceCondition() {
	int i=ListView_GetNextItem(ctl(C_DEVICES),-1,LVNI_SELECTED); if (i<0 || i>=int(ruleDevices.size())) return; auto d=ruleDevices[i]; int condition=selection(C_CONDITION);
	std::erase_if(draftRule.required,[&](const auto& a) { return a.id==d.id; }); std::erase_if(draftRule.absent,[&](const auto& a) { return a.id==d.id; }); if (condition==1) draftRule.required.push_back(d); if (condition==2) draftRule.absent.push_back(d);
	std::wstring value=condition==1 ? L"Must be connected" : condition==2 ? L"Must be absent" : L"Ignore"; ListView_SetItemText(ctl(C_DEVICES),i,2,value.data());
}
void Window::menu(bool trayMenu, const std::string& folderId) {
	HMENU menu = CreatePopupMenu();
	if (!folderId.empty()) {
		AppendMenuW(menu, MF_STRING, C_FOLDER_RENAME, L"Rename folder…");
		AppendMenuW(menu, MF_STRING, C_FOLDER_REMOVE, L"Remove folder…");
	} else if (trayMenu) {
		AppendMenuW(menu, MF_STRING, C_SHOW, L"Open DisplayMind");
		AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
		const auto* current = activePreset();
		for (size_t i = 0; i < settings.presets.size(); ++i) {
			const auto& preset = settings.presets[i];
			AppendMenuW(menu, MF_STRING | (!canApply() || !unavailable(preset, hardware).empty() ? MF_GRAYED : 0) | (&preset == current ? MF_CHECKED : 0), 1000+i, wide(preset.name).c_str());
		}
		AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
		AppendMenuW(menu, MF_STRING | (settings.automatic ? MF_CHECKED : 0) | (locked() || readOnly ? MF_GRAYED : 0), C_AUTOMATIC, L"Automatic switching");
		if (!pending.empty() && pendingUntil) {
			AppendMenuW(menu, MF_STRING, C_KEEP, L"Keep changes");
			AppendMenuW(menu, MF_STRING, C_REVERT, L"Revert changes");
		}
	} else {
		if (auto p = selectedPreset(); p && !readOnly && !locked()) {
			AppendMenuW(menu, MF_STRING, C_RENAME, L"Rename preset…");
			AppendMenuW(menu, MF_STRING, C_DUPLICATE, L"Duplicate preset");
			AppendMenuW(menu, MF_STRING, C_DELETE, L"Delete preset");
			if (!settings.folders.empty()) {
				HMENU folders = CreatePopupMenu();
				AppendMenuW(folders, MF_STRING | (p->folder.empty() ? MF_CHECKED : 0), C_MOVE_PRESET, L"Ungrouped");
				for (size_t i = 0; i < settings.folders.size(); ++i) {
					const auto& group = settings.folders[i];
					AppendMenuW(folders, MF_STRING | (p->folder == group.id ? MF_CHECKED : 0), C_MOVE_PRESET+i+1, wide(group.name).c_str());
				}
				AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(folders), L"Move to folder");
			}
			AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
		}
		AppendMenuW(menu, MF_STRING, C_SYSTEM_DISPLAY, L"Windows display settings");
		AppendMenuW(menu, MF_STRING, C_DIAGNOSTICS, L"Save diagnostics…");
	}
	if (folderId.empty()) {
		if (recoveryFailed) AppendMenuW(menu, MF_STRING, C_RETRY_RECOVERY, L"Retry recovery");
		if (!error.empty()) {
			AppendMenuW(menu, MF_STRING, C_ERROR_DETAILS, L"Error details");
			AppendMenuW(menu, MF_STRING, C_DISMISS, L"Dismiss error");
		}
		if (trayMenu) {
			AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
			AppendMenuW(menu, MF_STRING | (busy ? MF_GRAYED : 0), C_QUIT, L"Quit");
		}
	}
	POINT point{};
	GetCursorPos(&point);
	SetForegroundWindow(hwnd);
	auto choice = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, hwnd, nullptr);
	DestroyMenu(menu);
	if (choice && folderId.empty()) command(int(choice), MenuCommand);
	if (choice && !folderId.empty() && !locked() && !readOnly) {
		auto next = settings;
		auto group = std::find_if(next.folders.begin(), next.folders.end(), [&](const PresetFolder& f) { return f.id == folderId; });
		if (group != next.folders.end()) {
			if (choice == C_FOLDER_RENAME) startNameEdit(NameTarget::folder, group->id, group->name);
			else if (choice == C_FOLDER_REMOVE && MessageBoxW(hwnd, L"Remove this folder and move its presets to Ungrouped?", L"Remove folder", MB_YESNO | MB_ICONQUESTION) == IDYES) {
				for (auto& preset : next.presets) if (preset.folder == folderId) preset.folder.clear();
				next.folders.erase(group);
				persist(std::move(next));
				build();
			}
		}
	}
	PostMessageW(hwnd, WM_NULL, 0, 0);
}
void Window::command(int id, int code) {
	if (rebuilding) return;
	try {
		if (id>=1000 && id<2000) { size_t i=static_cast<size_t>(id-1000); if (i<settings.presets.size()) { selected=settings.presets[i].id; page=Page::presets; apply(settings.presets[i],false); } return; }
		if (id >= C_MOVE_PRESET && id <= C_MOVE_PRESET + int(settings.folders.size())) {
			if (selectedPreset() && !readOnly && !locked()) {
				auto next = settings;
				auto p = std::find_if(next.presets.begin(), next.presets.end(), [&](const Preset& a) { return a.id == selected; });
				p->folder = id == C_MOVE_PRESET ? "" : next.folders[id-C_MOVE_PRESET-1].id;
				for (auto& f : next.folders) if (f.id == p->folder) f.collapsed = false;
				persist(std::move(next)); build();
			}
			return;
		}
		if (id==C_PRESETS && code==LBN_SELCHANGE) {
			auto i = int(SendMessageW(ctl(id), LB_GETCURSEL, 0, 0));
			if (i < 0 || i >= int(sidebarRows.size()) || locked()) return;
			auto row = sidebarRows[i];
			if (row.heading) {
				if (!row.id.empty() && !readOnly) {
					auto next = settings;
					auto f = std::find_if(next.folders.begin(), next.folders.end(), [&](const PresetFolder& group) { return group.id == row.id; });
					if (f != next.folders.end()) { f->collapsed = !f->collapsed; persist(std::move(next)); }
				}
				populateSidebar();
			} else { selected = row.id; page = Page::presets; scroll = 0; build(); }
		}
		else if (id==C_PRESETS && code==LBN_DBLCLK) command(C_RENAME,0);
		else if (id==C_FILTER) { filterOpen = !filterOpen; build(); }
		else if (id==C_FILTER_MODE && code==CBN_SELCHANGE) { matchAll = selection(id) == 0; populateSidebar(); }
		else if (id==C_CLEAR_FILTER) { displayFilter.clear(); build(); }
		else if (id==C_ADD_FOLDER && !readOnly && !locked()) startNameEdit(NameTarget::newFolder, {}, "New folder");
		else if (id==C_INLINE_NAME && code==EN_CHANGE) nameDraft = narrow(textOf(ctl(id)));
		else if (id==C_INLINE_SAVE) saveName();
		else if (id==C_INLINE_CANCEL) { nameTarget = NameTarget::none; build(); }
		else if (id==C_CAPTURE && !locked() && !readOnly && !hardware.displays.empty()) {
			auto p=Preset{}; p.id=newId(); p.name="Preset "+std::to_string(settings.presets.size()+1); p.displays=hardware.displays; p.audio=hardware.audio; p.confirmed=true;
			for (const auto& device:hardware.audioDevices) { if (device.id==p.audio.output) p.outputName=device.name; if (device.id==p.audio.input) p.inputName=device.name; }
			auto cast=std::find_if(p.displays.begin(),p.displays.end(),[](const auto& d) { return d.wireless && d.enabled; }); if (cast!=p.displays.end()) { p.receiver=cast->name; p.wirelessDisplay=cast->id; } startEditor(p);
		}
		else if (id==C_RULES && !locked()) { page=Page::rules; scroll=0; build(); }
		else if (id==C_AUTOMATIC && !locked() && !readOnly) { auto next=settings; next.automatic=code==MenuCommand ? !settings.automatic : checked(C_AUTOMATIC); persist(next); gate.reset(); build(); settle(); }
		else if (id==C_LOGIN) { if (!fixture) setLoginEnabled(checked(C_LOGIN)); }
		else if (id==C_FOLDER) { fs::create_directories(folder); ShellExecuteW(hwnd,L"open",folder.c_str(),nullptr,nullptr,SW_SHOW); }
		else if (id==C_REFRESH) { error.clear(); refresh(); }
		else if (id==C_APPLY && selectedPreset()) apply(*selectedPreset(),false);
		else if (id==C_EDIT && selectedPreset() && !locked()) startEditor(*selectedPreset());
		else if (id==C_MORE) menu();
		else if (id==C_KEEP) keep(); else if (id==C_REVERT) revert();
		else if (id==C_SAVE && (page==Page::editor || page==Page::ruleEditor)) saveDraft();
		else if (id==C_CANCEL) { page=page==Page::editor ? Page::presets : Page::rules; scroll=0; build(); settle(); }
		else if (id==C_RENAME && selectedPreset() && !locked() && !readOnly) { auto p = selectedPreset(); startNameEdit(NameTarget::preset, p->id, p->name); }
		else if (id==C_DUPLICATE && selectedPreset() && !locked()) { auto p=*selectedPreset(); p.id=newId(); p.name+=" copy"; auto next=settings; next.presets.push_back(p); persist(next); selected=p.id; build(); }
		else if (id==C_DELETE && selectedPreset() && !locked()) {
			if (MessageBoxW(hwnd,L"Delete this preset and its connection rules?",L"Delete preset",MB_YESNO | MB_ICONQUESTION)!=IDYES) return; auto next=settings; auto key=selected; std::erase_if(next.presets,[&](const auto& p) { return p.id==key; }); std::erase_if(next.rules,[&](const auto& r) { return r.preset==key; }); persist(next); selected=settings.presets.empty() ? "" : settings.presets.front().id; build();
		}
		else if (id>=C_TAB_DISPLAY && id<=C_TAB_WIRELESS) { updateDisplay(); draft.name=narrow(textOf(ctl(C_NAME))); tab=id-C_TAB_DISPLAY; build(); }
		else if (id==C_DISPLAY && code==CBN_SELCHANGE) { updateDisplay(); draft.name=narrow(textOf(ctl(C_NAME))); displayIndex=selection(C_DISPLAY); build(); }
		else if (id==C_ROTATION && code==CBN_SELCHANGE) { updateDisplay(); draft.name=narrow(textOf(ctl(C_NAME))); auto& d=draft.displays[displayIndex]; int rotation=selection(C_ROTATION)*90; if (rotation%180!=d.rotation%180) std::swap(d.mode.width,d.mode.height); d.rotation=rotation; build(); }
		else if (id==C_MODE && code==CBN_SELCHANGE) { updateDisplay(); auto i=selection(C_MODE); if (i>=0 && i<int(editModes.size())) draft.displays[displayIndex].mode=editModes[i]; InvalidateRect(canvas,nullptr,FALSE); }
		else if (id==C_USE && code==CBN_SELCHANGE) {
			updateDisplay();
			auto& d = draft.displays[displayIndex];
			int i = selection(C_USE);
			if (i < 0 || i >= int(useIds.size()) || d.mirror == useIds[i]) return;
			if (useIds[i].empty()) {
				auto others = draft.displays;
				std::erase_if(others, [&](const Display& other) { return other.id == d.id; });
				d.mirror.clear();
				d = layoutWithExtraDisplays(others, {d}).back();
			} else {
				bool wasMain = d.mirror.empty() && d.x == 0 && d.y == 0;
				d.mirror = useIds[i];
				for (auto& other : draft.displays) if (other.mirror == d.id) other.mirror = d.mirror;
				if (wasMain) makeMain(draft.displays, d.mirror);
			}
			build();
		}
		else if (id==C_MAIN) { updateDisplay(); draft.name=narrow(textOf(ctl(C_NAME))); makeMain(draft.displays,draft.displays[displayIndex].id); build(); }
		else if (id==C_PLACE) {
			updateDisplay(); HMENU menu=CreatePopupMenu(); int n=1; std::vector<std::pair<int,int>> positions; const auto& d=draft.displays[displayIndex];
			for (const auto& a:draft.displays) if (a.id!=d.id && a.enabled && a.mirror.empty()) for (auto [title,pos]:std::vector<std::pair<std::wstring,std::pair<int,int>>>{{L"Right of ",{a.x+a.mode.width,a.y}},{L"Left of ",{a.x-d.mode.width,a.y}},{L"Above ",{a.x,a.y-d.mode.height}},{L"Below ",{a.x,a.y+a.mode.height}}}) { AppendMenuW(menu,MF_STRING,n++,(title+wide(a.name)).c_str()); positions.push_back(pos); }
			POINT point{}; GetCursorPos(&point); int choice=TrackPopupMenu(menu,TPM_RETURNCMD,point.x,point.y,0,hwnd,nullptr); DestroyMenu(menu); if (choice>0 && choice<=int(positions.size())) { draft.displays[displayIndex].x=positions[choice-1].first; draft.displays[displayIndex].y=positions[choice-1].second; draft.name=narrow(textOf(ctl(C_NAME))); build(); }
		}
		else if ((id==C_AUDIO_IN || id==C_AUDIO_OUT) && code==CBN_SELCHANGE) { auto& ids=id==C_AUDIO_IN ? inputIds : outputIds; int i=selection(id); if (i>=0 && i<int(ids.size())) { (id==C_AUDIO_IN ? draft.audio.input : draft.audio.output)=ids[i]; auto& name=id==C_AUDIO_IN ? draft.inputName : draft.outputName; auto device=std::find_if(hardware.audioDevices.begin(),hardware.audioDevices.end(),[&](const auto& a) { return a.id==ids[i]; }); if (device!=hardware.audioDevices.end()) name=device->name; else if (ids[i].empty()) name.clear(); } }
		else if (id==C_NAME && code==EN_CHANGE) { if (page==Page::editor) draft.name=narrow(textOf(ctl(id))); if (page==Page::ruleEditor) draftRule.name=narrow(textOf(ctl(id))); }
		else if (id==321 && code==EN_CHANGE && page==Page::editor && !draft.displays.empty()) draft.displays[displayIndex].name=narrow(textOf(ctl(id)));
		else if ((id==C_X || id==C_Y) && code==EN_CHANGE && page==Page::editor) { auto text=narrow(textOf(ctl(id))); int position=0; auto r=std::from_chars(text.data(),text.data()+text.size(),position); if (r.ec==std::errc() && r.ptr==text.data()+text.size()) { (id==C_X ? draft.displays[displayIndex].x : draft.displays[displayIndex].y)=position; if (canvas) InvalidateRect(canvas,nullptr,FALSE); } }
		else if (id==C_RECEIVER && code==EN_CHANGE) draft.receiver=narrow(textOf(ctl(id)));
		else if (id==C_WIRELESS_DISPLAY && code==CBN_SELCHANGE) {
			int i = selection(id);
			if (i >= 0 && i < int(wirelessIds.size())) {
				draft.wirelessDisplay = wirelessIds[i];
				if (i == 0) draft.receiver.clear();
				else if (auto display = std::find_if(draft.displays.begin(), draft.displays.end(), [&](const Display& d) { return d.id == draft.wirelessDisplay; }); display != draft.displays.end()) draft.receiver = display->name;
				SetWindowTextW(ctl(C_RECEIVER), wide(draft.receiver).c_str());
				EnableWindow(ctl(C_RECEIVER), i > 0);
			}
		}
		else if (id==C_CAST && !fixture) openCastFlyout();
		else if (id==C_NEW_RULE && !locked()) startRule();
		else if ((id==C_RULE_EDIT || id==C_RULE_DELETE || id==C_RULE_UP || id==C_RULE_DOWN) && !locked()) {
			int i=ListView_GetNextItem(ctl(C_RULE_LIST),-1,LVNI_SELECTED); if (i<0 || i>=int(settings.rules.size())) return;
			if (id==C_RULE_EDIT) startRule(&settings.rules[i]);
			else { auto next=settings; int chosen=i; if (id==C_RULE_DELETE) next.rules.erase(next.rules.begin()+i); else { int other=i+(id==C_RULE_UP ? -1 : 1); if (other<0 || other>=int(next.rules.size())) return; std::swap(next.rules[i],next.rules[other]); chosen=other; } persist(next); gate.reset(); build(); if (chosen<int(settings.rules.size())) ListView_SetItemState(ctl(C_RULE_LIST),chosen,LVIS_SELECTED,LVIS_SELECTED); settle(); }
		}
		else if (id==C_SEARCH && code==EN_CHANGE) { ruleFilter=narrow(textOf(ctl(C_SEARCH))); updateRuleDevices(); }
		else if (id==C_RULE_PRESET && code==CBN_SELCHANGE) { auto i=selection(id); if (i>=0 && i<int(settings.presets.size())) draftRule.preset=settings.presets[i].id; }
		else if (id==C_EXACT && code==BN_CLICKED) draftRule.exact=checked(id);
		else if (id==C_ENABLED && code==BN_CLICKED) draftRule.enabled=checked(id);
		else if (id==C_CONDITION && code==CBN_SELCHANGE) deviceCondition();
		else if (id==C_DISMISS) { error.clear(); status=std::to_string(hardware.displays.size())+" displays connected"; build(); }
		else if (id==C_RETRY_RECOVERY && !locked()) {
			auto transaction = recovery.retryFailed(fixture);
			recovery.watch(fixture, executable(), false);
			pending = transaction;
			pendingUntil = 0;
			error.clear(); recoveryFailed = false; status = "Retrying recovery."; build(); SetTimer(hwnd, ID_ATTENTION, 200, nullptr);
		}
		else if (id==C_ERROR_DETAILS && !error.empty()) { if (!testMode) MessageBoxW(hwnd,wide(error+(recoveryFailed ? "\n\nUse Retry recovery from the preset or tray menu to retry the saved snapshot." : "")).c_str(),L"DisplayMind",MB_OK | MB_ICONWARNING); }
		else if (id==C_DIAGNOSTICS) { atomicWrite(folder/L"diagnostics.json",diagnostics(*backend).dump()); status="Read-only diagnostics saved"; ShellExecuteW(hwnd,L"open",(folder/L"diagnostics.json").c_str(),nullptr,nullptr,SW_SHOW); }
		else if (id==C_SYSTEM_DISPLAY) ShellExecuteW(hwnd,L"open",L"ms-settings:display",nullptr,nullptr,SW_SHOW);
		else if (id==C_SYSTEM_SOUND) ShellExecuteW(hwnd,L"open",L"ms-settings:sound",nullptr,nullptr,SW_SHOW);
		else if (id==C_SHOW) show();
		else if (id==C_QUIT && !busy) { quitting=true; DestroyWindow(hwnd); }
	} catch (const std::exception& e) { fail(e.what()); if (!testMode) MessageBoxW(hwnd,wide(e.what()).c_str(),L"DisplayMind",MB_OK | MB_ICONWARNING); }
}
LRESULT CALLBACK Window::canvasProcedure(HWND w, UINT m, WPARAM a, LPARAM b) {
	auto self=reinterpret_cast<Window*>(GetWindowLongPtrW(GetParent(w),GWLP_USERDATA)); if (!self) return DefWindowProcW(w,m,a,b);
	if (m==WM_PAINT) { PAINTSTRUCT ps{}; HDC dc=BeginPaint(w,&ps); self->paintCanvas(dc,w); EndPaint(w,&ps); return 0; }
	if (m==WM_ERASEBKGND) return 1;
	if (self->page==Page::editor && m==WM_LBUTTONDOWN) {
		float x=GET_X_LPARAM(b)/self->dpi,y=GET_Y_LPARAM(b)/self->dpi;
		for (const auto& [i,r]:self->canvasRects) if (r.Contains(x,y)) {
			try { self->updateDisplay(); } catch (const std::exception& e) { self->fail(e.what()); return 0; }
			self->draft.name=narrow(textOf(self->ctl(C_NAME))); self->displayIndex=i; self->tab=0; self->build();
			const auto& d=self->draft.displays[i]; if (d.x || d.y) { self->dragIndex=i; self->dragStart={GET_X_LPARAM(b),GET_Y_LPARAM(b)}; self->dragX=d.x; self->dragY=d.y; SetCapture(self->canvas); } return 0;
		}
	}
	if (m==WM_MOUSEMOVE && self->dragIndex>=0 && (a & MK_LBUTTON)) {
		auto& d=self->draft.displays[self->dragIndex]; d.x=std::clamp(self->dragX+int((GET_X_LPARAM(b)-self->dragStart.x)/(self->dpi*self->canvasScale)),-100000,100000); d.y=std::clamp(self->dragY+int((GET_Y_LPARAM(b)-self->dragStart.y)/(self->dpi*self->canvasScale)),-100000,100000);
		int snap=std::max(1,int(10/self->canvasScale));
		for (const auto& other:self->draft.displays) if (other.id!=d.id && other.enabled && other.mirror.empty()) {
			for (int edge:{other.x,other.x+other.mode.width,other.x-d.mode.width}) if (std::abs(d.x-edge)<snap) d.x=edge;
			for (int edge:{other.y,other.y+other.mode.height,other.y-d.mode.height}) if (std::abs(d.y-edge)<snap) d.y=edge;
		}
		SetWindowTextW(self->ctl(C_X),std::to_wstring(d.x).c_str()); SetWindowTextW(self->ctl(C_Y),std::to_wstring(d.y).c_str()); InvalidateRect(w,nullptr,FALSE); return 0;
	}
	if ((m==WM_LBUTTONUP || m==WM_CAPTURECHANGED) && self->dragIndex>=0) {
		auto& d = self->draft.displays[self->dragIndex];
		if (auto position = snappedPosition(self->draft.displays, d.id, d.x, d.y)) {
			d.x = position->first; d.y = position->second;
		} else { d.x = self->dragX; d.y = self->dragY; }
		self->dragIndex = -1; ReleaseCapture();
		SetWindowTextW(self->ctl(C_X), std::to_wstring(d.x).c_str());
		SetWindowTextW(self->ctl(C_Y), std::to_wstring(d.y).c_str());
		InvalidateRect(w, nullptr, FALSE); return 0;
	}
	return DefWindowProcW(w,m,a,b);
}
LRESULT CALLBACK Window::procedure(HWND w, UINT m, WPARAM a, LPARAM b) {
	auto self=reinterpret_cast<Window*>(GetWindowLongPtrW(w,GWLP_USERDATA));
	if (m==WM_NCCREATE) { self=static_cast<Window*>(reinterpret_cast<CREATESTRUCTW*>(b)->lpCreateParams); self->hwnd=w; SetWindowLongPtrW(w,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self)); }
	if (!self) return DefWindowProcW(w,m,a,b);
	if (!self->fixture && self->taskbarCreated && m == self->taskbarCreated) { self->addTray(); return 0; }
	try {
		switch (m) {
		case WM_CREATE: {
			self->dpi=GetDpiForWindow(w)/96.0f; self->icon=static_cast<HICON>(LoadImageW(self->instance,MAKEINTRESOURCEW(101),IMAGE_ICON,64,64,LR_DEFAULTCOLOR)); if (!self->icon) self->icon=makeIcon(); SendMessageW(w,WM_SETICON,ICON_BIG,reinterpret_cast<LPARAM>(self->icon)); SendMessageW(w,WM_SETICON,ICON_SMALL,reinterpret_cast<LPARAM>(self->icon));
			if (!self->fixture) {
				self->taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
				self->tray.cbSize=sizeof(self->tray); self->tray.hWnd=w; self->tray.uID=1; self->tray.uFlags=NIF_ICON | NIF_MESSAGE | NIF_TIP; self->tray.uCallbackMessage=WM_TRAY; self->tray.hIcon=self->icon; wcscpy_s(self->tray.szTip,L"DisplayMind"); self->addTray();
				DEV_BROADCAST_DEVICEINTERFACE_W filter{}; filter.dbcc_size=sizeof(filter); filter.dbcc_devicetype=DBT_DEVTYP_DEVICEINTERFACE; self->deviceNotify=RegisterDeviceNotificationW(w,&filter,DEVICE_NOTIFY_WINDOW_HANDLE | DEVICE_NOTIFY_ALL_INTERFACE_CLASSES);
				try { self->audioWatcher=std::make_unique<AudioWatcher>(w,WM_HARDWARE); } catch (const std::exception& e) { self->status = e.what(); }
				SetTimer(w,ID_FALLBACK,60000,nullptr);
				try {
					if (auto pending = self->recovery.inFlight()) {
						self->recovery.watch(false, executable(), false);
						self->pending = pending->id;
						SetTimer(w, ID_ATTENTION, 200, nullptr);
					}
				} catch (const std::exception& e) {
					self->recoveryFailed = true;
					self->fail(e.what());
				}
			}
			return 0;
		}
		case WM_SIZE: self->width=int(LOWORD(b)/self->dpi); self->height=int(HIWORD(b)/self->dpi); if (a!=SIZE_MINIMIZED) self->build(); return 0;
		case WM_DPICHANGED: { self->dpi=HIWORD(a)/96.0f; auto r=reinterpret_cast<RECT*>(b); SetWindowPos(w,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER | SWP_NOACTIVATE); return 0; }
		case WM_GETMINMAXINFO: { auto p=reinterpret_cast<MINMAXINFO*>(b); p->ptMinTrackSize={self->px(1000),self->px(650)}; return 0; }
		case WM_ERASEBKGND: return 1;
		case WM_PAINT: { PAINTSTRUCT ps{}; HDC dc=BeginPaint(w,&ps); self->paint(dc); EndPaint(w,&ps); return 0; }
		case WM_COMMAND: self->command(LOWORD(a),HIWORD(a)); return 0;
		case WM_CONTEXTMENU: {
			if (auto list = self->ctl(C_PRESETS); list && reinterpret_cast<HWND>(a) == list) {
				int index = int(SendMessageW(list, LB_GETCURSEL, 0, 0));
				if (b != -1) {
					POINT p{GET_X_LPARAM(b), GET_Y_LPARAM(b)};
					ScreenToClient(list, &p);
					auto row = SendMessageW(list, LB_ITEMFROMPOINT, 0, MAKELPARAM(p.x, p.y));
					if (!HIWORD(row)) index = LOWORD(row);
				}
				if (index >= 0 && index < int(self->sidebarRows.size())) {
					auto row = self->sidebarRows[index];
					if (row.heading) { if (!row.id.empty()) self->menu(false, row.id); }
					else { self->selected = row.id; self->page = Page::presets; self->build(); self->menu(); }
				}
			}
			return 0;
		}
		case WM_CTLCOLOREDIT: case WM_CTLCOLORSTATIC: case WM_CTLCOLORBTN: case WM_CTLCOLORLISTBOX: {
			HDC dc = reinterpret_cast<HDC>(a);
			auto c = self->colors();
			bool sidebar = m == WM_CTLCOLORLISTBOX && reinterpret_cast<HWND>(b) == self->ctl(C_PRESETS);
			bool field = m == WM_CTLCOLOREDIT || m == WM_CTLCOLORLISTBOX;
			SetTextColor(dc, c.text);
			SetBkColor(dc, sidebar ? c.side : field ? c.card : c.bg);
			return reinterpret_cast<LRESULT>(sidebar ? self->sideBrush : field ? self->cardBrush : self->bgBrush);
		}
		case WM_DRAWITEM: {
			auto item=reinterpret_cast<DRAWITEMSTRUCT*>(b); Graphics g(item->hDC); g.SetSmoothingMode(SmoothingModeAntiAlias); auto c=self->colors(); RectF r(float(item->rcItem.left),float(item->rcItem.top),float(item->rcItem.right-item->rcItem.left-1),float(item->rcItem.bottom-item->rcItem.top-1));
			if (item->CtlType==ODT_COMBOBOX) {
				SolidBrush brush(color((item->itemState & ODS_SELECTED) ? c.selection : c.card)); g.FillRectangle(&brush,r);
				std::wstring text;
				if (item->itemID!=UINT(-1)) { int length=int(SendMessageW(item->hwndItem,CB_GETLBTEXTLEN,item->itemID,0)); if (length>=0) { text.resize(size_t(length)+1); SendMessageW(item->hwndItem,CB_GETLBTEXT,item->itemID,reinterpret_cast<LPARAM>(text.data())); text.resize(length); } }
				drawText(g,text,RectF(r.X+8*self->dpi,r.Y+3*self->dpi,r.Width-16*self->dpi,r.Height-4*self->dpi),14*self->dpi,c.text); return TRUE;
			} else if (item->CtlID==C_PRESETS) {
				if (item->itemID >= self->sidebarRows.size()) return TRUE;
				const auto& row = self->sidebarRows[item->itemID];
				SolidBrush bg(color(c.side)); g.FillRectangle(&bg, r);
				if (row.heading) {
					auto f = std::find_if(self->settings.folders.begin(), self->settings.folders.end(), [&](const PresetFolder& a) { return a.id == row.id; });
					auto name = f == self->settings.folders.end() ? L"Ungrouped" : (f->collapsed ? L"▸  " : L"▾  ") + wide(f->name);
					drawText(g, name, RectF(r.X+6*self->dpi,r.Y+5*self->dpi,r.Width-12*self->dpi,23*self->dpi), 13*self->dpi, c.text, true);
					return TRUE;
				}
				auto p = std::find_if(self->settings.presets.begin(), self->settings.presets.end(), [&](const Preset& a) { return a.id == row.id; });
				if (p == self->settings.presets.end()) return TRUE;
				if (item->itemState & ODS_SELECTED) rounded(g,RectF(r.X+2,r.Y+2,r.Width-4,r.Height-4),c.selection,c.selection,8*self->dpi);
				bool active = &*p == self->activePreset();
				drawThumbnail(g,*p,RectF(r.X+8*self->dpi,r.Y+10*self->dpi,44*self->dpi,34*self->dpi),c);
				drawText(g,wide(p->name),RectF(r.X+60*self->dpi,r.Y+7*self->dpi,r.Width-65*self->dpi,24*self->dpi),14*self->dpi,c.text,true);
				drawText(g,std::to_wstring(p->displays.size())+(p->displays.size()==1 ? L" display" : L" displays")+(active ? L" · Active" : L""),RectF(r.X+60*self->dpi,r.Y+30*self->dpi,r.Width-65*self->dpi,20*self->dpi),12*self->dpi,active ? c.accent : c.secondary);
			} else {
				bool pressed=(item->itemState & ODS_SELECTED)!=0 || (item->CtlID>=C_TAB_DISPLAY && item->CtlID<=C_TAB_WIRELESS && self->tab==int(item->CtlID)-C_TAB_DISPLAY), disabled=(item->itemState & ODS_DISABLED)!=0; rounded(g,r,pressed ? c.selection : c.button,c.border,7*self->dpi); drawText(g,textOf(item->hwndItem),r,14*self->dpi,disabled ? c.secondary : c.text,false,true);
				if (item->itemState & ODS_FOCUS) DrawFocusRect(item->hDC,&item->rcItem);
			} return TRUE;
		}
		case WM_MEASUREITEM: {
			auto item = reinterpret_cast<MEASUREITEMSTRUCT*>(b);
			bool heading = item->CtlID == C_PRESETS && item->itemID < self->sidebarRows.size() && self->sidebarRows[item->itemID].heading;
			item->itemHeight = self->px(item->CtlType == ODT_COMBOBOX ? 26 : heading ? 31 : 54);
			return TRUE;
		}
		case WM_NOTIFY: {
			auto n=reinterpret_cast<NMHDR*>(b); if (self->rebuilding) break;
			if (n->idFrom == C_FILTER_DISPLAYS && n->code == LVN_ITEMCHANGED) {
				auto change = reinterpret_cast<NMLISTVIEW*>(b);
				if ((change->uChanged & LVIF_STATE) && ((change->uOldState ^ change->uNewState) & LVIS_STATEIMAGEMASK) && change->iItem >= 0 && change->iItem < int(self->filterDevices.size())) {
					const auto& id = self->filterDevices[change->iItem].id;
					if (ListView_GetCheckState(n->hwndFrom, change->iItem)) self->displayFilter.insert(id);
					else self->displayFilter.erase(id);
					self->populateSidebar();
				}
			}
			if (n->idFrom==C_TABS && n->code==TCN_SELCHANGE) { self->updateDisplay(); self->draft.name=narrow(textOf(self->ctl(C_NAME))); self->tab=TabCtrl_GetCurSel(self->ctl(C_TABS)); self->build(); }
			if (n->idFrom==C_RULE_LIST && n->code==NM_DBLCLK) self->command(C_RULE_EDIT,0);
			if (n->idFrom==C_RULE_LIST && n->code==LVN_ITEMCHANGED) {
				auto change = reinterpret_cast<NMLISTVIEW*>(b);
				if ((change->uChanged & LVIF_STATE) && change->iItem >= 0 && change->iItem < int(self->settings.rules.size())) {
					if (change->uNewState & LVIS_SELECTED) self->selectedRule = self->settings.rules[change->iItem].id;
					if (((change->uOldState ^ change->uNewState) & LVIS_STATEIMAGEMASK) && !self->readOnly && !self->locked()) {
						auto next = self->settings;
						next.rules[change->iItem].enabled = ListView_GetCheckState(self->ctl(C_RULE_LIST), change->iItem) != 0;
						self->persist(next); self->gate.reset(); self->settle();
					}
				}
			}
			if (n->idFrom==C_DEVICES && n->code==LVN_ITEMCHANGED) {
				int i=ListView_GetNextItem(self->ctl(C_DEVICES),-1,LVNI_SELECTED); if (i>=0 && i<int(self->ruleDevices.size())) { const auto& d=self->ruleDevices[i]; self->selectedCondition=d.id; int condition=std::any_of(self->draftRule.required.begin(),self->draftRule.required.end(),[&](const auto& a) { return a.id==d.id; }) ? 1 : std::any_of(self->draftRule.absent.begin(),self->draftRule.absent.end(),[&](const auto& a) { return a.id==d.id; }) ? 2 : 0; EnableWindow(self->ctl(C_CONDITION), TRUE); SendMessageW(self->ctl(C_CONDITION),CB_SETCURSEL,condition,0); }
			}
			break;
		}
		case WM_VSCROLL: case WM_MOUSEWHEEL: {
			int old=self->scroll; if (m==WM_MOUSEWHEEL) self->scroll-=GET_WHEEL_DELTA_WPARAM(a)/WHEEL_DELTA*60; else { switch (LOWORD(a)) { case SB_LINEUP: self->scroll-=30; break; case SB_LINEDOWN: self->scroll+=30; break; case SB_PAGEUP: self->scroll-=self->height; break; case SB_PAGEDOWN: self->scroll+=self->height; break; case SB_THUMBTRACK: { SCROLLINFO si{sizeof(si),SIF_TRACKPOS}; GetScrollInfo(w,SB_VERT,&si); self->scroll=si.nTrackPos; break; } } }
			self->scroll=std::clamp(self->scroll,0,std::max(0,self->totalHeight-self->height)); if (old!=self->scroll) { ScrollWindowEx(w,0,self->px(old-self->scroll),nullptr,nullptr,nullptr,nullptr,SW_SCROLLCHILDREN | SW_INVALIDATE | SW_ERASE); SetScrollPos(w,SB_VERT,self->scroll,TRUE); } return 0;
		}
		case WM_HARDWARE: case WM_DEVICECHANGE: case WM_DISPLAYCHANGE: if (!self->fixture) SetTimer(w,ID_DEBOUNCE,180,nullptr); return TRUE;
		case WM_POWERBROADCAST: if (!self->fixture && (a==PBT_APMRESUMEAUTOMATIC || a==PBT_APMRESUMESUSPEND)) { self->gate.reset(); SetTimer(w,ID_DEBOUNCE,180,nullptr); } return TRUE;
		case WM_TIMER: if (a==ID_DEBOUNCE) { KillTimer(w,ID_DEBOUNCE); self->refresh(); } else if (a==ID_FALLBACK) self->refresh(); else if (a==ID_ATTENTION) self->tick(); return 0;
		case WM_WORK: self->finish(reinterpret_cast<WorkResult*>(b)); return 0;
		case WM_SETTINGCHANGE: if (!self->forceTheme) { self->dark=systemDark(); self->build(); } return 0;
		case WM_TRAY: if (b==WM_LBUTTONUP || b==WM_LBUTTONDBLCLK) self->show(); else if (b==WM_RBUTTONUP) self->menu(true); return 0;
		case WM_CLOSE: if (self->fixture) DestroyWindow(w); else ShowWindow(w,self->trayReady ? SW_HIDE : SW_MINIMIZE); return 0;
		case WM_DESTROY: self->quitting=true; if (!self->fixture) Shell_NotifyIconW(NIM_DELETE,&self->tray); PostQuitMessage(0); return 0;
		}
	} catch (const std::exception& e) { self->fail(e.what()); }
	return DefWindowProcW(w,m,a,b);
}
static void saveWindow(HWND window, const fs::path& file) {
	RECT r{}; GetClientRect(window,&r); HDC dc=GetDC(window), memory=CreateCompatibleDC(dc); HBITMAP bitmap=CreateCompatibleBitmap(dc,r.right,r.bottom); auto old=SelectObject(memory,bitmap);
	if (!PrintWindow(window,memory,PW_CLIENTONLY)) { SelectObject(memory,old); DeleteObject(bitmap); DeleteDC(memory); ReleaseDC(window,dc); throw std::runtime_error("Preview render failed"); }
	Bitmap image(bitmap,nullptr); CLSID encoder{}; UINT size=0,count=0; GetImageEncodersSize(&count,&size); std::vector<BYTE> data(size); auto codecs=reinterpret_cast<ImageCodecInfo*>(data.data()); GetImageEncoders(count,size,codecs);
	for (UINT i=0;i<count;++i) if (std::wstring(codecs[i].MimeType)==L"image/png") encoder=codecs[i].Clsid;
	fs::create_directories(file.parent_path()); auto result=image.Save(file.c_str(),&encoder,nullptr); SelectObject(memory,old); DeleteObject(bitmap); DeleteDC(memory); ReleaseDC(window,dc); if (result!=Ok) throw std::runtime_error("Cannot save preview PNG");
}
#include "ui_tests.inl"
int runApp(HINSTANCE instance, const std::vector<std::wstring>& args) {
	auto has=[&](const std::wstring& key) { return std::find(args.begin(),args.end(),key)!=args.end(); };
	auto value=[&](const std::wstring& key)->std::wstring { auto i=std::find(args.begin(),args.end(),key); return i!=args.end() && ++i!=args.end() ? *i : L""; };
	if (has(L"--watchdog")) {
		auto folder = value(L"--watchdog");
		if (folder.empty()) throw std::runtime_error("Pass a data folder to --watchdog");
		return runWatchdog(folder, has(L"--fixture"));
	}
	bool preview=has(L"--preview") || has(L"--render-preview") || has(L"--ui-self-test"); fs::path folder=value(L"--data-dir"); if (folder.empty()) folder=preview ? fs::temp_directory_path()/L"DisplayMind-fixture-preview"/wide(newId()) : dataFolder();
	if (has(L"--diagnostics")) { WindowsBackend backend; auto file=value(L"--diagnostics"); if (file.empty()) throw std::runtime_error("Pass a JSON output path to --diagnostics"); atomicWrite(file,diagnostics(backend).dump()+"\n"); return 0; }
	const auto lockName = recoveryLockName(folder);
	const auto windowClass = preview ? std::wstring(L"DisplayMind.Preview") : L"DisplayMind.Window." + lockName.substr(lockName.rfind(L'.') + 1);
	bool background = has(L"--background");
	std::unique_ptr<void, decltype(&CloseHandle)> singleton(nullptr, CloseHandle);
	if (!preview) {
		singleton.reset(CreateMutexW(nullptr, FALSE, (lockName + L".App").c_str()));
		if (!singleton) throw std::runtime_error("Cannot open application lock");
		auto lock = WaitForSingleObject(singleton.get(), 0);
		if (lock == WAIT_TIMEOUT) {
			if (background) return 0;
			auto until = GetTickCount64() + 2000;
			do {
				if (auto existing = FindWindowW(windowClass.c_str(), nullptr)) {
					DWORD pid = 0;
					GetWindowThreadProcessId(existing, &pid);
					AllowSetForegroundWindow(pid);
					PostMessageW(existing, WM_COMMAND, C_SHOW, 0);
					return 0;
				}
				std::this_thread::sleep_for(std::chrono::milliseconds(50));
			} while (GetTickCount64() < until);
			throw std::runtime_error("Another DisplayMind window is starting or running on a different desktop.");
		}
		if (lock != WAIT_OBJECT_0 && lock != WAIT_ABANDONED) throw std::runtime_error("Cannot acquire application lock");
	}
	Window app(instance,folder,preview,has(L"--dark") || (!has(L"--light") && systemDark()),has(L"--dark") || has(L"--light")); app.load();
	if (has(L"--empty") && preview) { app.settings={}; app.selected.clear(); }
	if (has(L"--long") && preview) { for (auto& p:app.settings.presets) p.name="A very long saved workspace name with several displays and a USB dock"; }
	if (has(L"--many") && preview && !app.settings.presets.empty()) { for (int i=0;i<12;++i) { auto p=app.settings.presets[0]; p.id="fixture:many"+std::to_string(i); p.name="Workspace "+std::to_string(i+1); app.settings.presets.push_back(p); } }
	if (has(L"--folders") && preview && app.settings.presets.size() >= 2) {
		app.settings.folders = {{"fixture:work", "Work", false}, {"fixture:travel", "Travel", true}};
		app.settings.presets[0].folder = "fixture:work";
		app.settings.presets[1].folder = "fixture:travel";
		app.filterOpen = has(L"--filter");
	}
	if (has(L"--unavailable") && preview && !app.hardware.displays.empty()) { app.hardware.displays.pop_back(); }
	if (has(L"--pending") && preview) { app.pending="fixture:preview"; app.pendingUntil=utcMillis()+10000; }
	if (has(L"--rules")) app.page=Page::rules;
	if (has(L"--editor") && !app.settings.presets.empty()) {
		app.page = Page::editor; app.draft = app.settings.presets.front(); app.displayIndex = 1;
		if (has(L"--sound")) app.tab = 1;
		if (has(L"--wireless")) {
			app.tab = 2;
			if (preview) {
				auto& receiver = app.draft.displays[1];
				receiver.wireless = true; receiver.name = "Living room TV";
				app.draft.receiver = receiver.name; app.draft.wirelessDisplay = receiver.id;
			}
		}
	}
	if (has(L"--rule-editor") && !app.settings.rules.empty()) { app.page=Page::ruleEditor; app.draftRule=app.settings.rules.front(); }
	WNDCLASSEXW wc{sizeof(wc)}; wc.lpfnWndProc=Window::procedure; wc.hInstance=instance; wc.hCursor=LoadCursorW(nullptr,IDC_ARROW); wc.lpszClassName=windowClass.c_str(); if (!RegisterClassExW(&wc) && GetLastError()!=ERROR_CLASS_ALREADY_EXISTS) throw std::runtime_error("Cannot register native window");
	wc.lpfnWndProc=Window::canvasProcedure; wc.lpszClassName=L"DisplayMind.Canvas"; RegisterClassExW(&wc);
	UINT dpi=GetDpiForSystem(); int width=MulDiv(1180,int(dpi),96),height=MulDiv(850,int(dpi),96);
	HWND window=CreateWindowExW(WS_EX_CONTROLPARENT,windowClass.c_str(),preview ? L"DisplayMind · Preview" : L"DisplayMind",WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN | WS_VSCROLL,CW_USEDEFAULT,CW_USEDEFAULT,width,height,nullptr,nullptr,instance,&app); if (!window) throw std::runtime_error("Cannot create DisplayMind window");
	if ((!background || !app.trayReady) && !has(L"--render-preview") && !has(L"--ui-self-test")) ShowWindow(window,SW_SHOW); app.build();
	if (has(L"--ui-self-test")) { SetWindowPos(window,nullptr,-30000,-30000,width,height,SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW); app.build(); auto result=uiSelfTest(app,value(L"--ui-self-test")); DestroyWindow(window); return result; }
	if (has(L"--render-preview")) { SetWindowPos(window,nullptr,-30000,-30000,width,height,SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW); UpdateWindow(window); for (auto c:app.controls) UpdateWindow(c); saveWindow(window,value(L"--render-preview")); DestroyWindow(window); return 0; }
	if (!preview) { app.gate.reset(); SetTimer(window,ID_ATTENTION,250,nullptr); }
	MSG msg{};
	while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
		if (msg.message == WM_KEYDOWN) {
			auto focus = GetFocus();
			if (focus && focus == app.ctl(C_INLINE_NAME) && (msg.wParam == VK_RETURN || msg.wParam == VK_ESCAPE)) {
				app.command(msg.wParam == VK_RETURN ? C_INLINE_SAVE : C_INLINE_CANCEL, 0);
				continue;
			}
			if (focus && focus == app.ctl(C_PRESETS)) {
				if (msg.wParam == VK_F2) { app.command(C_RENAME, 0); continue; }
				if (msg.wParam == VK_UP || msg.wParam == VK_DOWN) {
					auto index = int(SendMessageW(focus, LB_GETCURSEL, 0, 0));
					int step = msg.wParam == VK_UP ? -1 : 1;
					for (int i = index+step; i >= 0 && i < int(app.sidebarRows.size()); i += step) if (!app.sidebarRows[i].heading) {
						SendMessageW(focus, LB_SETCURSEL, i, 0);
						app.command(C_PRESETS, LBN_SELCHANGE);
						break;
					}
					continue;
				}
			}
			if (app.page == Page::editor || app.page == Page::ruleEditor) {
				if (msg.wParam == VK_ESCAPE) {
					if (SendMessageW(focus, CB_GETDROPPEDSTATE, 0, 0)) SendMessageW(focus, CB_SHOWDROPDOWN, FALSE, 0);
					else app.command(C_CANCEL, 0);
					continue;
				}
				if (msg.wParam == 'S' && (GetKeyState(VK_CONTROL)&0x8000)) { app.command(C_SAVE, 0); continue; }
			}
		}
		if (!IsDialogMessageW(window, &msg)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
	}
	if (singleton) ReleaseMutex(singleton.get());
	return int(msg.wParam);
}
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,LPWSTR,int) {
	SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2); HRESULT com=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
	GdiplusStartupInput input; ULONG_PTR token=0; GdiplusStartup(&token,&input,nullptr); INITCOMMONCONTROLSEX controls{sizeof(controls),ICC_STANDARD_CLASSES | ICC_LISTVIEW_CLASSES | ICC_TAB_CLASSES}; InitCommonControlsEx(&controls);
	int count=0; auto argv=CommandLineToArgvW(GetCommandLineW(),&count); std::vector<std::wstring> args; for (int i=1;i<count;++i) args.emplace_back(argv[i]); LocalFree(argv); int result=0;
	try { result=dm::runApp(instance,args); } catch (const std::exception& e) { MessageBoxW(nullptr,dm::wide(e.what()).c_str(),L"DisplayMind",MB_OK | MB_ICONERROR); result=1; }
	GdiplusShutdown(token); if (SUCCEEDED(com)) CoUninitialize(); return result;
}
