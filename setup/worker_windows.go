//go:build windows

package main

import (
	"fmt"
	"runtime"
	"strings"
	"syscall"
)

const wmSetupEvent = 0x8001
const setupTimer = 71

type setupEvent struct {
	phase     string
	done      bool
	removing  bool
	err       error
	installed bool
	version   string
}

var setupEvents chan setupEvent
var closePending bool

func beginSetupOperation(hwnd uintptr, removing bool) {
	if busy {
		return
	}
	setBusy("Préparation de l’opération…")
	timer, _, err := user32.NewProc("SetTimer").Call(hwnd, setupTimer, 100, 0)
	if timer == 0 {
		clearBusy()
		messageBox(fmt.Sprintf("SetTimer: %v", err), appName+" Setup", MB_OK|MB_ICONERROR)
		return
	}
	events := setupEvents
	go func() {
		result := performSetupOperation(removing)
		events <- result
		user32.NewProc("PostMessageW").Call(hwnd, wmSetupEvent, 0, 0)
	}()
}

func performSetupOperation(removing bool) setupEvent {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	result := setupEvent{done: true, removing: removing}
	result.err = setupPhase("worker.sta", func() error {
		ole := syscall.NewLazyDLL("ole32.dll")
		hr, _, _ := ole.NewProc("CoInitializeEx").Call(0, 6) // STA | DISABLE_OLE1DDE.
		if err := shellHRESULT("CoInitializeEx(worker STA)", hr); err != nil {
			return err
		}
		defer ole.NewProc("CoUninitialize").Call()
		if removing {
			return uninstall()
		}
		return install()
	})
	result.installed = isInstalled()
	if result.installed {
		result.version = detectedInstalledVersion()
	}
	return result
}

func phaseStatus(phase string) string {
	switch {
	case phase == "payload.remove":
		return "Suppression des fichiers de l’application…"
	case phase == "shortcut.remove":
		return "Suppression du raccourci Démarrer…"
	case strings.HasPrefix(phase, "payload."):
		return "Copie et vérification des fichiers…"
	case strings.HasPrefix(phase, "shortcut."):
		return "Configuration du raccourci Démarrer…"
	case phase == "registry":
		return "Configuration du démarrage Windows…"
	case phase == "launch.wsh":
		return "Lancement de Wallhaven Rotator…"
	case phase == "install.json":
		return "Finalisation de l’installation…"
	default:
		return "Opération en cours…"
	}
}

func receiveSetupEvents(hwnd uintptr) {
	for {
		select {
		case event := <-setupEvents:
			if !event.done {
				if !closePending {
					busyStatus = phaseStatus(event.phase)
				}
				procInvalidateRect.Call(hwnd, 0, 1)
				continue
			}
			user32.NewProc("KillTimer").Call(hwnd, setupTimer)
			installed, installedVersion = event.installed, event.version
			if event.err != nil {
				messageBox(event.err.Error()+"\n\nJournal : "+setupTracePath(), appName+" Setup", MB_OK|MB_ICONERROR)
			} else if !closePending {
				text := "Installation terminée.\n\nLa demande d’ouverture de Wallhaven Rotator a été transmise."
				if event.removing {
					text = "Wallhaven Rotator a été désinstallé."
				}
				messageBox(text, appName+" Setup", MB_OK|MB_ICONINFORMATION)
			}
			clearBusy()
			if closePending {
				user32.NewProc("DestroyWindow").Call(hwnd)
			}
		default:
			return
		}
	}
}

func requestSetupClose(hwnd uintptr) {
	if busy {
		closePending = true
		busyStatus = "Fermeture à la fin de l’opération…"
		procInvalidateRect.Call(hwnd, 0, 1)
		return
	}
	user32.NewProc("DestroyWindow").Call(hwnd)
}
