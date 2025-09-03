package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/BurntSushi/toml"
)

func TestNewSwitcher(t *testing.T) {
	tempDir := t.TempDir()
	os.Setenv("HOME", tempDir)
	defer os.Unsetenv("HOME")

	s, err := NewSwitcher()
	if err != nil {
		t.Fatalf("NewSwitcher failed: %v", err)
	}
	if s.configPath != filepath.Join(tempDir, ".switch.toml") {
		t.Errorf("Wrong config path: %s", s.configPath)
	}
	if _, err := os.Stat(s.configPath); err != nil {
		t.Error("Config file not created")
	}
}

func TestLoadConfig(t *testing.T) {
	tempDir := t.TempDir()
	os.Setenv("HOME", tempDir)
	defer os.Unsetenv("HOME")

	configPath := filepath.Join(tempDir, ".switch.toml")
	config := Config{
		Default: DefaultConfig{Config: "codex"},
		Codex: map[string]CodexEntry{
			"test": {Current: "test"},
		},
	}
	file, _ := os.Create(configPath)
	toml.NewEncoder(file).Encode(config)
	file.Close()

	s := &Switcher{configPath: configPath}
	err := s.loadConfig()
	if err != nil {
		t.Fatalf("loadConfig failed: %v", err)
	}
	if s.config.Default.Config != "codex" {
		t.Error("Default config not loaded")
	}
	if _, ok := s.config.Codex["test"]; !ok {
		t.Error("Codex entry not loaded")
	}
}

func TestSaveConfig(t *testing.T) {
	tempDir := t.TempDir()
	configPath := filepath.Join(tempDir, ".switch.toml")

	s := &Switcher{
		configPath: configPath,
		config: &Config{
			Default: DefaultConfig{Config: "codex"},
			Codex: map[string]CodexEntry{
				"user1": {Current: "user1"},
			},
		},
	}

	err := s.saveConfig()
	if err != nil {
		t.Fatalf("saveConfig failed: %v", err)
	}

	data, _ := os.ReadFile(configPath)
	var loaded Config
	toml.Unmarshal(data, &loaded)
	if loaded.Default.Config != "codex" {
		t.Error("Config not saved correctly")
	}
}

func TestAddCodexAccount(t *testing.T) {
	tempDir := t.TempDir()
	os.Setenv("HOME", tempDir)
	defer os.Unsetenv("HOME")

	codexDir := filepath.Join(tempDir, ".codex")
	os.MkdirAll(codexDir, 0755)
	authPath := filepath.Join(codexDir, "auth.json")
	authData := map[string]string{"token": "test123"}
	data, _ := json.Marshal(authData)
	os.WriteFile(authPath, data, 0600)

	s, _ := NewSwitcher()
	err := s.AddCodexAccount("testuser")
	if err != nil {
		t.Fatalf("AddCodexAccount failed: %v", err)
	}

	switchPath := authPath + ".testuser.switch"
	if _, err := os.Stat(switchPath); err != nil {
		t.Error("Switch file not created")
	}

	switchData, _ := os.ReadFile(switchPath)
	var loaded map[string]string
	json.Unmarshal(switchData, &loaded)
	if loaded["token"] != "test123" {
		t.Error("Auth data not copied correctly")
	}
}

func TestAddCodexAccountDuplicate(t *testing.T) {
	tempDir := t.TempDir()
	os.Setenv("HOME", tempDir)
	defer os.Unsetenv("HOME")

	codexDir := filepath.Join(tempDir, ".codex")
	os.MkdirAll(codexDir, 0755)
	authPath := filepath.Join(codexDir, "auth.json")
	os.WriteFile(authPath, []byte(`{"token":"test"}`), 0600)

	switchPath := authPath + ".existing.switch"
	os.WriteFile(switchPath, []byte(`{"token":"existing"}`), 0600)

	s, _ := NewSwitcher()
	err := s.AddCodexAccount("existing")
	if err == nil {
		t.Error("Should fail on duplicate account")
	}
}

func TestSwitchCodexAccount(t *testing.T) {
	tempDir := t.TempDir()
	os.Setenv("HOME", tempDir)
	defer os.Unsetenv("HOME")

	codexDir := filepath.Join(tempDir, ".codex")
	os.MkdirAll(codexDir, 0755)
	authPath := filepath.Join(codexDir, "auth.json")

	os.WriteFile(authPath, []byte(`{"token":"current"}`), 0600)
	os.WriteFile(authPath+".user1.switch", []byte(`{"token":"user1"}`), 0600)
	os.WriteFile(authPath+".user2.switch", []byte(`{"token":"user2"}`), 0600)

	s, _ := NewSwitcher()
	err := s.SwitchCodexAccount("user2")
	if err != nil {
		t.Fatalf("SwitchCodexAccount failed: %v", err)
	}

	data, _ := os.ReadFile(authPath)
	var loaded map[string]string
	json.Unmarshal(data, &loaded)
	if loaded["token"] != "user2" {
		t.Error("Account not switched correctly")
	}
}

func TestSwitchCodexAccountNotFound(t *testing.T) {
	tempDir := t.TempDir()
	os.Setenv("HOME", tempDir)
	defer os.Unsetenv("HOME")

	codexDir := filepath.Join(tempDir, ".codex")
	os.MkdirAll(codexDir, 0755)

	s, _ := NewSwitcher()
	err := s.SwitchCodexAccount("nonexistent")
	if err == nil {
		t.Error("Should fail for non-existent account")
	}
}

