/**
 * Terminal Hook
 *
 * LiveView hook that integrates xterm.js for terminal emulation.
 * Handles bidirectional communication between the server PTY and browser terminal.
 */

import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { WebLinksAddon } from "@xterm/addon-web-links"

// Catppuccin-inspired terminal themes
const THEMES = {
  dark: {
    background: "#1e1e2e",
    foreground: "#cdd6f4",
    cursor: "#f5e0dc",
    cursorAccent: "#1e1e2e",
    selectionBackground: "#585b70",
    selectionForeground: "#cdd6f4",
    black: "#45475a",
    red: "#f38ba8",
    green: "#a6e3a1",
    yellow: "#f9e2af",
    blue: "#89b4fa",
    magenta: "#f5c2e7",
    cyan: "#94e2d5",
    white: "#bac2de",
    brightBlack: "#585b70",
    brightRed: "#f38ba8",
    brightGreen: "#a6e3a1",
    brightYellow: "#f9e2af",
    brightBlue: "#89b4fa",
    brightMagenta: "#f5c2e7",
    brightCyan: "#94e2d5",
    brightWhite: "#a6adc8",
  },
  light: {
    background: "#eff1f5",
    foreground: "#4c4f69",
    cursor: "#dc8a78",
    cursorAccent: "#eff1f5",
    selectionBackground: "#acb0be",
    selectionForeground: "#4c4f69",
    black: "#5c5f77",
    red: "#d20f39",
    green: "#40a02b",
    yellow: "#df8e1d",
    blue: "#1e66f5",
    magenta: "#ea76cb",
    cyan: "#179299",
    white: "#acb0be",
    brightBlack: "#6c6f85",
    brightRed: "#d20f39",
    brightGreen: "#40a02b",
    brightYellow: "#df8e1d",
    brightBlue: "#1e66f5",
    brightMagenta: "#ea76cb",
    brightCyan: "#179299",
    brightWhite: "#bcc0cc",
  },
}

export default {
  mounted() {
    this.sessionId = this.el.dataset.sessionId
    this.terminalId = this.el.id
    this.theme = this.el.dataset.theme || "dark"
    this.fontSize = parseInt(this.el.dataset.fontSize) || 14

    this.initTerminal()
    this.setupEventListeners()
    this.setupResizeObserver()

    // Signal ready to receive output
    this.pushEvent("terminal_ready", { id: this.terminalId })
  },

  initTerminal() {
    const container = this.el.querySelector("[data-terminal-target='container']")

    if (!container) {
      console.error("[TerminalHook] Container element not found")
      return
    }

    this.fitAddon = new FitAddon()

    this.terminal = new Terminal({
      theme: THEMES[this.theme] || THEMES.dark,
      fontSize: this.fontSize,
      fontFamily:
        '"JetBrains Mono", "Fira Code", "Cascadia Code", "SF Mono", Menlo, Monaco, "Courier New", monospace',
      cursorBlink: true,
      cursorStyle: "block",
      scrollback: 10000,
      allowProposedApi: true,
      convertEol: true,
    })

    this.terminal.loadAddon(this.fitAddon)
    this.terminal.loadAddon(new WebLinksAddon())

    this.terminal.open(container)

    // Fit after a brief delay to ensure container has dimensions
    requestAnimationFrame(() => {
      this.fitAddon.fit()
      this.sendResize()
    })
  },

  setupEventListeners() {
    // Handle user input - send to server
    this.terminal.onData((data) => {
      this.pushEvent("terminal_input", {
        id: this.terminalId,
        data: data,
      })
    })

    // Handle server output - write to terminal
    this.handleEvent("terminal:output", ({ id, data }) => {
      if (id === this.terminalId && this.terminal) {
        // Decode base64 data
        try {
          const decoded = atob(data)
          this.terminal.write(decoded)
        } catch (e) {
          // If not base64, write directly
          this.terminal.write(data)
        }
      }
    })

    // Handle terminal exit
    this.handleEvent("terminal:exit", ({ id, code }) => {
      if (id === this.terminalId && this.terminal) {
        this.terminal.writeln(`\r\n\x1b[90m[Process exited with code ${code}]\x1b[0m`)
        this.terminal.writeln("\x1b[90m[Press any key to close]\x1b[0m")

        // One-time listener for any key to close
        const disposable = this.terminal.onKey(() => {
          disposable.dispose()
          this.pushEvent("terminal_close", { id: this.terminalId })
        })
      }
    })

    // Handle clear command from server
    this.handleEvent("terminal:clear", ({ id }) => {
      if (id === this.terminalId && this.terminal) {
        this.terminal.clear()
      }
    })
  },

  setupResizeObserver() {
    this.resizeObserver = new ResizeObserver(() => {
      this.handleResize()
    })
    this.resizeObserver.observe(this.el)
  },

  handleResize() {
    if (this.resizeTimeout) {
      clearTimeout(this.resizeTimeout)
    }

    // Debounce resize events
    this.resizeTimeout = setTimeout(() => {
      if (this.fitAddon && this.terminal) {
        this.fitAddon.fit()
        this.sendResize()
      }
    }, 100)
  },

  sendResize() {
    if (this.terminal) {
      const { cols, rows } = this.terminal
      this.pushEvent("terminal_resize", {
        id: this.terminalId,
        cols: cols,
        rows: rows,
      })
    }
  },

  updated() {
    // Re-fit if the element was updated (e.g., visibility change)
    if (this.fitAddon && this.terminal) {
      requestAnimationFrame(() => {
        this.fitAddon.fit()
        this.sendResize()
      })
    }
  },

  destroyed() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
    if (this.terminal) {
      this.terminal.dispose()
    }
    if (this.resizeTimeout) {
      clearTimeout(this.resizeTimeout)
    }
  },
}
