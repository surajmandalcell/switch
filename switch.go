package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"

	"github.com/BurntSushi/toml"
)

const (
	ColorReset  = "\033[0m"
	ColorRed    = "\033[31m"
	ColorGreen  = "\033[32m"
	ColorYellow = "\033[33m"
	ColorBlue   = "\033[34m"
	ColorCyan   = "\033[36m"
)

var version = "1.0.2"

type Config struct {
	Default DefaultConfig        `toml:"default"`
	Apps    map[string]AppConfig `toml:"apps"`
}

type DefaultConfig struct {
	Config string `toml:"config"`
}

type AppConfig struct {
	Current       string   `toml:"current"`
	Accounts      []string `toml:"accounts"`
	AuthPath      string   `toml:"auth_path"`
	SwitchPattern string   `toml:"switch_pattern"`
}

type AppTemplate struct {
	DetectPaths []string
	AuthPath    string
	Pattern     string
	Description string
}

type Switcher struct {
	configPath string
	config     *Config
}

var stdinReader = bufio.NewReader(os.Stdin)

var AppTemplates = map[string]AppTemplate{
	"codex": {
		DetectPaths: []string{"~/.codex/auth.json"},
		AuthPath:    "~/.codex/auth.json",
		Pattern:     "{auth_path}.{name}.switch",
		Description: "Codex authentication file",
	},
	"claude": {
		DetectPaths: []string{"~/.claude/config.json"},
		AuthPath:    "~/.claude/config.json",
		Pattern:     "{auth_path}.{name}.switch",
		Description: "Claude configuration file",
	},
	"vscode": {
		DetectPaths: []string{"~/.vscode/User", "~/Library/Application Support/Code/User"},
		AuthPath:    "~/.vscode/User",
		Pattern:     "~/.vscode/profiles/{name}.switch",
		Description: "VSCode user settings folder",
	},
	"cursor": {
		DetectPaths: []string{"~/.cursor", "~/Library/Application Support/Cursor"},
		AuthPath:    "~/.cursor",
		Pattern:     "~/.cursor/profiles/{name}.switch",
		Description: "Cursor configuration folder",
	},
	"ssh": {
		DetectPaths: []string{"~/.ssh"},
		AuthPath:    "~/.ssh",
		Pattern:     "~/.ssh/profiles/{name}.switch",
		Description: "SSH configuration folder",
	},
	"git": {
		DetectPaths: []string{"~/.gitconfig"},
		AuthPath:    "~/.gitconfig",
		Pattern:     "{auth_path}.{name}.switch",
		Description: "Git configuration file",
	},
}

// getHomeDir returns the user's home directory, respecting environment variables.
// This is needed because os.UserHomeDir() on Windows uses the Windows API which
// ignores environment variable changes (like those made in tests with t.Setenv).
func getHomeDir() (string, error) {
	// First check environment variables
	if runtime.GOOS == "windows" {
		// On Windows, check USERPROFILE first, then HOME
		if home := os.Getenv("USERPROFILE"); home != "" {
			return home, nil
		}
	}
	if home := os.Getenv("HOME"); home != "" {
		return home, nil
	}
	// Fall back to os.UserHomeDir() if no env vars are set
	return os.UserHomeDir()
}

