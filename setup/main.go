//go:build windows

package main

import (
	"bytes"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

//go:embed payload/*
var payloadFS embed.FS

const (
	appName       = "Wallhaven Rotator"
	installFolder = "WallhavenWallpaperRotator"
	mutexName     = `Local\WallhavenWallpaperRotator`
	runValueName  = "WallhavenWallpaperRotator"

	WM_DESTROY    = 0x0002
	WM_PAINT      = 0x000F
	WM_CLOSE      = 0x0010
	WM_ERASEBKGND = 0x0014
	WM_DRAWITEM   = 0x002B
	WM_SETFONT    = 0x0030
	WM_SETICON    = 0x0080
	WM_COMMAND    = 0x0111
	ICON_SMALL    = 0
	ICON_BIG      = 1

	WS_OVERLAPPED  = 0x00000000
	WS_CAPTION     = 0x00C00000
	WS_SYSMENU     = 0x00080000
	WS_MINIMIZEBOX = 0x00020000
	WS_VISIBLE     = 0x10000000
	WS_CHILD       = 0x40000000
	WS_TABSTOP     = 0x00010000
	BS_PUSHBUTTON  = 0x00000000
	BS_OWNERDRAW   = 0x0000000B

	ODS_SELECTED = 0x0001
	ODS_DISABLED = 0x0004
	ODS_FOCUS    = 0x0010

	DT_LEFT         = 0x0000
	DT_CENTER       = 0x0001
	DT_VCENTER      = 0x0004
	DT_WORDBREAK    = 0x0010
	DT_SINGLELINE   = 0x0020
	DT_END_ELLIPSIS = 0x8000

	TRANSPARENT = 1
	PS_SOLID    = 0
	NULL_PEN    = 8

	FW_NORMAL         = 400
	FW_SEMIBOLD       = 600
	FW_BOLD           = 700
	DEFAULT_CHARSET   = 1
	CLEARTYPE_QUALITY = 5

	CW_USEDEFAULT = 0x80000000
	SW_HIDE       = 0
	SW_SHOW       = 5
	SW_SHOWNORMAL = 1

	MB_OK              = 0x00000000
	MB_ICONINFORMATION = 0x00000040
	MB_ICONWARNING     = 0x00000030
	MB_ICONERROR       = 0x00000010

	COLOR_WINDOW     = 5
	DEFAULT_GUI_FONT = 17

	KEY_SET_VALUE     = 0x0002
	REG_SZ            = 1
	HKEY_CURRENT_USER = 0x80000001

	SYNCHRONIZE          = 0x00100000
	ERROR_FILE_NOT_FOUND = 2

	ID_INSTALL   = 1001
	ID_UNINSTALL = 1002
	ID_CLOSE     = 1003

	SM_CXSCREEN = 0
	SM_CYSCREEN = 1

	IMAGE_ICON      = 1
	LR_DEFAULTCOLOR = 0x0000
)

var (
	appVersion   = "1.0.0"
	setupVersion = "1.0.0"
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	advapi32 = syscall.NewLazyDLL("advapi32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")

	procRegisterClassExW = user32.NewProc("RegisterClassExW")
	procCreateWindowExW  = user32.NewProc("CreateWindowExW")
	procDefWindowProcW   = user32.NewProc("DefWindowProcW")
	procShowWindow       = user32.NewProc("ShowWindow")
	procUpdateWindow     = user32.NewProc("UpdateWindow")
	procGetMessageW      = user32.NewProc("GetMessageW")
	procTranslateMessage = user32.NewProc("TranslateMessage")
	procDispatchMessageW = user32.NewProc("DispatchMessageW")
	procPostQuitMessage  = user32.NewProc("PostQuitMessage")
	procMessageBoxW      = user32.NewProc("MessageBoxW")
	procSetWindowTextW   = user32.NewProc("SetWindowTextW")
	procEnableWindow     = user32.NewProc("EnableWindow")
	procSendMessageW     = user32.NewProc("SendMessageW")
	procGetSystemMetrics = user32.NewProc("GetSystemMetrics")
	procLoadImageW       = user32.NewProc("LoadImageW")
	procLoadIconW        = user32.NewProc("LoadIconW")
	procDrawIconEx       = user32.NewProc("DrawIconEx")
	procBeginPaint       = user32.NewProc("BeginPaint")
	procEndPaint         = user32.NewProc("EndPaint")
	procGetClientRect    = user32.NewProc("GetClientRect")
	procInvalidateRect   = user32.NewProc("InvalidateRect")

	procGetModuleHandleW = kernel32.NewProc("GetModuleHandleW")
	procOpenMutexW       = kernel32.NewProc("OpenMutexW")
	procCloseHandle      = kernel32.NewProc("CloseHandle")

	procRegCreateKeyExW = advapi32.NewProc("RegCreateKeyExW")
	procRegSetValueExW  = advapi32.NewProc("RegSetValueExW")
	procRegDeleteValueW = advapi32.NewProc("RegDeleteValueW")
	procRegCloseKey     = advapi32.NewProc("RegCloseKey")

	procShellExecuteW    = shell32.NewProc("ShellExecuteW")
	procGetStockObject   = gdi32.NewProc("GetStockObject")
	procCreateSolidBrush = gdi32.NewProc("CreateSolidBrush")
	procDeleteObject     = gdi32.NewProc("DeleteObject")
	procSelectObject     = gdi32.NewProc("SelectObject")
	procCreatePen        = gdi32.NewProc("CreatePen")
	procRoundRect        = gdi32.NewProc("RoundRect")
	procFillRect         = user32.NewProc("FillRect")
	procSetBkMode        = gdi32.NewProc("SetBkMode")
	procSetTextColor     = gdi32.NewProc("SetTextColor")
	procDrawTextW        = user32.NewProc("DrawTextW")
	procCreateFontW      = gdi32.NewProc("CreateFontW")

	dwmapi                    = syscall.NewLazyDLL("dwmapi.dll")
	procDwmSetWindowAttribute = dwmapi.NewProc("DwmSetWindowAttribute")
)

var (
	hwndMain, hwndInstall, hwndUninstall, hwndClose uintptr
	installed                                       bool
	installedVersion                                string
	installDir                                      string
	busy                                            bool
	busyStatus                                      string
	appIcon                                         uintptr

	fontEyebrow   uintptr
	fontTitle     uintptr
	fontSubtitle  uintptr
	fontCardTitle uintptr
	fontBody      uintptr
	fontSmall     uintptr
	fontButton    uintptr
)

type wndClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   syscall.Handle
	Icon       syscall.Handle
	Cursor     syscall.Handle
	Background syscall.Handle
	MenuName   *uint16
	ClassName  *uint16
	IconSm     syscall.Handle
}

