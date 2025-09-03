package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
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
	Default DefaultConfig         `toml:"default"`
	Codex   map[string]CodexEntry `toml:"codex"`
}

type DefaultConfig struct {
	Config string `toml:"config"`
}

type CodexEntry struct {
	Current string `toml:"current"`
}

type Switcher struct {
	configPath string
	config     *Config
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
				Codex:   make(map[string]CodexEntry),
			}
			return s.saveConfig()
		}
		return fmt.Errorf("read config: %w", err)
	}
	s.config = &Config{}
	if err := toml.Unmarshal(data, s.config); err != nil {
		return fmt.Errorf("parse config: %w", err)
	}
	if s.config.Codex == nil {
		s.config.Codex = make(map[string]CodexEntry)
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

func (s *Switcher) getCodexPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".codex", "auth.json"), nil
}

func (s *Switcher) setupNewAccount() error {
	authPath, err := s.getCodexPath()
	if err != nil {
		return err
	}

	fmt.Printf("%s✗ No auth.json found at %s%s\n", ColorRed, authPath, ColorReset)
	fmt.Printf("%sLet's set up your first account%s\n\n", ColorCyan, ColorReset)

	reader := bufio.NewReader(os.Stdin)

	fmt.Printf("Application name (codex/claude etc) [%scodex%s]: ", ColorYellow, ColorReset)
	appName, _ := reader.ReadString('\n')
	appName = strings.TrimSpace(appName)
	if appName == "" {
		appName = "codex"
	}

	fmt.Printf("Account name (suraj/cruel etc): ")
	accountName, _ := reader.ReadString('\n')
	accountName = strings.TrimSpace(accountName)
	if accountName == "" {
		fmt.Printf("%s✗ Account name cannot be empty%s\n", ColorRed, ColorReset)
		return fmt.Errorf("empty account name")
	}

	s.config.Default.Config = appName
	fmt.Printf("\n%s✓ Setup complete! Create your auth.json at %s and run 'switch %s add %s'%s\n",
		ColorGreen, authPath, appName, accountName, ColorReset)
	return s.saveConfig()
}

func (s *Switcher) AddCodexAccount(name string) error {
	authPath, err := s.getCodexPath()
	if err != nil {
		return err
	}

	if _, err := os.Stat(authPath); err != nil {
		if len(s.getCodexAccounts()) == 0 {
			return s.setupNewAccount()
		}
		fmt.Printf("%s✗ No auth.json found at %s%s\n", ColorRed, authPath, ColorReset)
		return fmt.Errorf("auth.json not found")
	}

	switchPath := authPath + "." + name + ".switch"
	if _, err := os.Stat(switchPath); err == nil {
		fmt.Printf("%s✗ Account '%s' already exists%s\n", ColorRed, name, ColorReset)
		fmt.Printf("Overwrite? (yes/no): ")
		reader := bufio.NewReader(os.Stdin)
		response, _ := reader.ReadString('\n')
		response = strings.TrimSpace(strings.ToLower(response))
		if response != "yes" && response != "y" {
			fmt.Printf("%sCancelled%s\n", ColorYellow, ColorReset)
			return fmt.Errorf("cancelled by user")
		}
	}

	if err := copyFile(authPath, switchPath); err != nil {
		return fmt.Errorf("copy auth file: %w", err)
	}

	if len(s.config.Codex) == 0 {
		s.config.Codex[name] = CodexEntry{Current: name}
	}
	s.config.Codex[name] = CodexEntry{Current: name}

	if err := s.saveConfig(); err != nil {
		os.Remove(switchPath)
		return err
	}

	fmt.Printf("%s✓ Added account: %s%s\n", ColorGreen, name, ColorReset)
	return nil
}

func (s *Switcher) SwitchCodexAccount(name string) error {
	authPath, err := s.getCodexPath()
	if err != nil {
		return err
	}

	if name == "" {
		return s.cycleCodexAccount()
	}

	switchPath := authPath + "." + name + ".switch"
	if _, err := os.Stat(switchPath); err != nil {
		fmt.Printf("%s✗ Account '%s' not found%s\n", ColorRed, name, ColorReset)
		return fmt.Errorf("account not found")
	}

	currentAuth, _ := os.ReadFile(authPath)
	currentName := s.findCurrentAccount()

	if currentName != "" && currentName != name {
		currentPath := authPath + "." + currentName + ".switch"
		os.WriteFile(currentPath, currentAuth, 0600)
	}

	data, err := os.ReadFile(switchPath)
	if err != nil {
		return fmt.Errorf("read switch file: %w", err)
	}

	if err := os.WriteFile(authPath, data, 0600); err != nil {
		return fmt.Errorf("write auth file: %w", err)
	}

	for k := range s.config.Codex {
		entry := s.config.Codex[k]
		entry.Current = k
		s.config.Codex[k] = entry
	}
	s.saveConfig()

	if currentName != "" && currentName != name {
		fmt.Printf("%s✓ Codex account switched from %s to %s!%s\n",
			ColorGreen, currentName, name, ColorReset)
	} else {
		fmt.Printf("%s✓ Switched to: %s%s\n", ColorGreen, name, ColorReset)
	}
	return nil
}

