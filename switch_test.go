package main

import (
    "bufio"
    "io"
    "os"
    "path/filepath"
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
    done := make(chan struct{})
    var outBuf, errBuf strings.Builder
    go func() {
        io.Copy(&outBuf, rOut)
        close(done)
    }()
    go func() { io.Copy(&errBuf, rErr) }()
    fn()
    wOut.Close()
    wErr.Close()
    <-done
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

func TestCopyFileFolderAndPath(t *testing.T) {
    setHome(t)
    base := t.TempDir()
    // file copy
    src := filepath.Join(base, "a.txt")
    dst := filepath.Join(base, "b.txt")
    os.WriteFile(src, []byte("hello"), 0644)
    if err := copyFile(src, dst); err != nil { t.Fatalf("copyFile: %v", err) }
    b, _ := os.ReadFile(dst)
    if string(b) != "hello" { t.Fatalf("file content mismatch: %q", string(b)) }
    // folder copy via copyPath
    dsrc := filepath.Join(base, "dirsrc")
    ddst := filepath.Join(base, "dirdst")
    os.MkdirAll(filepath.Join(dsrc, "nested"), 0755)
    os.WriteFile(filepath.Join(dsrc, "nested", "f.txt"), []byte("x"), 0644)
    if err := copyPath(dsrc, ddst); err != nil { t.Fatalf("copyPath folder: %v", err) }
    if _, err := os.Stat(filepath.Join(ddst, "nested", "f.txt")); err != nil { t.Fatalf("copied file missing: %v", err) }
}

func TestEqualFunctions(t *testing.T) {
    setHome(t)
    dir := t.TempDir()
    // fileEqual with JSON order-insensitive via jsonEqual
    f1 := filepath.Join(dir, "a.json")
    f2 := filepath.Join(dir, "b.json")
    os.WriteFile(f1, []byte(`{"k":1, "z":2}`), 0644)
    os.WriteFile(f2, []byte(`{"z":2, "k":1}`), 0644)
    if !fileEqual(f1, f2) { t.Errorf("fileEqual json should be true") }
    // fileEqual plain text
    t1 := filepath.Join(dir, "a.txt")
    t2 := filepath.Join(dir, "b.txt")
    os.WriteFile(t1, []byte("abc"), 0644)
    os.WriteFile(t2, []byte("abc"), 0644)
    if !fileEqual(t1, t2) { t.Errorf("fileEqual text should be true") }
    // folderEqual only checks both are directories
    d1 := filepath.Join(dir, "d1")
    d2 := filepath.Join(dir, "d2")
    os.MkdirAll(d1, 0755)
    os.MkdirAll(d2, 0755)
    if !folderEqual(d1, d2) { t.Errorf("folderEqual should be true for dirs") }
    // contentEqual delegates
    if !contentEqual(t1, t2) { t.Errorf("contentEqual files should be true") }
    if !contentEqual(d1, d2) { t.Errorf("contentEqual dirs should be true") }
}

// Switcher core APIs
func TestGetSetAppConfig(t *testing.T) {
    setHome(t)
    s, _ := NewSwitcher()
    _, ok := s.GetAppConfig("codex")
    if ok { t.Fatalf("expected no codex app yet") }
    cfg := AppConfig{Current: "", Accounts: []string{}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"}
    s.SetAppConfig("codex", cfg)
    c2, ok := s.GetAppConfig("codex")
    if !ok || c2.AuthPath != cfg.AuthPath { t.Fatalf("Get/Set mismatch") }
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
    if err := s.AddAccount("codex", "alice"); err != nil { t.Fatalf("AddAccount: %v", err) }
    // switch file created and config updated
    if _, err := os.Stat(authPath+".alice.switch"); err != nil { t.Fatalf("switch backup missing: %v", err) }
    app, ok := s.GetAppConfig("codex")
    if !ok { t.Fatalf("app not set") }
    if app.Current != "alice" || !contains(app.Accounts, "alice") { t.Fatalf("config not updated correctly: %+v", app) }
}

func TestAddAccount_Duplicate_NoOverwrite(t *testing.T) {
    home := setHome(t)
    authPath := setupCodexFiles(t, home, `{"token":"orig"}`, map[string]string{"alice": `{"token":"old"}`})
    s, _ := NewSwitcher()
    // Seed app config to trigger duplicate prompt
    s.SetAppConfig("codex", AppConfig{Current: "alice", Accounts: []string{"alice"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
    if err := s.saveConfig(); err != nil { t.Fatal(err) }
    withStdin(t, "no\n", func() {
        if err := s.AddAccount("codex", "alice"); err == nil { t.Fatalf("expected cancellation error") }
    })
    // ensure file unchanged
    b, _ := os.ReadFile(authPath+".alice.switch")
    if !strings.Contains(string(b), "old") { t.Fatalf("switch file should remain old, got: %s", string(b)) }
}

func TestSwitchAccount_Success(t *testing.T) {
    home := setHome(t)
    authPath := setupCodexFiles(t, home, `{"token":"a"}`, map[string]string{"a": `{"token":"a"}`, "b": `{"token":"b"}`})
    s, _ := NewSwitcher()
    s.SetAppConfig("codex", AppConfig{Current: "a", Accounts: []string{"a", "b"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
    if err := s.saveConfig(); err != nil { t.Fatal(err) }
    if err := s.SwitchAccount("codex", "b"); err != nil { t.Fatalf("SwitchAccount: %v", err) }
    bts, _ := os.ReadFile(authPath)
    if !strings.Contains(string(bts), "b") { t.Fatalf("auth not switched: %s", string(bts)) }
}

func TestSwitchAccount_NotFound(t *testing.T) {
    setHome(t)
    s, _ := NewSwitcher()
    s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{"a"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
    if err := s.SwitchAccount("codex", "missing"); err == nil { t.Fatalf("expected error for missing account") }
}

func TestCycleAccounts(t *testing.T) {
    home := setHome(t)
    authPath := setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": `{"token":"u1"}`, "u2": `{"token":"u2"}`, "u3": `{"token":"u3"}`})
    s, _ := NewSwitcher()
    s.SetAppConfig("codex", AppConfig{Current: "u1", Accounts: []string{"u1","u2","u3"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
    if err := s.saveConfig(); err != nil { t.Fatal(err) }
    // First cycle -> u2
    if err := s.CycleAccounts("codex"); err != nil { t.Fatalf("CycleAccounts: %v", err) }
    bts, _ := os.ReadFile(authPath)
    if !strings.Contains(string(bts), "u2") { t.Fatalf("expected u2, got %s", string(bts)) }
    // Second cycle -> u3
    if err := s.CycleAccounts("codex"); err != nil { t.Fatalf("CycleAccounts: %v", err) }
    bts, _ = os.ReadFile(authPath)
    if !strings.Contains(string(bts), "u3") { t.Fatalf("expected u3, got %s", string(bts)) }
    // Third cycle -> u1
    if err := s.CycleAccounts("codex"); err != nil { t.Fatalf("CycleAccounts: %v", err) }
    bts, _ = os.ReadFile(authPath)
    if !strings.Contains(string(bts), "u1") { t.Fatalf("expected u1, got %s", string(bts)) }
}

func TestFindCurrentAccount(t *testing.T) {
    home := setHome(t)
    setupCodexFiles(t, home, `{"token":"u2data"}`, map[string]string{"u1": `{"token":"u1data"}`, "u2": `{"token":"u2data"}`})
    s, _ := NewSwitcher()
    s.SetAppConfig("codex", AppConfig{Current: "", Accounts: []string{"u1","u2"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
    cur := s.findCurrentAccount("codex")
    if cur != "u2" { t.Fatalf("expected current u2, got %q", cur) }
}

// Listing and detection
func TestListAccountsAndAllApps(t *testing.T) {
    home := setHome(t)
    setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": `{"token":"u1"}`, "u2": `{"token":"u2"}`})
    s, _ := NewSwitcher()
    s.SetAppConfig("codex", AppConfig{Current: "u1", Accounts: []string{"u1","u2"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"})
    s.config.Default.Config = "codex"
    if err := s.saveConfig(); err != nil { t.Fatal(err) }
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
    if _, ok := found["claude"]; !ok { t.Fatalf("claude not detected") }
    if _, ok := found["vscode"]; !ok { t.Fatalf("vscode not detected") }
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
        if err != nil || v1 != "def" { t.Fatalf("promptString default failed: %v %q", err, v1) }
        v2, err := promptString("Label", "def")
        if err != nil || v2 != "value" { t.Fatalf("promptString value failed: %v %q", err, v2) }
    })
    withStdin(t, "\nYes\nno\n", func() {
        b1, _ := promptYesNo("Q", true)
        if !b1 { t.Fatalf("promptYesNo default true failed") }
        b2, _ := promptYesNo("Q", false)
        if !b2 { t.Fatalf("promptYesNo yes failed") }
        b3, _ := promptYesNo("Q", true)
        if b3 { t.Fatalf("promptYesNo no failed") }
    })
    withStdin(t, "2\n", func() {
        idx, err := promptChoice("Choose:", []string{"a","b","c"})
        if err != nil || idx != 1 { t.Fatalf("promptChoice failed: %v %d", err, idx) }
    })
}

// CLI helpers
func TestShortVersion(t *testing.T) {
    old := version
    defer func() { version = old }()
    version = "v1.2.3-4-gabcdef"
    if shortVersion() != "abcdef" { t.Fatalf("shortVersion git describe failed") }
    version = "v1.2.3-dirty"
    if shortVersion() != "v1.2.3" { t.Fatalf("shortVersion dirty strip failed: %q", shortVersion()) }
}

func TestRunDefaultCycle(t *testing.T) {
    home := setHome(t)
    authPath := setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": `{"token":"u1"}`, "u2": `{"token":"u2"}`})
    // prepare config file directly
    s := &Switcher{configPath: filepath.Join(home, ".switch.toml"), config: &Config{Default: DefaultConfig{Config: "codex"}, Apps: map[string]AppConfig{
        "codex": {Current: "u1", Accounts: []string{"u1","u2"}, AuthPath: "~/.codex/auth.json", SwitchPattern: "{auth_path}.{name}.switch"},
    }}}
    if err := s.saveConfig(); err != nil { t.Fatal(err) }
    code := runDefaultCycle()
    if code != 0 { t.Fatalf("runDefaultCycle exit code: %d", code) }
    bts, _ := os.ReadFile(authPath)
    if !strings.Contains(string(bts), "u2") { t.Fatalf("expected switched to u2, got %s", string(bts)) }
}

func TestHandleAddAndListAndApp(t *testing.T) {
    home := setHome(t)
    setupCodexFiles(t, home, `{"token":"u1"}`, map[string]string{"u1": `{}`})
    s, _ := NewSwitcher()
    // handleAdd with one arg prompts for profile name
    out, _ := captureOutput(t, func() {
        withStdin(t, "bob\n", func() {
            if code := handleAdd(s, []string{"codex"}); code != 0 { t.Fatalf("handleAdd one-arg failed: %d", code) }
        })
    })
    if !strings.Contains(out, "Profile name") { t.Fatalf("handleAdd should prompt for profile name") }
    // handleAdd with two args (no prompt)
    if code := handleAdd(s, []string{"codex","carol"}); code != 0 { t.Fatalf("handleAdd two-arg failed: %d", code) }
    // handleList
    out2, _ := captureOutput(t, func() { _ = handleList(s, []string{"codex"}) })
    if !strings.Contains(out2, "Codex") { t.Fatalf("handleList output unexpected: %q", out2) }
    // handleApp: list
    out3, _ := captureOutput(t, func() { _ = handleApp(s, "codex", []string{"list"}) })
    if !strings.Contains(out3, "Codex") { t.Fatalf("handleApp list output unexpected: %q", out3) }
    // handleApp: bad format -> returns 1
    if code := handleApp(s, "codex", []string{"add", "x", "y"}); code != 1 { t.Fatalf("handleApp bad format should return 1") }
}
