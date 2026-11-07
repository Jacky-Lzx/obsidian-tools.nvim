# obsidian-tools.nvim

Vault note identity, links, indexes and daily-note workflows.

## Features

- Find notes, tags, backlinks and daily notes.
- Follow shared Markdown/wiki links and provide completion candidates.
- Plan note moves and update supported references with snapshot validation.

## Requirements

Neovim **0.11+**. `markdown-tools.nvim` is required. Open Markdown inside an existing `.obsidian` vault for auto-detection, or configure explicit workspaces.

## Installation

With lazy.nvim:

```lua
{
  "Jacky-Lzx/obsidian-tools.nvim",
  main = "obsidian_tools",
  dependencies = { "Jacky-Lzx/markdown-tools.nvim" },
  opts = { auto_detect = true },
}
```

Or put this repository and its required dependencies on `runtimepath`, then call:

```lua
require("obsidian_tools").setup({ auto_detect = true })
```

## Usage

```vim
:ObsidianTools quick_switch
:ObsidianTools daily
:ObsidianTools info
```

## Documentation

- [Complete reference](doc/obsidian-tools.txt) — `:help obsidian-tools`.

## Development

Run from the repository root:

```sh
python3 tests/run.py unit --filter docs
python3 tests/run.py default
```

See [the test workflow](tests/README.md) for dependencies, optional suites and
retained failure evidence. Local development overrides belong in your package
manager configuration; public installation uses the repository above.

[License](LICENSE).