func NewSwitcher() (*Switcher, error) {
	home, err := getHomeDir()
	if err != nil {
		return nil, fmt.Errorf("get home dir: %w", err)
	}
	configPath := filepath.Join(home, ".switch.toml")
	s := &Switcher{configPath: configPath}
	if err := s.loadConfig(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Switcher) loadConfig() error {
	data, err := os.ReadFile(s.configPath)
	if err != nil {
		if os.IsNotExist(err) {
			s.config = &Config{
				Default: DefaultConfig{Config: "codex"},
				Apps:    make(map[string]AppConfig),
			}
			return s.saveConfig()
		}
		return fmt.Errorf("read config: %w", err)
	}
	s.config = &Config{}
	if err := toml.Unmarshal(data, s.config); err != nil {
		return fmt.Errorf("parse config: %w", err)
	}
	if s.config.Apps == nil {
		s.config.Apps = make(map[string]AppConfig)
	}
	return nil
}

func (s *Switcher) saveConfig() error {
	file, err := os.Create(s.configPath)
	if err != nil {
		return fmt.Errorf("create config: %w", err)
	}
	defer file.Close()
	encoder := toml.NewEncoder(file)
	return encoder.Encode(s.config)
}

// Utility functions
// expandPath expands a leading ~, ~/ or ~\\ to the user's home directory
// and normalizes any Windows-style backslashes to forward slashes for
// consistent cross-platform behavior. Returned paths with forward slashes
// are still accepted by Go's file APIs on Windows.
func expandPath(p string) string {
	if p == "" {
		return p
	}
	// Normalize any backslashes to forward slashes first
	// so we can treat separators uniformly across platforms.
	p = strings.ReplaceAll(p, "\\", "/")

	if strings.HasPrefix(p, "~") {
		home, _ := getHomeDir()
		switch {
		case p == "~":
			p = home
		case strings.HasPrefix(p, "~/"):
			p = filepath.Join(home, p[2:])
		default:
			// Unsupported forms like ~user – just fall back to replacing the tilde
			// with home if the next char is a path separator (already handled),
			// otherwise leave as-is.
		}
	}
	// Clean the path and convert to forward slashes for stable comparisons
	// while remaining valid for OS operations.
	p = filepath.Clean(p)
	return filepath.ToSlash(p)
}

func fileOrDirExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func isFolder(path string) bool {
	stat, err := os.Stat(path)
	return err == nil && stat.IsDir()
}

func resolveSwitchPattern(pattern, authPath, name string) string {
	resolved := strings.ReplaceAll(pattern, "{auth_path}", authPath)
	resolved = strings.ReplaceAll(resolved, "{name}", name)
	// Support patterns that use backslashes as separators
	resolved = strings.ReplaceAll(resolved, "\\", "/")
	// Expand ~ and normalize to slash form
	return expandPath(resolved)
}

// File and folder operations
func copyPath(src, dst string) error {
	if isFolder(src) {
		return copyFolder(src, dst)
	}
	return copyFile(src, dst)
}

func copyFile(src, dst string) error {
	srcInfo, err := os.Stat(src)
	if err != nil {
		return err
	}
	perm := srcInfo.Mode().Perm()
	source, err := os.Open(src)
	if err != nil {
		return err
	}
	defer source.Close()

	dstDir := filepath.Dir(dst)
	if err := os.MkdirAll(dstDir, 0755); err != nil {
		return err
	}

	destination, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	defer destination.Close()

	_, err = io.Copy(destination, source)
	if err != nil {
		return err
	}
	return os.Chmod(dst, perm)
}

func copyFolder(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		relPath, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		dstPath := filepath.Join(dst, relPath)

		if info.IsDir() {
			if err := os.MkdirAll(dstPath, info.Mode().Perm()); err != nil {
				return err
			}
			return os.Chmod(dstPath, info.Mode().Perm())
		}
		return copyFile(path, dstPath)
	})
}

func contentEqual(a, b string) bool {
	if isFolder(a) && isFolder(b) {
		return folderEqual(a, b)
	} else if !isFolder(a) && !isFolder(b) {
		return fileEqual(a, b)
	}
	return false
}

func fileEqual(a, b string) bool {
	aData, err := os.ReadFile(a)
	if err != nil {
		return false
	}
	bData, err := os.ReadFile(b)
	if err != nil {
		return false
	}

	var aJSON, bJSON map[string]interface{}
	if json.Unmarshal(aData, &aJSON) == nil && json.Unmarshal(bData, &bJSON) == nil {
		return jsonEqual(aJSON, bJSON)
	}

	return string(aData) == string(bData)
}

func folderEqual(a, b string) bool {
	aInfo, aErr := os.Stat(a)
	bInfo, bErr := os.Stat(b)
	if aErr != nil || bErr != nil {
		return false
	}
	return aInfo.IsDir() && bInfo.IsDir()
}

