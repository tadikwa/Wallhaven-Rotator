//go:build windows

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestParseAutostartArg(t *testing.T) {
	if !parseAutostartArg([]string{"--autostart=1"}, false) {
		t.Fatal("--autostart=1 should enable autostart")
	}
	if parseAutostartArg([]string{"--autostart=0"}, true) {
		t.Fatal("--autostart=0 should disable autostart")
	}
	if !parseAutostartArg(nil, true) {
		t.Fatal("missing argument should preserve fallback=true")
	}
	if parseAutostartArg(nil, false) {
		t.Fatal("missing argument should preserve fallback=false")
	}
}

func TestSettingsMigrationPreserves110Fields(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")

	input := map[string]any{
		"sort":               "Populaires",
		"category":           "Général",
		"value":              3,
		"unit":               "Minutes",
		"autoRotation":       true,
		"resolutionMode":     "Personnalisé",
		"resolutionMatch":    "Exacte",
		"customWidth":        3440,
		"customHeight":       1440,
		"customRatio":        "21:9",
		"checkUpdates":       true,
		"autoUpdate":         true,
		"lastNotifiedUpdate": "1.1.0",
	}

	b, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0644); err != nil {
		t.Fatal(err)
	}

	if err := cleanOldSettings(path); err != nil {
		t.Fatal(err)
	}

	outBytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	var out cleanSettings
	if err := json.Unmarshal(outBytes, &out); err != nil {
		t.Fatal(err)
	}

	if out.ResolutionMode != "Personnalisé" || out.ResolutionMatch != "Exacte" {
		t.Fatalf("resolution mode not preserved: %+v", out)
	}
	if out.CustomWidth != 3440 || out.CustomHeight != 1440 || out.CustomRatio != "21:9" {
		t.Fatalf("custom display settings not preserved: %+v", out)
	}
	if !out.CheckUpdates || !out.AutoUpdate || out.LastNotifiedUpdate != "1.1.0" {
		t.Fatalf("update settings not preserved: %+v", out)
	}
}