type point struct{ X, Y int32 }
type rect struct{ Left, Top, Right, Bottom int32 }
type paintStruct struct {
	Hdc       uintptr
	Erase     int32
	RcPaint   rect
	Restore   int32
	IncUpdate int32
	Reserved  [32]byte
}
type drawItemStruct struct {
	CtlType    uint32
	CtlID      uint32
	ItemID     uint32
	ItemAction uint32
	ItemState  uint32
	HwndItem   uintptr
	HDC        uintptr
	RcItem     rect
	ItemData   uintptr
}
type msg struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
	Private uint32
}

type cleanSettings struct {
	Sort         string `json:"sort"`
	Category     string `json:"category"`
	Value        int    `json:"value"`
	Unit         string `json:"unit"`
	AutoRotation bool   `json:"autoRotation"`
}

type installMarker struct {
	Product       string            `json:"product"`
	Version       string            `json:"version"`
	SetupVersion  string            `json:"setupVersion"`
	InstalledAt   string            `json:"installedAt"`
	PayloadSHA256 map[string]string `json:"payloadSha256"`
}

type payloadItem struct {
	Name string
}

var payload = []payloadItem{
	{"Wallhaven-Wallpaper-Tray.ps1"},
	{"Wallhaven-Rotator-Launcher.vbs"},
	{"Wallhaven-Rotator.ico"},
	{"Wallhaven-Rotator.png"},
	{"README.txt"},
}

func utf16Ptr(s string) *uint16 {
	p, err := syscall.UTF16PtrFromString(s)
	if err != nil {
		panic(err)
	}
	return p
}

