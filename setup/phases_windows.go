//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
	"unsafe"
)

var setupProgress = func(string) {}

func lockSetupOperation() (func(), error) {
	runtime.LockOSThread()
	name := `Local\WallhavenRotatorSetup-` + hashBytes([]byte(strings.ToLower(expandedShortcutPath(appPath()))))
	h, _, err := kernel32.NewProc("CreateMutexW").Call(0, 0, uintptr(unsafe.Pointer(utf16Ptr(name))))
	if h == 0 {
		runtime.UnlockOSThread()
		return nil, fmt.Errorf("CreateMutexW: %v", err)
	}
	status, _, err := kernel32.NewProc("WaitForSingleObject").Call(h, 0)
	if status != 0 && status != 0x80 {
		procCloseHandle.Call(h)
		runtime.UnlockOSThread()
		if status == 0x102 {
			return nil, fmt.Errorf("Une autre opération du setup est déjà en cours pour cette installation.")
		}
		return nil, fmt.Errorf("WaitForSingleObject: %v", err)
	}
	return func() { kernel32.NewProc("ReleaseMutex").Call(h); procCloseHandle.Call(h); runtime.UnlockOSThread() }, nil
}

func setupTracePath() string {
	return filepath.Join(os.TempDir(), fmt.Sprintf("WallhavenRotator-Setup-%d.log", os.Getpid()))
}

func appendSetupTrace(message string) {
	f, err := os.OpenFile(setupTracePath(), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339Nano), message)
}

var setupPhase = func(name string, action func() error) error {
	start := time.Now()
	thread, _, _ := kernel32.NewProc("GetCurrentThreadId").Call()
	appendSetupTrace(fmt.Sprintf("phase=%s event=begin thread=%d", name, thread))
	setupProgress(name)
	err := action()
	appendSetupTrace(fmt.Sprintf("phase=%s event=end elapsed_ms=%d error=%v", name, time.Since(start).Milliseconds(), err))
	return err
}