func jsonEqual(a, b map[string]interface{}) bool {
	aBytes, _ := json.Marshal(a)
	bBytes, _ := json.Marshal(b)
	return string(aBytes) == string(bBytes)
}

// Application-agnostic functions
func (s *Switcher) GetAppConfig(appName string) (AppConfig, bool) {
	config, exists := s.config.Apps[appName]
	return config, exists
}

func (s *Switcher) SetAppConfig(appName string, config AppConfig) {
	s.config.Apps[appName] = config
}

func (s *Switcher) AddAccount(appName, accountName string) error {
	appConfig, exists := s.GetAppConfig(appName)
	if !exists {
		template, hasTemplate := AppTemplates[appName]
		if !hasTemplate {
			return fmt.Errorf("no configuration found for app '%s'", appName)
		}

		authPath := expandPath(template.AuthPath)
		if _, err := os.Stat(authPath); err != nil {
			return fmt.Errorf("auth path not found: %s", authPath)
		}

		appConfig = AppConfig{
			Current:       "",
			Accounts:      []string{},
			AuthPath:      template.AuthPath,
			SwitchPattern: template.Pattern,
		}
	}

	authPath := expandPath(appConfig.AuthPath)
	switchPath := resolveSwitchPattern(appConfig.SwitchPattern, authPath, accountName)

	for _, acc := range appConfig.Accounts {
		if acc == accountName {
			fmt.Printf("%s✗ Account '%s' already exists for %s%s\n", ColorRed, accountName, appName, ColorReset)
			fmt.Printf("Overwrite? (yes/no): ")
			response, _ := stdinReader.ReadString('\n')
			response = strings.TrimSpace(strings.ToLower(response))
			if response != "yes" && response != "y" {
				fmt.Printf("%sCancelled%s\n", ColorYellow, ColorReset)
				return fmt.Errorf("cancelled by user")
			}
			break
		}
	}

	if err := copyPath(authPath, switchPath); err != nil {
		return fmt.Errorf("copy config: %w", err)
	}

	if !contains(appConfig.Accounts, accountName) {
		appConfig.Accounts = append(appConfig.Accounts, accountName)
		sort.Strings(appConfig.Accounts)
	}
	if appConfig.Current == "" {
		appConfig.Current = accountName
	}

	s.SetAppConfig(appName, appConfig)
	if err := s.saveConfig(); err != nil {
		os.RemoveAll(switchPath)
		return err
	}

	fmt.Printf("%s✓ Added account: %s for %s%s\n", ColorGreen, accountName, appName, ColorReset)
	return nil
}

func (s *Switcher) SwitchAccount(appName, accountName string) error {
	appConfig, exists := s.GetAppConfig(appName)
	if !exists {
		return fmt.Errorf("no configuration found for app '%s'", appName)
	}

	if accountName == "" {
		return s.CycleAccounts(appName)
	}

	if !contains(appConfig.Accounts, accountName) {
		return fmt.Errorf("account '%s' not found for %s", accountName, appName)
	}

	authPath := expandPath(appConfig.AuthPath)
	switchPath := resolveSwitchPattern(appConfig.SwitchPattern, authPath, accountName)

	if _, err := os.Stat(switchPath); err != nil {
		return fmt.Errorf("switch file not found: %s", switchPath)
	}

	currentAccount := s.findCurrentAccount(appName)
	if currentAccount != "" && currentAccount != accountName {
		currentSwitchPath := resolveSwitchPattern(appConfig.SwitchPattern, authPath, currentAccount)
		copyPath(authPath, currentSwitchPath)
	}

	if err := copyPath(switchPath, authPath); err != nil {
		return fmt.Errorf("switch config: %w", err)
	}

	appConfig.Current = accountName
	s.SetAppConfig(appName, appConfig)
	s.saveConfig()

	if currentAccount != "" && currentAccount != accountName {
		fmt.Printf("%s✓ %s account switched from %s to %s!%s\n",
			ColorGreen, strings.Title(appName), currentAccount, accountName, ColorReset)
	} else {
		fmt.Printf("%s✓ Switched to: %s%s\n", ColorGreen, accountName, ColorReset)
	}
	return nil
}

