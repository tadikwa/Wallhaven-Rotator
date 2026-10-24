//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// Subprocess harness: actual HWND, payload, COM link and WSH; no real Run key or app data.
func TestSetupGUIProcess(t *testing.T) {
	if os.Getenv("WALLHAVEN_SETUP_GUI_CHILD") != "1" {
		return
	}
	root := os.Getenv("WALLHAVEN_SETUP_GUI_ROOT")
	if root == "" || !strings.Contains(root, "sm-") {
		t.Fatal("missing isolated root")
	}
	isRunning = func() bool { return false }
	setRunValue = func(s string) error { return os.WriteFile(filepath.Join(root, "run.txt"), []byte(s), 0644) }
	deleteRunValue = func() error { return os.WriteFile(filepath.Join(root, "run.txt"), nil, 0644) }
	nativeLaunch := launchInstalledApp
	probe := filepath.Join(root, "probe")
	if err := os.MkdirAll(probe, 0755); err != nil {
		t.Fatal(err)
	}
	vbs, err := payloadFS.ReadFile("payload/Wallhaven-Rotator-Launcher.vbs")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(probe, "Wallhaven-Rotator-Launcher.vbs"), vbs, 0644); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(probe, "Wallhaven-Wallpaper-Tray.ps1"), []byte(`param([switch]$Autostart)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'started.txt'),'started')`), 0644); err != nil {
		t.Fatal(err)
	}
	launchInstalledApp = func(_ string, mode string) error { return nativeLaunch(probe, mode) }
	originalPhase := setupPhase
	injected := false
	setupPhase = func(name string, action func() error) error {
		return originalPhase(name, func() error {
			if name == os.Getenv("WALLHAVEN_SETUP_ERROR_PHASE") && !injected {
				injected = true
				return shellHRESULT("injected COM error", uintptr(0x80004005))
			}
			if name == os.Getenv("WALLHAVEN_SETUP_DELAY_PHASE") {
				_ = os.WriteFile(filepath.Join(root, "delaying.txt"), []byte(name), 0644)
				time.Sleep(1500 * time.Millisecond)
			}
			if name == "shortcut.com.save" {
				var apartment, qualifier int32
				hr, _, _ := syscall.NewLazyDLL("ole32.dll").NewProc("CoGetApartmentType").Call(uintptr(unsafe.Pointer(&apartment)), uintptr(unsafe.Pointer(&qualifier)))
				if err := shellHRESULT("CoGetApartmentType", hr); err != nil {
					return err
				}
				if apartment != 0 && apartment != 3 {
					return fmt.Errorf("worker is not STA: %d", apartment)
				}
			}
			return action()
		})
	}
	messageBox = func(text, title string, flags uintptr) {
		thread, _, _ := kernel32.NewProc("GetCurrentThreadId").Call()
		b, _ := json.Marshal(map[string]any{"text": text, "flags": flags, "thread": thread})
		_ = atomicWrite(filepath.Join(root, "message.json"), b)
	}
	if os.Getenv("WALLHAVEN_SETUP_BAD_LAUNCH") == "1" {
		if err := os.WriteFile(filepath.Join(probe, "Wallhaven-Rotator-Launcher.vbs"), []byte("WScript.Quit 7"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if err := runGUI(); err != nil {
		t.Fatal(err)
	}
}

type setupWindowSearch struct {
	pid  uint32
	hwnd uintptr
}

var setupWindowCallback = syscall.NewCallback(func(h, param uintptr) uintptr {
	search := (*setupWindowSearch)(unsafe.Pointer(param))
	var p uint32
	user32.NewProc("GetWindowThreadProcessId").Call(h, uintptr(unsafe.Pointer(&p)))
	if p == search.pid {
		buf := make([]uint16, 128)
		user32.NewProc("GetClassNameW").Call(h, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
		if syscall.UTF16ToString(buf) == "WallhavenRotatorSetupWindowModern" {
			search.hwnd = h
			return 0
		}
	}
	return 1
})

func setupWindow(pid int) uintptr {
	search := setupWindowSearch{pid: uint32(pid)}
	user32.NewProc("EnumWindows").Call(setupWindowCallback, uintptr(unsafe.Pointer(&search)))
	return search.hwnd
}

func TestSetupRealGUIInstallAndReinstallRemainResponsive(t *testing.T) {
	var metrics []map[string]any
	defer func() {
		if err := os.MkdirAll("../dist", 0755); err != nil {
			t.Error(err)
			return
		}
		b, err := json.MarshalIndent(metrics, "", "  ")
		if err != nil {
			t.Error(err)
			return
		}
		if err = os.WriteFile("../dist/setup-ui-metrics.json", b, 0644); err != nil {
			t.Error(err)
		}
	}()
	for _, delay := range []string{"", "shortcut.com.save", "launch.wsh", "payload.remove"} {
		t.Run("phase="+delay, func(t *testing.T) {
			p := startSetupFixture(t, "WALLHAVEN_SETUP_DELAY_PHASE="+delay)
			dir, root, hwnd, cmd := p.dir, p.root, p.hwnd, p.cmd
			for rotation := 0; rotation < 3; rotation++ {
				_ = os.Remove(filepath.Join(root, "message.json"))
				_ = os.Remove(filepath.Join(root, "delaying.txt"))
				_ = os.Remove(filepath.Join(root, "probe", "started.txt"))
				started := time.Now()
				command := uintptr(ID_INSTALL)
				if rotation == 2 {
					command = ID_UNINSTALL
				}
				user32.NewProc("PostMessageW").Call(hwnd, WM_COMMAND, command, 0)
				heartbeats, misses := 0, 0
				var maxResponse time.Duration
				deadline := time.Now().Add(20 * time.Second)
				for time.Now().Before(deadline) {
					if _, e := os.Stat(filepath.Join(root, "message.json")); e == nil {
						break
					}
					var result uintptr
					responseStarted := time.Now()
					ok, _, _ := user32.NewProc("SendMessageTimeoutW").Call(hwnd, 0, 0, 0, 2, 250, uintptr(unsafe.Pointer(&result)))
					if elapsed := time.Since(responseStarted); elapsed > maxResponse {
						maxResponse = elapsed
					}
					if ok == 0 {
						misses++
					} else {
						heartbeats++
					}
					time.Sleep(20 * time.Millisecond)
				}
				b, e := os.ReadFile(filepath.Join(root, "message.json"))
				if e != nil {
					logs, _ := os.ReadFile(filepath.Join(os.TempDir(), fmt.Sprintf("WallhavenRotator-Setup-%d.log", cmd.Process.Pid)))
					t.Fatalf("setup incomplete: %v\n%s", e, logs)
				}
				t.Logf("install=%d delay=%s elapsed_ms=%d heartbeat=%d missed=%d result=%s", rotation, delay, time.Since(started).Milliseconds(), heartbeats, misses, b)
				metrics = append(metrics, map[string]any{"operationIndex": rotation, "delayPhase": delay, "elapsedMs": time.Since(started).Milliseconds(), "uiResponses": heartbeats, "missedResponses": misses, "maxResponseMs": float64(maxResponse) / float64(time.Millisecond)})
				if misses > 0 {
					t.Errorf("UI blocked during real installation: %d missed WM_NULL responses", misses)
				}
				var message struct {
					Flags  uintptr
					Thread uint32
				}
				_ = json.Unmarshal(b, &message)
				if message.Flags&MB_ICONERROR != 0 {
					t.Fatal(string(b))
				}
				owner, _, _ := user32.NewProc("GetWindowThreadProcessId").Call(hwnd, 0)
				if uintptr(message.Thread) != owner {
					t.Fatal("completion notification is not on UI thread")
				}
				if rotation < 2 {
					_ = waitSetupFile(t, p, filepath.Join("probe", "started.txt"))
					if _, e = os.Stat(filepath.Join(dir, "install.json")); e != nil {
						t.Fatal("missing completed install marker", e)
					}
				} else if _, e = os.Stat(dir); !os.IsNotExist(e) {
					t.Fatal("uninstall left app directory", e)
				}
			}
			logs, _ := os.ReadFile(filepath.Join(os.TempDir(), fmt.Sprintf("WallhavenRotator-Setup-%d.log", cmd.Process.Pid)))
			owner, _, _ := user32.NewProc("GetWindowThreadProcessId").Call(hwnd, 0)
			if strings.Contains(string(logs), fmt.Sprintf("event=begin thread=%d", owner)) {
				t.Fatal("installation phase ran on UI thread")
			}
			t.Logf("phase timings:\n%s", logs)
			user32.NewProc("PostMessageW").Call(hwnd, WM_CLOSE, 0, 0)
			select {
			case <-p.done:
				if p.err != nil {
					t.Fatal(p.err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal(fmt.Errorf("setup did not close"))
			}
		})
	}
}

type setupFixtureProcess struct {
	dir, root string
	hwnd      uintptr
	cmd       *exec.Cmd
	done      chan struct{}
	err       error
}

func startSetupFixture(t *testing.T, extra ...string) *setupFixtureProcess {
	t.Helper()
	dir, _ := shortcutFixture(t)
	p := &setupFixtureProcess{dir: dir, root: filepath.Dir(os.Getenv("APPDATA")), done: make(chan struct{})}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	p.cmd = exec.Command(exe, "-test.run=^TestSetupGUIProcess$", "-test.v")
	p.cmd.Env = append(os.Environ(), append([]string{"WALLHAVEN_SETUP_GUI_CHILD=1", "WALLHAVEN_SETUP_GUI_ROOT=" + p.root}, extra...)...)
	p.cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err = p.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() { p.err = p.cmd.Wait(); close(p.done) }()
	t.Cleanup(func() {
		_ = p.cmd.Process.Kill()
		select {
		case <-p.done:
		case <-time.After(3 * time.Second):
		}
	})
	deadline := time.Now().Add(10 * time.Second)
	for p.hwnd == 0 && time.Now().Before(deadline) {
		p.hwnd = setupWindow(p.cmd.Process.Pid)
		time.Sleep(20 * time.Millisecond)
	}
	if p.hwnd == 0 {
		t.Fatal("setup HWND missing")
	}
	return p
}

func waitSetupFile(t *testing.T, p *setupFixtureProcess, name string) []byte {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(filepath.Join(p.root, name)); err == nil {
			return b
		}
		var result uintptr
		ok, _, _ := user32.NewProc("SendMessageTimeoutW").Call(p.hwnd, 0, 0, 0, 2, 250, uintptr(unsafe.Pointer(&result)))
		if ok == 0 {
			t.Fatal("setup UI stopped responding")
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("missing setup fixture file %s", name)
	return nil
}

func TestSetupDefersCloseAndIgnoresDuplicateCommands(t *testing.T) {
	p := startSetupFixture(t, "WALLHAVEN_SETUP_DELAY_PHASE=shortcut.com.save")
	user32.NewProc("PostMessageW").Call(p.hwnd, WM_COMMAND, ID_INSTALL, 0)
	_ = waitSetupFile(t, p, "delaying.txt")
	for _, command := range []uintptr{ID_INSTALL, ID_INSTALL, ID_UNINSTALL, ID_CLOSE} {
		user32.NewProc("PostMessageW").Call(p.hwnd, WM_COMMAND, command, 0)
	}
	var result uintptr
	if ok, _, _ := user32.NewProc("SendMessageTimeoutW").Call(p.hwnd, 0, 0, 0, 2, 250, uintptr(unsafe.Pointer(&result))); ok == 0 {
		t.Fatal("close blocked UI")
	}
	select {
	case <-p.done:
		t.Fatal("setup exited before operation cleanup")
	case <-time.After(100 * time.Millisecond):
	}
	select {
	case <-p.done:
		if p.err != nil {
			t.Fatal(p.err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("deferred close never completed")
	}
	log, _ := os.ReadFile(filepath.Join(os.TempDir(), fmt.Sprintf("WallhavenRotator-Setup-%d.log", p.cmd.Process.Pid)))
	if strings.Count(string(log), "operation=install event=end") != 1 || strings.Contains(string(log), "operation=uninstall") {
		t.Fatal("duplicate/reentrant operation", string(log))
	}
	if _, err := os.Stat(filepath.Join(p.dir, "install.json")); err != nil {
		t.Fatal("closed before marker", err)
	}
	if _, err := os.Stat(filepath.Join(p.root, "message.json")); !os.IsNotExist(err) {
		t.Fatal("success dialog prevented requested close")
	}
}

func TestSetupReportsCOMAndLaunchErrorsOnUIThread(t *testing.T) {
	for _, mode := range []string{"COM", "launch"} {
		t.Run(mode, func(t *testing.T) {
			extra := "WALLHAVEN_SETUP_ERROR_PHASE=shortcut.com.save"
			if mode == "launch" {
				extra = "WALLHAVEN_SETUP_BAD_LAUNCH=1"
			}
			p := startSetupFixture(t, extra)
			user32.NewProc("PostMessageW").Call(p.hwnd, WM_COMMAND, ID_INSTALL, 0)
			b := waitSetupFile(t, p, "message.json")
			var message struct {
				Flags  uintptr
				Thread uint32
			}
			if err := json.Unmarshal(b, &message); err != nil {
				t.Fatal(err)
			}
			var pid uint32
			owner, _, _ := user32.NewProc("GetWindowThreadProcessId").Call(p.hwnd, uintptr(unsafe.Pointer(&pid)))
			if message.Flags&MB_ICONERROR == 0 || uintptr(message.Thread) != owner {
				t.Fatal("false success or notification off UI thread", string(b))
			}
			if mode == "COM" {
				if _, err := os.Stat(filepath.Join(p.dir, "install.json")); !os.IsNotExist(err) {
					t.Fatal("marker written after failed COM")
				}
				_ = os.Remove(filepath.Join(p.root, "message.json"))
				user32.NewProc("PostMessageW").Call(p.hwnd, WM_COMMAND, ID_INSTALL, 0)
				b = waitSetupFile(t, p, "message.json")
				_ = json.Unmarshal(b, &message)
				if message.Flags&MB_ICONERROR != 0 {
					t.Fatal("retry did not recover", string(b))
				}
			}
			user32.NewProc("PostMessageW").Call(p.hwnd, WM_CLOSE, 0, 0)
		})
	}
}