func loword(v uintptr) uint16 { return uint16(v & 0xffff) }

func messageBox(text, title string, flags uintptr) {
	procMessageBoxW.Call(hwndMain, uintptr(unsafe.Pointer(utf16Ptr(text))), uintptr(unsafe.Pointer(utf16Ptr(title))), flags)
}

func setText(hwnd uintptr, s string) {
	procSetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(utf16Ptr(s))))
}

func enable(hwnd uintptr, on bool) {
	v := uintptr(0)
	if on {
		v = 1
	}
	procEnableWindow.Call(hwnd, v)
}

func appPath() string {
	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		if home, err := os.UserHomeDir(); err == nil {
			base = filepath.Join(home, "AppData", "Local")
		}
	}
	return filepath.Join(base, installFolder)
}

func isInstalled() bool {
	p := appPath()
	main := filepath.Join(p, "Wallhaven-Wallpaper-Tray.ps1")
	launcher := filepath.Join(p, "Wallhaven-Rotator-Launcher.vbs")
	_, e1 := os.Stat(main)
	_, e2 := os.Stat(launcher)
	return e1 == nil && e2 == nil
}

func detectedInstalledVersion() string {
	b, err := os.ReadFile(filepath.Join(appPath(), "install.json"))
	if err != nil {
		return "ancienne"
	}
	var marker installMarker
	if json.Unmarshal(bytes.TrimPrefix(b, []byte{0xEF, 0xBB, 0xBF}), &marker) != nil || strings.TrimSpace(marker.Version) == "" {
		return "ancienne"
	}
	return marker.Version
}

func isRunning() bool {
	h, _, _ := procOpenMutexW.Call(SYNCHRONIZE, 0, uintptr(unsafe.Pointer(utf16Ptr(mutexName))))
	if h == 0 {
		return false
	}
	procCloseHandle.Call(h)
	return true
}

func hashBytes(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func atomicWrite(path string, data []byte) error {
	tmp := path + ".setup-tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(path)
		if err2 := os.Rename(tmp, path); err2 != nil {
			_ = os.Remove(tmp)
			return err2
		}
	}
	return nil
}

func cleanOldSettings(path string) error {
	def := cleanSettings{Sort: "Aléatoire", Category: "Toutes", Value: 1, Unit: "Minutes", AutoRotation: true}
	data, err := os.ReadFile(path)
	if err == nil {
		data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
		var raw map[string]interface{}
		if json.Unmarshal(data, &raw) == nil {
			if s, ok := raw["sort"].(string); ok && contains([]string{"Tendance", "Populaires", "Nouveaux", "Aléatoire"}, s) {
				def.Sort = s
			}
			if s, ok := raw["category"].(string); ok && contains([]string{"Général", "Anime", "Personnes", "Toutes"}, s) {
				def.Category = s
			}
			if s, ok := raw["unit"].(string); ok && contains([]string{"Minutes", "Heures", "Jours"}, s) {
				def.Unit = s
			}
			if n, ok := raw["value"].(float64); ok && int(n) >= 1 && int(n) <= 999 {
				def.Value = int(n)
			}
			if b, ok := raw["autoRotation"].(bool); ok {
				def.AutoRotation = b
			}
		}
	}
	out, _ := json.MarshalIndent(def, "", "  ")
	out = append(out, '\n')
	return atomicWrite(path, out)
}

func contains(a []string, s string) bool {
	for _, v := range a {
		if v == s {
			return true
		}
	}
	return false
}

func setRunValue(command string) error {
	const subkey = `Software\Microsoft\Windows\CurrentVersion\Run`
	var key uintptr
	r, _, _ := procRegCreateKeyExW.Call(
		HKEY_CURRENT_USER,
		uintptr(unsafe.Pointer(utf16Ptr(subkey))),
		0, 0, 0, KEY_SET_VALUE, 0,
		uintptr(unsafe.Pointer(&key)), 0,
	)
	if r != 0 {
		return fmt.Errorf("RegCreateKeyExW: %d", r)
	}
	defer procRegCloseKey.Call(key)
	u, _ := syscall.UTF16FromString(command)
	r, _, _ = procRegSetValueExW.Call(
		key,
		uintptr(unsafe.Pointer(utf16Ptr(runValueName))),
		0, REG_SZ,
		uintptr(unsafe.Pointer(&u[0])),
		uintptr(len(u)*2),
	)
	if r != 0 {
		return fmt.Errorf("RegSetValueExW: %d", r)
	}
	return nil
}