func (s *Switcher) CycleAccounts(appName string) error {
	appConfig, exists := s.GetAppConfig(appName)
	if !exists {
		return fmt.Errorf("no configuration found for app '%s'", appName)
	}

	if len(appConfig.Accounts) == 0 {
		fmt.Printf("%s✗ No accounts configured for %s%s\n", ColorRed, appName, ColorReset)
		fmt.Printf("Run 'switch %s add <name>' to add your first account\n", appName)
		return fmt.Errorf("no accounts")
	}

	current := s.findCurrentAccount(appName)
	var next string

	if current == "" {
		next = appConfig.Accounts[0]
	} else {
		for i, acc := range appConfig.Accounts {
			if acc == current {
				next = appConfig.Accounts[(i+1)%len(appConfig.Accounts)]
				break
			}
		}
		if next == "" {
			next = appConfig.Accounts[0]
		}
	}
	return s.SwitchAccount(appName, next)
}

func (s *Switcher) findCurrentAccount(appName string) string {
	appConfig, exists := s.GetAppConfig(appName)
	if !exists {
		return ""
	}

	authPath := expandPath(appConfig.AuthPath)
	if _, err := os.Stat(authPath); err != nil {
		return ""
	}

	for _, accountName := range appConfig.Accounts {
		switchPath := resolveSwitchPattern(appConfig.SwitchPattern, authPath, accountName)
		if _, err := os.Stat(switchPath); err != nil {
			continue
		}
		if contentEqual(authPath, switchPath) {
			return accountName
		}
	}
	return ""
}

func (s *Switcher) ListAccounts(appName string) {
	if appName == "" {
		s.ListAllApps()
		return
	}

	appConfig, exists := s.GetAppConfig(appName)
	if !exists {
		fmt.Printf("%s✗ No accounts configured for %s%s\n", ColorRed, appName, ColorReset)
		fmt.Printf("Run 'switch %s add <name>' to add your first account\n", appName)
		return
	}

	current := s.findCurrentAccount(appName)
	fmt.Printf("%s%s accounts:%s\n", ColorCyan, strings.Title(appName), ColorReset)
	for _, acc := range appConfig.Accounts {
		if acc == current {
			fmt.Printf("  %s●%s %s %s(current)%s\n", ColorGreen, ColorReset, acc, ColorYellow, ColorReset)
		} else {
			fmt.Printf("  ○ %s\n", acc)
		}
	}
}

func (s *Switcher) ListAllApps() {
	if len(s.config.Apps) == 0 {
		fmt.Printf("%s✗ No applications configured%s\n", ColorRed, ColorReset)
		fmt.Printf("Run 'switch add' to set up your first application\n")
		return
	}

	fmt.Printf("%sConfigured applications:%s\n", ColorCyan, ColorReset)
	for appName, appConfig := range s.config.Apps {
		current := s.findCurrentAccount(appName)
		accountCount := len(appConfig.Accounts)

		if appName == s.config.Default.Config {
			fmt.Printf("  %s●%s %s (%d accounts) %s(default)%s", ColorGreen, ColorReset, appName, accountCount, ColorYellow, ColorReset)
		} else {
			fmt.Printf("  ○ %s (%d accounts)", appName, accountCount)
		}

		if current != "" {
			fmt.Printf(" - current: %s", current)
		}
		fmt.Printf("\n")
	}
}

func (s *Switcher) SetDefaultApp(appName string) error {
	_, exists := s.GetAppConfig(appName)
	if !exists {
		return fmt.Errorf("app '%s' not found", appName)
	}

	oldDefault := s.config.Default.Config
	s.config.Default.Config = appName
	if err := s.saveConfig(); err != nil {
		return fmt.Errorf("save config: %w", err)
	}

	if oldDefault != "" {
		fmt.Printf("%s✓ Default app changed from %s to %s%s\n", ColorGreen, oldDefault, appName, ColorReset)
	} else {
		fmt.Printf("%s✓ Default app set to %s%s\n", ColorGreen, appName, ColorReset)
	}
	return nil
}

