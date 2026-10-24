//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"
)

var errForeignShortcut = errors.New("le raccourci existant vise une autre application ; il est conservé")

type shellLinkInfo struct {
	Target, Arguments, Icon, Work, Description string
	IconIndex                                  int32
}

// Vtable order: Windows SDK IShellLinkW and IPersistFile (IUnknown first).
type shellCOM struct{ table *[21]uintptr }

func shellHRESULT(operation string, hr uintptr) error {
	if int32(hr) < 0 {
		return fmt.Errorf("%s: HRESULT 0x%08X", operation, uint32(hr))
	}
	return nil
}

func withShellLink(action func(link, persist *shellCOM) error) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	ole := syscall.NewLazyDLL("ole32.dll")
	hr, _, _ := ole.NewProc("CoInitializeEx").Call(0, 2) // STA, including balanced S_FALSE.
	if err := shellHRESULT("CoInitializeEx", hr); err != nil {
		return err
	}
	defer ole.NewProc("CoUninitialize").Call()
	clsid := syscall.GUID{Data1: 0x00021401, Data4: [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	iid := syscall.GUID{Data1: 0x000214F9, Data4: [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	var link *shellCOM
	hr, _, _ = ole.NewProc("CoCreateInstance").Call(uintptr(unsafe.Pointer(&clsid)), 0, 1, uintptr(unsafe.Pointer(&iid)), uintptr(unsafe.Pointer(&link)))
	if err := shellHRESULT("CoCreateInstance(IShellLinkW)", hr); err != nil {
		return err
	}
	defer syscall.SyscallN(link.table[2], uintptr(unsafe.Pointer(link)))
	iidPersist := syscall.GUID{Data1: 0x0000010b, Data4: [8]byte{0xC0, 0, 0, 0, 0, 0, 0, 0x46}}
	var persist *shellCOM
	hr, _, _ = syscall.SyscallN(link.table[0], uintptr(unsafe.Pointer(link)), uintptr(unsafe.Pointer(&iidPersist)), uintptr(unsafe.Pointer(&persist)))
	if err := shellHRESULT("QueryInterface(IPersistFile)", hr); err != nil {
		return err
	}
	defer syscall.SyscallN(persist.table[2], uintptr(unsafe.Pointer(persist)))
	return action(link, persist)
}

func (c *shellCOM) text(method int) (string, int32, error) {
	buf := make([]uint16, 32768)
	var index int32
	var hr uintptr
	switch method {
	case 3: // GetPath, raw: never Resolve a link or access its target.
		hr, _, _ = syscall.SyscallN(c.table[method], uintptr(unsafe.Pointer(c)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 4)
	case 16: // GetIconLocation
		hr, _, _ = syscall.SyscallN(c.table[method], uintptr(unsafe.Pointer(c)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), uintptr(unsafe.Pointer(&index)))
	default:
		hr, _, _ = syscall.SyscallN(c.table[method], uintptr(unsafe.Pointer(c)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	}
	return syscall.UTF16ToString(buf), index, shellHRESULT("IShellLinkW.Get", hr)
}

func (c *shellCOM) setText(method int, value string) error {
	u, err := syscall.UTF16PtrFromString(value)
	if err != nil {
		return err
	}
	var hr uintptr
	if method == 17 { // SetIconLocation, index zero.
		hr, _, _ = syscall.SyscallN(c.table[method], uintptr(unsafe.Pointer(c)), uintptr(unsafe.Pointer(u)), 0)
	} else {
		hr, _, _ = syscall.SyscallN(c.table[method], uintptr(unsafe.Pointer(c)), uintptr(unsafe.Pointer(u)))
	}
	return shellHRESULT("IShellLinkW.Set", hr)
}

func (c *shellCOM) file(method int, path string, flags uintptr) error {
	u, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	hr, _, _ := syscall.SyscallN(c.table[method], uintptr(unsafe.Pointer(c)), uintptr(unsafe.Pointer(u)), flags)
	return shellHRESULT("IPersistFile", hr)
}

func readShellLink(path string) (shellLinkInfo, error) {
	var result shellLinkInfo
	err := withShellLink(func(link, persist *shellCOM) error {
		if err := persist.file(5, path, 0); err != nil {
			return err
		}
		for _, field := range []struct {
			method int
			dest   *string
		}{{3, &result.Target}, {6, &result.Description}, {8, &result.Work}, {10, &result.Arguments}, {16, &result.Icon}} {
			value, index, err := link.text(field.method)
			if err != nil {
				return err
			}
			*field.dest = value
			if field.method == 16 {
				result.IconIndex = index
			}
		}
		return nil
	})
	return result, err
}

func writeShellLink(path string, info shellLinkInfo) error {
	return withShellLink(func(link, persist *shellCOM) error {
		for _, field := range []struct {
			method int
			value  string
		}{{20, info.Target}, {7, info.Description}, {9, info.Work}, {11, info.Arguments}, {17, info.Icon}} {
			if err := link.setText(field.method, field.value); err != nil {
				return err
			}
		}
		hr, _, _ := syscall.SyscallN(link.table[15], uintptr(unsafe.Pointer(link)), SW_SHOWNORMAL)
		if err := shellHRESULT("IShellLinkW.SetShowCmd", hr); err != nil {
			return err
		}
		return persist.file(6, path, 1)
	})
}

func startMenuShortcutPath() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	if !filepath.IsAbs(base) {
		return "", fmt.Errorf("APPDATA doit être un chemin absolu")
	}
	return filepath.Join(base, "Microsoft", "Windows", "Start Menu", "Programs", appName+".lnk"), nil
}

func windowsScriptHost() string {
	windir := os.Getenv("WINDIR")
	if windir == "" {
		windir = `C:\Windows`
	}
	return filepath.Join(windir, "System32", "wscript.exe")
}

func expandedShortcutPath(value string) string {
	buf := make([]uint16, 32768)
	u, err := syscall.UTF16PtrFromString(value)
	if err != nil {
		return ""
	}
	n, _, _ := kernel32.NewProc("ExpandEnvironmentStringsW").Call(uintptr(unsafe.Pointer(u)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 || n > uintptr(len(buf)) {
		return ""
	}
	return filepath.Clean(syscall.UTF16ToString(buf))
}

func ownsStartMenuShortcut(info shellLinkInfo, dir string) bool {
	launcher := filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs")
	target := expandedShortcutPath(info.Target)
	if strings.EqualFold(target, launcher) {
		return true
	} // Manual shortcut directly to our VBS.
	if !strings.EqualFold(target, windowsScriptHost()) {
		return false
	}
	var count int32
	argv, err := syscall.CommandLineToArgv(utf16Ptr("wscript.exe "+info.Arguments), &count)
	if err != nil {
		return false
	}
	defer syscall.LocalFree(syscall.Handle(uintptr(unsafe.Pointer(argv))))
	if count < 2 || count > 8192 {
		return false
	}
	for i := 1; i < int(count); i++ {
		arg := syscall.UTF16ToString(argv[i][:])
		if strings.HasPrefix(arg, "//") {
			continue
		}
		return strings.EqualFold(expandedShortcutPath(arg), launcher)
	}
	return false
}

func existingStartMenuShortcut(path, dir string) (bool, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() {
		return false, errForeignShortcut
	}
	link, err := readShellLink(path)
	if err != nil {
		return false, fmt.Errorf("raccourci illisible, conservé : %w", err)
	}
	if !ownsStartMenuShortcut(link, dir) {
		return false, errForeignShortcut
	}
	return true, nil
}

func ensureStartMenuShortcut(dir string) error {
	path, err := startMenuShortcutPath()
	if err != nil {
		return err
	}
	if _, err = existingStartMenuShortcut(path, dir); err != nil {
		return fmt.Errorf("%s : %w", path, err)
	}
	if err = os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".wallhaven-shortcut-*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if err = tmp.Close(); err != nil {
		_ = os.Remove(name)
		return err
	}
	defer os.Remove(name)
	info := shellLinkInfo{Target: windowsScriptHost(), Arguments: fmt.Sprintf(`//B //Nologo "%s" show`, filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs")), Icon: filepath.Join(dir, "Wallhaven-Rotator.ico"), Work: dir, Description: appName}
	if err = writeShellLink(name, info); err != nil {
		return err
	}
	// Recheck ownership before publishing; a failed replacement never deletes the old link.
	if _, err = existingStartMenuShortcut(path, dir); err != nil {
		return err
	}
	if err = os.Rename(name, path); err != nil {
		return err
	}
	procSHChangeNotify.Call(0x2000, 5, uintptr(unsafe.Pointer(utf16Ptr(path))), 0)
	return nil
}

var procSHChangeNotify = shell32.NewProc("SHChangeNotify")

func removeStartMenuShortcut(dir string) error {
	path, err := startMenuShortcutPath()
	if err != nil {
		return err
	}
	exists, err := existingStartMenuShortcut(path, dir)
	if errors.Is(err, errForeignShortcut) {
		return nil
	}
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	if err = os.Remove(path); err != nil {
		return err
	}
	procSHChangeNotify.Call(4, 5, uintptr(unsafe.Pointer(utf16Ptr(path))), 0)
	return nil
}