func deleteRunValue() {
	const subkey = `Software\Microsoft\Windows\CurrentVersion\Run`
	var key uintptr
	r, _, _ := procRegCreateKeyExW.Call(
		HKEY_CURRENT_USER,
		uintptr(unsafe.Pointer(utf16Ptr(subkey))),
		0, 0, 0, KEY_SET_VALUE, 0,
		uintptr(unsafe.Pointer(&key)), 0,
	)
	if r != 0 {
		return
	}
	defer procRegCloseKey.Call(key)
	procRegDeleteValueW.Call(key, uintptr(unsafe.Pointer(utf16Ptr(runValueName))))
}

func removeObsolete(dir string) {
	obsoleteFiles := []string{
		"TheMatrix.scr", "TheMatrix.ini", "Set-LockScreenImage.ps1",
		"Installer-Wallhaven-Rotator.ps1", "Installer-Wallhaven-Rotator.cmd",
		"Desinstaller-Wallhaven-Rotator.ps1", "Desinstaller-Wallhaven-Rotator.cmd",
	}
	for _, n := range obsoleteFiles {
		_ = os.Remove(filepath.Join(dir, n))
	}
	_ = os.RemoveAll(filepath.Join(dir, "lockscreen"))
}

func install() error {
	if isRunning() {
		return fmt.Errorf("Wallhaven Rotator est actuellement en cours d'exécution.\n\nQuittez-le d'abord depuis son icône dans la zone de notification (clic droit > Quitter), puis relancez le setup.")
	}

	dir := appPath()
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(dir, "cache"), 0755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(dir, "logs"), 0755); err != nil {
		return err
	}

	removeObsolete(dir)

	hashes := map[string]string{}
	for _, item := range payload {
		data, err := payloadFS.ReadFile("payload/" + item.Name)
		if err != nil {
			return fmt.Errorf("lecture payload %s: %w", item.Name, err)
		}
		expected := hashBytes(data)
		dest := filepath.Join(dir, item.Name)
		if err := atomicWrite(dest, data); err != nil {
			return fmt.Errorf("écriture %s: %w", item.Name, err)
		}
		diskHash, err := hashFile(dest)
		if err != nil || !strings.EqualFold(diskHash, expected) {
			return fmt.Errorf("vérification du fichier installé échouée : %s", item.Name)
		}
		hashes[item.Name] = expected
	}

	if err := cleanOldSettings(filepath.Join(dir, "settings.json")); err != nil {
		return fmt.Errorf("settings.json: %w", err)
	}

	windir := os.Getenv("WINDIR")
	if windir == "" {
		windir = `C:\Windows`
	}
	wscript := filepath.Join(windir, "System32", "wscript.exe")
	launcher := filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs")
	runCmd := fmt.Sprintf(`"%s" //B //Nologo "%s" autostart`, wscript, launcher)
	if err := setRunValue(runCmd); err != nil {
		return fmt.Errorf("autostart: %w", err)
	}

	marker := installMarker{
		Product: appName, Version: appVersion, SetupVersion: setupVersion,
		InstalledAt: time.Now().Format(time.RFC3339), PayloadSHA256: hashes,
	}
	b, _ := json.MarshalIndent(marker, "", "  ")
	b = append(b, '\n')
	if err := atomicWrite(filepath.Join(dir, "install.json"), b); err != nil {
		return err
	}

	launchInstalledApp(dir)
	return nil
}

func launchInstalledApp(dir string) {
	windir := os.Getenv("WINDIR")
	if windir == "" {
		windir = `C:\Windows`
	}
	wscript := filepath.Join(windir, "System32", "wscript.exe")
	launcher := filepath.Join(dir, "Wallhaven-Rotator-Launcher.vbs")
	params := fmt.Sprintf(`//B //Nologo "%s" show`, launcher)
	procShellExecuteW.Call(
		0,
		uintptr(unsafe.Pointer(utf16Ptr("open"))),
		uintptr(unsafe.Pointer(utf16Ptr(wscript))),
		uintptr(unsafe.Pointer(utf16Ptr(params))),
		uintptr(unsafe.Pointer(utf16Ptr(dir))),
		SW_SHOWNORMAL,
	)
}