func (s *Switcher) OpenConfig() error {
	editor := os.Getenv("EDITOR")
	if editor == "" {
		// Try common editors
		for _, e := range []string{"nano", "vi", "vim", "code", "gedit"} {
			if _, err := exec.LookPath(e); err == nil {
				editor = e
				break
			}
		}
	}
	if editor == "" {
		return fmt.Errorf("no text editor found. Set EDITOR environment variable or install nano/vim/code")
	}

	cmd := exec.Command(editor, s.configPath)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// App detection based on templates
func DetectApplications() map[string]AppTemplate {
	found := make(map[string]AppTemplate)
	for name, tpl := range AppTemplates {
		for _, p := range tpl.DetectPaths {
			p = expandPath(p)
			if fileOrDirExists(p) {
				t := tpl
				t.AuthPath = tpl.AuthPath
				if !fileOrDirExists(expandPath(tpl.AuthPath)) {
					t.AuthPath = p
				}
				found[name] = t
				break
			}
		}
	}
	return found
}

// Simple interactive prompts
func promptString(label string, defaultVal string) (string, error) {
	if defaultVal != "" {
		fmt.Printf("%s (%s): ", label, defaultVal)
	} else {
		fmt.Printf("%s: ", label)
	}
	input, err := stdinReader.ReadString('\n')
	if err != nil {
		return "", err
	}
	input = strings.TrimSpace(input)
	if input == "" {
		return defaultVal, nil
	}
	return input, nil
}

func promptYesNo(label string, defaultYes bool) (bool, error) {
	def := "y/N"
	if defaultYes {
		def = "Y/n"
	}
	fmt.Printf("%s (%s): ", label, def)
	input, err := stdinReader.ReadString('\n')
	if err != nil {
		return false, err
	}
	input = strings.TrimSpace(strings.ToLower(input))
	if input == "" {
		return defaultYes, nil
	}
	return input == "y" || input == "yes", nil
}

func promptChoice(title string, options []string) (int, error) {
	fmt.Println(title)
	for i, opt := range options {
		fmt.Printf("  %d. %s\n", i+1, opt)
	}
	for {
		fmt.Printf("Choose (1-%d): ", len(options))
		line, err := stdinReader.ReadString('\n')
		if err != nil {
			return -1, err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			return -1, nil
		}
		var idx int
		_, err = fmt.Sscanf(line, "%d", &idx)
		if err == nil && idx >= 1 && idx <= len(options) {
			return idx - 1, nil
		}
		fmt.Println("Invalid choice, try again.")
	}
}

// Interactive setup wizard
func (s *Switcher) RunWizard() error {
	hasApps := len(s.config.Apps) > 0

	if !hasApps {
		fmt.Println("\n┌─ Switch Setup Wizard ─────────────────────────────────────┐")
		fmt.Println("│ 🚀 Welcome to Switch! Let's set up your first profile.   │")
		fmt.Println("└───────────────────────────────────────────────────────────┘")
		fmt.Println()

		detected := DetectApplications()
		var keys []string
		for name := range detected {
			keys = append(keys, name)
		}
		sort.Strings(keys)
		var options []string
		for _, k := range keys {
			d := detected[k]
			path := expandPath(d.AuthPath)
			kind := "File"
			if isFolder(path) {
				kind = "Folder"
			}
			options = append(options, fmt.Sprintf("%s      %s  [%s]", strings.Title(k), path, kind))
		}
		options = append(options, "Other (manual setup)")

		idx, err := promptChoice("Available applications:", options)
		if err != nil {
			return err
		}
		if idx == -1 {
			return fmt.Errorf("cancelled")
		}

		var appName string
		var authPath string
		var pattern string
		if idx == len(options)-1 {
			appName, err = promptString("Application name", "")
			if err != nil {
				return err
			}
			authPath, err = promptString("Config file/folder path", "")
			if err != nil {
				return err
			}
			var defPattern string
			if strings.Contains(filepath.Base(authPath), ".") {
				defPattern = "{auth_path}.{name}.switch"
			} else {
				defPattern = filepath.Join(filepath.Dir(authPath), "profiles", "{name}.switch")
			}
			pattern, err = promptString("Switch pattern", defPattern)
			if err != nil {
				return err
			}
		} else {
			key := keys[idx]
			tpl := detected[key]
			appName, err = promptString("Application name", key)
			if err != nil {
				return err
			}
			authPath, err = promptString("Config path", tpl.AuthPath)
			if err != nil {
				return err
			}
			pattern, err = promptString("Switch pattern", tpl.Pattern)
			if err != nil {
				return err
			}
		}
		appName = strings.ToLower(strings.TrimSpace(appName))
		authPath = expandPath(strings.TrimSpace(authPath))
		profile, err := promptString("Current profile/account name", "")
		if err != nil {
			return err
		}
		profile = strings.TrimSpace(profile)

		fmt.Println("\nSummary:")
		fmt.Printf("  App:         %s\n", appName)
		fmt.Printf("  Profile:     %s\n", profile)
		fmt.Printf("  Config path: %s\n", authPath)
		fmt.Printf("  Backup path: %s\n", resolveSwitchPattern(pattern, authPath, profile))

		ok, err := promptYesNo("Save this configuration?", true)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("cancelled")
		}

		s.SetAppConfig(appName, AppConfig{
			Current:       profile,
			Accounts:      []string{},
			AuthPath:      authPath,
			SwitchPattern: pattern,
		})
		if err := s.AddAccount(appName, profile); err != nil {
			return err
		}
		// Set default app if not set
		if s.config.Default.Config == "" {
			s.config.Default.Config = appName
			if err := s.saveConfig(); err != nil {
				return err
			}
		}
		return nil
	}

	fmt.Println("\n┌─ Switch Setup Wizard ─────────────────────────────────────┐")
	fmt.Println("│ Add new profile                                           │")
	fmt.Println("└───────────────────────────────────────────────────────────┘")
	fmt.Println()

	var existing []string
	for name := range s.config.Apps {
		existing = append(existing, name)
	}
	sort.Strings(existing)

	options := append([]string{}, existing...)
	options = append(options, "Auto-detect new application")
	options = append(options, "Manual setup")

	idx, err := promptChoice("Choose target:", options)
	if err != nil {
		return err
	}
	if idx == -1 {
		return fmt.Errorf("cancelled")
	}

	if idx < len(existing) {
		appName := existing[idx]
		profile, err := promptString("New profile name", "")
		if err != nil {
			return err
		}
		fmt.Println("\nSummary:")
		appCfg := s.config.Apps[appName]
		fmt.Printf("  App:         %s\n", appName)
		fmt.Printf("  Profile:     %s\n", profile)
		fmt.Printf("  Config path: %s\n", expandPath(appCfg.AuthPath))
		fmt.Printf("  Backup path: %s\n", resolveSwitchPattern(appCfg.SwitchPattern, expandPath(appCfg.AuthPath), profile))
		ok, err := promptYesNo("Save this configuration?", true)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("cancelled")
		}
		return s.AddAccount(appName, profile)
	}

	if idx == len(existing) { // auto-detect
		detected := DetectApplications()
		var keys []string
		for name := range detected {
			if _, exists := s.config.Apps[name]; !exists {
				keys = append(keys, name)
			}
		}
		if len(keys) == 0 {
			fmt.Println("No new applications detected.")
			return nil
		}
		sort.Strings(keys)
		var opts []string
		for _, k := range keys {
			d := detected[k]
			path := expandPath(d.AuthPath)
			kind := "File"
			if isFolder(path) {
				kind = "Folder"
			}
			opts = append(opts, fmt.Sprintf("%s      %s  [%s]", strings.Title(k), path, kind))
		}
		j, err := promptChoice("Detected applications:", opts)
		if err != nil {
			return err
		}
		if j == -1 {
			return fmt.Errorf("cancelled")
		}
		key := keys[j]
		tpl := detected[key]
		appName, err := promptString("Application name", key)
		if err != nil {
			return err
		}
		authPath, err := promptString("Config path", tpl.AuthPath)
		if err != nil {
			return err
		}
		pattern, err := promptString("Switch pattern", tpl.Pattern)
		if err != nil {
			return err
		}
		profile, err := promptString("Current profile name", "")
		if err != nil {
			return err
		}
		authPath = expandPath(authPath)
		fmt.Println("\nSummary:")
		fmt.Printf("  App:         %s\n", appName)
		fmt.Printf("  Profile:     %s\n", profile)
		fmt.Printf("  Config path: %s\n", authPath)
		fmt.Printf("  Backup path: %s\n", resolveSwitchPattern(pattern, authPath, profile))
		ok, err := promptYesNo("Save this configuration?", true)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("cancelled")
		}
		s.SetAppConfig(appName, AppConfig{Current: profile, Accounts: []string{}, AuthPath: authPath, SwitchPattern: pattern})
		if err := s.AddAccount(appName, profile); err != nil {
			return err
		}
		if s.config.Default.Config == "" {
			s.config.Default.Config = appName
			if err := s.saveConfig(); err != nil {
				return err
			}
		}
		return nil
	}

	// Manual setup
	appName, err := promptString("Application name", "")
	if err != nil {
		return err
	}
	authPath, err := promptString("Config file/folder path", "")
	if err != nil {
		return err
	}
	var defPattern string
	if strings.Contains(filepath.Base(authPath), ".") {
		defPattern = "{auth_path}.{name}.switch"
	} else {
		defPattern = filepath.Join(filepath.Dir(authPath), "profiles", "{name}.switch")
	}
	pattern, err := promptString("Switch pattern", defPattern)
	if err != nil {
		return err
	}
	profile, err := promptString("Current profile name", "")
	if err != nil {
		return err
	}
	authPath = expandPath(authPath)
	fmt.Println("\nSummary:")
	fmt.Printf("  App:         %s\n", appName)
	fmt.Printf("  Profile:     %s\n", profile)
	fmt.Printf("  Config path: %s\n", authPath)
	fmt.Printf("  Backup path: %s\n", resolveSwitchPattern(pattern, authPath, profile))
	ok, err := promptYesNo("Save this configuration?", true)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("cancelled")
	}
	s.SetAppConfig(appName, AppConfig{Current: profile, Accounts: []string{}, AuthPath: authPath, SwitchPattern: pattern})
	if err := s.AddAccount(appName, profile); err != nil {
		return err
	}
	if s.config.Default.Config == "" {
		s.config.Default.Config = appName
		if err := s.saveConfig(); err != nil {
			return err
		}
	}
	return nil
}