func TestCycleCodexAccount(t *testing.T) {
	tempDir := t.TempDir()
	os.Setenv("HOME", tempDir)
	defer os.Unsetenv("HOME")

	codexDir := filepath.Join(tempDir, ".codex")
	os.MkdirAll(codexDir, 0755)
	authPath := filepath.Join(codexDir, "auth.json")

	os.WriteFile(authPath, []byte(`{"token":"user1"}`), 0600)
	os.WriteFile(authPath+".user1.switch", []byte(`{"token":"user1"}`), 0600)
	os.WriteFile(authPath+".user2.switch", []byte(`{"token":"user2"}`), 0600)
	os.WriteFile(authPath+".user3.switch", []byte(`{"token":"user3"}`), 0600)

	s, _ := NewSwitcher()
	s.config.Codex["user1"] = CodexEntry{Current: "user1"}

	s.SwitchCodexAccount("")

	data, _ := os.ReadFile(authPath)
	var loaded map[string]string
	json.Unmarshal(data, &loaded)
	if loaded["token"] != "user2" {
		t.Errorf("Should cycle to user2, got %s", loaded["token"])
	}

	s.SwitchCodexAccount("")
	data, _ = os.ReadFile(authPath)
	json.Unmarshal(data, &loaded)
	if loaded["token"] != "user3" {
		t.Errorf("Should cycle to user3, got %s", loaded["token"])
	}

	s.SwitchCodexAccount("")
	data, _ = os.ReadFile(authPath)
	json.Unmarshal(data, &loaded)
	if loaded["token"] != "user1" {
		t.Errorf("Should cycle back to user1, got %s", loaded["token"])
	}
}

func TestFindCurrentAccount(t *testing.T) {
	tempDir := t.TempDir()
	os.Setenv("HOME", tempDir)
	defer os.Unsetenv("HOME")

	codexDir := filepath.Join(tempDir, ".codex")
	os.MkdirAll(codexDir, 0755)
	authPath := filepath.Join(codexDir, "auth.json")

	os.WriteFile(authPath, []byte(`{"token":"user2data"}`), 0600)
	os.WriteFile(authPath+".user1.switch", []byte(`{"token":"user1data"}`), 0600)
	os.WriteFile(authPath+".user2.switch", []byte(`{"token":"user2data"}`), 0600)

	s, _ := NewSwitcher()
	s.config.Codex = map[string]CodexEntry{
		"user1": {Current: ""},
		"user2": {Current: ""},
	}

	current := s.findCurrentAccount()
	if current != "user2" {
		t.Errorf("Wrong current account: %s", current)
	}
}

func TestGetCodexAccounts(t *testing.T) {
	tempDir := t.TempDir()
	os.Setenv("HOME", tempDir)
	defer os.Unsetenv("HOME")

	codexDir := filepath.Join(tempDir, ".codex")
	os.MkdirAll(codexDir, 0755)
	authPath := filepath.Join(codexDir, "auth.json")

	os.WriteFile(authPath+".user1.switch", []byte(`{}`), 0600)
	os.WriteFile(authPath+".user2.switch", []byte(`{}`), 0600)
	os.WriteFile(authPath+".user3.switch", []byte(`{}`), 0600)
	os.WriteFile(filepath.Join(codexDir, "other.json"), []byte(`{}`), 0600)

	s, _ := NewSwitcher()
	accounts := s.getCodexAccounts()

	if len(accounts) != 3 {
		t.Errorf("Wrong number of accounts: %d", len(accounts))
	}

	expected := map[string]bool{"user1": true, "user2": true, "user3": true}
	for _, acc := range accounts {
		if !expected[acc] {
			t.Errorf("Unexpected account: %s", acc)
		}
		delete(expected, acc)
	}
	if len(expected) > 0 {
		t.Error("Not all accounts found")
	}
}

func TestCopyFile(t *testing.T) {
	tempDir := t.TempDir()
	src := filepath.Join(tempDir, "source.txt")
	dst := filepath.Join(tempDir, "dest.txt")

	content := []byte("test content")
	os.WriteFile(src, content, 0644)

	err := copyFile(src, dst)
	if err != nil {
		t.Fatalf("copyFile failed: %v", err)
	}

	copied, _ := os.ReadFile(dst)
	if string(copied) != string(content) {
		t.Error("File content not copied correctly")
	}
}

func TestJsonEqual(t *testing.T) {
	tests := []struct {
		a, b  map[string]interface{}
		equal bool
	}{
		{
			map[string]interface{}{"key": "value"},
			map[string]interface{}{"key": "value"},
			true,
		},
		{
			map[string]interface{}{"key": "value1"},
			map[string]interface{}{"key": "value2"},
			false,
		},
		{
			map[string]interface{}{"key": float64(123)},
			map[string]interface{}{"key": float64(123)},
			true,
		},
		{
			map[string]interface{}{"a": "1", "b": "2"},
			map[string]interface{}{"b": "2", "a": "1"},
			true,
		},
	}

	for i, tt := range tests {
		result := jsonEqual(tt.a, tt.b)
		if result != tt.equal {
			t.Errorf("Test %d: expected %v, got %v", i, tt.equal, result)
		}
	}
}

func TestMainFunction(t *testing.T) {
	tempDir := t.TempDir()
	os.Setenv("HOME", tempDir)
	defer os.Unsetenv("HOME")

	codexDir := filepath.Join(tempDir, ".codex")
	os.MkdirAll(codexDir, 0755)
	authPath := filepath.Join(codexDir, "auth.json")
	os.WriteFile(authPath, []byte(`{"token":"test"}`), 0600)

	oldArgs := os.Args
	defer func() { os.Args = oldArgs }()

	os.Args = []string{"switch", "codex", "add", "testuser"}
	main()

	if _, err := os.Stat(authPath + ".testuser.switch"); err != nil {
		t.Error("Account not added via main")
	}
}