func uninstall() error {
	if isRunning() {
		return fmt.Errorf("Wallhaven Rotator est actuellement en cours d'exécution.\n\nQuittez-le d'abord depuis son icône dans la zone de notification (clic droit > Quitter), puis relancez le setup pour le désinstaller.")
	}
	deleteRunValue()
	dir := appPath()
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	return nil
}

func rgb(r, g, b byte) uintptr {
	return uintptr(uint32(r) | uint32(g)<<8 | uint32(b)<<16)
}

func makeRect(l, t, r, b int32) rect { return rect{l, t, r, b} }

func fillRectColor(hdc uintptr, rc rect, color uintptr) {
	brush, _, _ := procCreateSolidBrush.Call(color)
	procFillRect.Call(hdc, uintptr(unsafe.Pointer(&rc)), brush)
	procDeleteObject.Call(brush)
}

func roundRectColor(hdc uintptr, rc rect, radius int32, fill, border uintptr, borderWidth int32) {
	brush, _, _ := procCreateSolidBrush.Call(fill)
	pen, _, _ := procCreatePen.Call(PS_SOLID, uintptr(borderWidth), border)
	oldBrush, _, _ := procSelectObject.Call(hdc, brush)
	oldPen, _, _ := procSelectObject.Call(hdc, pen)
	procRoundRect.Call(hdc, uintptr(rc.Left), uintptr(rc.Top), uintptr(rc.Right), uintptr(rc.Bottom), uintptr(radius), uintptr(radius))
	procSelectObject.Call(hdc, oldPen)
	procSelectObject.Call(hdc, oldBrush)
	procDeleteObject.Call(pen)
	procDeleteObject.Call(brush)
}

func drawText(hdc uintptr, text string, rc rect, font, color uintptr, flags uint32) {
	if text == "" {
		return
	}
	old, _, _ := procSelectObject.Call(hdc, font)
	procSetBkMode.Call(hdc, TRANSPARENT)
	procSetTextColor.Call(hdc, color)
	procDrawTextW.Call(
		hdc,
		uintptr(unsafe.Pointer(utf16Ptr(text))),
		^uintptr(0),
		uintptr(unsafe.Pointer(&rc)),
		uintptr(flags),
	)
	procSelectObject.Call(hdc, old)
}

func drawPill(hdc uintptr, text string, rc rect, fill, border, textColor uintptr) {
	roundRectColor(hdc, rc, 18, fill, border, 1)
	drawText(hdc, text, rc, fontSmall, textColor, DT_CENTER|DT_VCENTER|DT_SINGLELINE)
}

func drawCheck(hdc uintptr, x, y int32, text string) {
	dot := makeRect(x, y+4, x+10, y+14)
	roundRectColor(hdc, dot, 10, rgb(113, 226, 167), rgb(113, 226, 167), 1)
	drawText(hdc, text, makeRect(x+18, y, x+190, y+22), fontSmall, rgb(151, 166, 173), DT_LEFT|DT_VCENTER|DT_SINGLELINE)
}

