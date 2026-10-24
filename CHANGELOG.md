# Changelog

All notable LernAssist changes. The app version is set in the Xcode project.

## 4.0.0

### Added

- **Flow design**: accent colors, glass strength, color field and subtle motion; floating glass cards for the sidebar and settings; smoothly resizable sidebar that snaps back from the window edge.
- **Bilingual UI**: English by default and German as a second language, switchable live under **Settings → Appearance**.
- **Interactive outputs**: HTML artifacts run with locally bundled libraries (Chart.js, D3, Three.js, Leaflet, Cytoscape, ECharts, Plotly, Rough.js, Tone.js, P5.js, WaveSurfer.js), collapse cleanly, open in full screen, in a detached window (double-click, proportional zoom) or in the browser. Script errors appear as non-blocking warnings on the tool step.
- **Python figures in the `[B#]` image system**: plots generated in `coding_sandbox` receive collision-free `[B#]` indices (alongside web figures), are stored in the app's image store and can be placed inline by the model right next to the relevant paragraph. Figures saved to `/tmp/` or left open without `plt.show()` / `plt.savefig()` are captured automatically while keeping the prompt prefix cache intact.
- **Automatic output repair**: Mermaid diagrams, Markdown tables, LaTeX math (including double superscripts like `\Delta G^\circ'`, `\ce{...}` chemistry macros, unescaped `%` in math mode and bare display equations), tool arguments and common Python syntax mistakes are repaired before rendering.
- **One-click "Repair" actions**: diagrams that still fail to parse are fixed by the model for display only (leaving chat history and KV cache untouched); failed HTML or Python steps can send their error trace back to the model with one click.
- **Per-model settings** (new **Models** tab): thinking on/off, reasoning effort, thinking budget, preserve thinking, temperature, `top_p`, `top_k`, `min_p`, presence and repetition penalties, max tokens, context window, streaming on/off, vision on/off (with automatic screenshot description fallback for text-only models) and custom `chat_template_kwargs`. Stored per model with precedence Model > Profile > Server. Built-in presets for Sage-A1.5 (including verification mode), Qwen 3.8 and Qwen 3.5/3.6.
- **Refined didactic study modes**: all seven learning modes (*Detailed*, *Compact*, *Exam*, *Beginner*, *Tutor*, *Examples* and *Custom*) share a unified formatting and explanation baseline.
- **Connection watcher**: checks the active endpoint, fallback endpoint and search server while idle. Unreachable services appear as a dismissible banner in chat (with a direct link to the matching settings tab) and as a macOS notification in the background.
- **SearXNG server catalog**: configure multiple local or remote SearXNG instances with per-server authentication (Bearer token, Basic auth or custom header stored in the macOS Keychain).
- **Search across all settings**: jumps straight to the matching tab, expands collapsed sections and highlights the row.
- **PubMed and Brave Search**: PubMed (NCBI E-Utilities, enabled by default, no API key required) and Brave Search as an optional fallback source alongside Exa.
- **Storage overview** under **Settings → Advanced**: live folder sizes, Reveal in Finder and one-click cleanup for Python workspace files.
- **Quality of life**: regenerate last answer, copy button on code blocks, scroll-to-bottom pill, in-chat search (`⌘F`), discreet auto-hiding scrollbars and text size controls in the View menu.

### Changed

- **Faster, more resilient web research** (typically 8–13 s instead of 30–40 s): per-source time budget (30 s default), automatic cooldown on rate limits or consecutive failures, early completion once enough hits arrive (3 s grace period for slow sources) and per-phase timing breakdowns in the tool step.
- **Lower streaming CPU usage**: streamed tool-call deltas are buffered at 5 Hz, running tool steps stay collapsed and long chats render lazily with cached message heights (reducing CPU load during tool streaming from ~100 % to 12–20 %).
- Thinking mode, thinking budget and preserve-thinking settings moved from endpoint profiles to the per-model **Models** tab (existing values are migrated automatically; `/think` now updates the active model).

## 3.0.0

### Added

- **FSRS-5 spaced repetition**: upgraded the flashcard scheduler from SM-2 to FSRS-5 (Free Spaced Repetition Scheduler) with configurable target retention (80 %–97 %, default 90 %) and automatic migration of existing cards.
- **Flashcards & review panel**: dedicated header panel with tabs for *Due Reviews* (keyboard navigation with Space and `1`–`4`), *All Cards* and the *Mistake Log*.
- **One-click card extraction ("Save as card")**: distills any assistant answer or completed quiz card into 1–3 study flashcards with immediate undo.
- **Mistake log & targeted error training**: missed quiz questions and forgotten flashcards are recorded automatically in `mistakes.json`; one click starts a tailored practice session focused on open knowledge gaps.
- **Slash commands**:
  - `/quiz [count] [topic]`: interactive multiple-choice and free-text quiz cards with final score summary.
  - `/case [topic]` (`/fall`): interactive step-by-step case studies adapted to the chat's subject (systems design and debugging for computer science, multi-part derivations for mathematics and physics, clinical cases for life sciences).
  - `/summary [topic]`: structured study sheet with key takeaways, glossary table, Mermaid diagram and review questions.
- **A4 PDF & Markdown export**: export any answer or study sheet as a formatted A4 PDF (including rendered KaTeX formulas and Mermaid diagrams) or Markdown file.
- **Automatic chat titles & subject tags**: the model assigns a concise title and subject badge after the first turn and refines both after the third question; chats can be filtered by subject in the sidebar.
- **Setup Assistant**: 5-step onboarding wizard for local or two-Mac (Tailscale/LAN) setups, endpoint diagnostics, web search configuration and macOS permission checks.
- **Settings info mode**: toggleable `(i)` explanations for every setting row, plus dynamic light/dark Mermaid re-theming without reloading the chat view.

### Changed

- Responsive two-line chat header with compact telemetry pill on narrower windows, hover-only answer action bar with floating tooltip bubbles, and full Swift 6 strict concurrency compliance.

## 2.0.0

### Added

- **Flow UI foundation (DS 2.0)**: borderless surface hierarchy, custom vector brand icon (`LernAssistBrandIcon`) across sidebar, header and welcome screen.
- **Live streaming telemetry & sparkline**: separate prefill (TTFT, prompt tokens/s) and decode (tokens/s) metrics with a 5 Hz live sparkline in the header and a detailed history popover with quick model/server switching.
- **Local Python coding sandbox**: isolated Python execution via `uv` (`numpy`, `matplotlib`, `scipy`, `sympy`, `pandas`) with inline plot rendering in chat.
- **Local web research**: privacy-respecting search via SearXNG, Wikipedia, arXiv and Stack Exchange with full-page extraction and local oMLX reranking.
- **Collapsible work steps**: reasoning tokens (`<think>`) and tool calls are grouped into a clean collapsible progress block during streaming.
- **Archive & trash browser**: dedicated window for searching, previewing and restoring archived or deleted chat sessions.

## 1.0.0

First standalone release of LernAssist: interactive screen-region capture via global hotkey (`⌃⇧L`), streaming chat against OpenAI-compatible servers (oMLX, LM Studio, Ollama), Markdown + KaTeX + highlight.js rendering, didactic study modes, multiple-choice quizzes, SM-2 flashcards, menu bar quick access and local JSON persistence in `~/Library/Application Support/Lernassist/`.