func (s *Switcher) cycleCodexAccount() error {
	accounts := s.getCodexAccounts()
	if len(accounts) == 0 {
		fmt.Printf("%s✗ No accounts configured%s\n", ColorRed, ColorReset)
		fmt.Printf("Run 'switch codex add <name>' to add your first account\n")
		return fmt.Errorf("no accounts")
	}

	current := s.findCurrentAccount()
	var next string

	if current == "" {
		next = accounts[0]
	} else {
		for i, acc := range accounts {
			if acc == current {
				next = accounts[(i+1)%len(accounts)]
				break
			}
		}
		if next == "" {
			next = accounts[0]
		}
	}
	return s.SwitchCodexAccount(next)
}

func (s *Switcher) findCurrentAccount() string {
	authPath, err := s.getCodexPath()
	if err != nil {
		return ""
	}

	currentData, err := os.ReadFile(authPath)
	if err != nil {
		return ""
	}

	var currentJSON map[string]interface{}
	json.Unmarshal(currentData, &currentJSON)

	accounts := s.getCodexAccounts()
	for _, name := range accounts {
		switchPath := authPath + "." + name + ".switch"
		switchData, err := os.ReadFile(switchPath)
		if err != nil {
			continue
		}
		var switchJSON map[string]interface{}
		if json.Unmarshal(switchData, &switchJSON) == nil {
			if jsonEqual(currentJSON, switchJSON) {
				return name
			}
		}
	}
	return ""
}

func (s *Switcher) getCodexAccounts() []string {
	authPath, _ := s.getCodexPath()
	dir := filepath.Dir(authPath)
	files, err := os.ReadDir(dir)
	if err != nil {
		return []string{}
	}

	var accounts []string
	for _, f := range files {
		if strings.HasPrefix(f.Name(), "auth.json.") && strings.HasSuffix(f.Name(), ".switch") {
			name := strings.TrimPrefix(f.Name(), "auth.json.")
			name = strings.TrimSuffix(name, ".switch")
			accounts = append(accounts, name)
		}
	}
	return accounts
}

func (s *Switcher) ListCodexAccounts() {
	accounts := s.getCodexAccounts()
	current := s.findCurrentAccount()

	if len(accounts) == 0 {
		fmt.Printf("%s✗ No accounts configured%s\n", ColorRed, ColorReset)
		fmt.Printf("Run 'switch codex add <name>' to add your first account\n")
		return
	}

	fmt.Printf("%sCodex accounts:%s\n", ColorCyan, ColorReset)
	for _, acc := range accounts {
		if acc == current {
			fmt.Printf("  %s●%s %s %s(current)%s\n", ColorGreen, ColorReset, acc, ColorYellow, ColorReset)
		} else {
			fmt.Printf("  ○ %s\n", acc)
		}
	}
}

func copyFile(src, dst string) error {
	source, err := os.Open(src)
	if err != nil {
		return err
	}
	defer source.Close()

	destination, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destination.Close()

	_, err = io.Copy(destination, source)
	return err
}

func jsonEqual(a, b map[string]interface{}) bool {
	aBytes, _ := json.Marshal(a)
	bBytes, _ := json.Marshal(b)
	return string(aBytes) == string(bBytes)
}

func printError(err error) {
	fmt.Fprintf(os.Stderr, "%s✗ Error: %v%s\n", ColorRed, err, ColorReset)
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
	case "codex":
		if len(os.Args) == 2 {
			if err := s.SwitchCodexAccount(""); err != nil {
				os.Exit(1)
			}
		} else if os.Args[2] == "add" && len(os.Args) > 3 {
			if err := s.AddCodexAccount(os.Args[3]); err != nil {
				os.Exit(1)
			}
		} else if os.Args[2] == "list" {
			s.ListCodexAccounts()
		} else {
			if err := s.SwitchCodexAccount(os.Args[2]); err != nil {
				os.Exit(1)
			}
		}
	case "list":
		s.ListCodexAccounts()
	case "help":
		fmt.Printf("%sSwitch - Account Switcher%s\n\n", ColorCyan, ColorReset)
		fmt.Printf("Usage:\n")
		fmt.Printf("  switch                    Cycle through accounts\n")
		fmt.Printf("  switch codex              Cycle through codex accounts\n")
		fmt.Printf("  switch codex <name>       Switch to specific account\n")
		fmt.Printf("  switch codex add <name>   Add current auth.json as account\n")
		fmt.Printf("  switch codex list         List all accounts\n")
		fmt.Printf("  switch help               Show this help\n")
	default:
		fmt.Printf("%s✗ Unknown command: %s%s\n", ColorRed, os.Args[1], ColorReset)
		fmt.Printf("Run 'switch help' for usage\n")
		os.Exit(1)
	}
}