func paintMainWindow(hwnd uintptr) {
	var ps paintStruct
	hdc, _, _ := procBeginPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))
	if hdc == 0 {
		return
	}
	defer procEndPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))

	var client rect
	procGetClientRect.Call(hwnd, uintptr(unsafe.Pointer(&client)))
	fillRectColor(hdc, client, rgb(18, 24, 28))

	// Hero / branding
	if appIcon != 0 {
		procDrawIconEx.Call(hdc, 30, 30, appIcon, 54, 54, 0, 0, 3)
	}
	drawText(hdc, "WALLHAVEN ROTATOR", makeRect(100, 26, 400, 48), fontEyebrow, rgb(113, 226, 167), DT_LEFT|DT_VCENTER|DT_SINGLELINE)
	drawText(hdc, "Setup", makeRect(100, 47, 390, 82), fontTitle, rgb(245, 248, 249), DT_LEFT|DT_VCENTER|DT_SINGLELINE)
	drawText(hdc, "v"+appVersion+" · installation utilisateur", makeRect(100, 82, 430, 105), fontSubtitle, rgb(142, 158, 166), DT_LEFT|DT_VCENTER|DT_SINGLELINE)

	if busy {
		drawPill(hdc, "EN COURS", makeRect(500, 38, 606, 68), rgb(25, 45, 62), rgb(68, 139, 194), rgb(151, 211, 255))
	} else if installed {
		drawPill(hdc, "INSTALLÉ · "+installedVersion, makeRect(480, 38, 606, 68), rgb(20, 55, 41), rgb(55, 130, 91), rgb(133, 234, 180))
	} else {
		drawPill(hdc, "PRÊT", makeRect(514, 38, 606, 68), rgb(20, 55, 41), rgb(55, 130, 91), rgb(133, 234, 180))
	}

	// Main card
	card := makeRect(28, 124, 612, 257)
	roundRectColor(hdc, card, 18, rgb(27, 36, 41), rgb(47, 60, 67), 1)

	var cardTitle, cardBody string
	if busy {
		cardTitle = busyStatus
		cardBody = "Patientez quelques secondes. Le setup vérifie chaque fichier avant de terminer l'opération."
	} else if installed {
		cardTitle = "Version " + installedVersion + " détectée"
		cardBody = "Wallhaven Rotator est déjà présent dans votre profil Windows. Vous pouvez remettre les fichiers à jour ou le supprimer proprement."
	} else {
		cardTitle = "Prêt à installer"
		cardBody = "Le rotateur sera installé uniquement dans votre profil utilisateur, sans service Windows et sans demander de droits administrateur."
	}

	drawText(hdc, cardTitle, makeRect(50, 146, 580, 174), fontCardTitle, rgb(245, 248, 249), DT_LEFT|DT_VCENTER|DT_SINGLELINE)
	drawText(hdc, cardBody, makeRect(50, 179, 586, 222), fontBody, rgb(174, 186, 191), DT_LEFT|DT_WORDBREAK)

	path := installDir
	if path == "" {
		path = appPath()
	}
	pathBox := makeRect(50, 225, 590, 247)
	drawText(hdc, "›  "+path, pathBox, fontSmall, rgb(113, 226, 167), DT_LEFT|DT_VCENTER|DT_SINGLELINE|DT_END_ELLIPSIS)

	// Footer trust indicators
	drawCheck(hdc, 30, 374, "Sans UAC")
	drawCheck(hdc, 166, 374, "Aucun service")
	drawCheck(hdc, 316, 374, "Autostart utilisateur")
	drawText(hdc, "Setup natif Windows x64", makeRect(477, 374, 612, 396), fontSmall, rgb(92, 108, 116), DT_RIGHT|DT_VCENTER|DT_SINGLELINE)
}

func buttonLabel(id uint32) string {
	switch id {
	case ID_INSTALL:
		if installed {
			return "Mettre à jour / Réinstaller"
		}
		return "Installer Wallhaven Rotator"
	case ID_UNINSTALL:
		return "Désinstaller"
	case ID_CLOSE:
		return "Fermer"
	}
	return ""
}

const DT_RIGHT = 0x0002

func drawOwnerButton(dis *drawItemStruct) {
	rc := dis.RcItem
	pressed := (dis.ItemState & ODS_SELECTED) != 0
	disabled := (dis.ItemState & ODS_DISABLED) != 0

	fill := rgb(32, 42, 47)
	border := rgb(66, 82, 90)
	textColor := rgb(231, 237, 239)

	switch dis.CtlID {
	case ID_INSTALL:
		fill = rgb(113, 226, 167)
		border = rgb(113, 226, 167)
		textColor = rgb(13, 31, 23)
		if pressed {
			fill = rgb(88, 194, 139)
			border = fill
		}
	case ID_UNINSTALL:
		fill = rgb(40, 31, 34)
		border = rgb(132, 67, 75)
		textColor = rgb(255, 151, 160)
		if pressed {
			fill = rgb(65, 38, 43)
		}
	case ID_CLOSE:
		fill = rgb(27, 36, 41)
		border = rgb(57, 70, 77)
		textColor = rgb(185, 197, 202)
		if pressed {
			fill = rgb(39, 49, 55)
		}
	}

	if disabled {
		fill = rgb(31, 38, 42)
		border = rgb(47, 56, 61)
		textColor = rgb(89, 102, 108)
	}

	roundRectColor(dis.HDC, rc, 14, fill, border, 1)
	drawText(dis.HDC, buttonLabel(dis.CtlID), rc, fontButton, textColor, DT_CENTER|DT_VCENTER|DT_SINGLELINE)
}

