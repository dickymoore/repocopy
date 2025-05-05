# repocopy (rpcp)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/dickymoore/repocopy)](https://github.com/dickymoore/repocopy/releases)
[![CI](https://github.com/dickymoore/repocopy/actions/workflows/ci.yml/badge.svg)](https://github.com/dickymoore/repocopy/actions/workflows/ci.yml)

📎 What is it?
A lightweight utility to copy the file contents of a local directory to the clipboard.

🤔 Is that all it does?
It has the ability to filter out files matched on name or type, or to redact text patterns.

❓ But why?
In case you've got sensitive information or huge irrelevant files in the repo.

🧠 No, I mean why copy your repo at all?
Various reasons, but it can be useful for when using web-based tooling to help with development or debugging — such as giving an LLM like ChatGPT the full context to a coding issue.

😐 Why would I want to do that?
I dunno mate. You might not, in which case, go enjoy yourself.

---

## 🎯 Use Case

When working with AI-assisted development ("vibe coding"), you often need to provide the AI with the exact context of your repository or a specific directory. With **repocopy**, you can quickly copy all relevant files (excluding things like `.git`, `node_modules`, large binaries, etc.) into your clipboard in one shot. Then just paste that into your AI tool to give it full awareness of your codebase structure and content.

---

## 🚀 Features

- **Config-driven**: Exclude folders, files, set max file size, and define token replacements via `config.json`.
- **One-command operation**: Clone the repo, add the script directory to your `PATH`, then run `rpcp` to copy contents of the current folder.
- **Automatic replacements**: Swap tokens (e.g. `PARENT_COMPANY`, `CLIENT_NAME`) as defined in your config.
- **Verbose mode**: See exactly which files were included or excluded and why.
- **Show summary**: Optionally list which files got copied, either via CLI or config.
- **Cross-platform support**: Run on Windows PowerShell or macOS/Linux Bash.

---

## 📦 Installation

1. **Clone the repocopy repository**

   ```bash
   git clone --recurse-submodules https://github.com/dickymoore/repocopy.git
   git submodule update --init --recursive
   ```

2. **Add to your PATH**

   - **Windows (PowerShell)**:
     1. Locate the folder where you cloned `repocopy` (e.g. `C:\tools\repocopy`).
     2. Open System Settings → Environment Variables → User Variables → `Path` → Edit → New.
     3. Paste the full path to your `repocopy` folder and click OK.
     4. Restart your PowerShell session.

   - **macOS/Linux (Bash)**:
     1. Ensure you have [PowerShell Core](https://github.com/PowerShell/PowerShell) or use the Bash script directly.
     2. Add the folder to your `PATH`: 
        ```bash
        export PATH="$PATH:/path/to/repocopy"
        ```
     3. Add that line to your shell profile (`~/.bashrc`, `~/.zshrc`, or `~/.profile`).

3. **Optionally create an alias**

   - **PowerShell** (in your PowerShell profile):
     ```powershell
     Set-Alias rpcp "$(Join-Path 'C:\tools\repocopy' 'rpcp.ps1')"
     ```
   - **Bash** (in your shell profile):
     ```bash
     alias rpcp='rpcp.sh'
     ```

Now you can run:

```bash
rpcp
```

---

## ⚙️ Configuration (`config.json`)

Place a `config.json` alongside `rpcp.ps1` or `rpcp.sh`. Example:

```json
{
  "repoPath": ".",
  "maxFileSize": 204800,
  "ignoreFolders": [
    ".git", ".github", ".terraform", "node_modules",
    "plugin-cache", "terraform-provider*", "logo-drafts",
    "build", ".archive"
  ],
  "ignoreFiles": [
    "manifest.json", "package-lock.json"
  ],
  "replacements": {
    "PARENT_COMPANY": "pca",
    "CLIENT_NAME": "ClientName",
    "PROJECT_ACRONYM": "wla"
  },
  "showCopiedFiles": true
}
```

- **repoPath**: Default folder to scan (`.` = current directory).
- **maxFileSize**: Max bytes per file (0 = no limit).
- **ignoreFolders**: Wildcard patterns of folder names to skip.
- **ignoreFiles**: Exact file names to skip.
- **replacements**: Key/value pairs to replace in file contents.
- **showCopiedFiles**: `true` to list included files after copying.

---

## 💻 Usage

### PowerShell (Windows or Core)

```powershell
# Copy current directory
rpcp

# Override max size, suppress summary:
rpcp -MaxFileSize 0 -ShowCopiedFiles:$false

# Scan a different directory:
rpcp -RepoPath 'C:\Projects\MyApp'

# Verbose debugging:
rpcp -Verbose
```

### Bash (macOS/Linux)

```bash
# Copy current directory
rpcp

# Override max size, suppress summary:
rpcp.sh --max-file-size 0 --show-copied-files=false

# Scan a different directory:
rpcp.sh --repo-path /path/to/project

# Verbose debugging:
rpcp.sh --verbose
```

---

## 🎯 Vibe Coding

After running `rpcp`, your clipboard contains all relevant files with context. Paste directly into your AI tool to provide the full structure and content, no manual file hunting required.

---

## 🧪 Testing & Linting

# Running tests locally

## Bash (Bats)

```bash
sudo apt install bats jq xclip   # or the equivalent for your OS
bats tests/bash/repocopy.bats
```

## PowerShell (Pester)

```
Install-Module Pester -Force -Scope CurrentUser  # once
Invoke-Pester -Path tests/powershell -Output Detailed
```


---

## 📄 License

MIT License · © 2025 Dicky Moore
