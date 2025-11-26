/**
 * CardList Hook - Composable card list with drag & drop and selection support
 *
 * This hook manages:
 * - Drag & drop reordering (desktop and touch)
 * - Multi-select with checkboxes
 * - Expand/collapse toggle events
 * - Tree structure with depth-based indentation
 */

const DROP_ZONE_RATIO = 0.25
const DROP_MODES = {
  BEFORE: "before",
  AFTER: "after",
  INTO: "into",
  END: "end"
}

const DROP_CLASSES = {
  before: "card-list__row--drop-before",
  after: "card-list__row--drop-after",
  into: "card-list__row--drop-into"
}

export default {
  mounted() {
    this.draggedRows = []
    this.dragPrimaryRow = null
    this.selectable = this.el.dataset.selectable === "true"
    this.draggable = this.el.dataset.draggable === "true"
    this.selection = null
    this.selectionHash = this.el.dataset.selectionHash || null
    this.touchDragState = null

    this.setup()
  },

  updated() {
    this.setup()
  },

  destroyed() {
    this.teardownTouchDrag()
  },

  setup() {
    this.refreshDomRefs()
    this.selectable = this.el.dataset.selectable === "true"
    this.draggable = this.el.dataset.draggable === "true"
    this.pendingSelectionHash = this.el.dataset.selectionHash || null

    if (this.draggable) {
      this.initDragging()
    }
    if (this.selectable) {
      this.initSelection()
    }
    this.initExpandToggles()
  },

  refreshDomRefs() {
    this.container = this.el.querySelector('[data-role="card-list-container"]')
  },

  // ===========================================================================
  // Dragging
  // ===========================================================================

  initDragging() {
    if (!this.container) return

    this.initContainerDropzone()

    const rows = this.getAllRows()
    rows.forEach((row) => {
      if (row.dataset.cardListBound !== "1") {
        row.dataset.cardListBound = "1"
        row.dataset.dragging = "0"
        row.dataset.handleActive = "0"

        row.addEventListener("dragstart", (e) => this.beginDrag(e, row))
        row.addEventListener("dragend", () => this.endDrag())
        row.addEventListener("dragover", (e) => this.handleDragOver(e, row))
        row.addEventListener("dragleave", () => this.clearDropState(row))
        row.addEventListener("drop", (e) => this.completeDrop(e, row))
        row.addEventListener("click", (e) => {
          if (row.dataset.dragging === "1") {
            e.preventDefault()
            e.stopImmediatePropagation()
          }
        })
      }

      this.attachDragHandle(row)
    })
  },

  attachDragHandle(row) {
    const handle = row.querySelector("[data-drag-handle]")
    if (!handle || handle.dataset.handleBound === "1") return

    handle.dataset.handleBound = "1"

    const enable = () => {
      row.dataset.handleActive = "1"
      row.draggable = true
    }

    const disable = () => {
      if (row.dataset.dragging === "1") return
      row.dataset.handleActive = "0"
      row.draggable = false
    }

    handle.addEventListener("pointerdown", (e) => {
      e.stopPropagation()
      enable()
    })
    handle.addEventListener("pointerup", (e) => {
      e.stopPropagation()
      disable()
    })
    handle.addEventListener("pointercancel", disable)
    handle.addEventListener("pointerleave", disable)
    handle.addEventListener("touchstart", (e) => {
      e.stopPropagation()
      e.preventDefault()
      enable()
      this.beginTouchDrag(e, row)
    }, {passive: false})
    handle.addEventListener("mousedown", (e) => {
      e.stopPropagation()
      enable()
    })
    handle.addEventListener("mouseup", (e) => {
      e.stopPropagation()
      disable()
    })
  },

  initContainerDropzone() {
    if (!this.container || this.container.dataset.dropzoneBound === "1") return

    this.container.dataset.dropzoneBound = "1"

    this.container.addEventListener("dragover", (e) => {
      if (!this.draggedRows.length) return
      e.preventDefault()
      this.clearAllDropStates()
    })

    this.container.addEventListener("drop", (e) => {
      if (!this.draggedRows.length) return
      e.preventDefault()
      this.moveRowsDom(this.draggedRows, null, DROP_MODES.END)
      this.pushDropEvent(this.draggedRows, null, DROP_MODES.END)
      this.endDrag()
    })
  },

  beginDrag(event, row) {
    if (row.dataset.handleActive !== "1") {
      event.preventDefault()
      event.stopPropagation()
      return
    }

    const rowsToDrag = this.rowsForDrag(row)
    this.dragPrimaryRow = row
    this.draggedRows = rowsToDrag

    rowsToDrag.forEach((r) => {
      r.classList.add("is-dragging")
      r.dataset.dragging = "1"
    })

    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", row.dataset.rowId)
    this.notifyDrag("start", row)
  },

  endDrag() {
    const primaryRow = this.dragPrimaryRow

    if (this.draggedRows.length) {
      this.draggedRows.forEach((row) => {
        row.classList.remove("is-dragging")
        row.dataset.dragging = "0"
        row.dataset.handleActive = "0"
        row.draggable = false
      })
    }

    this.dragPrimaryRow = null
    this.draggedRows = []
    this.clearAllDropStates()
    this.notifyDrag("end", primaryRow)
  },

  // ===========================================================================
  // Touch Drag & Drop
  // ===========================================================================

  beginTouchDrag(event, row) {
    const touch = event.touches[0]
    if (!touch) return

    const rowsToDrag = this.rowsForDrag(row)
    this.dragPrimaryRow = row
    this.draggedRows = rowsToDrag

    rowsToDrag.forEach((r) => {
      r.classList.add("is-dragging")
      r.dataset.dragging = "1"
    })

    this.touchDragState = {
      startY: touch.clientY,
      currentTarget: null,
      currentMode: null
    }

    this.notifyDrag("start", row)

    this._touchMoveHandler = (e) => this.handleTouchDragMove(e)
    this._touchEndHandler = (e) => this.handleTouchDragEnd(e)

    document.addEventListener("touchmove", this._touchMoveHandler, {passive: false})
    document.addEventListener("touchend", this._touchEndHandler, {passive: false})
    document.addEventListener("touchcancel", this._touchEndHandler, {passive: false})
  },

  handleTouchDragMove(event) {
    if (!this.touchDragState || !this.draggedRows.length) return

    event.preventDefault()

    const touch = event.touches[0]
    if (!touch) return

    const targetRow = this.findRowAtPoint(touch.clientX, touch.clientY)
    this.clearAllDropStates()

    if (targetRow && !this.draggedRows.includes(targetRow)) {
      const mode = this.dropModeFromPoint(touch.clientY, targetRow)
      this.setDropState(targetRow, mode)
      this.touchDragState.currentTarget = targetRow
      this.touchDragState.currentMode = mode
    } else {
      this.touchDragState.currentTarget = null
      this.touchDragState.currentMode = null
    }
  },

  handleTouchDragEnd(event) {
    if (!this.touchDragState) return

    event.preventDefault()

    const {currentTarget, currentMode} = this.touchDragState

    document.removeEventListener("touchmove", this._touchMoveHandler)
    document.removeEventListener("touchend", this._touchEndHandler)
    document.removeEventListener("touchcancel", this._touchEndHandler)
    this._touchMoveHandler = null
    this._touchEndHandler = null

    if (currentTarget && currentMode && this.draggedRows.length) {
      this.moveRowsDom(this.draggedRows, currentTarget, currentMode)
      this.pushDropEvent(this.draggedRows, currentTarget, currentMode)
    }

    this.touchDragState = null
    this.endDrag()
  },

  findRowAtPoint(x, y) {
    const rows = this.getAllRows()
    for (const row of rows) {
      const rect = row.getBoundingClientRect()
      if (y >= rect.top && y <= rect.bottom && x >= rect.left && x <= rect.right) {
        return row
      }
    }
    return null
  },

  teardownTouchDrag() {
    if (this._touchMoveHandler) {
      document.removeEventListener("touchmove", this._touchMoveHandler)
      this._touchMoveHandler = null
    }
    if (this._touchEndHandler) {
      document.removeEventListener("touchend", this._touchEndHandler)
      document.removeEventListener("touchcancel", this._touchEndHandler)
      this._touchEndHandler = null
    }
    this.touchDragState = null
  },

  // ===========================================================================
  // Drag Over / Drop
  // ===========================================================================

  handleDragOver(event, row) {
    if (!this.draggedRows.length || this.draggedRows.includes(row)) return

    const mode = this.dropModeFromEvent(event, row)
    event.preventDefault()
    event.stopPropagation()
    this.setDropState(row, mode)
  },

  completeDrop(event, row) {
    if (!this.draggedRows.length || this.draggedRows.includes(row)) return

    event.preventDefault()
    event.stopPropagation()
    const mode = this.dropModeFromEvent(event, row)
    this.moveRowsDom(this.draggedRows, row, mode)
    this.pushDropEvent(this.draggedRows, row, mode)
    this.endDrag()
  },

  dropModeFromEvent(event, row) {
    return this.dropModeFromPoint(event.clientY, row)
  },

  dropModeFromPoint(clientY, row) {
    const rect = row.getBoundingClientRect()
    const offset = clientY - rect.top
    const ratio = rect.height ? offset / rect.height : 0.5

    if (ratio < DROP_ZONE_RATIO) return DROP_MODES.BEFORE
    if (ratio > 1 - DROP_ZONE_RATIO) return DROP_MODES.AFTER
    return DROP_MODES.INTO
  },

  setDropState(row, mode) {
    this.clearDropState(row)
    const className = DROP_CLASSES[mode]
    if (className) row.classList.add(className)
  },

  clearDropState(row) {
    row.classList.remove(...Object.values(DROP_CLASSES))
  },

  clearAllDropStates() {
    this.getAllRows().forEach((row) => this.clearDropState(row))
  },

  // ===========================================================================
  // DOM Manipulation
  // ===========================================================================

  moveRowsDom(sourceRows, targetRow, mode) {
    if (!this.container) return

    const rows = Array.isArray(sourceRows) ? sourceRows : [sourceRows]
    if (!rows.length) return

    if (mode === DROP_MODES.END || !targetRow) {
      rows.forEach((row) => {
        this.container.appendChild(row)
        this.setRowParent(row, null, 0)
      })
      return
    }

    if (mode === DROP_MODES.BEFORE) {
      rows.forEach((row) => {
        this.container.insertBefore(row, targetRow)
        this.setRowParent(row, targetRow.dataset.parentId, this.getRowDepth(targetRow))
      })
      return
    }

    if (mode === DROP_MODES.AFTER) {
      let reference = targetRow.nextElementSibling
      rows.forEach((row) => {
        this.container.insertBefore(row, reference)
        this.setRowParent(row, targetRow.dataset.parentId, this.getRowDepth(targetRow))
        reference = row.nextElementSibling
      })
      return
    }

    // INTO mode - nest into target
    const insertionPoint = this.findFolderInsertionPoint(targetRow)
    const depth = this.getRowDepth(targetRow) + 1
    rows.forEach((row) => {
      this.container.insertBefore(row, insertionPoint)
      this.setRowParent(row, targetRow.dataset.rowId, depth)
    })
  },

  setRowParent(row, parentId, depth) {
    row.dataset.parentId = parentId || ""
    row.dataset.depth = depth
    row.style.setProperty("--card-depth", depth)
  },

  findFolderInsertionPoint(targetRow) {
    let cursor = targetRow.nextElementSibling
    const targetDepth = this.getRowDepth(targetRow)
    while (cursor) {
      const cursorDepth = this.getRowDepth(cursor)
      if (cursorDepth <= targetDepth) break
      cursor = cursor.nextElementSibling
    }
    return cursor
  },

  getRowDepth(row) {
    return parseInt(row?.dataset.depth || "0", 10)
  },

  // ===========================================================================
  // Events
  // ===========================================================================

  pushDropEvent(sourceRows, targetRow, mode) {
    const rows = Array.isArray(sourceRows) ? sourceRows : [sourceRows]
    if (!rows.length) return

    const primaryRow = rows[0]
    const sourceIds = rows.map((row) => row.dataset.rowId).filter((id) => id != null)

    // If dropping "into" a non-folder, prompt for folder name
    let folderName = null
    if (mode === DROP_MODES.INTO && targetRow && targetRow.dataset.type !== "folder") {
      folderName = window.prompt("Enter a name for the new folder:")
      if (folderName === null) {
        // User cancelled - abort the drop
        return
      }
      folderName = folderName.trim()
      if (!folderName) {
        // Empty name - abort
        return
      }
    }

    this.pushEvent(this.el.dataset.rowDropEvent, {
      list_id: this.el.id,
      source_id: primaryRow.dataset.rowId,
      source_ids: sourceIds,
      target_id: targetRow ? targetRow.dataset.rowId : null,
      action: mode,
      source_parent_id: primaryRow.dataset.parentId || null,
      target_parent_id: targetRow ? targetRow.dataset.parentId || null : null,
      source_depth: this.getRowDepth(primaryRow),
      target_depth: targetRow ? this.getRowDepth(targetRow) : 0,
      folder_name: folderName
    })
  },

  notifyDrag(state, row) {
    const eventName = this.el.dataset.rowDragEvent
    if (!eventName) return

    this.pushEvent(eventName, {
      list_id: this.el.id,
      state,
      row_id: row ? row.dataset.rowId : null
    })
  },

  // ===========================================================================
  // Selection
  // ===========================================================================

  initSelection() {
    if (!this.selection || this.pendingSelectionHash !== this.selectionHash) {
      this.selection = new Set(this.parseSelectedAttr())
      this.selectionHash = this.pendingSelectionHash
    }

    this.pruneSelection({silent: true})

    const checkboxes = Array.from(this.el.querySelectorAll('input[data-selection-control="card"]'))
    checkboxes.forEach((input) => {
      if (input.dataset.selectionBound === "1") return
      input.dataset.selectionBound = "1"

      const halt = (e) => e.stopPropagation()

      input.addEventListener("pointerdown", halt)
      input.addEventListener("pointerup", halt)
      input.addEventListener("click", halt)
      input.addEventListener("change", (e) => {
        e.stopPropagation()
        this.handleCheckboxChange(input)
      })
    })

    this.syncSelectionToDom()
  },

  handleCheckboxChange(input) {
    if (!this.selection) this.selection = new Set()

    const rowId = input.dataset.rowId
    if (!rowId) return

    if (input.checked) {
      this.selection.add(rowId)
    } else {
      this.selection.delete(rowId)
    }

    this.syncSelectionToDom()
    this.pushSelectionChange()
  },

  syncSelectionToDom() {
    if (!this.selectable || !this.selection) return

    const rows = this.getAllRows()
    rows.forEach((row) => {
      const isSelected = this.selection.has(row.dataset.rowId)
      if (isSelected) {
        row.dataset.selected = "true"
        row.classList.add("card-list__row--selected")
      } else {
        delete row.dataset.selected
        row.classList.remove("card-list__row--selected")
      }
    })

    const checkboxes = Array.from(this.el.querySelectorAll('input[data-selection-control="card"]'))
    checkboxes.forEach((input) => {
      input.checked = this.selection.has(input.dataset.rowId)
    })
  },

  rowsForDrag(row) {
    if (!row) return []

    if (!this.selectable || !this.selection || !this.selection.has(row.dataset.rowId)) {
      return [row]
    }

    const selectedRows = this.getAllRows().filter((r) => this.selection.has(r.dataset.rowId))
    return selectedRows.length ? selectedRows : [row]
  },

  parseSelectedAttr() {
    const payload = this.el.dataset.selectedRows
    if (!payload) return []

    try {
      const parsed = JSON.parse(payload)
      return Array.isArray(parsed) ? parsed : []
    } catch (_error) {
      return []
    }
  },

  pruneSelection(options = {}) {
    if (!this.selection) {
      this.selection = new Set()
      return
    }

    const allowedIds = new Set(this.getAllRows().map((r) => r.dataset.rowId).filter(Boolean))
    let changed = false

    Array.from(this.selection).forEach((id) => {
      if (!allowedIds.has(id)) {
        this.selection.delete(id)
        changed = true
      }
    })

    if (changed && !options.silent) {
      this.syncSelectionToDom()
      this.pushSelectionChange()
    }
  },

  pushSelectionChange() {
    const eventName = this.el.dataset.selectionEvent
    if (!eventName) return

    const selectedIds = this.getAllRows()
      .map((r) => r.dataset.rowId)
      .filter((id) => id && this.selection.has(id))

    this.pushEvent(eventName, {
      list_id: this.el.id,
      selected_ids: selectedIds
    })
  },

  getAllRows() {
    return Array.from(this.container?.querySelectorAll("[data-row-id]") || [])
  },

  // ===========================================================================
  // Expand/Collapse
  // ===========================================================================

  initExpandToggles() {
    const toggles = Array.from(this.el.querySelectorAll("[data-expand-toggle]"))
    toggles.forEach((toggle) => {
      if (toggle.dataset.expandBound === "1") return
      toggle.dataset.expandBound = "1"

      toggle.addEventListener("click", (e) => {
        e.stopPropagation()
        const row = toggle.closest("[data-row-id]")
        if (row) this.toggleExpand(row)
      })
    })
  },

  toggleExpand(row) {
    const rowId = row.dataset.rowId
    const isExpanded = row.dataset.expanded === "true"
    const eventName = this.el.dataset.expandEvent

    if (!eventName) return

    // Push event to server - let server handle state
    this.pushEvent(eventName, {
      list_id: this.el.id,
      id: rowId,
      expanded: !isExpanded
    })
  }
}
