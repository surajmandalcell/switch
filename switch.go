package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
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

type Config struct {
	Default DefaultConfig        `toml:"default"`
	Apps    map[string]AppConfig `toml:",inline"`
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

func NewSwitcher() (*Switcher, error) {
	home, err := os.UserHomeDir()
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
func expandPath(path string) string {
	if strings.HasPrefix(path, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, path[2:])
	}
	return path
}

func isFolder(path string) bool {
	stat, err := os.Stat(path)
	return err == nil && stat.IsDir()
}

func resolveSwitchPattern(pattern, authPath, name string) string {
	resolved := strings.ReplaceAll(pattern, "{auth_path}", authPath)
	resolved = strings.ReplaceAll(resolved, "{name}", name)
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
	source, err := os.Open(src)
	if err != nil {
		return err
	}
	defer source.Close()

	// Create destination directory if needed
	dstDir := filepath.Dir(dst)
	if err := os.MkdirAll(dstDir, 0755); err != nil {
		return err
	}

	destination, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destination.Close()

	_, err = io.Copy(destination, source)
	return err
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
			return os.MkdirAll(dstPath, info.Mode())
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

	// For JSON files, compare structure
	var aJSON, bJSON map[string]interface{}
	if json.Unmarshal(aData, &aJSON) == nil && json.Unmarshal(bData, &bJSON) == nil {
		return jsonEqual(aJSON, bJSON)
	}

	// Otherwise, compare raw bytes
	return string(aData) == string(bData)
}

func folderEqual(a, b string) bool {
	// Simple folder comparison - check if both exist
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
	// Get or create app config
	appConfig, exists := s.GetAppConfig(appName)
	if !exists {
		// Try to use template
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

	// Check if account already exists
	for _, acc := range appConfig.Accounts {
		if acc == accountName {
			fmt.Printf("%s✗ Account '%s' already exists for %s%s\n", ColorRed, accountName, appName, ColorReset)
			fmt.Printf("Overwrite? (yes/no): ")
			reader := bufio.NewReader(os.Stdin)
			response, _ := reader.ReadString('\n')
			response = strings.TrimSpace(strings.ToLower(response))
			if response != "yes" && response != "y" {
				fmt.Printf("%sCancelled%s\n", ColorYellow, ColorReset)
				return fmt.Errorf("cancelled by user")
			}
			break
		}
	}

	// Copy current config to switch file
	if err := copyPath(authPath, switchPath); err != nil {
		return fmt.Errorf("copy config: %w", err)
	}

	// Update app config
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

	// Save current config to current account's switch file
	currentAccount := s.findCurrentAccount(appName)
	if currentAccount != "" && currentAccount != accountName {
		currentSwitchPath := resolveSwitchPattern(appConfig.SwitchPattern, authPath, currentAccount)
		copyPath(authPath, currentSwitchPath)
	}

	// Load target account's config
	if err := copyPath(switchPath, authPath); err != nil {
		return fmt.Errorf("switch config: %w", err)
	}

	// Update current in config
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

func main() {
	if len(os.Args) < 2 {
		os.Args = append(os.Args, "codex")
	}

	s, err := NewSwitcher()
	if err != nil {
		printError(err)
		os.Exit(1)
	}

	switch os.Args[1] {
	case "add":
		if len(os.Args) == 2 {
			fmt.Printf("Interactive wizard not implemented yet\n")
			fmt.Printf("Usage: switch add <app> <account>\n")
			os.Exit(1)
		} else if len(os.Args) == 4 {
			if err := s.AddAccount(os.Args[2], os.Args[3]); err != nil {
				printError(err)
				os.Exit(1)
			}
		} else {
			fmt.Printf("Usage: switch add <app> <account>\n")
			os.Exit(1)
		}

	case "list":
		if len(os.Args) == 2 {
			s.ListAllApps()
		} else {
			s.ListAccounts(os.Args[2])
		}

	case "help":
		fmt.Printf("%sSwitch - Universal Account Switcher%s\n\n", ColorCyan, ColorReset)
		fmt.Printf("Usage:\n")
		fmt.Printf("  switch                       Cycle through default app accounts\n")
		fmt.Printf("  switch <app>                 Cycle through app accounts\n")
		fmt.Printf("  switch <app> <account>       Switch to specific account\n")
		fmt.Printf("  switch add <app> <account>   Add current config as account\n")
		fmt.Printf("  switch list                  List all apps and accounts\n")
		fmt.Printf("  switch list <app>            List accounts for specific app\n")
		fmt.Printf("  switch help                  Show this help\n\n")
		fmt.Printf("Supported apps: codex, claude, vscode, cursor, ssh, git\n")

	// Handle app-specific commands
	default:
		appName := os.Args[1]
		
		if len(os.Args) == 2 {
			// switch <app> - cycle accounts
			if err := s.CycleAccounts(appName); err != nil {
				printError(err)
				os.Exit(1)
			}
		} else if len(os.Args) == 3 {
			accountName := os.Args[2]
			if accountName == "add" {
				fmt.Printf("Usage: switch add <app> <account>\n")
				os.Exit(1)
			} else if accountName == "list" {
				s.ListAccounts(appName)
			} else {
				// switch <app> <account> - switch to account
				if err := s.SwitchAccount(appName, accountName); err != nil {
					printError(err)
					os.Exit(1)
				}
			}
		} else if len(os.Args) == 4 && os.Args[2] == "add" {
			// switch <app> add <account>
			if err := s.AddAccount(appName, os.Args[3]); err != nil {
				printError(err)
				os.Exit(1)
			}
		} else {
			fmt.Printf("%s✗ Unknown command format%s\n", ColorRed, ColorReset)
			fmt.Printf("Run 'switch help' for usage\n")
			os.Exit(1)
		}
	}
}