package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Helpers
func setHome(t *testing.T) string {
	t.Helper()
	temp := t.TempDir()
	t.Setenv("HOME", temp)
	return temp
}

func withStdin(t *testing.T, input string, fn func()) {
	t.Helper()
	old := stdinReader
	stdinReader = bufio.NewReader(strings.NewReader(input))
	defer func() { stdinReader = old }()
	fn()
}

func captureOutput(t *testing.T, fn func()) (string, string) {
	t.Helper()
	oldOut := os.Stdout
	oldErr := os.Stderr
	rOut, wOut, _ := os.Pipe()
	rErr, wErr, _ := os.Pipe()
	os.Stdout = wOut
	os.Stderr = wErr
	defer func() {
		os.Stdout = oldOut
		os.Stderr = oldErr
	}()
	var outBuf, errBuf strings.Builder
	outDone := make(chan struct{})
	errDone := make(chan struct{})
	go func() { io.Copy(&outBuf, rOut); close(outDone) }()
	go func() { io.Copy(&errBuf, rErr); close(errDone) }()
	fn()
	wOut.Close()
	wErr.Close()
	<-outDone
	<-errDone
	return outBuf.String(), errBuf.String()
}

// Config and initialization
func TestNewSwitcher_CreatesConfig(t *testing.T) {
	home := setHome(t)
	s, err := NewSwitcher()
	if err != nil {
		t.Fatalf("NewSwitcher failed: %v", err)
	}
	if s.configPath != filepath.Join(home, ".switch.toml") {
		t.Errorf("wrong configPath: %s", s.configPath)
	}
	if _, err := os.Stat(s.configPath); err != nil {
		t.Fatalf("config file not created: %v", err)
	}
	if s.config.Default.Config != "codex" {
		t.Errorf("default config not initialized, got %q", s.config.Default.Config)
	}
}