func updateUI() {
	installed = isInstalled()
	if installed {
		installedVersion = detectedInstalledVersion()
	} else {
		installedVersion = ""
	}
	installDir = appPath()
	if hwndUninstall != 0 {
		if installed {
			procShowWindow.Call(hwndUninstall, SW_SHOW)
		} else {
			procShowWindow.Call(hwndUninstall, SW_HIDE)
		}
	}
	if hwndMain != 0 {
		procInvalidateRect.Call(hwndMain, 0, 1)
		procInvalidateRect.Call(hwndInstall, 0, 1)
		procInvalidateRect.Call(hwndUninstall, 0, 1)
		procInvalidateRect.Call(hwndClose, 0, 1)
	}
}

func setBusy(text string) {
	busy = true
	busyStatus = text
	enable(hwndInstall, false)
	enable(hwndUninstall, false)
	enable(hwndClose, false)
	updateUI()
	procUpdateWindow.Call(hwndMain)
}

func clearBusy() {
	busy = false
	busyStatus = ""
	enable(hwndInstall, true)
	enable(hwndUninstall, true)
	enable(hwndClose, true)
	updateUI()
}

func wndProc(hwnd uintptr, m uint32, wparam, lparam uintptr) uintptr {
	switch m {
	case WM_PAINT:
		paintMainWindow(hwnd)
		return 0
	case WM_ERASEBKGND:
		return 1
	case WM_DRAWITEM:
		if lparam != 0 {
			dis := (*drawItemStruct)(unsafe.Pointer(lparam))
			drawOwnerButton(dis)
			return 1
		}
	case WM_COMMAND:
		switch loword(wparam) {
		case ID_INSTALL:
			setBusy("Installation en cours…")
			err := install()
			if err != nil {
				messageBox(err.Error(), appName+" Setup", MB_OK|MB_ICONERROR)
			} else {
				messageBox("Installation terminée.\n\nWallhaven Rotator est prêt et son lancement automatique avec Windows est activé.", appName+" Setup", MB_OK|MB_ICONINFORMATION)
			}
			clearBusy()
			return 0
		case ID_UNINSTALL:
			setBusy("Désinstallation en cours…")
			err := uninstall()
			if err != nil {
				messageBox(err.Error(), appName+" Setup", MB_OK|MB_ICONERROR)
			} else {
				messageBox("Wallhaven Rotator a été désinstallé.", appName+" Setup", MB_OK|MB_ICONINFORMATION)
			}
			clearBusy()
			return 0
		case ID_CLOSE:
			procPostQuitMessage.Call(0)
			return 0
		}
	case WM_CLOSE, WM_DESTROY:
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(hwnd, uintptr(m), wparam, lparam)
	return r
}

func createButton(text string, x, y, w, h int32, parent uintptr, id uintptr) uintptr {
	hwnd, _, _ := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(utf16Ptr("BUTTON"))),
		uintptr(unsafe.Pointer(utf16Ptr(text))),
		uintptr(WS_CHILD|WS_VISIBLE|WS_TABSTOP|BS_OWNERDRAW),
		uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		parent, id, 0, 0,
	)
	return hwnd
}

func createUIFont(height int32, weight int32) uintptr {
	h, _, _ := procCreateFontW.Call(
		uintptr(height), 0, 0, 0, uintptr(weight),
		0, 0, 0, DEFAULT_CHARSET,
		0, 0, CLEARTYPE_QUALITY, 0,
		uintptr(unsafe.Pointer(utf16Ptr("Segoe UI"))),
	)
	return h
}