// Utility functions
func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

func printError(err error) {
	fmt.Fprintf(os.Stderr, "%s✗ Error: %v%s\n", ColorRed, err, ColorReset)
}

// Backward compatibility functions
func (s *Switcher) AddCodexAccount(name string) error {
	return s.AddAccount("codex", name)
}

func (s *Switcher) SwitchCodexAccount(name string) error {
	return s.SwitchAccount("codex", name)
}

func (s *Switcher) ListCodexAccounts() {
	s.ListAccounts("codex")
}

func printHelp() {
	fmt.Printf("%sSwitch - Universal Account Switcher%s\n\n", ColorCyan, ColorReset)
	fmt.Printf("Usage:\n")
	fmt.Printf("  switch                       Cycle through default app accounts\n")
	fmt.Printf("  switch <app>                 Cycle through app accounts\n")
	fmt.Printf("  switch <app> <account>       Switch to specific account\n")
	fmt.Printf("  switch add                   Launch setup wizard\n")
	fmt.Printf("  switch add <app>             Add a profile to app\n")
	fmt.Printf("  switch add <app> <account>   Add current config as account\n")
	fmt.Printf("  switch list                  List all apps and profiles\n")
	fmt.Printf("  switch list <app>            List profiles for specific app\n")
	fmt.Printf("  switch default <app>         Set default app\n")
	fmt.Printf("  switch config                Open config file in editor\n")
	fmt.Printf("  switch <app> config          Open config file in editor\n")
	fmt.Printf("  switch -v                   Print short version (commit)\n")
	fmt.Printf("  switch help                 Show this help\n\n")
	fmt.Printf("Built-in templates: codex, claude, vscode, cursor, ssh, git\n")
}

