# Codex Claude Proxy

![Codex Claude Proxy README cover](./images/readme-cover.png)

_Current README cover: a short, thumbgen-style composite generated from fresh local dashboard screenshots._

[![MIT License](https://img.shields.io/badge/License-MIT-green.svg)](https://choosealicense.com/licenses/mit/)
[![Node.js Version](https://img.shields.io/badge/Node.js-18%2B-blue.svg)](https://nodejs.org/)
[![GitHub stars](https://img.shields.io/github/stars/surajmandalcell/codex-proxy?style=social)](https://github.com/surajmandalcell/codex-proxy)

> **Use Claude Code CLI with the power of ChatGPT Codex models.**
> A local proxy that translates Anthropic API requests into ChatGPT Codex calls, enabling you to use the `claude` CLI tool with your ChatGPT Free/Plus/Pro subscription.

| Role | Details |
| --- | --- |
| Maintainer | Suraj Mandal |
| GitHub | [surajmandalcell](https://github.com/surajmandalcell) |
| Contact | [surajmandalcell@gmail.com](mailto:surajmandalcell@gmail.com) |
| Package | [@pikoloo/codex-proxy](https://www.npmjs.com/package/@pikoloo/codex-proxy) |
| Changelog | [Changelog](CHANGELOG.md) |

---

## 🚀 Features

- **Seamless Translation**: Translates Anthropic Messages API calls to ChatGPT Codex format.
- **Model Mapping**: maps Claude model aliases to current OpenAI models, with direct GPT model IDs passed through.
- **Personal Account Mode**: Stores and uses one configured ChatGPT account for local-only personal use, with token auto-refresh.
- **Web Dashboard**: Built-in macOS-style UI (`http://localhost:8081`) for managing the local account, configuring Claude Code, viewing logs, adjusting settings, and testing prompts.
- **Streaming Support**: Full Server-Sent Events (SSE) support for real-time responses.
- **Native Tool Calling**: Supports Claude's tool use capabilities by translating them to Codex function calls.

---

## Security & Privacy

**Is this a malicious proxy? No.**

- **Local Execution**: This server binds to `127.0.0.1` by default.
- **Direct Communication by Default**: Claude and GPT model requests connect directly to OpenAI/ChatGPT endpoints.
- **Single Account Only**: Requests use one configured ChatGPT account. Adding or importing an account replaces the existing local account.
- **Third-Party Opt-In**: The explicit `kilo` model route uses Kilo/OpenRouter-backed free models only when `CODEX_CLAUDE_PROXY_ENABLE_KILO=true` is set. Default routing is OpenAI-only.
- **Open Source**: The full source code is available here for you to audit.
- **No Data Collection**: We do not track your prompts, keys, or personal data.

---

## Responsible Use And Account Boundaries

| Boundary | Commitment |
| --- | --- |
| Single user | This tool is intended for local, single-user use with your own ChatGPT/Codex account. |
| Single account | The proxy stores and uses one configured ChatGPT account at a time. Adding or importing an account replaces the existing local account. |
| No sharing | Do not expose the proxy to other users or make your ChatGPT credentials, session, or local proxy available to anyone else. |
| No resale | This package distributes client software only. It does not sell, rent, sublicense, bundle, or provide OpenAI service access. |
| No rate-limit bypass | The project does not pool accounts, rotate accounts, retry on another account, or attempt to avoid usage limits. |
| Unofficial tool | This project is independent and is not affiliated with, endorsed by, or sponsored by OpenAI, Anthropic, or Kilo. |
| Terms reminder | Users remain responsible for their own compliance with the [OpenAI Terms](https://openai.com/policies/terms-of-use/) and [Anthropic Terms](https://www.anthropic.com/legal/consumer-terms). |

This project uses unofficial ChatGPT/Codex backend behavior and does not claim official approval or guaranteed Terms compliance.

---

## ⚙️ How it works

This tool acts as a "translation layer" between the Claude CLI and ChatGPT's Codex backend.

1.  **Intercept**: Claude Code CLI sends a request to `localhost:8081` (thinking it's Anthropic's API).
2.  **Translate**: The proxy converts the Anthropic-format JSON into the specific payload format required by ChatGPT's internal Codex API.
3.  **Forward**: The request is sent securely to ChatGPT using your own authenticated session.
4.  **Stream**: The response from ChatGPT is converted back into Anthropic's Server-Sent Events (SSE) format and streamed to your terminal.

```
┌──────────────────┐     ┌─────────────────────┐     ┌────────────────────────────┐
│   Claude Code    │────▶│  This Proxy Server  │────▶│  ChatGPT Codex Backend API  │
│ (Anthropic API)  │     │ (Anthropic ⇄ OpenAI)│     │ (codex/responses)           │
└──────────────────┘     └─────────────────────┘     └────────────────────────────┘
```

---

## Installation

Install globally to use the CLI commands anywhere:

```bash
npm install -g @pikoloo/codex-proxy
codex-proxy start
```

Or run the published package without a global install:

```bash
npx @pikoloo/codex-proxy@latest start
```

For release work from this checkout, use `make update` and `make publish`.

The legacy `codex-claude-proxy` command remains available after installing this package.

---

## 🚦 Quick Start

### 1. Start the Proxy

```bash
codex-proxy start
```
The server will start at `http://localhost:8081`.

### 2. Add Your Account

#### **Option A: Web Dashboard (Local Desktop)**

1. Open the dashboard at **[http://localhost:8081](http://localhost:8081)**
2. Go to the **Account** tab
3. Click **Add Account** and login with your ChatGPT account

#### **Option B: CLI (Desktop or Headless/VM)**

```bash
# Desktop (opens browser)
codex-proxy account add

# Headless/VM server (manual code input)
codex-proxy account add --no-browser
```

For **headless/VM servers** without a browser:
1. Run the command with `--no-browser`
2. It will print a URL - copy and open it on a device with a browser
3. Complete login on that device
4. After redirect, copy the callback URL (or just the code)
5. Paste it back in the terminal

### 3. Configure Claude Code
   In the dashboard, click **Configure Claude Code** to write the proxy settings into Claude Code. Enable **Configure on startup** if you want the proxy to keep Claude Code pointed at the local server whenever it starts. Click **Reset Claude Code** to remove those overrides and return Claude Code to its default official configuration.

   You can also run this command:
   ```bash
   curl -X POST http://localhost:8081/claude/config/proxy
   ```

   *Alternatively, set the environment variables manually:*
   ```bash
   export ANTHROPIC_BASE_URL=http://localhost:8081
   export ANTHROPIC_API_KEY=dummy-key # The key is ignored but required by the CLI
   ```

4. **Run Claude**:
   ```bash
   claude
   ```

---

## 🧠 Model Mapping

The proxy automatically maps Claude model names to current OpenAI backend models. Direct `gpt-*` model IDs are passed through.

| Requested Model ID | Upstream Model | Auth Required | Description |
| :--- | :--- | :---: | :--- |
| `claude-sonnet-4-5` | `gpt-5.5` | ✅ | Current default high-intelligence model |
| `claude-opus-4-5` | `gpt-5.5` | ✅ | Current default high-intelligence model |
| `claude-haiku-4` | `gpt-5.4-mini` | ✅ | OpenAI small-model lane |
| `codex` | `gpt-5.3-codex` | ✅ | Latest Codex-optimized model |
| `kilo` | Selected Kilo target | ❌ | Explicit third-party free-model route, disabled unless `CODEX_CLAUDE_PROXY_ENABLE_KILO=true` |

---

## 🛠️ Configuration & API

### Web Dashboard

The dashboard uses a clean desktop split-view layout with a compact toolbar, native-feeling glass surfaces, single-account management, live logs, settings, Claude Code configuration, and prompt test panels. The screenshots below are captured from the actual local app.

| Dashboard | Settings |
| --- | --- |
| ![Codex Proxy dashboard screenshot](./images/dashboard-screenshot.png) | ![Codex Proxy settings screenshot](./images/settings-screenshot.png) |

Visit `http://localhost:8081` to:
- **Manage Account**: Add, import, refresh, replace, or remove the one local ChatGPT account.
- **Personal Mode**: Requests use the configured account only.
- **Configure Claude Code**: Use the dashboard button to set `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, and Claude model defaults, or reset Claude Code back to the official default config.
- **View Logs**: See real-time request/response logs for debugging.
- **Test Models**: Run quick tests against the configured models.

### API Endpoints
- `GET /health`: Check server status.
- `GET /account`: View the configured account.
- `POST /v1/messages`: Anthropic-compatible chat completion endpoint.

See [API Documentation](./docs/API.md) for full details.

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## ⚠️ Disclaimer
This project is an independent open-source tool and is not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, or Kilo. "Claude" is a trademark of Anthropic PBC. "ChatGPT" and "Codex" are trademarks of OpenAI. Use responsibly and in accordance with applicable Terms of Service.

---

<div align="center">
  <p>If you find this project useful, please give it a star! ⭐️</p>
  <a href="https://github.com/surajmandalcell/codex-proxy">
    <img src="https://img.shields.io/github/stars/surajmandalcell/codex-proxy?style=social" alt="Star on GitHub">
  </a>
</div>