func TestLoadSaveConfig_RoundTrip(t *testing.T) {
	home := setHome(t)
	s, err := NewSwitcher()
	if err != nil {
		t.Fatal(err)
	}
	s.config.Default.Config = "codex"
	s.config.Apps["codex"] = AppConfig{Current: "u1", Accounts: []string{"u1", "u2"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"}
	if err := s.saveConfig(); err != nil {
		t.Fatalf("saveConfig: %v", err)
	}
	s2 := &Switcher{configPath: filepath.Join(home, ".switch.toml")}
	if err := s2.loadConfig(); err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if s2.config.Default.Config != "codex" {
		t.Errorf("roundtrip default mismatch: %q", s2.config.Default.Config)
	}
	if _, ok := s2.config.Apps["codex"]; !ok {
		t.Errorf("apps map missing codex")
	}
}

// Path and copy utilities
func TestExpandAndResolve(t *testing.T) {
	home := setHome(t)
	got := expandPath("~/file.txt")
	if got != filepath.Join(home, "file.txt") {
		t.Errorf("expandPath mismatch: %s", got)
	}
	p := resolveSwitchPattern("{auth_path}.{name}.switch", filepath.Join(home, ".codex/auth.json"), "alice")
	if !strings.HasSuffix(p, ".codex/auth.json.alice.switch") {
		t.Errorf("resolveSwitchPattern unexpected: %s", p)
	}
}

func TestExpandAndResolve_WindowsLikePaths(t *testing.T) {
	home := setHome(t)
	// Ensure backslashes after tilde expand correctly
	got := expandPath("~\\sub\\file.txt")
	exp := filepath.ToSlash(filepath.Clean(filepath.Join(home, "sub", "file.txt")))
	if got != exp {
		t.Errorf("expandPath windows-like mismatch: got %q want %q", got, exp)
	}

	// Pattern and auth path using backslashes normalize to slash form and resolve correctly
	auth := "~\\.codex\\auth.json"
	pat := "{auth_path}\\{name}.switch"
	out := resolveSwitchPattern(pat, expandPath(auth), "alice")
	if !strings.HasSuffix(out, ".codex/auth.json/alice.switch") && !strings.HasSuffix(out, ".codex/auth.json.alice.switch") {
		t.Errorf("resolveSwitchPattern windows-like unexpected: %s", out)
	}

	// Arbitrary Windows absolute path should be normalized to forward slashes
	in := "C:\\Users\\me\\file.txt"
	norm := expandPath(in)
	if strings.Contains(norm, "\\") {
		t.Errorf("expected forward slashes, got %q", norm)
	}
}

func TestCopyFileFolderAndPath(t *testing.T) {
	setHome(t)
	base := t.TempDir()
	// file copy
	src := filepath.Join(base, "a.txt")
	dst := filepath.Join(base, "b.txt")
	os.WriteFile(src, []byte("hello"), 0644)
	if err := copyFile(src, dst); err != nil {
		t.Fatalf("copyFile: %v", err)
	}
	b, _ := os.ReadFile(dst)
	if string(b) != "hello" {
		t.Fatalf("file content mismatch: %q", string(b))
	}
	// folder copy via copyPath
	dsrc := filepath.Join(base, "dirsrc")
	ddst := filepath.Join(base, "dirdst")
	os.MkdirAll(filepath.Join(dsrc, "nested"), 0755)
	os.WriteFile(filepath.Join(dsrc, "nested", "f.txt"), []byte("x"), 0644)
	if err := copyPath(dsrc, ddst); err != nil {
		t.Fatalf("copyPath folder: %v", err)
	}
	if _, err := os.Stat(filepath.Join(ddst, "nested", "f.txt")); err != nil {
		t.Fatalf("copied file missing: %v", err)
	}
}

func TestCopyPreservesPermissions_FileAndDir(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("skipping POSIX permission tests on Windows")
	}
	setHome(t)
	base := t.TempDir()
	// File perms
	src := filepath.Join(base, "fp.txt")
	wantFilePerm := os.FileMode(0640)
	if err := os.WriteFile(src, []byte("data"), wantFilePerm); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(base, "out", "fp.txt")
	if err := copyFile(src, dst); err != nil {
		t.Fatalf("copyFile: %v", err)
	}
	gotInfo, err := os.Stat(dst)
	if err != nil {
		t.Fatal(err)
	}
	if got := gotInfo.Mode().Perm(); got != wantFilePerm {
		t.Fatalf("file perm mismatch: got %v want %v", got, wantFilePerm)
	}
	// Dir perms
	srcDir := filepath.Join(base, "srcd")
	wantDirPerm := os.FileMode(0750)
	if err := os.MkdirAll(filepath.Join(srcDir, "n"), wantDirPerm); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(srcDir, "n", "f"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	dstDir := filepath.Join(base, "dstd")
	if err := copyFolder(srcDir, dstDir); err != nil {
		t.Fatalf("copyFolder: %v", err)
	}
	dInfo, err := os.Stat(filepath.Join(dstDir, "n"))
	if err != nil {
		t.Fatal(err)
	}
	if got := dInfo.Mode().Perm(); got != wantDirPerm {
		t.Fatalf("dir perm mismatch: got %v want %v", got, wantDirPerm)
	}
}

func TestCopyFile_Errors(t *testing.T) {
	// Nonexistent src triggers early error path
	if err := copyFile("/no/such/src", t.TempDir()+"/x"); err == nil {
		t.Fatalf("expected error for missing src")
	}
}

func TestCopyFile_DestinationOpenError(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("skipping POSIX permission tests on Windows")
	}
	setHome(t)
	base := t.TempDir()
	src := filepath.Join(base, "src.txt")
	if err := os.WriteFile(src, []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	ro := filepath.Join(base, "rodir")
	if err := os.MkdirAll(ro, 0555); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(ro, "dest.txt")
	if err := copyFile(src, dst); err == nil {
		t.Fatalf("expected openFile error when dest dir not writable")
	}
}

func TestEqualFunctions(t *testing.T) {
	setHome(t)
	dir := t.TempDir()
	// fileEqual with JSON order-insensitive via jsonEqual
	f1 := filepath.Join(dir, "a.json")
	f2 := filepath.Join(dir, "b.json")
	os.WriteFile(f1, []byte(`{"k":1, "z":2}`), 0644)
	os.WriteFile(f2, []byte(`{"z":2, "k":1}`), 0644)
	if !fileEqual(f1, f2) {
		t.Errorf("fileEqual json should be true")
	}
	// fileEqual plain text
	t1 := filepath.Join(dir, "a.txt")
	t2 := filepath.Join(dir, "b.txt")
	os.WriteFile(t1, []byte("abc"), 0644)
	os.WriteFile(t2, []byte("abc"), 0644)
	if !fileEqual(t1, t2) {
		t.Errorf("fileEqual text should be true")
	}
	// folderEqual only checks both are directories
	d1 := filepath.Join(dir, "d1")
	d2 := filepath.Join(dir, "d2")
	os.MkdirAll(d1, 0755)
	os.MkdirAll(d2, 0755)
	if !folderEqual(d1, d2) {
		t.Errorf("folderEqual should be true for dirs")
	}
	// contentEqual delegates
	if !contentEqual(t1, t2) {
		t.Errorf("contentEqual files should be true")
	}
	if !contentEqual(d1, d2) {
		t.Errorf("contentEqual dirs should be true")
	}
}

func TestFileEqual_NonJSON_NotEqual(t *testing.T) {
	setHome(t)
	dir := t.TempDir()
	a := filepath.Join(dir, "a.txt")
	b := filepath.Join(dir, "b.txt")
	_ = os.WriteFile(a, []byte("aaa"), 0644)
	_ = os.WriteFile(b, []byte("bbb"), 0644)
	if fileEqual(a, b) {
		t.Fatalf("expected not equal for different text files")
	}
}

// Switcher core APIs
func TestGetSetAppConfig(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	_, ok := s.GetAppConfig("codex")
	if ok {
		t.Fatalf("expected no codex app yet")
	}
	cfg := AppConfig{Current: "", Accounts: []string{}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"}
	s.SetAppConfig("codex", cfg)
	c2, ok := s.GetAppConfig("codex")
	if !ok || c2.AuthPath != cfg.AuthPath {
		t.Fatalf("Get/Set mismatch")
	}
}

func setupCodexFiles(t *testing.T, home string, authData string, accounts map[string]string) string {
	t.Helper()
	codexDir := filepath.Join(home, ".codex")
	os.MkdirAll(codexDir, 0755)
	authPath := filepath.Join(codexDir, "auth.json")
	os.WriteFile(authPath, []byte(authData), 0600)
	for name, data := range accounts {
		os.WriteFile(authPath+"."+name+".switch", []byte(data), 0600)
	}
	return authPath
}

func TestAddAccount_NewTemplateApp(t *testing.T) {
	home := setHome(t)
	authPath := setupCodexFiles(t, home, `{"token":"t123"}`, map[string]string{})
	s, _ := NewSwitcher()
	if err := s.AddAccount("codex", "alice"); err != nil {
		t.Fatalf("AddAccount: %v", err)
	}
	// switch file created and config updated
	if _, err := os.Stat(authPath + ".alice.switch"); err != nil {
		t.Fatalf("switch backup missing: %v", err)
	}
	app, ok := s.GetAppConfig("codex")
	if !ok {
		t.Fatalf("app not set")
	}
	if app.Current != "alice" || !contains(app.Accounts, "alice") {
		t.Fatalf("config not updated correctly: %+v", app)
	}
}

func TestAddAccount_Duplicate_NoOverwrite(t *testing.T) {
	home := setHome(t)
	authPath := setupCodexFiles(t, home, `{"token":"orig"}`, map[string]string{"alice": `{"token":"old"}`})
	s, _ := NewSwitcher()
	// Seed app config to trigger duplicate prompt
	s.SetAppConfig("codex", AppConfig{Current: "alice", Accounts: []string{"alice"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	withStdin(t, "no\n", func() {
		if err := s.AddAccount("codex", "alice"); err == nil {
			t.Fatalf("expected cancellation error")
		}
	})
	// ensure file unchanged
	b, _ := os.ReadFile(authPath + ".alice.switch")
	if !strings.Contains(string(b), "old") {
		t.Fatalf("switch file should remain old, got: %s", string(b))
	}
}

func TestAddAccount_SaveConfigError_RollsBack(t *testing.T) {
	home := setHome(t)
	authPath := setupCodexFiles(t, home, `{"token":"z"}`, map[string]string{})
	s, _ := NewSwitcher()
	// Force saveConfig error
	badDir := t.TempDir()
	s.configPath = badDir
	if err := s.AddAccount("codex", "p1"); err == nil {
		t.Fatalf("expected error from saveConfig")
	}
	// Switch backup should have been removed
	if _, err := os.Stat(authPath + ".p1.switch"); !os.IsNotExist(err) {
		t.Fatalf("expected backup removed on error, err=%v", err)
	}
}

func TestSwitchAccount_Success(t *testing.T) {
	home := setHome(t)
	authPath := setupCodexFiles(t, home, `{"token":"a"}`, map[string]string{"a": `{"token":"a"}`, "b": `{"token":"b"}`})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "a", Accounts: []string{"a", "b"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	if err := s.SwitchAccount("codex", "b"); err != nil {
		t.Fatalf("SwitchAccount: %v", err)
	}
	bts, _ := os.ReadFile(authPath)
	if !strings.Contains(string(bts), "b") {
		t.Fatalf("auth not switched: %s", string(bts))
	}
}

func TestSwitchAccount_SameAccount(t *testing.T) {
	home := setHome(t)
	authPath := setupCodexFiles(t, home, `{"token":"a"}`, map[string]string{"a": `{"token":"a"}`})
	_ = authPath
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "a", Accounts: []string{"a"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	out, _ := captureOutput(t, func() { _ = s.SwitchAccount("codex", "a") })
	if !strings.Contains(out, "Switched to: a") {
		t.Fatalf("expected 'Switched to: a' message, got %q", out)
	}
}

func TestSwitchAccount_NotFound(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{"a"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.SwitchAccount("codex", "missing"); err == nil {
		t.Fatalf("expected error for missing account")
	}
}

func TestCycleAccounts(t *testing.T) {
	home := setHome(t)
	authPath := setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": `{"token":"u1"}`, "u2": `{"token":"u2"}`, "u3": `{"token":"u3"}`})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "u1", Accounts: []string{"u1", "u2", "u3"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	// First cycle -> u2
	if err := s.CycleAccounts("codex"); err != nil {
		t.Fatalf("CycleAccounts: %v", err)
	}
	bts, _ := os.ReadFile(authPath)
	if !strings.Contains(string(bts), "u2") {
		t.Fatalf("expected u2, got %s", string(bts))
	}
	// Second cycle -> u3
	if err := s.CycleAccounts("codex"); err != nil {
		t.Fatalf("CycleAccounts: %v", err)
	}
	bts, _ = os.ReadFile(authPath)
	if !strings.Contains(string(bts), "u3") {
		t.Fatalf("expected u3, got %s", string(bts))
	}
	// Third cycle -> u1
	if err := s.CycleAccounts("codex"); err != nil {
		t.Fatalf("CycleAccounts: %v", err)
	}
	bts, _ = os.ReadFile(authPath)
	if !strings.Contains(string(bts), "u1") {
		t.Fatalf("expected u1, got %s", string(bts))
	}
}

func TestFindCurrentAccount(t *testing.T) {
	home := setHome(t)
	setupCodexFiles(t, home, `{"token":"u2data"}`, map[string]string{"u1": `{"token":"u1data"}`, "u2": `{"token":"u2data"}`})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{"u1", "u2"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	cur := s.findCurrentAccount("codex")
	if cur != "u2" {
		t.Fatalf("expected current u2, got %q", cur)
	}
}

func TestRunWizard_ManualSetup_Success(t *testing.T) {
	home := setHome(t)
	// Prepare a real auth file
	authDir := filepath.Join(home, ".myapp")
	if err := os.MkdirAll(authDir, 0755); err != nil {
		t.Fatal(err)
	}
	authPath := filepath.Join(authDir, "cfg.json")
	if err := os.WriteFile(authPath, []byte(`{"k":1}`), 0644); err != nil {
		t.Fatal(err)
	}

	s, _ := NewSwitcher()
	inputs := strings.Join([]string{
		"1",      // choose Other (manual setup)
		"myapp",  // app name
		authPath, // config path
		"",       // accept default pattern
		"acc1",   // current profile
		"",       // accept save yes
		"",
	}, "\n") + "\n"
	withStdin(t, inputs, func() {
		if err := s.RunWizard(); err != nil {
			t.Fatalf("RunWizard manual: %v", err)
		}
	})
	// Config saved
	app, ok := s.GetAppConfig("myapp")
	if !ok {
		t.Fatalf("app not saved")
	}
	if app.Current != "acc1" {
		t.Fatalf("current not set: %+v", app)
	}
	// Backup file created
	if _, err := os.Stat(resolveSwitchPattern(app.SwitchPattern, authPath, "acc1")); err != nil {
		t.Fatalf("backup not created: %v", err)
	}
}

func TestLoadConfig_ReadError(t *testing.T) {
	home := setHome(t)
	s := &Switcher{configPath: home} // directory path causes read error
	if err := s.loadConfig(); err == nil {
		t.Fatalf("expected read config error for directory path")
	}
}

func TestRunWizard_AddToExisting_Success(t *testing.T) {
	home := setHome(t)
	// Seed app config
	authPath := setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": `{"token":"u1"}`})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "u1", Accounts: []string{"u1"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	inputs := strings.Join([]string{
		"1",  // choose existing app codex
		"u2", // new profile name
		"",   // accept save yes
		"",
	}, "\n") + "\n"
	withStdin(t, inputs, func() {
		if err := s.RunWizard(); err != nil {
			t.Fatalf("RunWizard existing: %v", err)
		}
	})
	// New switch file exists and config contains u2
	if _, err := os.Stat(authPath + ".u2.switch"); err != nil {
		t.Fatalf("switch backup u2 missing: %v", err)
	}
	if app, ok := s.GetAppConfig("codex"); !ok || !contains(app.Accounts, "u2") {
		t.Fatalf("account u2 not added: %+v", app)
	}
}

func TestRunWizard_Initial_DetectedTemplate_Success(t *testing.T) {
	home := setHome(t)
	// Create codex config to be detected
	if err := os.MkdirAll(filepath.Join(home, ".codex"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".codex", "auth.json"), []byte(`{"t":1}`), 0600); err != nil {
		t.Fatal(err)
	}
	s, _ := NewSwitcher()
	// options: only detected templates + Other -> choose first detected
	inputs := strings.Join([]string{
		"1",  // choose detected codex
		"",   // Application name default
		"",   // Config path default
		"",   // Switch pattern default
		"p1", // profile name
		"",   // save yes
	}, "\n") + "\n"
	withStdin(t, inputs, func() {
		if err := s.RunWizard(); err != nil {
			t.Fatalf("RunWizard detected: %v", err)
		}
	})
	if _, ok := s.GetAppConfig("codex"); !ok {
		t.Fatalf("codex app not created")
	}
}

// Listing and detection
func TestListAccountsAndAllApps(t *testing.T) {
	home := setHome(t)
	setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": `{"token":"u1"}`, "u2": `{"token":"u2"}`})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "u1", Accounts: []string{"u1", "u2"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	s.config.Default.Config = "codex"
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	out1, _ := captureOutput(t, func() { s.ListAccounts("codex") })
	if !strings.Contains(out1, "Codex") || !strings.Contains(out1, "u1") || !strings.Contains(out1, "u2") {
		t.Fatalf("ListAccounts output unexpected: %q", out1)
	}
	out2, _ := captureOutput(t, func() { s.ListAllApps() })
	if !strings.Contains(out2, "Configured applications:") || !strings.Contains(out2, "codex") {
		t.Fatalf("ListAllApps output unexpected: %q", out2)
	}
}

func TestListAllApps_Empty(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	out, _ := captureOutput(t, func() { s.ListAllApps() })
	if !strings.Contains(out, "No applications configured") {
		t.Fatalf("expected empty apps message, got: %q", out)
	}
}

func TestDetectApplications(t *testing.T) {
	home := setHome(t)
	// Create only Code/User (second detect path), not ~/.vscode/User
	vscodeAlt := filepath.Join(home, "Library", "Application Support", "Code", "User")
	os.MkdirAll(vscodeAlt, 0755)
	// Create claude config file
	claude := filepath.Join(home, ".claude", "config.json")
	os.MkdirAll(filepath.Dir(claude), 0755)
	os.WriteFile(claude, []byte("{}"), 0644)

	found := DetectApplications()
	if _, ok := found["claude"]; !ok {
		t.Fatalf("claude not detected")
	}
	if _, ok := found["vscode"]; !ok {
		t.Fatalf("vscode not detected")
	}
	// If default AuthPath (~/.vscode/User) absent, AuthPath should equal the detected path
	if expandPath(found["vscode"].AuthPath) != vscodeAlt {
		t.Fatalf("vscode AuthPath not set to detected path: %q", found["vscode"].AuthPath)
	}
}

// Prompts
func TestPrompts(t *testing.T) {
	setHome(t)
	withStdin(t, "\nvalue\n", func() {
		// First call empty -> default, second -> value
		v1, err := promptString("Label", "def")
		if err != nil || v1 != "def" {
			t.Fatalf("promptString default failed: %v %q", err, v1)
		}
		v2, err := promptString("Label", "def")
		if err != nil || v2 != "value" {
			t.Fatalf("promptString value failed: %v %q", err, v2)
		}
	})
	withStdin(t, "\nYes\nno\n", func() {
		b1, _ := promptYesNo("Q", true)
		if !b1 {
			t.Fatalf("promptYesNo default true failed")
		}
		b2, _ := promptYesNo("Q", false)
		if !b2 {
			t.Fatalf("promptYesNo yes failed")
		}
		b3, _ := promptYesNo("Q", true)
		if b3 {
			t.Fatalf("promptYesNo no failed")
		}
	})
	withStdin(t, "2\n", func() {
		idx, err := promptChoice("Choose:", []string{"a", "b", "c"})
		if err != nil || idx != 1 {
			t.Fatalf("promptChoice failed: %v %d", err, idx)
		}
	})
}

// CLI helpers
func TestShortVersion(t *testing.T) {
	old := version
	defer func() { version = old }()
	version = "v1.2.3-4-gabcdef"
	if shortVersion() != "abcdef" {
		t.Fatalf("shortVersion git describe failed")
	}
	version = "v1.2.3-dirty"
	if shortVersion() != "v1.2.3" {
		t.Fatalf("shortVersion dirty strip failed: %q", shortVersion())
	}
}

func TestPrintHelpersAndWrappers(t *testing.T) {
	setHome(t)
	out, errOut := captureOutput(t, func() {
		printHelp()
		printError(fmt.Errorf("boom"))
	})
	if !strings.Contains(out, "Switch - Universal Account Switcher") {
		t.Fatalf("printHelp out unexpected: %q", out)
	}
	if !strings.Contains(errOut, "boom") {
		t.Fatalf("printError err unexpected: %q", errOut)
	}

	// Wrappers
	home := os.Getenv("HOME")
	// prepare codex file for wrapper adds
	_ = os.MkdirAll(filepath.Join(home, ".codex"), 0755)
	_ = os.WriteFile(filepath.Join(home, ".codex", "auth.json"), []byte(`{"t":1}`), 0600)
	s, _ := NewSwitcher()
	if err := s.AddCodexAccount("wrap"); err != nil {
		t.Fatalf("AddCodexAccount: %v", err)
	}
	if err := s.SwitchCodexAccount("wrap"); err != nil {
		t.Fatalf("SwitchCodexAccount: %v", err)
	}
	// Should not panic
	s.ListCodexAccounts()
}

func TestHandleAdd_ZeroArgs_Cancelled(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	// Cause wizard to cancel (empty choice -> -1)
	withStdin(t, "\n", func() {
		if code := handleAdd(s, []string{}); code != 1 {
			t.Fatalf("expected cancel code 1, got %d", code)
		}
	})
}

// main() subprocess tests to cover exit paths
func TestMain_CLI_Subprocess(t *testing.T) {
	run := func(args []string, env map[string]string) (int, string) {
		cmd := exec.Command(os.Args[0], append([]string{"-test.run", "TestHelperProcess"}, args...)...)
		cmd.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
		for k, v := range env {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
		out, err := cmd.CombinedOutput()
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode(), string(out)
		}
		return 0, string(out)
	}

	// help
	if code, out := run([]string{"help"}, nil); code != 0 || !strings.Contains(out, "Usage:") {
		t.Fatalf("help code/out: %d %q", code, out)
	}
	// version subcommand (avoid -v to not collide with go test flags)
	if code, out := run([]string{"version"}, nil); code != 0 || len(strings.TrimSpace(out)) == 0 {
		t.Fatalf("version code/out: %d %q", code, out)
	}
	// default cycle with no config should error
	tmpHome := t.TempDir()
	if code, _ := run(nil, map[string]string{"HOME": tmpHome}); code == 0 {
		t.Fatalf("expected non-zero for empty default cycle")
	}
	// unknown app format -> error path
	if code, _ := run([]string{"codex", "add", "x", "y"}, nil); code != 1 {
		t.Fatalf("expected code 1 for bad format, got %d", code)
	}
}

// Helper process that actually invokes main() with provided args
func TestHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HELPER_PROCESS") != "1" {
		return
	}
	args := os.Args[3:] // after -test.run and TestHelperProcess
	if len(args) == 0 {
		os.Args = []string{"switch"}
	} else {
		os.Args = append([]string{"switch"}, args...)
	}
	main()
	os.Exit(0)
}

func TestRunDefaultCycle(t *testing.T) {
	home := setHome(t)
	authPath := setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": `{"token":"u1"}`, "u2": `{"token":"u2"}`})
	// prepare config file directly
	s := &Switcher{configPath: filepath.Join(home, ".switch.toml"), config: &Config{Default: DefaultConfig{Config: "codex"}, Apps: map[string]AppConfig{
		"codex": {Current: "u1", Accounts: []string{"u1", "u2"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"},
	}}}
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	code := runDefaultCycle()
	if code != 0 {
		t.Fatalf("runDefaultCycle exit code: %d", code)
	}
	bts, _ := os.ReadFile(authPath)
	if !strings.Contains(string(bts), "u2") {
		t.Fatalf("expected switched to u2, got %s", string(bts))
	}
}

func TestHandleAddAndListAndApp(t *testing.T) {
	home := setHome(t)
	setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": `{}`})
	s, _ := NewSwitcher()
	// handleAdd with one arg prompts for profile name
	out, _ := captureOutput(t, func() {
		withStdin(t, "bob\n", func() {
			if code := handleAdd(s, []string{"codex"}); code != 0 {
				t.Fatalf("handleAdd one-arg failed: %d", code)
			}
		})
	})
	if !strings.Contains(out, "Profile name") {
		t.Fatalf("handleAdd should prompt for profile name")
	}
	// handleAdd with two args (no prompt)
	if code := handleAdd(s, []string{"codex", "carol"}); code != 0 {
		t.Fatalf("handleAdd two-arg failed: %d", code)
	}
	// handleList
	out2, _ := captureOutput(t, func() { _ = handleList(s, []string{"codex"}) })
	if !strings.Contains(out2, "Codex") {
		t.Fatalf("handleList output unexpected: %q", out2)
	}
	// handleApp: list
	out3, _ := captureOutput(t, func() { _ = handleApp(s, "codex", []string{"list"}) })
	if !strings.Contains(out3, "Codex") {
		t.Fatalf("handleApp list output unexpected: %q", out3)
	}
	// handleApp: bad format -> returns 1
	if code := handleApp(s, "codex", []string{"add", "x", "y"}); code != 1 {
		t.Fatalf("handleApp bad format should return 1")
	}
}

func TestLoadConfig_ParseError(t *testing.T) {
	home := setHome(t)
	bad := filepath.Join(home, ".switch.toml")
	if err := os.WriteFile(bad, []byte("not=toml=here\n[apps\n"), 0644); err != nil {
		t.Fatal(err)
	}
	s := &Switcher{configPath: bad}
	if err := s.loadConfig(); err == nil {
		t.Fatalf("expected parse config error")
	}
}

func TestAddAccount_TemplateAuthMissing_Error(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	if err := s.AddAccount("codex", "x"); err == nil || !strings.Contains(err.Error(), "auth path not found") {
		t.Fatalf("expected auth path not found, got %v", err)
	}
}

func TestSwitchAccount_EmptyDelegatesToCycle(t *testing.T) {
	home := setHome(t)
	authPath := setupCodexFiles(t, home, `{"token":"a"}`, map[string]string{"a": "{}", "b": "{}"})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "a", Accounts: []string{"a", "b"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	if err := s.SwitchAccount("codex", ""); err != nil {
		t.Fatalf("SwitchAccount empty: %v", err)
	}
	bts, _ := os.ReadFile(authPath)
	if !strings.Contains(string(bts), "{}") {
		t.Fatalf("expected switched content from backup")
	}
}

func TestRunWizard_Existing_AddExisting_Cancel(t *testing.T) {
	home := setHome(t)
	_ = setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": "{}"})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "u1", Accounts: []string{"u1"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	inputs := strings.Join([]string{
		"1",  // choose existing app codex
		"p",  // new profile name
		"no", // cancel save
	}, "\n") + "\n"
	withStdin(t, inputs, func() {
		if err := s.RunWizard(); err == nil || !strings.Contains(err.Error(), "cancelled") {
			t.Fatalf("expected cancelled, got %v", err)
		}
	})
}

func TestRunWizard_Existing_AutoDetect_NoNew(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	// Add some existing app, but don't create any detectable paths
	s.SetAppConfig("codex", AppConfig{Current: "a", Accounts: []string{"a"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	withStdin(t, "2\n", func() {
		if err := s.RunWizard(); err != nil {
			t.Fatalf("expected nil when no new applications detected, got %v", err)
		}
	})
}

func TestRunWizard_Existing_ManualSetup_Success(t *testing.T) {
	home := setHome(t)
	// seed existing app to enter existing flow
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "a", Accounts: []string{"a"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	// Prepare a real config file for manual
	appDir := filepath.Join(home, ".xapp")
	if err := os.MkdirAll(appDir, 0755); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(appDir, "cfg.json")
	if err := os.WriteFile(cfg, []byte("{}"), 0644); err != nil {
		t.Fatal(err)
	}
	inputs := strings.Join([]string{
		"3",    // Manual setup
		"xapp", // Application name
		cfg,    // Config file path
		"",     // Accept default pattern
		"p0",   // Current profile name
		"",     // Save default yes
	}, "\n") + "\n"
	withStdin(t, inputs, func() {
		if err := s.RunWizard(); err != nil {
			t.Fatalf("RunWizard manual existing: %v", err)
		}
	})
	if _, ok := s.GetAppConfig("xapp"); !ok {
		t.Fatalf("xapp app not created")
	}
}

func TestHandleAdd_PromptError(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	old := stdinReader
	stdinReader = bufio.NewReader(badReader{})
	defer func() { stdinReader = old }()
	if code := handleAdd(s, []string{"codex"}); code != 1 {
		t.Fatalf("expected 1 on prompt error, got %d", code)
	}
}

func TestHandleApp_AddSubcommand_Success(t *testing.T) {
	home := setHome(t)
	authPath := setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": "{}"})
	_ = authPath
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "u1", Accounts: []string{"u1"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	if code := handleApp(s, "codex", []string{"add", "u2"}); code != 0 {
		t.Fatalf("expected 0 for add subcommand, got %d", code)
	}
}

func TestMain_CLI_Subprocess_ListAndAdd(t *testing.T) {
	run := func(args []string, env map[string]string) (int, string) {
		cmd := exec.Command(os.Args[0], append([]string{"-test.run", "TestHelperProcess"}, args...)...)
		cmd.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
		for k, v := range env {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
		out, err := cmd.CombinedOutput()
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode(), string(out)
		}
		return 0, string(out)
	}
	tmpHome := t.TempDir()
	// Prepare codex auth file
	_ = os.MkdirAll(filepath.Join(tmpHome, ".codex"), 0755)
	if err := os.WriteFile(filepath.Join(tmpHome, ".codex", "auth.json"), []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	// Seed config file
	cfg := &Config{Default: DefaultConfig{Config: "codex"}, Apps: map[string]AppConfig{"codex": {Current: "", Accounts: []string{}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"}}}
	// Write toml
	s := &Switcher{configPath: filepath.Join(tmpHome, ".switch.toml"), config: cfg}
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	// list
	if code, _ := run([]string{"list"}, map[string]string{"HOME": tmpHome}); code != 0 {
		t.Fatalf("list exit code: %d", code)
	}
	// add codex bob
	if code, out := run([]string{"add", "codex", "bob"}, map[string]string{"HOME": tmpHome}); code != 0 {
		t.Fatalf("add exit code: %d, out=%q", code, out)
	}
}

func TestSaveConfig_ErrorOnDirectoryPath(t *testing.T) {
	home := setHome(t)
	s, _ := NewSwitcher()
	// Point configPath to a directory so WriteFile fails
	dir := filepath.Join(home, "confdir")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	s.configPath = dir
	if err := s.saveConfig(); err == nil {
		t.Fatalf("expected error writing to directory path")
	}
}

type badReader struct{}

func (badReader) Read(p []byte) (int, error) { return 0, fmt.Errorf("read error") }

func TestPrompts_ErrorPaths(t *testing.T) {
	setHome(t)
	old := stdinReader
	stdinReader = bufio.NewReader(badReader{})
	defer func() { stdinReader = old }()
	if _, err := promptString("L", ""); err == nil {
		t.Fatalf("expected promptString error")
	}
	if _, err := promptYesNo("L", true); err == nil {
		t.Fatalf("expected promptYesNo error")
	}
	if _, err := promptChoice("T", []string{"a"}); err == nil {
		t.Fatalf("expected promptChoice error")
	}
}

func TestRunWizard_Cancel_NoApps(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	withStdin(t, "\n", func() {
		if err := s.RunWizard(); err == nil || !strings.Contains(err.Error(), "cancelled") {
			t.Fatalf("expected cancelled error, got %v", err)
		}
	})
}

func TestRunWizard_Cancel_WithExistingApps(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "a", Accounts: []string{"a"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	withStdin(t, "\n", func() {
		if err := s.RunWizard(); err == nil || !strings.Contains(err.Error(), "cancelled") {
			t.Fatalf("expected cancelled error, got %v", err)
		}
	})
}

func TestHandleAdd_UnknownAppError(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	if code := handleAdd(s, []string{"unknown", "p"}); code != 1 {
		t.Fatalf("expected 1 for unknown app, got %d", code)
	}
}

func TestHandleApp_SwitchSubcommand(t *testing.T) {
	home := setHome(t)
	_ = setupCodexFiles(t, home, `{"token":"a"}`, map[string]string{"a": "{}", "b": "{}"})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "a", Accounts: []string{"a", "b"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	if code := handleApp(s, "codex", []string{"b"}); code != 0 {
		t.Fatalf("expected 0 for switch subcommand, got %d", code)
	}
}

func TestCopyFile_MkdirAllError(t *testing.T) {
	setHome(t)
	base := t.TempDir()
	src := filepath.Join(base, "src.txt")
	if err := os.WriteFile(src, []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	// Create a file where a directory is expected
	badDir := filepath.Join(base, "notadir")
	if err := os.WriteFile(badDir, []byte("f"), 0644); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(badDir, "child", "dest.txt")
	if err := copyFile(src, dst); err == nil {
		t.Fatalf("expected error due to MkdirAll on file path")
	}
}

func TestCopyFolder_MkdirAllError(t *testing.T) {
	setHome(t)
	base := t.TempDir()
	src := filepath.Join(base, "srcd")
	if err := os.MkdirAll(filepath.Join(src, "sub"), 0755); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(base, "dstd")
	if err := os.MkdirAll(dst, 0755); err != nil {
		t.Fatal(err)
	}
	// Place a file where a directory should be created
	if err := os.WriteFile(filepath.Join(dst, "sub"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := copyFolder(src, dst); err == nil {
		t.Fatalf("expected error due to MkdirAll on existing file")
	}
}

func TestContentAndFileFolderEqual_Negatives(t *testing.T) {
	setHome(t)
	dir := t.TempDir()
	f := filepath.Join(dir, "f")
	d := filepath.Join(dir, "d")
	_ = os.WriteFile(f, []byte("x"), 0644)
	_ = os.MkdirAll(d, 0755)
	if contentEqual(f, d) {
		t.Fatalf("contentEqual should be false for file vs dir")
	}
	if fileEqual("/nope/a", "/nope/b") {
		t.Fatalf("fileEqual missing files should be false")
	}
	if folderEqual("/nope/a", d) {
		t.Fatalf("folderEqual missing should be false")
	}
}

func TestAddAccount_OverwriteYes(t *testing.T) {
	home := setHome(t)
	authPath := setupCodexFiles(t, home, `{"token":"NEW"}`, map[string]string{"alice": `{"token":"OLD"}`})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "alice", Accounts: []string{"alice"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	withStdin(t, "yes\n", func() {
		if err := s.AddAccount("codex", "alice"); err != nil {
			t.Fatalf("AddAccount overwrite: %v", err)
		}
	})
	// Switch file should now match current auth.json
	b1, _ := os.ReadFile(authPath)
	b2, _ := os.ReadFile(authPath + ".alice.switch")
	if string(b1) != string(b2) {
		t.Fatalf("overwrite did not copy current content")
	}
}

func TestAddAccount_NoTemplateError(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	if err := s.AddAccount("unknownapp", "p"); err == nil || !strings.Contains(err.Error(), "no configuration found") {
		t.Fatalf("expected no configuration found error, got %v", err)
	}
}

func TestSwitchAccount_SwitchFileNotFound(t *testing.T) {
	home := setHome(t)
	_ = setupCodexFiles(t, home, `{"t":1}`, map[string]string{})
	s, _ := NewSwitcher()
	// Configure an account that has no backup file present
	s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{"ghost"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	if err := s.SwitchAccount("codex", "ghost"); err == nil || !strings.Contains(err.Error(), "switch file not found") {
		t.Fatalf("expected switch file not found error, got %v", err)
	}
}

func TestCycleAccounts_NoAccounts_And_EmptyCurrent(t *testing.T) {
	home := setHome(t)
	_ = setupCodexFiles(t, home, `{"t":1}`, map[string]string{"a": "{}", "b": "{}"})
	s, _ := NewSwitcher()
	// No accounts
	s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.CycleAccounts("codex"); err == nil {
		t.Fatalf("expected error for no accounts")
	}
	// Empty current -> should pick first
	s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{"a", "b"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.CycleAccounts("codex"); err != nil {
		t.Fatalf("CycleAccounts empty current: %v", err)
	}
}

func TestFindCurrentAccount_None(t *testing.T) {
	home := setHome(t)
	_ = setupCodexFiles(t, home, `{"token":"main"}`, map[string]string{"a": "{}", "b": "{}"})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{"a", "b"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if cur := s.findCurrentAccount("codex"); cur != "" {
		t.Fatalf("expected none, got %q", cur)
	}
}

func TestFindCurrentAccount_MissingAuthPath(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{"a"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if got := s.findCurrentAccount("codex"); got != "" {
		t.Fatalf("expected empty current, got %q", got)
	}
}

func TestListAccounts_Variants(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	out, _ := captureOutput(t, func() { s.ListAccounts("nosuch") })
	if !strings.Contains(out, "No accounts configured for nosuch") {
		t.Fatalf("unexpected out: %q", out)
	}
	// Empty appName delegates to ListAllApps
	s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	out2, _ := captureOutput(t, func() { s.ListAccounts("") })
	if !strings.Contains(out2, "Configured applications:") && !strings.Contains(out2, "No applications configured") {
		t.Fatalf("expected list all apps output, got: %q", out2)
	}
}

func TestPromptChoice_InvalidThenValid(t *testing.T) {
	setHome(t)
	withStdin(t, "99\n2\n", func() {
		idx, err := promptChoice("Title:", []string{"a", "b"})
		if err != nil || idx != 1 {
			t.Fatalf("promptChoice retry failed: %v %d", err, idx)
		}
	})
}

func TestRunWizard_AutoDetect_NewApp(t *testing.T) {
	home := setHome(t)
	// Create detection for git
	gitCfg := filepath.Join(home, ".gitconfig")
	if err := os.WriteFile(gitCfg, []byte("[user]\nname = t"), 0644); err != nil {
		t.Fatal(err)
	}
	s, _ := NewSwitcher()
	// Seed with one existing app so we enter the "Add new profile" branch
	s.SetAppConfig("codex", AppConfig{Current: "c", Accounts: []string{"c"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	// Choose Auto-detect (2nd option), then pick first detected app, accept defaults, name profile p1, confirm save
	inputs := strings.Join([]string{
		"2",  // Choose Auto-detect new application
		"1",  // Pick first detected (git)
		"",   // Application name default
		"",   // Config path default
		"",   // Switch pattern default
		"p1", // Current profile name
		"",   // Save yes (default)
	}, "\n") + "\n"
	withStdin(t, inputs, func() {
		if err := s.RunWizard(); err != nil {
			t.Fatalf("RunWizard auto-detect: %v", err)
		}
	})
	if _, ok := s.GetAppConfig("git"); !ok {
		t.Fatalf("git app not created by wizard")
	}
}

func TestHandleAdd_TooManyArgs(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	if code := handleAdd(s, []string{"a", "b", "c"}); code != 1 {
		t.Fatalf("expected 1 for too many args, got %d", code)
	}
}

func TestHandleApp_Branches(t *testing.T) {
	setHome(t)
	s, _ := NewSwitcher()
	// No accounts cycle error
	s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if code := handleApp(s, "codex", []string{}); code != 1 {
		t.Fatalf("expected 1 for cycle error, got %d", code)
	}
	// add usage
	if code := handleApp(s, "codex", []string{"add"}); code != 1 {
		t.Fatalf("expected 1 for add usage, got %d", code)
	}
}

func TestHandleApp_CycleSuccess(t *testing.T) {
	home := setHome(t)
	_ = setupCodexFiles(t, home, `{"token":"a"}`, map[string]string{"a": "{}", "b": "{}"})
	s, _ := NewSwitcher()
	s.SetAppConfig("codex", AppConfig{Current: "a", Accounts: []string{"a", "b"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	if code := handleApp(s, "codex", []string{}); code != 0 {
		t.Fatalf("expected 0 for cycle success, got %d", code)
	}
}

func TestRunDefaultCycle_NoDefault(t *testing.T) {
	home := setHome(t)
	// Write config with empty default
	cfg := []byte("[default]\nconfig=\"\"\n\n[apps]\n")
	if err := os.WriteFile(filepath.Join(home, ".switch.toml"), cfg, 0644); err != nil {
		t.Fatal(err)
	}
	if code := runDefaultCycle(); code != 1 {
		t.Fatalf("expected non-zero code for no default")
	}
}

func TestRunDefaultCycle_DefaultAppMissing(t *testing.T) {
	home := setHome(t)
	// Write config with default but no apps
	cfg := &Config{Default: DefaultConfig{Config: "codex"}, Apps: map[string]AppConfig{}}
	s := &Switcher{configPath: filepath.Join(home, ".switch.toml"), config: cfg}
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	if code := runDefaultCycle(); code != 1 {
		t.Fatalf("expected error code when default app missing")
	}
}

func TestNewSwitcher_ConfigReadError(t *testing.T) {
	home := setHome(t)
	// Make ~/.switch.toml a directory so reading fails inside NewSwitcher->loadConfig
	if err := os.MkdirAll(filepath.Join(home, ".switch.toml"), 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := NewSwitcher(); err == nil {
		t.Fatalf("expected NewSwitcher to fail on unreadable config path")
	}
}

func TestRunDefaultCycle_NoAccountsInDefault(t *testing.T) {
	home := setHome(t)
	// prepare codex auth file so DetectApplications is irrelevant and CycleAccounts runs
	_ = os.MkdirAll(filepath.Join(home, ".codex"), 0755)
	_ = os.WriteFile(filepath.Join(home, ".codex", "auth.json"), []byte("{}"), 0600)
	cfg := &Config{Default: DefaultConfig{Config: "codex"}, Apps: map[string]AppConfig{
		"codex": {Current: "", Accounts: []string{}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"},
	}}
	s := &Switcher{configPath: filepath.Join(home, ".switch.toml"), config: cfg}
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	if code := runDefaultCycle(); code != 1 {
		t.Fatalf("expected 1 when default has no accounts, got %d", code)
	}
}

func TestMain_CLI_Subprocess_AppCommands(t *testing.T) {
	run := func(args []string, env map[string]string) (int, string) {
		cmd := exec.Command(os.Args[0], append([]string{"-test.run", "TestHelperProcess"}, args...)...)
		cmd.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")
		for k, v := range env {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
		out, err := cmd.CombinedOutput()
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode(), string(out)
		}
		return 0, string(out)
	}
	tmpHome := t.TempDir()
	// Prepare codex data and config
	_ = os.MkdirAll(filepath.Join(tmpHome, ".codex"), 0755)
	if err := os.WriteFile(filepath.Join(tmpHome, ".codex", "auth.json"), []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	cfg := &Config{Default: DefaultConfig{Config: "codex"}, Apps: map[string]AppConfig{"codex": {Current: "", Accounts: []string{}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"}}}
	s := &Switcher{configPath: filepath.Join(tmpHome, ".switch.toml"), config: cfg}
	if err := s.saveConfig(); err != nil {
		t.Fatal(err)
	}
	// list profiles for app via CLI default case
	if code, out := run([]string{"codex", "list"}, map[string]string{"HOME": tmpHome}); code != 0 || !strings.Contains(out, "Codex") {
		t.Fatalf("codex list failed: code=%d out=%q", code, out)
	}
	// add and then switch via CLI
	if code, out := run([]string{"codex", "add", "p1"}, map[string]string{"HOME": tmpHome}); code != 0 {
		t.Fatalf("codex add failed: %d %q", code, out)
	}
	if code, out := run([]string{"codex", "p1"}, map[string]string{"HOME": tmpHome}); code != 0 {
		t.Fatalf("codex switch failed: %d %q", code, out)
	}
}

func TestRunWizard_ManualFolder_DefaultPattern(t *testing.T) {
	home := setHome(t)
	// Create a folder as the "config path" so wizard chooses profiles/{name}.switch default pattern
	confDir := filepath.Join(home, ".confdir")
	if err := os.MkdirAll(confDir, 0755); err != nil {
		t.Fatal(err)
	}
	// Put a file inside the folder to be copied
	if err := os.WriteFile(filepath.Join(confDir, "a.txt"), []byte("data"), 0644); err != nil {
		t.Fatal(err)
	}
	s, _ := NewSwitcher()
	inputs := strings.Join([]string{
		"1",         // Other (manual setup)
		"folderapp", // app name
		confDir,     // folder path
		"",          // accept default pattern (profiles/{name}.switch)
		"p1",        // current profile
		"",          // save yes
		"",
	}, "\n") + "\n"
	withStdin(t, inputs, func() {
		if err := s.RunWizard(); err != nil {
			t.Fatalf("wizard folder: %v", err)
		}
	})
	app, ok := s.GetAppConfig("folderapp")
	if !ok {
		t.Fatalf("folderapp missing from config")
	}
	backup := resolveSwitchPattern(app.SwitchPattern, confDir, "p1")
	// Expect the file under profiles/{name}.switch/a.txt
	if _, err := os.Stat(filepath.Join(backup, "a.txt")); err != nil {
		t.Fatalf("expected copied file in backup dir: %v", err)
	}
}

func TestHandleAdd_ZeroArgs_Success(t *testing.T) {
	home := setHome(t)
	// Prepare a minimal config file to add
	if err := os.MkdirAll(filepath.Join(home, ".mapp"), 0755); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(home, ".mapp", "cfg.json")
	if err := os.WriteFile(cfg, []byte("{}"), 0644); err != nil {
		t.Fatal(err)
	}
	s, _ := NewSwitcher()
	inputs := strings.Join([]string{
		"1",    // manual setup
		"mapp", // app name
		cfg,    // config file
		"",     // pattern default
		"p0",   // profile
		"",     // save yes
		"",
	}, "\n") + "\n"
	code := 1
	withStdin(t, inputs, func() { code = handleAdd(s, []string{}) })
	if code != 0 {
		t.Fatalf("expected handleAdd success, got %d", code)
	}
}