func shortVersion() string {
	v := version
	// strip -dirty suffix (noop if absent)
	v = strings.TrimSuffix(v, "-dirty")
	// extract after -g if present (git describe format)
	if i := strings.LastIndex(v, "-g"); i != -1 && i+2 < len(v) {
		return v[i+2:]
	}
	return v
}

func runDefaultCycle() int {
	s, err := NewSwitcher()
	if err != nil {
		printError(err)
		return 1
	}
	def := s.config.Default.Config
	if def == "" {
		fmt.Printf("%s✗ No default application configured%s\n", ColorRed, ColorReset)
		fmt.Printf("Run 'switch add' to set up an application.\n")
		return 1
	}
	if err := s.CycleAccounts(def); err != nil {
		printError(err)
		return 1
	}
	return 0
}

func handleAdd(s *Switcher, args []string) int {
	switch len(args) {
	case 0:
		if err := s.RunWizard(); err != nil {
			if err.Error() != "cancelled" {
				printError(err)
			}
			return 1
		}
		return 0
	case 1:
		appName := args[0]
		profile, err := promptString("Profile name", "")
		if err != nil {
			printError(err)
			return 1
		}
		if err := s.AddAccount(appName, profile); err != nil {
			printError(err)
			return 1
		}
		return 0
	case 2:
		if err := s.AddAccount(args[0], args[1]); err != nil {
			printError(err)
			return 1
		}
		return 0
	default:
		fmt.Printf("Usage: switch add <app> <account>\n")
		return 1
	}
}

