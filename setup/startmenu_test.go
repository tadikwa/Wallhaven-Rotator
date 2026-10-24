//go:build windows

package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode/utf16"
	"unsafe"
)

func shortcutFixture(t *testing.T) (string, string) {
	t.Helper()
	root, err := os.MkdirTemp(os.Getenv("TEMP"), "sm-")
	if err != nil {
		t.Fatal(err)
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	t.Setenv("APPDATA", filepath.Join(root, "Roaming"))
	t.Setenv("LOCALAPPDATA", filepath.Join(root, "Élève espace"))
	dir := appPath()
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"Wallhaven-Rotator-Launcher.vbs", "Wallhaven-Rotator.ico"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("fixture"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	return dir, filepath.Join(root, "Roaming", "Microsoft", "Windows", "Start Menu", "Programs", "Wallhaven Rotator.lnk")
}

// Independent WSH reader/writer: validates the native COM implementation's file format.
func shortcutWSH(t *testing.T, path, script string, extra ...string) []byte {
	t.Helper()
	code := `$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); $ErrorActionPreference='Stop'; $shell=New-Object -ComObject WScript.Shell; $link=$shell.CreateShortcut($env:LINK_FIXTURE); ` + script
	u := utf16.Encode([]rune(code))
	b := make([]byte, len(u)*2)
	for i, v := range u {
		binary.LittleEndian.PutUint16(b[2*i:], v)
	}
	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", base64.StdEncoding.EncodeToString(b))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	cmd.Env = append(os.Environ(), append([]string{"LINK_FIXTURE=" + path}, extra...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("WSH fixture: %v\n%s", err, out)
	}
	return out
}

func assertStartMenuLink(t *testing.T, path, dir string) {
	t.Helper()
	out := shortcutWSH(t, path, `@{Target=$link.TargetPath;Arguments=$link.Arguments;Icon=$link.IconLocation;Work=$link.WorkingDirectory;Description=$link.Description}|ConvertTo-Json -Compress`)
	var link map[string]string
	if err := json.Unmarshal(out, &link); err != nil {
		t.Fatalf("shortcut properties: %v: %s", err, out)
	}
	wscript := filepath.Join(os.Getenv("WINDIR"), "System32", "wscript.exe")
	wantArgs := `//B //Nologo "` + filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs") + `" show`
	if !strings.EqualFold(link["Target"], wscript) || link["Arguments"] != wantArgs ||
		!strings.EqualFold(link["Icon"], filepath.Join(dir, "Wallhaven-Rotator.ico")+",0") ||
		!strings.EqualFold(link["Work"], dir) || link["Description"] != "Wallhaven Rotator" {
		native, nativeErr := readShellLink(path)
		t.Fatalf("incorrect shortcut properties: %+v; native=%+v err=%v", link, native, nativeErr)
	}
}

func TestStartMenuShortcutCreationRepairAndUnicode(t *testing.T) {
	dir, path := shortcutFixture(t)
	for i := 0; i < 2; i++ {
		if err := ensureStartMenuShortcut(dir); err != nil {
			t.Fatal(err)
		}
		assertStartMenuLink(t, path, dir)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("reinstallation left duplicates or temporary files: %v", entries)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := ensureStartMenuShortcut(dir); err != nil {
		t.Fatal(err)
	}
	assertStartMenuLink(t, path, dir)
}

func TestStartMenuManualLauncherShortcutIsAdopted(t *testing.T) {
	dir, path := shortcutFixture(t)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	shortcutWSH(t, path, `$link.TargetPath=$env:LAUNCHER_FIXTURE; $link.Save()`, "LAUNCHER_FIXTURE="+filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs"))
	if err := ensureStartMenuShortcut(dir); err != nil {
		info, readErr := readShellLink(path)
		t.Fatalf("%v; expected=%s existing=%+v read=%v", err, dir, info, readErr)
	}
	assertStartMenuLink(t, path, dir)
}

func TestStartMenuManualShortcutWithShortProfilePath(t *testing.T) {
	for _, mode := range []string{"manual", "repaired", "wscript-short-arguments"} {
		t.Run(mode, func(t *testing.T) {
			// Hosted runners expose TEMP through the RUNNER~1 alias; the Shell expands it.
			t.Setenv("TEMP", filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Local", "Temp"))
			dir, path := shortcutFixture(t)
			buf := make([]uint16, 32768)
			n, _, _ := kernel32.NewProc("GetShortPathNameW").Call(uintptr(unsafe.Pointer(utf16Ptr(dir))), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
			if n == 0 || n >= uintptr(len(buf)) {
				t.Fatal("GetShortPathNameW failed")
			}
			shortDir := syscall.UTF16ToString(buf)
			if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
				t.Fatal(err)
			}
			if mode == "wscript-short-arguments" {
				shortcutWSH(t, path, `$link.TargetPath=$env:HOST_FIXTURE; $link.Arguments='//B //Nologo "'+$env:LAUNCHER_FIXTURE+'" show'; $link.Save()`, "HOST_FIXTURE="+windowsScriptHost(), "LAUNCHER_FIXTURE="+filepath.Join(shortDir, "Wallhaven-Rotator-Launcher.vbs"))
			} else {
				shortcutWSH(t, path, `$link.TargetPath=$env:LAUNCHER_FIXTURE; $link.Save()`, "LAUNCHER_FIXTURE="+filepath.Join(shortDir, "Wallhaven-Rotator-Launcher.vbs"))
			}
			info, err := readShellLink(path)
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("expected=%s short=%s stored=%s", dir, shortDir, info.Target)
			if _, err := existingStartMenuShortcut(path, shortDir); err != nil {
				t.Fatal(err)
			}
			if mode == "repaired" {
				if err := ensureStartMenuShortcut(shortDir); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("LOCALAPPDATA", filepath.Dir(shortDir))
			oldRunning, oldDelete := isRunning, deleteRunValue
			t.Cleanup(func() { isRunning, deleteRunValue = oldRunning, oldDelete })
			isRunning = func() bool { return false }
			deleteRunValue = func() error { return nil }
			if err := uninstall(); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatal("owned shortcut not removed after alias target disappeared")
			}
		})
	}
}

func TestStartMenuForeignShortcutIsNeverOverwrittenOrDeleted(t *testing.T) {
	dir, path := shortcutFixture(t)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	shortcutWSH(t, path, `$link.TargetPath=$env:FOREIGN_FIXTURE; $link.Description='Wallhaven Rotator'; $link.Save()`, "FOREIGN_FIXTURE="+filepath.Join(os.Getenv("WINDIR"), "System32", "notepad.exe"))
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := ensureStartMenuShortcut(dir); err == nil {
		t.Fatal("foreign shortcut silently replaced")
	}
	snapshot, err := startMenuShortcutForRemoval(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := removeStartMenuShortcut(snapshot); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("foreign shortcut was modified")
	}
}

func TestInstallerAndSilentUpdateManageOnlyTheirShortcut(t *testing.T) {
	dir, path := shortcutFixture(t)
	oldRunning, oldSet, oldDelete, oldLaunch := isRunning, setRunValue, deleteRunValue, launchInstalledApp
	t.Cleanup(func() {
		isRunning, setRunValue, deleteRunValue, launchInstalledApp = oldRunning, oldSet, oldDelete, oldLaunch
	})
	isRunning = func() bool { return false }
	var runCommand, launchMode string
	setRunValue = func(command string) error { runCommand = command; return nil }
	deleteRunValue = func() error { runCommand = ""; return nil }
	launchInstalledApp = func(_ string, mode string) error { launchMode = mode; return nil }
	settings := []byte(`{"sort":"Aléatoire","category":"Toutes","query":"+nature","contentFilter":"Strict","value":7,"unit":"Minutes","autoRotation":false,"resolutionMode":"Personnalisé","resolutionMatch":"Exacte","customWidth":5120,"customHeight":1440,"customRatio":"32:9","checkUpdates":true,"autoUpdate":false,"lastNotifiedUpdate":"","unknown":"keep"}`)
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), settings, 0644); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"history.json", "metadata-cache.json", "search-cache.json", "cache/user.jpg"} {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("keep existing user data"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	shared := filepath.Join(os.Getenv("LOCALAPPDATA"), "WallhavenShared", "history.json")
	if err := os.MkdirAll(filepath.Dir(shared), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(shared, []byte("shared history untouched"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := installWithLaunch("show", true); err != nil {
		t.Fatal(err)
	}
	assertStartMenuLink(t, path, dir)
	wantRun := `"` + filepath.Join(os.Getenv("WINDIR"), "System32", "wscript.exe") + `" //B //Nologo "` + filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs") + `" autostart`
	if launchMode != "show" || runCommand != wantRun {
		t.Fatalf("autostart/show regression: %q %q", launchMode, runCommand)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := silentUpdate(false); err != nil {
		t.Fatal(err)
	}
	assertStartMenuLink(t, path, dir)
	if launchMode != "autostart" || runCommand != "" {
		t.Fatal("OTA changed startup semantics")
	}
	if err := installWithLaunch("", false); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"history.json", "metadata-cache.json", "search-cache.json", "cache/user.jpg"} {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil || string(b) != "keep existing user data" {
			t.Fatalf("existing data changed: %s: %v", name, err)
		}
	}
	b, err := os.ReadFile(filepath.Join(dir, "settings.json"))
	if err != nil || string(b) != string(settings) {
		t.Fatal("settings were reset")
	}
	other := filepath.Join(filepath.Dir(path), "Other app.lnk")
	if err := os.WriteFile(other, []byte("foreign shortcut"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := uninstall(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("owned shortcut survived uninstall")
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatal("fixture app directory survived uninstall")
	}
	if b, err := os.ReadFile(other); err != nil || string(b) != "foreign shortcut" {
		t.Fatal("uninstall removed another shortcut")
	}
	if b, err := os.ReadFile(shared); err != nil || string(b) != "shared history untouched" {
		t.Fatal("uninstall removed shared history")
	}
}

func TestStartMenuWideUnicodeIsStoredLosslessly(t *testing.T) {
	dir, path := shortcutFixture(t)
	dir = filepath.Join(dir, "中文 🖼")
	for i := 0; i < 2; i++ {
		if err := ensureStartMenuShortcut(dir); err != nil {
			t.Fatal(err)
		}
	}
	info, err := readShellLink(path)
	if err != nil {
		t.Fatal(err)
	}
	want := `//B //Nologo "` + filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs") + `" show`
	if info.Arguments != want || info.Work != dir || info.Icon != filepath.Join(dir, "Wallhaven-Rotator.ico") {
		t.Fatalf("Unicode lost: %+v", info)
	}
	// WSH exposes ANSI strings; verify the actual UTF-16 payload beyond its code page.
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	units := utf16.Encode([]rune(want))
	encoded := make([]byte, len(units)*2)
	for i, u := range units {
		binary.LittleEndian.PutUint16(encoded[i*2:], u)
	}
	if !bytes.Contains(data, encoded) {
		t.Fatal("UTF-16 arguments absent from persisted link")
	}
}

func TestStartMenuRejectsUnknownAndForeignScriptLinks(t *testing.T) {
	for _, kind := range []string{"corrupt", "directory", "foreign-script"} {
		t.Run(kind, func(t *testing.T) {
			dir, path := shortcutFixture(t)
			if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
				t.Fatal(err)
			}
			switch kind {
			case "corrupt":
				if err := os.WriteFile(path, []byte("not a link"), 0644); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Mkdir(path, 0755); err != nil {
					t.Fatal(err)
				}
			case "foreign-script":
				shortcutWSH(t, path, `$link.TargetPath=$env:HOST_FIXTURE; $link.Arguments='//B "C:\foreign.vbs" "'+$env:LAUNCHER_FIXTURE+'"'; $link.Save()`, "HOST_FIXTURE="+windowsScriptHost(), "LAUNCHER_FIXTURE="+filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs"))
			}
			before, _ := os.ReadFile(path)
			if err := ensureStartMenuShortcut(dir); err == nil {
				t.Fatal("unknown shortcut replaced")
			}
			snapshot, err := startMenuShortcutForRemoval(dir)
			if err == nil {
				_ = removeStartMenuShortcut(snapshot)
			}
			if _, err := os.Stat(path); err != nil {
				t.Fatal("unknown shortcut removed", err)
			}
			after, _ := os.ReadFile(path)
			if !bytes.Equal(before, after) {
				t.Fatal("unknown shortcut modified")
			}
		})
	}
}

func TestStartMenuRepairsStaleManualWscriptLink(t *testing.T) {
	dir, path := shortcutFixture(t)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	shortcutWSH(t, path, `$link.TargetPath=$env:HOST_FIXTURE; $link.Arguments='//B //Nologo "'+$env:LAUNCHER_FIXTURE+'" autostart'; $link.Save()`, "HOST_FIXTURE="+windowsScriptHost(), "LAUNCHER_FIXTURE="+filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs"))
	if err := ensureStartMenuShortcut(dir); err != nil {
		t.Fatal(err)
	}
	assertStartMenuLink(t, path, dir)
}

func TestStartMenuLockedReplacementAndFailedUninstallPreserveLink(t *testing.T) {
	dir, path := shortcutFixture(t)
	if err := ensureStartMenuShortcut(dir); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	h, err := syscall.CreateFile(utf16Ptr(path), syscall.GENERIC_READ, syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE, nil, syscall.OPEN_EXISTING, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := ensureStartMenuShortcut(dir); err == nil {
		syscall.CloseHandle(h)
		t.Fatal("locked shortcut was replaced")
	}
	syscall.CloseHandle(h)
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("failed replacement lost original link", err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(entries) != 1 {
		t.Fatal("temporary shortcut leaked", err)
	}
	h, err = syscall.CreateFile(utf16Ptr(filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs")), syscall.GENERIC_READ, syscall.FILE_SHARE_READ, nil, syscall.OPEN_EXISTING, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.CloseHandle(h)
	oldRunning, oldDelete := isRunning, deleteRunValue
	t.Cleanup(func() { isRunning, deleteRunValue = oldRunning, oldDelete })
	isRunning = func() bool { return false }
	deleteRunValue = func() error { return nil }
	if err := uninstall(); err == nil {
		t.Fatal("locked app uninstall succeeded")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("failed uninstall removed shortcut", err)
	}
}

func TestInstallerForeignShortcutConflictHasNoInstallationSideEffects(t *testing.T) {
	dir, path := shortcutFixture(t)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	shortcutWSH(t, path, `$link.TargetPath=$env:FOREIGN_FIXTURE; $link.Save()`, "FOREIGN_FIXTURE="+filepath.Join(os.Getenv("WINDIR"), "System32", "notepad.exe"))
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	oldRunning, oldSet, oldDelete, oldLaunch := isRunning, setRunValue, deleteRunValue, launchInstalledApp
	t.Cleanup(func() {
		isRunning, setRunValue, deleteRunValue, launchInstalledApp = oldRunning, oldSet, oldDelete, oldLaunch
	})
	isRunning = func() bool { return false }
	setRunValue = func(string) error { t.Fatal("registry written before shortcut preflight"); return nil }
	deleteRunValue = func() error { t.Fatal("registry deleted before shortcut preflight"); return nil }
	launchInstalledApp = func(string, string) error { t.Fatal("app launched on shortcut conflict"); return nil }
	if err := installWithLaunch("show", true); err == nil {
		t.Fatal("foreign conflict was not reported")
	}
	b, err := os.ReadFile(filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs"))
	if err != nil || string(b) != "fixture" {
		t.Fatal("payload overwritten before conflict was reported")
	}
	// A successful uninstall must also leave this same-name foreign shortcut alone.
	deleteRunValue = func() error { return nil }
	if err := uninstall(); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("uninstall changed foreign shortcut")
	}
}

func TestUninstallPreservesShortcutChangedAfterOwnershipCheck(t *testing.T) {
	dir, path := shortcutFixture(t)
	if err := ensureStartMenuShortcut(dir); err != nil {
		t.Fatal(err)
	}
	snapshot, err := startMenuShortcutForRemoval(dir)
	if err != nil {
		t.Fatal(err)
	}
	shortcutWSH(t, path, `$link.TargetPath=$env:FOREIGN_FIXTURE; $link.Save()`, "FOREIGN_FIXTURE="+filepath.Join(os.Getenv("WINDIR"), "System32", "notepad.exe"))
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := removeStartMenuShortcut(snapshot); err == nil {
		t.Fatal("changed shortcut was deleted without error")
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("foreign replacement was deleted")
	}
}

func TestStartMenuLaunchesOfficialVBSAndRestoresOneIsolatedWPFInstance(t *testing.T) {
	_, path := shortcutFixture(t)
	cmd := exec.Command("powershell.exe", "-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "../tests/Start-IsolatedDesktop.ps1", "-PrepareOnly")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("prepare isolated runtime: %v\n%s", err, out)
	}
	var fixture struct{ Path, Mutex string }
	if err = json.Unmarshal(out, &fixture); err != nil {
		t.Fatalf("fixture JSON: %v %s", err, out)
	}
	if fixture.Path == "" || !strings.Contains(fixture.Path, "desktop-preview-") {
		t.Fatal("unsafe fixture path")
	}
	// The staged runtime has unique mutexes, hardcoded isolated data paths and no network/wallpaper writes.
	t.Cleanup(func() { _ = os.WriteFile(filepath.Join(fixture.Path, "exit.fixture"), nil, 0644) })
	if err := ensureStartMenuShortcut(fixture.Path); err != nil {
		t.Fatal(err)
	}
	launch := func() {
		t.Helper()
		// WSH provides the Shell caller's STA lifetime, unlike a transient Go thread.
		shortcutWSH(t, path, `$result=$shell.Run(('"'+$env:LINK_FIXTURE+'"'),1,$false); Start-Sleep -Seconds 2`)
	}
	type probe struct {
		PID                         int
		Visible, Taskbar, Autostart bool
	}
	waitProbe := func(visible bool) probe {
		t.Helper()
		deadline := time.Now().Add(35 * time.Second)
		for time.Now().Before(deadline) {
			b, _ := os.ReadFile(filepath.Join(fixture.Path, "ui-probe.json"))
			var p probe
			if json.Unmarshal(b, &p) == nil && p.PID > 0 && p.Visible == visible && p.Taskbar == visible && !p.Autostart {
				return p
			}
			time.Sleep(100 * time.Millisecond)
		}
		t.Fatalf("WPF visibility %v not observed (fixture %s)", visible, fixture.Path)
		return probe{}
	}
	launch()
	first := waitProbe(true)
	// Close the actual HWND, then reopen through the same .lnk / VBS activation path.
	var hwnd uintptr
	callback := syscall.NewCallback(func(h, _ uintptr) uintptr {
		var pid uint32
		user32.NewProc("GetWindowThreadProcessId").Call(h, uintptr(unsafe.Pointer(&pid)))
		visible, _, _ := user32.NewProc("IsWindowVisible").Call(h)
		if int(pid) == first.PID && visible != 0 {
			hwnd = h
			return 0
		}
		return 1
	})
	user32.NewProc("EnumWindows").Call(callback, 0)
	if hwnd == 0 {
		t.Fatal("isolated WPF HWND not found")
	}
	user32.NewProc("PostMessageW").Call(hwnd, 0x10, 0, 0)
	if p := waitProbe(false); p.PID != first.PID {
		t.Fatal("close killed tray instance")
	}
	launch()
	second := waitProbe(true)
	if second.PID != first.PID {
		t.Fatal("shortcut created a second persistent instance")
	}
	if err := os.WriteFile(filepath.Join(fixture.Path, "exit.fixture"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		h, err := syscall.OpenProcess(syscall.SYNCHRONIZE, false, uint32(first.PID))
		if err != nil {
			return
		}
		status, _ := syscall.WaitForSingleObject(h, 100)
		syscall.CloseHandle(h)
		if status == syscall.WAIT_OBJECT_0 {
			return
		}
	}
	t.Fatal("isolated tray failed to exit")
}
