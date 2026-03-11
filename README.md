# repocopy (rpcp)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/dickymoore/repocopy)](https://github.com/dickymoore/repocopy/releases)
[![CI](https://github.com/dickymoore/repocopy/actions/workflows/ci.yml/badge.svg)](https://github.com/dickymoore/repocopy/actions/workflows/ci.yml)

> **TL;DR** – `rpcp` is a one‑shot clipboard copier for *codebases*.
> It walks a folder, excludes junk (`.git`, `node_modules`, binaries, etc.),
> redacts secrets you define, then puts the result on your clipboard
> ready to paste into an AI assistant or chat.

---

## ✨ Why might I need this?

Sometimes you’re pair‑programming with an LLM (ChatGPT, Claude, Copilot Chat etc.)
and you need to give it your *entire* repo or a large sub‑directory for context.
Copy‑pasting file‑by‑file gets old fast – **repocopy** does it in a single command
while letting you:

* redact sensitive tokens (`ACME` → `ClientName`)
* skip whole directories or globs
* honour a max file‑size
* view exactly which files were included

---

## 🚀 Quick‑start

### PowerShell 7+ (Windows, macOS, Linux)

```powershell
# 1. Clone with submodules & jump in
git clone --recurse-submodules https://github.com/dickymoore/repocopy.git
cd repocopy

# 2. Add rpcp to your PATH
$env:PATH += ';' + (Get-Location) # (current session)

if ($([Environment]::GetEnvironmentVariable('PATH','User')) -split ';' -notcontains $((Get-Location).Path)) {[Environment]::SetEnvironmentVariable('PATH',"$([Environment]::GetEnvironmentVariable('PATH','User'));$((Get-Location).Path)",'User')} # (future sessions)

# 3. Copy the *current* folder (default)
rpcp

# 4. Copy another repo, verbose
rpcp -RepoPath 'C:\src\my-project' -Verbose
```

> **Clipboard helper** – uses the built‑in **Set‑Clipboard** cmdlet (no extra installs).

---

### Bash / Zsh (macOS, Linux, WSL)

```bash
# 1. Clone with submodules & add rpcp to your PATH
git clone --recurse-submodules https://github.com/dickymoore/repocopy.git
export PATH="$PATH:$(pwd)/repocopy"

# 2. Copy the *current* folder (default)
rpcp

# 3. Copy another repo, verbosely
rpcp --repo-path ~/src/my-project --verbose
```

> **Clipboard helpers** –  
> • Linux: uses `xclip`, `wl-copy`, `xsel`, or OSC52 terminal clipboard support  
> • macOS: uses `pbcopy`  
> • WSL: uses `clip.exe`

---

## 📦 Requirements

* **Bash** 4+ **or** **PowerShell** 7+
* `jq` – for the Bash version (auto‑installed if `autoInstallDeps = true`)
* A clipboard tool (`pbcopy`, `xclip`, `wl-copy`, `xsel`, `clip.exe`, `pwsh`, or OSC52 terminal clipboard support)

---

## ⚙️ Configuration (`config.json`)

```jsonc
{
  // folder to scan – “.” = working directory
  "repoPath": ".",

  // ignore folders / files (globs ok)
  "ignoreFolders": ["build", ".git", "node_modules"],
  "ignoreFiles":   ["manifest.json", "*.png"],

  // max bytes per file (0 = unlimited)
  "maxFileSize": 204800,

  // string replacements applied to every file (So in this case, ACME will be replaced with Company_name)
  "replacements": {
    "ACME": "Company_name"
  },

  // print a summary afterwards?
  "showCopiedFiles": true,

  // let rpcp.sh auto‑install jq if missing
  "autoInstallDeps": true
}
```

Every CLI switch overrides the matching JSON field – handy when you just
need to bump `--max-file-size` for one run.

---

## 💻 Usage snippets

### PowerShell

```powershell
# basic
rpcp

# disable size filter
rpcp -MaxFileSize 0

# different folder, quiet output
rpcp -RepoPath C:\Code\Foo -Verbose:$false
```

### Bash

```bash
# basic
rpcp

# disable size filter & summary
rpcp --max-file-size 0 --show-copied-files=false

# different folder
rpcp --repo-path ~/Code/Foo
```

---

## 🧪 Running tests locally

```bash
# one‑time: fetch the helper submodules
git submodule update --init --recursive

# Bash tests
sudo apt install bats jq xclip   # linux example
bats tests/bash

# PowerShell tests
pwsh -Command 'Install-Module Pester -Scope CurrentUser -Force'
pwsh -Command 'Invoke-Pester tests/powershell'
```

---

## 📝 Development notes

* Shell files are expected to use **LF** endings.  
  A `.gitattributes` is provided so Windows Git converts on checkout.
* CI runs both Pester (PowerShell) and Bats (Bash) on
  **ubuntu‑latest** and **windows‑latest** runners.
* Want to contribute? See **CONTRIBUTING.md**.

---

## 📄 License

MIT © 2025 Dicky Moore
