# obsidian-tools.nvim

Vault workflows for Neovim 0.11+, with markdown-tools.nvim as the shared Markdown
syntax/editing layer. This plugin owns note identity, vault indexes and link
resolution. Physical keys, picker UI, completion UI, images and rendering stay
with your configuration and existing plugins.

```lua
require('obsidian_tools').setup({
  workspaces = { { name = 'Research', path = '~/Research/Obsidian_Workspace' } },
  notes_subdir = 'notes',
  daily_notes = {
    folder = 'dailies',
    date_format = '%Y-%m-%d',
    alias_format = '%B %-d, %Y',
    template = 'daily-note.md',
    default_tags = { 'daily-notes' },
  },
  templates = { folder = 'templates', date_format = '%Y-%m-%d', time_format = '%H:%M' },
  -- note_id = function(title, ctx) return ... end,
})
```

Install both plugins on `runtimepath` before setup. Multiple workspaces select the
longest matching path. `auto_detect = true` optionally discovers an ancestor
`.obsidian/`; the default is false. No global mappings, cwd changes or editor
options are installed. Commands attach only to ordinary Markdown buffers inside
the selected vaults. Setup and buffer entry do not scan notes.

## Commands

`:ObsidianTools` opens a searchable action menu through `vim.ui.select`.
Use `:ObsidianTools {action} [argument]` for direct actions:

| Action | Behavior |
| --- | --- |
| `quick_switch [query]` | Select notes by title and vault-relative path. |
| `new [title]` | Create a note using the configured ID function, or timestamp/title by default. Existing filenames are retained and collisions get a suffix. |
| `daily [YYYY-MM-DD]` | Open/create a daily note, applying its optional template. |
| `dailies` | Select daily notes, newest filename first. |
| `search [query]` | Literal, case-insensitive content search, with line navigation. |
| `tags [tag]` | Select a tag, then a matching note. |
| `backlinks` | Select resolved references to the current note. |
| `follow_link` | Follow the link under the cursor, selecting ambiguous note matches. |
| `link` | Select a note and insert a vault-relative wiki link. |
| `template [name]` | Insert a rendered template before the cursor as one undo step. |
| `rename [path]` | Rename/move the current note to a vault-relative path and update supported links. |
| `refresh` | Refresh the index and report note/read-error counts. |
| `info` | Inspect workspace and configuration. |

New notes use YAML `id`, `aliases`, and `tags`. Daily notes retain both the date ID
and a human-readable date alias. Template IDs are replaced with the created
note's ID; existing daily notes are opened without modification. Templates support
`{{title}}`, `{{id}}`, `{{date}}`, `{{time}}`, plus `templates.substitutions` values
or functions receiving `{title,id,time,vault}`. Unknown placeholders are retained.
`new(title, template_name)` also accepts a template through Lua.

## Shared links and completion

Inject the optional handler into markdown-tools; it does not import vault code:

```lua
require('markdown_tools').setup({
  link_handler = function(link, ctx)
    return require('obsidian_tools').follow_link(link, ctx)
  end,
})
```

Outside a workspace, or for an external URI, this returns nil so the default
Markdown handler can continue. Inside a vault, note lookup considers explicit
paths, filename stems and IDs, then aliases. Duplicate matches open a picker.
Markdown links prefer the source note's directory; wiki links prefer the vault
root. Heading titles/slugs and `#^block-id` anchors are supported. Attachments
open through `vim.ui.open`; attachment preview/insertion belongs to image-tools.

The completion-tools provider is `require('obsidian_tools.completion').new()`.
It exposes `trigger(ctx)` and `complete(ctx, callback)` with native LSP
CompletionItems. Select it in your completion-tools `sources` and configure
`trigger_characters` for wiki links/tags. It handles notes, aliases, headings,
block IDs and tags. Text edits consume existing closing `]]`, preserving pairs
ownership. It installs no Insert keys. Completion is disabled outside vaults,
inside excluded code/front matter, and in non-Insert contexts.

## Index and rename behavior

Index refreshes run in scheduled batches, coalesce concurrent callers, cache
unchanged documents by file stats and buffer ticks, and include unsaved contents
of existing note buffers for queries. Files removed or changed externally are
observed on the next refresh. `.git`, `.obsidian`, `.trash`, `node_modules` and the
template directory are excluded; symlink entries are not traversed. The default
per-note size limit is 4 MiB (`max_file_bytes`). `ignore` customizes excluded names.
`dispose()` invalidates queued work and removes only unchanged owned commands.
Invalid setup options leave the running setup intact.

`plan_rename(destination)` returns a read-only proposal with source/destination,
before/after bytes for affected files and a reference count. It writes nothing.
`apply_rename(plan)` verifies file snapshots, clean affected buffers, containment,
symlink destinations and destination conflicts. It stages replacements and
backups, reserves the destination exclusively, updates references, and rolls back
reported write errors. Rollback failures retain backup files and report paths.
This multi-file operation is not crash-atomic. Renames preserve original note IDs,
aliases, link labels, embeds, anchors, line endings and unrelated bytes. Moving a
note adjusts its resolved outgoing relative links, including attachments.
Open unmodified buffers are reloaded after the disk changes.

The shared lightweight Markdown parser supports single-line wiki/inline links,
reference links with single-line definitions, and ATX/Setext headings. Fenced and
indented code, inline code, front matter and HTML comments are excluded. Multiline
link labels/definitions, raw HTML/JSX, nested Obsidian heading paths and general
YAML features such as anchors/flow mappings are outside its syntax coverage.
Metadata extraction supports scalar IDs/titles and scalar/flow/block lists for
aliases/tags. Rename rewrites supported resolved references, leaves unresolved
references unchanged, and refuses ambiguous references involving the moved note.
It does not rename metadata IDs, headings or blocks, implement graph views,
Dataview, Canvas, Sync, or replace the Obsidian application.

## Development

```sh
stylua --check lua tests
OBSIDIAN_TOOLS_MARKDOWN_PATH=/path/to/markdown-tools.nvim \
  TMPDIR=/private/tmp nvim --clean --headless -i NONE -l tests/run.lua
```

The sibling `../markdown-tools.nvim` is the default test dependency. Tests use a
private temporary vault and cover link spans, metadata, anchors, template/daily
creation, completions, ambiguous matches, byte-preserving rename/move, dirty and
stale-file protection, exclusive destination collisions, injected write failures,
rollback, cancellation and setup/disposal ownership.

[Test workflow](tests/README.md): registered suites, filtering, required fixtures and retained failure evidence.
