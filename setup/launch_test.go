//go:build windows

package main

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func TestWSHLaunchChecksExitStatusAndDeadline(t *testing.T) {
	dir, _ := shortcutFixture(t)
	launcher := filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs")
	if err := os.WriteFile(launcher, []byte("WScript.Quit 7"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := launchInstalledApp(dir, "show"); err == nil {
		t.Fatal("WSH exit 7 reported as success")
	}
	if err := os.Remove(launcher); err != nil {
		t.Fatal(err)
	}
	if err := launchInstalledApp(dir, "show"); err == nil {
		t.Fatal("missing VBS reported as success")
	}
	if err := os.WriteFile(launcher, []byte("WScript.Sleep 60000"), 0644); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	start := time.Now()
	if err := runWScript(ctx, dir, "show"); err == nil || ctx.Err() != context.DeadlineExceeded {
		t.Fatal("WSH deadline not enforced", err, ctx.Err())
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("WSH process did not terminate after its deadline")
	}
}

func TestCOMApartmentErrorDoesNotRunActionOrUninitializeCaller(t *testing.T) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	ole := syscall.NewLazyDLL("ole32.dll")
	hr, _, _ := ole.NewProc("CoInitializeEx").Call(0, 0)
	if err := shellHRESULT("test MTA initialization", hr); err != nil {
		t.Fatal(err)
	}
	defer ole.NewProc("CoUninitialize").Call()
	called := false
	err := withShellLink(func(*shellCOM, *shellCOM) error { called = true; return nil })
	if err == nil || called || !strings.Contains(err.Error(), "80010106") {
		t.Fatal("STA/MTA conflict not propagated", err, called)
	}
	var apt, q int32
	hr, _, _ = ole.NewProc("CoGetApartmentType").Call(uintptr(unsafe.Pointer(&apt)), uintptr(unsafe.Pointer(&q)))
	if err := shellHRESULT("caller still initialized", hr); err != nil || apt != 1 {
		t.Fatal("failed STA call uninitialized caller", err, apt)
	}
}

func TestUninstallRegistryFailurePreservesFilesAndShortcut(t *testing.T) {
	dir, path := shortcutFixture(t)
	if err := ensureStartMenuShortcut(dir); err != nil {
		t.Fatal(err)
	}
	oldRunning, oldDelete := isRunning, deleteRunValue
	t.Cleanup(func() { isRunning, deleteRunValue = oldRunning, oldDelete })
	isRunning = func() bool { return false }
	deleteRunValue = func() error { return syscall.ERROR_ACCESS_DENIED }
	if err := uninstall(); err == nil {
		t.Fatal("registry error reported as successful uninstall")
	}
	for _, p := range []string{dir, path} {
		if _, err := os.Stat(p); err != nil {
			t.Fatal("registry failure removed data", p, err)
		}
	}
}

func TestSetupOperationMutexExcludesAnotherThreadAndReleases(t *testing.T) {
	shortcutFixture(t)
	release, err := lockSetupOperation()
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() {
		unlock, err := lockSetupOperation()
		if unlock != nil {
			unlock()
		}
		result <- err
	}()
	if err := <-result; err == nil {
		release()
		t.Fatal("concurrent installer acquired operation mutex")
	}
	release()
	go func() {
		unlock, err := lockSetupOperation()
		if unlock != nil {
			unlock()
		}
		result <- err
	}()
	if err := <-result; err != nil {
		t.Fatal("mutex not released after operation", err)
	}
}

func TestRejectedSilentUpdateCannotRecreateUninstalledDirectory(t *testing.T) {
	dir, _ := shortcutFixture(t)
	oldRunning := isRunning
	t.Cleanup(func() { isRunning = oldRunning })
	isRunning = func() bool { return false }
	release, err := lockSetupOperation()
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- silentUpdate(false) }()
	if err := <-done; err == nil {
		t.Fatal("updater ignored another setup operation")
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatal("rejected updater recreated uninstalled app directory")
	}
}