func handleList(s *Switcher, args []string) int {
	if len(args) == 0 {
		s.ListAllApps()
	} else {
		s.ListAccounts(args[0])
	}
	return 0
}

func handleApp(s *Switcher, appName string, args []string) int {
	switch len(args) {
	case 0:
		if err := s.CycleAccounts(appName); err != nil {
			printError(err)
			return 1
		}
		return 0
	case 1:
		sub := args[0]
		if sub == "add" {
			fmt.Printf("Usage: switch add <app> <account>\n")
			return 1
		}
		if sub == "list" {
			s.ListAccounts(appName)
			return 0
		}
		if sub == "config" {
			if err := s.OpenConfig(); err != nil {
				printError(err)
				return 1
			}
			return 0
		}
		if err := s.SwitchAccount(appName, sub); err != nil {
			printError(err)
			return 1
		}
		return 0
	case 2:
		if args[0] == "add" {
			if err := s.AddAccount(appName, args[1]); err != nil {
				printError(err)
				return 1
			}
			return 0
		}
		fallthrough
	default:
		fmt.Printf("%s✗ Unknown command format%s\n", ColorRed, ColorReset)
		fmt.Printf("Run 'switch help' for usage\n")
		return 1
	}
}

func main() {
	if len(os.Args) == 1 {
		os.Exit(runDefaultCycle())
	}
	if len(os.Args) == 2 && (os.Args[1] == "-v" || os.Args[1] == "--version") {
		fmt.Println(shortVersion())
		return
	}

	s, err := NewSwitcher()
	if err != nil {
		printError(err)
		os.Exit(1)
	}

	switch os.Args[1] {
	case "version":
		fmt.Println(shortVersion())
		return
	case "add":
		os.Exit(handleAdd(s, os.Args[2:]))
	case "list":
		os.Exit(handleList(s, os.Args[2:]))
	case "default":
		if len(os.Args) != 3 {
			fmt.Printf("Usage: switch default <app>\n")
			os.Exit(1)
		}
		if err := s.SetDefaultApp(os.Args[2]); err != nil {
			printError(err)
			os.Exit(1)
		}
	case "config":
		if err := s.OpenConfig(); err != nil {
			printError(err)
			os.Exit(1)
		}
	case "help":
		printHelp()
	default:
		app := os.Args[1]
		os.Exit(handleApp(s, app, os.Args[2:]))
	}
}
