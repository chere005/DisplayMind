// Runs only in --ui-self-test, with FixtureBackend, isolated data, and no tray,
// device watchers, login changes, wireless control or live display/audio writes.
static int uiSelfTest(Window& app,const fs::path& report) {
	Json::Array results; int failed=0;
	auto expect=[](bool condition,const std::string& why) { if (!condition) throw std::runtime_error(why); };
	auto test=[&](const std::string& name,const std::function<void()>& action) {
		try { action(); if (!app.error.empty()) throw std::runtime_error(app.error); results.push_back(Json::Object{{"name",name},{"passed",true}}); }
		catch (const std::exception& e) { ++failed; results.push_back(Json::Object{{"name",name},{"passed",false},{"error",e.what()}}); app.error.clear(); }
	};
	auto pump=[&](const std::function<bool()>& done,int ms=6000) {
		auto until=GetTickCount64()+ms;
		while (GetTickCount64()<until) {
			MSG message{}; while (PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
			if (done()) return; std::this_thread::sleep_for(std::chrono::milliseconds(10));
		} throw std::runtime_error("Native UI did not finish before its deadline");
	};
	app.testMode=true;
	test("native sidebar exposes all saved presets",[&] {
		expect(SendMessageW(app.ctl(C_PRESETS),LB_GETCOUNT,0,0)==3,"Missing sidebar presets");
	});
	test("native capture editor saves unchanged layout as confirmed",[&] {
		app.command(C_CAPTURE,0); expect(app.page==Page::editor,"Capture did not open editor"); SetWindowTextW(app.ctl(C_NAME),L"Captured fixture layout"); app.command(C_SAVE,0);
		expect(app.settings.presets.size()==4 && app.selectedPreset()->confirmed,"Capture did not preserve confirmation");
	});
	test("native rotation control invalidates automatic eligibility",[&] {
		app.command(C_EDIT,0); SendMessageW(app.ctl(C_DISPLAY),CB_SETCURSEL,1,0); app.command(C_DISPLAY,CBN_SELCHANGE); SendMessageW(app.ctl(C_ROTATION),CB_SETCURSEL,3,0); app.command(C_ROTATION,CBN_SELCHANGE); app.command(C_SAVE,0);
		expect(!app.selectedPreset()->confirmed && app.selectedPreset()->displays[1].rotation==270,"Changed layout was not saved correctly");
	});
	test("native Sound page retains selection through tabs",[&] {
		app.command(C_EDIT,0); app.command(C_TAB_SOUND,0); SendMessageW(app.ctl(C_AUDIO_OUT),CB_SETCURSEL,0,0); app.command(C_AUDIO_OUT,CBN_SELCHANGE); app.command(C_TAB_WIRELESS,0); app.command(C_TAB_SOUND,0);
		expect(app.selection(C_AUDIO_OUT)==0,"Sound selection was lost"); app.command(C_SAVE,0); expect(app.selectedPreset()->audio.output.empty(),"Do not change output was not saved");
	});
	test("native Make main translates every display",[&] {
		app.command(C_EDIT,0); SendMessageW(app.ctl(C_DISPLAY),CB_SETCURSEL,1,0); app.command(C_DISPLAY,CBN_SELCHANGE); app.command(C_MAIN,0); validate(app.draft.displays);
		expect(app.draft.displays[1].x==0 && app.draft.displays[0].x==-2560,"Primary translation failed"); app.command(C_CANCEL,0);
	});
	test("native preset duplicate keeps a distinct identity",[&] {
		auto before=app.selected; app.command(C_DUPLICATE,0); expect(app.settings.presets.size()==5 && app.selected!=before,"Duplicate reused original identity");
	});
	test("native rule editor saves explicit device condition",[&] {
		app.command(C_RULES,0); app.command(C_NEW_RULE,0); SetWindowTextW(app.ctl(C_NAME),L"Fixture dock rule"); auto i=std::find_if(app.ruleDevices.begin(),app.ruleDevices.end(),[](const auto& d) { return d.usb; });
		expect(i!=app.ruleDevices.end(),"No fixture USB device"); int row=int(i-app.ruleDevices.begin()); ListView_SetItemState(app.ctl(C_DEVICES),row,LVIS_SELECTED,LVIS_SELECTED); SendMessageW(app.ctl(C_CONDITION),CB_SETCURSEL,1,0); app.command(C_CONDITION,CBN_SELCHANGE); app.command(C_SAVE,0);
		expect(app.settings.rules.size()==2 && app.settings.rules.back().required.size()==1,"Rule condition was lost");
	});
	test("native rule priority reorder changes evaluation order",[&] {
		auto id=app.settings.rules[1].id; ListView_SetItemState(app.ctl(C_RULE_LIST),1,LVIS_SELECTED,LVIS_SELECTED); app.command(C_RULE_UP,0); expect(app.settings.rules[0].id==id,"Move up did not reorder rule");
	});
	test("native rule checkbox toggles enabled state",[&] {
		ListView_SetCheckState(app.ctl(C_RULE_LIST),0,FALSE); expect(!app.settings.rules[0].enabled,"Rule checkbox was not persisted");
	});
	test("native search keeps remembered offline conditions",[&] {
		auto offline=Device{"usb:fixture-offline","Offline fixture dock",true}; auto next=app.settings; next.known.push_back(offline); app.persist(next); app.startRule(&app.settings.rules[0]); SetWindowTextW(app.ctl(C_SEARCH),L"Offline fixture");
		expect(app.ruleDevices.size()==1 && app.ruleDevices[0].id==offline.id,"Offline devices are missing from the editor"); app.command(C_CANCEL,0);
	});
	test("native automatic toggle persists paused state",[&] {
		auto old=app.settings.automatic; SendMessageW(app.ctl(C_AUTOMATIC),BM_CLICK,0,0); expect(app.settings.automatic!=old,"Automatic switching toggle did not persist");
	});
	test("native tray automation toggles even while the sidebar exists", [&] {
		auto old = app.settings.automatic;
		app.command(C_AUTOMATIC, MenuCommand);
		expect(app.settings.automatic != old && app.checked(C_AUTOMATIC) == app.settings.automatic, "Tray and sidebar automation controls did not stay in sync");
	});
	test("native Apply verifies before offering Revert",[&] {
		app.page=Page::presets; app.selected=app.settings.presets[3].id; app.build(); app.command(C_APPLY,0); pump([&]{return !app.busy;});
		expect(!app.pending.empty() && app.recovery.pending()->state=="verified" && IsWindow(app.ctl(C_REVERT)),"Revert was not offered after verification");
	});
	test("native Revert restores fixture layout through watchdog",[&] {
		app.command(C_REVERT,0); pump([&]{return app.pending.empty() && !app.busy;}); expect(matches(demoHardware().displays,app.hardware.displays),"Independent rollback did not restore fixture state");
	});
	test("native Keep confirms edited preset for rules",[&] {
		app.command(C_APPLY,0); pump([&]{return !app.busy;}); app.command(C_KEEP,0); expect(app.pending.empty() && app.selectedPreset()->confirmed,"Keep did not confirm preset");
	});
	test("native no-op Apply leaves no recovery journal",[&] {
		app.command(C_APPLY,0); pump([&]{return !app.busy;}); expect(app.pending.empty() && !app.recovery.pending(),"Unchanged layout opened a recovery journal");
	});
	test("native settle timer runs an eligible rule after 3 seconds",[&] {
		app.settings=demoSettings(); app.settings.presets[0].displays[1].rotation=90; app.settings.automatic=true; app.fixtureAutomation=true; app.gate.reset(); app.page=Page::presets; app.build(); app.settle();
		pump([&]{return !app.busy && app.active==app.settings.presets[0].id;},7000);
		expect(app.pending.empty() && !app.recovery.pending(), "Automatic rule opened a manual revert window");
		app.fixtureAutomation=false;
	});
	test("native editor keeps name and position through rebuilding",[&] {
		app.selected=app.settings.presets[0].id; app.startEditor(app.settings.presets[0]); SetWindowTextW(app.ctl(C_NAME),L"Name survives rebuilding"); SendMessageW(app.ctl(C_DISPLAY),CB_SETCURSEL,1,0); app.command(C_DISPLAY,CBN_SELCHANGE); SetWindowTextW(app.ctl(C_X),L"2800"); app.build();
		expect(textOf(app.ctl(C_NAME))==L"Name survives rebuilding" && textOf(app.ctl(C_X))==L"2800","Draft values were lost when controls rebuilt"); app.command(C_CANCEL,0);
	});
	test("native folders retain the selected preset and its rules after inline rename", [&] {
		app.command(C_ADD_FOLDER, 0);
		SetWindowTextW(app.ctl(C_INLINE_NAME), L"Workspaces");
		app.command(C_INLINE_SAVE, 0);
		auto preset = app.selected;
		auto rules = app.settings.rules;
		app.command(C_MOVE_PRESET + 1, MenuCommand);
		expect(app.selectedPreset()->folder == app.settings.folders.front().id, "Folder move lost the preset");
		SendMessageW(app.ctl(C_PRESETS), LB_SETCURSEL, 0, 0);
		app.command(C_PRESETS, LBN_SELCHANGE);
		expect(app.settings.folders.front().collapsed && app.selected == preset, "Collapsing the folder changed the active selection");
		app.command(C_RENAME, MenuCommand);
		SetWindowTextW(app.ctl(C_INLINE_NAME), L"Desk setup");
		app.command(C_INLINE_SAVE, 0);
		expect(!app.settings.folders.front().collapsed && app.selectedPreset()->name == "Desk setup" && app.settings.rules == rules, "Rename did not reveal the unchanged preset identity");
	});
	test("native display filter supports all and any without rebuilding its controls", [&] {
		app.command(C_FILTER, 0);
		auto filters = app.ctl(C_FILTER_DISPLAYS);
		for (size_t i = 0; i < app.filterDevices.size(); ++i) if (app.filterDevices[i].id != "fixture:portrait") ListView_SetCheckState(filters, int(i), TRUE);
		auto visible = [&] { return std::count_if(app.sidebarRows.begin(), app.sidebarRows.end(), [](const SidebarRow& row) { return !row.heading; }); };
		expect(app.displayFilter.size() == 2 && visible() == 2, "All selected displayed the wrong presets");
		SendMessageW(app.ctl(C_FILTER_MODE), CB_SETCURSEL, 1, 0);
		app.command(C_FILTER_MODE, CBN_SELCHANGE);
		expect(app.ctl(C_FILTER_DISPLAYS) == filters && visible() == 3, "Any selected lost the controls or displayed the wrong presets");
	});
	test("native editor refuses overlap without losing the draft or saved preset", [&] {
		app.settings = demoSettings(); app.selected = app.settings.presets[0].id; app.startEditor(app.settings.presets[0]);
		auto original = app.settings.presets[0];
		SendMessageW(app.ctl(C_DISPLAY), CB_SETCURSEL, 1, 0); app.command(C_DISPLAY, CBN_SELCHANGE);
		SetWindowTextW(app.ctl(C_X), L"2200"); app.command(C_SAVE, 0);
		expect(app.page == Page::editor && app.settings.presets[0] == original && app.error.find("overlap") != std::string::npos, "Invalid arrangement replaced the saved preset");
		app.error.clear(); app.command(C_CANCEL, 0);
	});
	test("native editor refuses separated displays and retains exact coordinates", [&] {
		app.startEditor(app.settings.presets[0]); SendMessageW(app.ctl(C_DISPLAY), CB_SETCURSEL, 1, 0); app.command(C_DISPLAY, CBN_SELCHANGE);
		SetWindowTextW(app.ctl(C_X), L"9000"); app.command(C_SAVE, 0);
		expect(app.page == Page::editor && app.draft.displays[1].x == 9000 && app.error.find("separated") != std::string::npos, "Separated arrangement was saved");
		app.error.clear(); app.command(C_CANCEL, 0);
	});
	test("native drag release snaps to a valid adjacent position", [&] {
		app.startEditor(app.settings.presets[0]); app.displayIndex = 1; app.build();
		app.dragIndex = 1; app.dragX = 2560; app.dragY = 0; app.draft.displays[1].x = 2200;
		SendMessageW(app.canvas, WM_LBUTTONUP, 0, 0);
		expect(app.draft.displays[1].x == 2560 && arrangementIssue(app.draft.displays).empty(), "Drag release left an overlap");
		app.command(C_CANCEL, 0);
	});
	test("native unsaved preset follows repeated dock changes while preserving edits", [&] {
		app.settings = demoSettings(); app.hardware = demoHardware();
		app.hardware.displays[0].monitor = {123, 456, "", "Studio Display"}; app.rememberHardware(true);
		app.startEditor(app.settings.presets[0]); SetWindowTextW(app.ctl(C_NAME), L"Unsaved desk name");
		app.draft.audio.output.clear(); app.draft.displays[0].mode.numerator = 75;
		for (const auto& id : {"fixture:dock-two", "fixture:dock-three"}) {
			auto next = app.hardware; auto old = next.displays[0].id;
			next.displays[0].id = id; next.devices[0].id = std::string("display:") + id;
			next.modes[id] = next.modes[old]; next.modes.erase(old);
			dynamic_cast<FixtureBackend&>(*app.backend).hardware = next;
			app.refresh(); pump([&] { return !app.busy; });
			expect(app.draft.displays[0].id == id && app.settings.presets[1].displays[1].mirror == id, "Draft or mirror retained the previous dock path");
		}
		expect(app.draft.name == "Unsaved desk name" && app.draft.audio.output.empty() && app.draft.displays[0].mode.numerator == 75, "Reconnection overwrote unsaved changes");
		app.command(C_CANCEL, 0);
	});
	test("native rule draft and selected condition follow a dock change", [&] {
		app.settings = demoSettings(); app.hardware = demoHardware();
		app.hardware.displays[0].monitor = {123, 456, "text:A", "Studio Display"}; app.rememberHardware(true);
		app.startRule(&app.settings.rules[0]);
		app.draftRule.absent.push_back({"display:fixture:studio", "Studio Display"});
		app.selectedCondition = "display:fixture:studio";
		app.hardware.displays[0].id = "fixture:dock-next"; app.hardware.devices[0].id = "display:fixture:dock-next";
		app.rememberHardware(true); app.updateRuleDevices();
		expect(app.draftRule.absent.back().id == "display:fixture:dock-next" && app.selectedCondition == "display:fixture:dock-next", "Unsaved rule retained its disconnected identity");
		app.command(C_CANCEL, 0);
	});
	atomicWrite(report,Json(Json::Object{{"passed",int(results.size())-failed},{"failed",failed},{"results",results},{"fixtureBackendsOnly",true},{"liveDisplayWrites",0}}).dump()+"\n"); return failed ? 1 : 0;
}
