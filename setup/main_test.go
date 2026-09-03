//go:build windows

package main

import (
	"bytes"
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

func TestSettingsMigrationPreservesLegacyValuesAndAdds110Defaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")

	input := map[string]any{
		"sort":          "Populaires",
		"category":      "GÃ©nÃ©ral",
		"value":         7,
		"unit":          "Heures",
		"autoRotation":  false,
		"futureSetting": map[string]any{"keep": true},
	}

	b, err := json.MarshalIndent(input, "", "  ")
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

	var out map[string]any
	if err := json.Unmarshal(outBytes, &out); err != nil {
		t.Fatal(err)
	}

	if out["sort"] != "Populaires" || out["category"] != "GÃ©nÃ©ral" {
		t.Fatalf("legacy selection settings were reset: %+v", out)
	}
	if out["value"] != float64(7) || out["unit"] != "Heures" || out["autoRotation"] != false {
		t.Fatalf("legacy rotation settings were reset: %+v", out)
	}
	if _, ok := out["futureSetting"]; !ok {
		t.Fatalf("unknown setting was dropped: %+v", out)
	}
	if out["resolutionMode"] != "Automatique" || out["resolutionMatch"] != "Au moins" {
		t.Fatalf("1.1.0 display defaults were not added: %+v", out)
	}
	if out["customWidth"] != float64(2560) || out["customHeight"] != float64(1440) || out["customRatio"] != "Automatique" {
		t.Fatalf("1.1.0 custom display defaults were not added: %+v", out)
	}
	if out["checkUpdates"] != true || out["autoUpdate"] != false || out["lastNotifiedUpdate"] != "" {
		t.Fatalf("1.1.0 update defaults were not added: %+v", out)
	}
}

func TestSettingsMigrationLeavesCompleteFileUntouched(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")

	original := []byte("\xef\xbb\xbf{\r\n  \"sort\": \"Nouveaux\",\r\n  \"category\": \"GÃ©nÃ©ral\",\r\n  \"value\": 4,\r\n  \"unit\": \"Minutes\",\r\n  \"autoRotation\": true,\r\n  \"resolutionMode\": \"PersonnalisÃ©\",\r\n  \"resolutionMatch\": \"Exacte\",\r\n  \"customWidth\": 3440,\r\n  \"customHeight\": 1440,\r\n  \"customRatio\": \"21:9\",\r\n  \"checkUpdates\": true,\r\n  \"autoUpdate\": true,\r\n  \"lastNotifiedUpdate\": \"1.1.0\",\r\n  \"futureSetting\": \"keep-me\"\r\n}\r\n")

	if err := os.WriteFile(path, original, 0644); err != nil {
		t.Fatal(err)
	}

	if err := cleanOldSettings(path); err != nil {
		t.Fatal(err)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	if !bytes.Equal(after, original) {
		t.Fatal("complete settings.json should remain byte-for-byte untouched")
	}
}

func TestSettingsMigrationRejectsMalformedJSONWithoutReset(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	original := []byte(`{"category":"GÃ©nÃ©ral",`)

	if err := os.WriteFile(path, original, 0644); err != nil {
		t.Fatal(err)
	}

	if err := cleanOldSettings(path); err == nil {
		t.Fatal("malformed settings.json should fail the upgrade")
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	if !bytes.Equal(after, original) {
		t.Fatal("malformed settings.json must not be overwritten")
	}
}