func applyModernWindowAttributes(hwnd uintptr) {
	useDark := int32(1)
	if procDwmSetWindowAttribute.Find() == nil {
		procDwmSetWindowAttribute.Call(hwnd, 20, uintptr(unsafe.Pointer(&useDark)), unsafe.Sizeof(useDark))
		corner := int32(2) // DWMWCP_ROUND
		procDwmSetWindowAttribute.Call(hwnd, 33, uintptr(unsafe.Pointer(&corner)), unsafe.Sizeof(corner))
	}
}

func runGUI() error {
	instance, _, _ := procGetModuleHandleW.Call(0)
	className := utf16Ptr("WallhavenRotatorSetupWindowModern")

	appIcon, _, _ = procLoadIconW.Call(instance, 1)

	wc := wndClassEx{
		Size:       uint32(unsafe.Sizeof(wndClassEx{})),
		WndProc:    syscall.NewCallback(wndProc),
		Instance:   syscall.Handle(instance),
		Icon:       syscall.Handle(appIcon),
		Background: 0,
		ClassName:  className,
		IconSm:     syscall.Handle(appIcon),
	}
	atom, _, err := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	if atom == 0 {
		return fmt.Errorf("RegisterClassExW: %v", err)
	}

	// Fonts are negative logical heights for crisp UI text.
	fontEyebrow = createUIFont(^int32(11)+1, FW_SEMIBOLD)
	fontTitle = createUIFont(^int32(28)+1, FW_SEMIBOLD)
	fontSubtitle = createUIFont(^int32(13)+1, FW_NORMAL)
	fontCardTitle = createUIFont(^int32(18)+1, FW_SEMIBOLD)
	fontBody = createUIFont(^int32(13)+1, FW_NORMAL)
	fontSmall = createUIFont(^int32(11)+1, FW_NORMAL)
	fontButton = createUIFont(^int32(13)+1, FW_SEMIBOLD)

	width, height := int32(656), int32(450)
	sw, _, _ := procGetSystemMetrics.Call(SM_CXSCREEN)
	sh, _, _ := procGetSystemMetrics.Call(SM_CYSCREEN)
	x := (int32(sw) - width) / 2
	y := (int32(sh) - height) / 2

	style := uint32(WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX)
	hwnd, _, err := procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(utf16Ptr("Wallhaven Rotator · Setup"))),
		uintptr(style),
		uintptr(x), uintptr(y), uintptr(width), uintptr(height),
		0, 0, instance, 0,
	)
	if hwnd == 0 {
		return fmt.Errorf("CreateWindowExW: %v", err)
	}
	hwndMain = hwnd

	if appIcon != 0 {
		procSendMessageW.Call(hwnd, WM_SETICON, ICON_BIG, appIcon)
		procSendMessageW.Call(hwnd, WM_SETICON, ICON_SMALL, appIcon)
	}
	applyModernWindowAttributes(hwnd)

	hwndInstall = createButton("Installer Wallhaven Rotator", 28, 282, 330, 54, hwnd, ID_INSTALL)
	hwndUninstall = createButton("Désinstaller", 370, 282, 242, 54, hwnd, ID_UNINSTALL)
	hwndClose = createButton("Fermer", 482, 341, 130, 38, hwnd, ID_CLOSE)

	updateUI()
	procShowWindow.Call(hwnd, SW_SHOW)
	procUpdateWindow.Call(hwnd)

	var m msg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}

	for _, h := range []uintptr{fontEyebrow, fontTitle, fontSubtitle, fontCardTitle, fontBody, fontSmall, fontButton} {
		if h != 0 {
			procDeleteObject.Call(h)
		}
	}
	return nil
}

func main() {
	args := os.Args[1:]
	if len(args) > 0 {
		switch strings.ToLower(args[0]) {
		case "/install", "--install":
			if err := install(); err != nil {
				messageBox(err.Error(), appName+" Setup", MB_OK|MB_ICONERROR)
				os.Exit(1)
			}
			os.Exit(0)
		case "/uninstall", "--uninstall":
			if err := uninstall(); err != nil {
				messageBox(err.Error(), appName+" Setup", MB_OK|MB_ICONERROR)
				os.Exit(1)
			}
			os.Exit(0)
		}
	}
	if err := runGUI(); err != nil {
		messageBox(err.Error(), appName+" Setup", MB_OK|MB_ICONERROR)
	}
}
