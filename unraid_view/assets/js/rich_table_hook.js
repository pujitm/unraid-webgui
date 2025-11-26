import {RichTableSearch} from "./rich_table_search"

const DROP_ZONE_RATIO = 0.25
const DROP_MODES = {
  BEFORE: "before",
  AFTER: "after",
  INTO: "into",
  END: "end"
}

const ROW_DROP_CLASSES = {
  before: "rich-table__row--drop-before",
  after: "rich-table__row--drop-after",
  into: "rich-table__row--drop-into"
}

export default {
  mounted() {
    this.columnResizeState = null
    this.draggedHeader = null
    this.draggedRow = null
    this.draggedRows = []
    this.dragPrimaryRow = null
    this.columnOrder = []
    this.selectable = this.el.dataset.selectable === "true"
    this.selection = null
    this.selectionHash = this.el.dataset.selectionHash || null
    this.selectionEvent = this.el.dataset.selectionEvent || null
    this.touchDragState = null

    // Search state
    this.searchable = this.el.dataset.searchable === "true"
    this.searcher = null
    this.searchQuery = ""
    this.searchMatchingIds = null // null = show all

    this.setup()
    this.handleEvent("rich-table:pulse", (payload) => this.applyPulseUpdates(payload))

    // Listen for search events from external search inputs
    this._searchHandler = (e) => this.handleSearchEvent(e)
    window.addEventListener("rich-table:search", this._searchHandler)
  },

  updated() {
    this.setup()
  },

  destroyed() {
    this.teardownColumnResize()
    this.teardownTouchDrag()
    if (this._searchHandler) {
      window.removeEventListener("rich-table:search", this._searchHandler)
      this._searchHandler = null
    }
  },

  setup() {
    this.refreshDomRefs()
    this.selectable = this.el.dataset.selectable === "true"
    this.selectionEvent = this.el.dataset.selectionEvent || null
    this.pendingSelectionHash = this.el.dataset.selectionHash || null
    this.selectionLabelTarget = this.el.dataset.selectionLabelTarget || null
    this.selectionLabelTemplates = {
      none: this.el.dataset.selectionLabelNone || "",
      single: this.el.dataset.selectionLabelSingle || "",
      multiple: this.el.dataset.selectionLabelMultiple || "",
      all: this.el.dataset.selectionLabelAll || ""
    }
    this.lastSelectionBroadcast = null
    this.searchable = this.el.dataset.searchable === "true"
    this.ensureColumnOrder()
    this.initColumnResizing()
    this.initColumnReordering()
    this.initRowDragging()
    this.initRowSelection()
    this.initSearch()
  },

  refreshDomRefs() {
    this.headerCells = Array.from(this.el.querySelectorAll("thead th[data-col-id]"))
    this.rowContainer = this.el.querySelector('[data-role="rich-table-body"]')
  },

  ensureColumnOrder() {
    if (!this.columnOrder.length) {
      this.columnOrder = this.getColumnOrder()
    }
  },

  initColumnResizing() {
    this.headerCells.forEach((th) => {
      if (th.dataset.richTableResizeBound === "1") {
        return
      }

      th.dataset.richTableResizeBound = "1"

      if (th.dataset.resizable === "false") {
        return
      }

      const handle = document.createElement("span")
      handle.className = "rich-table__resize-handle"
      handle.setAttribute("role", "separator")
      handle.setAttribute("aria-orientation", "vertical")
      handle.setAttribute("tabindex", "0")
      handle.title = "Drag to resize"
      handle.addEventListener("pointerdown", (event) => this.beginResize(event, th))
      handle.addEventListener("keydown", (event) => this.handleResizeKeyboard(event, th))
      handle.addEventListener("click", (event) => event.stopPropagation())
      handle.addEventListener("dblclick", (event) => event.stopPropagation())
      th.appendChild(handle)
    })
  },

  beginResize(event, th) {
    event.preventDefault()
    event.stopPropagation()

    const minWidth = parseInt(th.dataset.minWidth || "120", 10)
    // Read the CSS width from inline style if available, otherwise use computed width
    // This prevents jumps when content forces column wider than its set width
    const inlineWidth = th.style.width ? parseInt(th.style.width, 10) : null
    const startWidth = inlineWidth || th.getBoundingClientRect().width
    const startX = event.clientX
    let resizeState = null

    const handlePointerMove = (moveEvent) => {
      const delta = moveEvent.clientX - startX
      const nextWidth = Math.max(minWidth, startWidth + delta)
      this.applyColumnWidth(th.dataset.colId, nextWidth, minWidth)
      resizeState.width = nextWidth
    }

    const handlePointerUp = () => {
      document.removeEventListener("pointermove", resizeState.moveHandler)
      document.removeEventListener("pointerup", resizeState.upHandler)
      th.classList.remove("is-resizing")
      const finalWidth = resizeState.width
      this.columnResizeState = null

      if (typeof finalWidth === "number") {
        this.pushTableEvent(this.el.dataset.columnResizeEvent, {
          table_id: this.el.id,
          column_id: th.dataset.colId,
          width: finalWidth
        })
      }
    }

    resizeState = {
      columnId: th.dataset.colId,
      width: startWidth,
      moveHandler: handlePointerMove,
      upHandler: handlePointerUp
    }
    this.columnResizeState = resizeState

    th.classList.add("is-resizing")
    document.addEventListener("pointermove", resizeState.moveHandler)
    document.addEventListener("pointerup", resizeState.upHandler)
  },

  handleResizeKeyboard(event, th) {
    if (!["ArrowLeft", "ArrowRight"].includes(event.key)) {
      return
    }

    event.preventDefault()
    const minWidth = parseInt(th.dataset.minWidth || "120", 10)
    const delta = event.key === "ArrowLeft" ? -12 : 12
    const nextWidth = Math.max(minWidth, th.offsetWidth + delta)
    this.applyColumnWidth(th.dataset.colId, nextWidth, minWidth)
    this.pushTableEvent(this.el.dataset.columnResizeEvent, {
      table_id: this.el.id,
      column_id: th.dataset.colId,
      width: nextWidth,
      input: "keyboard"
    })
  },

  applyColumnWidth(columnId, width, minWidth) {
    const header = this.el.querySelector(`thead th[data-col-id="${columnId}"]`)
    if (header) {
      header.style.width = `${width}px`
      header.style.minWidth = `${minWidth}px`
    }

    this.rowContainer
      ?.querySelectorAll(`td[data-col-id="${columnId}"]`)
      .forEach((cell) => {
        cell.style.width = `${width}px`
      })
  },

  teardownColumnResize() {
    if (!this.columnResizeState) {
      return
    }

    document.removeEventListener("pointermove", this.columnResizeState.moveHandler)
    document.removeEventListener("pointerup", this.columnResizeState.upHandler)
    this.columnResizeState = null
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

  initColumnReordering() {
    this.headerCells.forEach((th) => {
      if (th.dataset.richTableReorderBound === "1") {
        return
      }

      th.dataset.richTableReorderBound = "1"

      if (th.dataset.reorderable === "false") {
        th.setAttribute("draggable", "false")
        return
      }

      th.setAttribute("draggable", "true")
      th.addEventListener("dragstart", (event) => this.beginColumnDrag(event, th))
      th.addEventListener("dragend", () => this.endColumnDrag())
      th.addEventListener("dragover", (event) => this.handleColumnDragOver(event, th))
      th.addEventListener("dragleave", () => this.clearHeaderDropState(th))
      th.addEventListener("drop", (event) => this.completeColumnDrop(event, th))
    })
  },

  beginColumnDrag(event, th) {
    this.draggedHeader = th
    th.classList.add("is-dragging")
    event.dataTransfer.effectAllowed = "move"
    try {
      event.dataTransfer.setData("text/plain", th.dataset.colId || "")
    } catch (_error) {
      // Safari throws if dataTransfer is not writable; ignore and rely on effectAllowed.
    }
  },

  endColumnDrag() {
    if (this.draggedHeader) {
      this.draggedHeader.classList.remove("is-dragging")
    }
    this.draggedHeader = null
    this.headerCells.forEach((th) => this.clearHeaderDropState(th))
  },

  handleColumnDragOver(event, target) {
    if (!this.draggedHeader || this.draggedHeader === target) {
      return
    }

    event.preventDefault()
    const position = this.columnDropPosition(event, target)
    this.setHeaderDropState(target, position)
  },

  completeColumnDrop(event, target) {
    if (!this.draggedHeader || this.draggedHeader === target) {
      return
    }

    event.preventDefault()
    const position = this.columnDropPosition(event, target)
    const headerRow = target.parentElement

    if (position === DROP_MODES.BEFORE) {
      headerRow.insertBefore(this.draggedHeader, target)
    } else {
      headerRow.insertBefore(this.draggedHeader, target.nextElementSibling)
    }

    this.syncBodyColumnOrder()
    this.refreshDomRefs()
    this.pushColumnOrderEventIfChanged()
    this.endColumnDrag()
  },

  columnDropPosition(event, target) {
    const rect = target.getBoundingClientRect()
    const midpoint = rect.left + rect.width / 2
    return event.clientX < midpoint ? DROP_MODES.BEFORE : DROP_MODES.AFTER
  },

  setHeaderDropState(target, position) {
    this.clearHeaderDropState(target)
    if (position === DROP_MODES.BEFORE) {
      target.classList.add("rich-table__header-cell--drop-before")
    } else {
      target.classList.add("rich-table__header-cell--drop-after")
    }
  },

  clearHeaderDropState(target) {
    target.classList.remove("rich-table__header-cell--drop-before", "rich-table__header-cell--drop-after")
  },

  pushColumnOrderEventIfChanged() {
    const order = this.getColumnOrder()
    if (JSON.stringify(order) === JSON.stringify(this.columnOrder)) {
      return
    }

    this.columnOrder = order
    this.pushTableEvent(this.el.dataset.columnOrderEvent, {
      table_id: this.el.id,
      order
    })
  },

  getColumnOrder() {
    return Array.from(this.el.querySelectorAll("thead th[data-col-id]")).map((th) => th.dataset.colId)
  },

  syncBodyColumnOrder() {
    if (!this.rowContainer) {
      return
    }

    const order = this.getColumnOrder()
    const rows = Array.from(this.rowContainer.querySelectorAll("tr[data-row-id]"))
    rows.forEach((row) => {
      const actionCell = row.querySelector(".rich-table__cell--actions")
      const cellMap = {}
      row.querySelectorAll("td[data-col-id]").forEach((cell) => {
        cellMap[cell.dataset.colId] = cell
      })

      order.forEach((colId) => {
        const cell = cellMap[colId]
        if (cell) {
          row.insertBefore(cell, actionCell)
        }
      })
    })
  },

  initRowDragging() {
    if (!this.rowContainer) {
      return
    }

    this.initRowContainerDropzone()

    const rows = Array.from(this.rowContainer.querySelectorAll("tr[data-row-id]"))
    rows.forEach((row) => {
      if (row.dataset.richTableRowBound !== "1") {
        row.dataset.richTableRowBound = "1"
        row.dataset.dragging = "0"
        row.dataset.handleActive = "0"
        row.draggable = row.dataset.draggable !== "false"

        row.addEventListener("dragstart", (event) => this.beginRowDrag(event, row))
        row.addEventListener("dragend", () => this.endRowDrag())
        row.addEventListener("dragover", (event) => this.handleRowDragOver(event, row))
        row.addEventListener("dragleave", () => this.clearRowDropState(row))
        row.addEventListener("drop", (event) => this.completeRowDrop(event, row))
        row.addEventListener("click", (event) => {
          if (row.dataset.dragging === "1") {
            event.preventDefault()
            event.stopImmediatePropagation()
          }
        })
      }

      this.attachRowHandle(row)
    })
  },

  attachRowHandle(row) {
    const handle = row.querySelector("[data-row-handle]")
    if (!handle) {
      return
    }

    if (handle.dataset.rowHandleBound === "1") {
      return
    }

    handle.dataset.rowHandleBound = "1"

    const enable = () => {
      if (row.dataset.draggable === "false") {
        return
      }
      row.dataset.handleActive = "1"
    }

    const disable = () => {
      if (row.dataset.dragging === "1") {
        return
      }
      row.dataset.handleActive = "0"
    }

    handle.addEventListener("pointerdown", (event) => {
      event.stopPropagation()
      enable()
    })
    handle.addEventListener("pointerup", (event) => {
      event.stopPropagation()
      disable()
    })
    handle.addEventListener("pointercancel", disable)
    handle.addEventListener("pointerleave", disable)
    handle.addEventListener(
      "touchstart",
      (event) => {
        event.stopPropagation()
        event.preventDefault()
        enable()
        this.beginTouchDrag(event, row)
      },
      {passive: false}
    )
    handle.addEventListener("mousedown", (event) => {
      event.stopPropagation()
      enable()
    })
    handle.addEventListener("mouseup", (event) => {
      event.stopPropagation()
      disable()
    })
  },

  initRowContainerDropzone() {
    if (!this.rowContainer || this.rowContainer.dataset.richTableDropzoneBound === "1") {
      return
    }

    this.rowContainer.dataset.richTableDropzoneBound = "1"

    this.rowContainer.addEventListener("dragover", (event) => {
      if (!this.draggedRows.length) {
        return
      }
      event.preventDefault()
      this.clearAllRowDropStates()
    })

    this.rowContainer.addEventListener("drop", (event) => {
      if (!this.draggedRows.length) {
        return
      }
      event.preventDefault()
      this.moveRowDom(this.draggedRows, null, DROP_MODES.END)
      this.pushRowDropEvent(this.draggedRows, null, DROP_MODES.END)
      this.endRowDrag()
    })
  },

  beginRowDrag(event, row) {
    if (row.dataset.draggable === "false" || row.dataset.handleActive !== "1") {
      event.preventDefault()
      event.stopPropagation()
      return
    }

    const rowsToDrag = this.rowsForDrag(row)
    this.draggedRow = row
    this.dragPrimaryRow = row
    this.draggedRows = rowsToDrag
    rowsToDrag.forEach((currentRow) => {
      currentRow.classList.add("is-dragging")
      currentRow.dataset.dragging = "1"
    })
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", row.dataset.rowId)
    this.notifyRowDrag("start", row)
  },

  endRowDrag() {
    const primaryRow = this.dragPrimaryRow

    // Already ended, nothing to do
    if (!primaryRow && !this.draggedRows.length) {
      return
    }

    if (this.draggedRows.length) {
      this.draggedRows.forEach((row) => {
        row.classList.remove("is-dragging")
        row.dataset.dragging = "0"
        row.dataset.handleActive = "0"
      })
    }

    this.draggedRow = null
    this.dragPrimaryRow = null
    this.draggedRows = []
    this.clearAllRowDropStates()
    this.notifyRowDrag("end", primaryRow)
  },

  // Touch-based drag and drop for mobile devices
  beginTouchDrag(event, row) {
    if (row.dataset.draggable === "false") {
      return
    }

    const touch = event.touches[0]
    if (!touch) {
      return
    }

    const rowsToDrag = this.rowsForDrag(row)
    this.draggedRow = row
    this.dragPrimaryRow = row
    this.draggedRows = rowsToDrag

    rowsToDrag.forEach((currentRow) => {
      currentRow.classList.add("is-dragging")
      currentRow.dataset.dragging = "1"
    })

    this.touchDragState = {
      startY: touch.clientY,
      currentTarget: null,
      currentMode: null
    }

    this.notifyRowDrag("start", row)

    // Bind touch move and end handlers to document
    this._touchMoveHandler = (e) => this.handleTouchDragMove(e)
    this._touchEndHandler = (e) => this.handleTouchDragEnd(e)

    document.addEventListener("touchmove", this._touchMoveHandler, {passive: false})
    document.addEventListener("touchend", this._touchEndHandler, {passive: false})
    document.addEventListener("touchcancel", this._touchEndHandler, {passive: false})
  },

  handleTouchDragMove(event) {
    if (!this.touchDragState || !this.draggedRows.length) {
      return
    }

    event.preventDefault()

    const touch = event.touches[0]
    if (!touch) {
      return
    }

    // Find the row element under the touch point
    const targetRow = this.findRowAtPoint(touch.clientX, touch.clientY)

    // Clear previous drop states
    this.clearAllRowDropStates()

    if (targetRow && !this.draggedRows.includes(targetRow)) {
      const mode = this.rowDropModeFromPoint(touch.clientY, targetRow)

      if (targetRow.dataset.droppable === "false" && mode === DROP_MODES.INTO) {
        this.touchDragState.currentTarget = null
        this.touchDragState.currentMode = null
        return
      }

      this.setRowDropState(targetRow, mode)
      this.touchDragState.currentTarget = targetRow
      this.touchDragState.currentMode = mode
    } else {
      this.touchDragState.currentTarget = null
      this.touchDragState.currentMode = null
    }
  },

  handleTouchDragEnd(event) {
    if (!this.touchDragState) {
      return
    }

    event.preventDefault()

    const {currentTarget, currentMode} = this.touchDragState

    // Clean up touch handlers
    document.removeEventListener("touchmove", this._touchMoveHandler)
    document.removeEventListener("touchend", this._touchEndHandler)
    document.removeEventListener("touchcancel", this._touchEndHandler)
    this._touchMoveHandler = null
    this._touchEndHandler = null

    if (currentTarget && currentMode && this.draggedRows.length) {
      this.moveRowDom(this.draggedRows, currentTarget, currentMode)
      this.pushRowDropEvent(this.draggedRows, currentTarget, currentMode)
    }

    this.touchDragState = null
    this.endRowDrag()
  },

  findRowAtPoint(x, y) {
    // Get all rows and find the one at the touch point
    const rows = Array.from(this.rowContainer?.querySelectorAll("tr[data-row-id]") || [])

    for (const row of rows) {
      const rect = row.getBoundingClientRect()
      if (y >= rect.top && y <= rect.bottom && x >= rect.left && x <= rect.right) {
        return row
      }
    }

    return null
  },

  rowDropModeFromPoint(clientY, row) {
    const rect = row.getBoundingClientRect()
    const offset = clientY - rect.top
    const ratio = rect.height ? offset / rect.height : 0.5

    if (ratio < DROP_ZONE_RATIO) {
      return DROP_MODES.BEFORE
    }

    if (ratio > 1 - DROP_ZONE_RATIO) {
      return DROP_MODES.AFTER
    }

    return DROP_MODES.INTO
  },

  handleRowDragOver(event, row) {
    if (!this.draggedRows.length || this.draggedRows.includes(row)) {
      return
    }

    const mode = this.rowDropMode(event, row)
    if (row.dataset.droppable === "false" && mode === DROP_MODES.INTO) {
      return
    }

    event.preventDefault()
    event.stopPropagation()
    this.setRowDropState(row, mode)
  },

  completeRowDrop(event, row) {
    if (!this.draggedRows.length || this.draggedRows.includes(row)) {
      return
    }

    event.preventDefault()
    event.stopPropagation()
    const mode = this.rowDropMode(event, row)
    this.moveRowDom(this.draggedRows, row, mode)
    this.pushRowDropEvent(this.draggedRows, row, mode)
    this.endRowDrag()
  },

  rowDropMode(event, row) {
    const rect = row.getBoundingClientRect()
    const offset = event.clientY - rect.top
    const ratio = rect.height ? offset / rect.height : 0.5

    if (ratio < DROP_ZONE_RATIO) {
      return DROP_MODES.BEFORE
    }

    if (ratio > 1 - DROP_ZONE_RATIO) {
      return DROP_MODES.AFTER
    }

    return DROP_MODES.INTO
  },

  setRowDropState(row, mode) {
    this.clearRowDropState(row)
    const className = ROW_DROP_CLASSES[mode]
    if (className) {
      row.classList.add(className)
    }
  },

  clearRowDropState(row) {
    row.classList.remove(...Object.values(ROW_DROP_CLASSES))
  },

  clearAllRowDropStates() {
    Array.from(this.rowContainer?.querySelectorAll("tr[data-row-id]") || []).forEach((row) =>
      this.clearRowDropState(row)
    )
  },

  moveRowDom(sourceRows, targetRow, mode) {
    if (!this.rowContainer) {
      return
    }

    const rows = Array.isArray(sourceRows) ? sourceRows : [sourceRows]
    if (!rows.length) {
      return
    }

    if (mode === DROP_MODES.END || !targetRow) {
      rows.forEach((row) => {
        this.rowContainer.appendChild(row)
        this.setRowParent(row, null, 0)
      })
      return
    }

    if (mode === DROP_MODES.BEFORE) {
      rows.forEach((row) => {
        this.rowContainer.insertBefore(row, targetRow)
        this.setRowParent(row, targetRow.dataset.parentId, this.getRowDepth(targetRow))
      })
      return
    }

    if (mode === DROP_MODES.AFTER) {
      let reference = targetRow.nextElementSibling

      rows.forEach((row) => {
        this.rowContainer.insertBefore(row, reference)
        this.setRowParent(row, targetRow.dataset.parentId, this.getRowDepth(targetRow))
        reference = row.nextElementSibling
      })
      return
    }

    const insertionPoint = this.findFolderInsertionPoint(targetRow)
    const depth = this.getRowDepth(targetRow) + 1
    rows.forEach((row) => {
      this.rowContainer.insertBefore(row, insertionPoint)
      this.setRowParent(row, targetRow.dataset.rowId, depth)
    })
  },

  setRowParent(row, parentId, depth) {
    row.dataset.parentId = parentId || ""
    row.dataset.depth = depth
    const indentHost = row.querySelector(".rich-table__cell-inner--with-indent")
    if (indentHost) {
      indentHost.style.setProperty("--rich-table-depth", depth)
    }
  },

  findFolderInsertionPoint(targetRow) {
    let cursor = targetRow.nextElementSibling
    const targetDepth = this.getRowDepth(targetRow)
    while (cursor) {
      const cursorDepth = this.getRowDepth(cursor)
      if (cursorDepth <= targetDepth) {
        break
      }
      cursor = cursor.nextElementSibling
    }
    return cursor
  },

  getRowDepth(row) {
    return parseInt(row?.dataset.depth || "0", 10)
  },

  pushRowDropEvent(sourceRows, targetRow, mode) {
    const rows = Array.isArray(sourceRows) ? sourceRows : [sourceRows]
    if (!rows.length) {
      return
    }
    const primaryRow = rows[0]
    const sourceIds = rows
      .map((row) => row.dataset.rowId)
      .filter((rowId) => rowId != null)

    this.pushTableEvent(this.el.dataset.rowDropEvent, {
      table_id: this.el.id,
      source_id: primaryRow.dataset.rowId,
      source_ids: sourceIds,
      target_id: targetRow ? targetRow.dataset.rowId : null,
      action: mode,
      source_parent_id: primaryRow.dataset.parentId || null,
      target_parent_id: targetRow ? targetRow.dataset.parentId || null : null,
      source_depth: this.getRowDepth(primaryRow),
      target_depth: targetRow ? this.getRowDepth(targetRow) : 0,
      source_index: this.rowIndexFor(primaryRow.dataset.rowId),
      target_index: targetRow ? this.rowIndexFor(targetRow.dataset.rowId) : this.rowCount() - 1
    })
  },

  rowIndexFor(rowId) {
    return this.getRowOrder().indexOf(rowId)
  },

  rowCount() {
    return this.getRowOrder().length
  },

  getRowOrder() {
    return Array.from(this.rowContainer?.querySelectorAll("tr[data-row-id]") || []).map(
      (row) => row.dataset.rowId
    )
  },

  initRowSelection() {
    if (!this.selectable) {
      this.selection = null
      this.selectionHash = null
      this.rowSelectionInputs = []
      this.headerSelectionInput = null
      return
    }

    if (!this.selection || this.pendingSelectionHash !== this.selectionHash) {
      this.selection = new Set(this.parseSelectedRowsAttr())
      this.selectionHash = this.pendingSelectionHash
    } else if (!this.selection) {
      this.selection = new Set()
    }

    this.pruneSelection({silent: true})

    const rowInputs = Array.from(this.el.querySelectorAll('input[data-selection-control="row"]'))
    rowInputs.forEach((input) => {
      if (input.dataset.selectionBound === "1") {
        return
      }
      input.dataset.selectionBound = "1"

      const halt = (event) => {
        event.stopPropagation()
      }

      input.addEventListener("pointerdown", halt)
      input.addEventListener("pointerup", halt)
      input.addEventListener("click", halt)
      input.addEventListener("change", (event) => {
        event.stopPropagation()
        this.handleRowCheckboxChange(input)
      })
    })
    this.rowSelectionInputs = rowInputs

    const headerInput = this.el.querySelector('input[data-selection-control="header"]')
    if (headerInput && headerInput.dataset.selectionBound !== "1") {
      headerInput.dataset.selectionBound = "1"
      headerInput.addEventListener("click", (event) => {
        event.preventDefault()
        event.stopPropagation()
        this.toggleHeaderSelection()
      })
    }
    this.headerSelectionInput = headerInput

    this.syncSelectionIntoDom()
  },

  handleRowCheckboxChange(input) {
    if (!this.selection) {
      this.selection = new Set()
    }
    const rowId = input.dataset.rowId
    if (!rowId) {
      return
    }

    if (input.checked) {
      this.selection.add(rowId)
    } else {
      this.selection.delete(rowId)
    }

    this.syncSelectionIntoDom()
    this.pushSelectionChange()
  },

  syncSelectionIntoDom() {
    if (!this.selectable) {
      this.updateSelectionLabel()
      return
    }

    if (!this.selection) {
      this.selection = new Set()
    }

    const selectedIds = this.selection
    const rows = this.getAllRows()
    rows.forEach((row) => {
      const isSelected = selectedIds.has(row.dataset.rowId)
      this.setRowSelectionState(row, isSelected)
    })

    if (this.rowSelectionInputs) {
      this.rowSelectionInputs.forEach((input) => {
        input.checked = selectedIds.has(input.dataset.rowId)
      })
    }

    const selectedCount = selectedIds.size
    const totalCount = rows.length
    this.updateHeaderSelectionState(selectedCount, totalCount)
    this.updateSelectionLabel(selectedCount, totalCount)
  },

  setRowSelectionState(row, selected) {
    if (!row) {
      return
    }

    if (selected) {
      row.dataset.selected = "true"
    } else {
      delete row.dataset.selected
    }

    row.classList.toggle("rich-table__row--selected", Boolean(selected))
  },

  updateHeaderSelectionState(selectedCount, totalCount) {
    if (!this.headerSelectionInput) {
      return
    }

    const total =
      typeof totalCount === "number" ? totalCount : this.getSelectableRowIds().length
    const count =
      typeof selectedCount === "number" ? selectedCount : this.selection ? this.selection.size : 0
    const checked = total > 0 && count === total
    const indeterminate = count > 0 && count < total

    this.headerSelectionInput.checked = checked
    this.headerSelectionInput.indeterminate = indeterminate
    this.headerSelectionInput.setAttribute(
      "aria-checked",
      indeterminate ? "mixed" : checked ? "true" : "false"
    )
  },

  updateSelectionLabel(countOverride, totalOverride) {
    const count =
      typeof countOverride === "number"
        ? countOverride
        : this.selection
          ? this.selection.size
          : 0
    const total =
      typeof totalOverride === "number" ? totalOverride : this.getAllRows().length

    if (this.selectionLabelTarget) {
      const labelEl = document.getElementById(this.selectionLabelTarget)
      if (labelEl) {
        const text = this.selectionLabelText(count, total)
        if (typeof text === "string" && text.length && labelEl.textContent !== text) {
          labelEl.textContent = text
        }
      }
    }

    this.dispatchSelectionChangeEvent(count, total)
  },

  selectionLabelText(count, total) {
    if (!this.selectionLabelTemplates) {
      return null
    }

    let template
    if (count === 0) {
      template = this.selectionLabelTemplates.none
    } else if (total > 0 && count === total) {
      template = this.selectionLabelTemplates.all
    } else if (count === 1) {
      template = this.selectionLabelTemplates.single
    } else {
      template = this.selectionLabelTemplates.multiple
    }

    return this.formatSelectionLabel(template, count, total)
  },

  formatSelectionLabel(template, count, total) {
    if (typeof template !== "string" || template.length === 0) {
      return ""
    }

    return template.replace(/%COUNT%/g, count).replace(/%TOTAL%/g, total)
  },

  dispatchSelectionChangeEvent(count, total) {
    const signature = `${count}/${total}`
    if (this.lastSelectionBroadcast === signature) {
      return
    }

    this.lastSelectionBroadcast = signature

    window.dispatchEvent(
      new CustomEvent("rich-table:selection-changed", {
        detail: {
          tableId: this.el.id,
          count,
          total
        }
      })
    )
  },

  toggleHeaderSelection() {
    if (!this.selectable) {
      return
    }

    const total = this.getSelectableRowIds().length

    if (total === 0) {
      this.clearSelection()
      return
    }

    if (this.selection && this.selection.size === total) {
      this.clearSelection()
    } else {
      this.selectAllRows()
    }
  },

  selectAllRows() {
    this.selection = new Set(this.getSelectableRowIds())
    this.syncSelectionIntoDom()
    this.pushSelectionChange()
  },

  clearSelection() {
    if (!this.selection) {
      this.selection = new Set()
    } else {
      this.selection.clear()
    }
    this.syncSelectionIntoDom()
    this.pushSelectionChange()
  },

  pruneSelection(options = {}) {
    if (!this.selection) {
      this.selection = new Set()
      return
    }

    const allowedIds = new Set(this.getSelectableRowIds())
    let changed = false

    Array.from(this.selection).forEach((rowId) => {
      if (!allowedIds.has(rowId)) {
        this.selection.delete(rowId)
        changed = true
      }
    })

    if (changed) {
      this.syncSelectionIntoDom()
      if (!options.silent) {
        this.pushSelectionChange()
      }
    }
  },

  getAllRows() {
    return Array.from(this.rowContainer?.querySelectorAll("tr[data-row-id]") || [])
  },

  getSelectableRowIds() {
    return this.getAllRows()
      .map((row) => row.dataset.rowId)
      .filter((rowId) => rowId != null)
  },

  getSelectedRowElements() {
    if (!this.selection || !this.selection.size) {
      return []
    }
    return this.getAllRows().filter((row) => this.selection.has(row.dataset.rowId))
  },

  getSelectedRowIdsInDomOrder() {
    if (!this.selection || !this.selection.size) {
      return []
    }
    return this.getAllRows()
      .map((row) => row.dataset.rowId)
      .filter((rowId) => rowId && this.selection.has(rowId))
  },

  rowsForDrag(row) {
    if (!row) {
      return []
    }

    if (!this.selectable || !this.selection || !this.selection.has(row.dataset.rowId)) {
      return [row]
    }

    const selectedRows = this.getSelectedRowElements()
    return selectedRows.length ? selectedRows : [row]
  },

  parseSelectedRowsAttr() {
    const payload = this.el.dataset.selectedRows
    if (!payload) {
      return []
    }

    try {
      const parsed = JSON.parse(payload)
      return Array.isArray(parsed) ? parsed : []
    } catch (_error) {
      return []
    }
  },

  pushSelectionChange(options = {}) {
    if (!this.selectionEvent || options.silent) {
      return
    }

    const selectedIds = this.getSelectedRowIdsInDomOrder()
    this.pushTableEvent(this.selectionEvent, {
      table_id: this.el.id,
      selected_ids: selectedIds
    })
  },

  applyPulseUpdates(payload) {
    if (!payload || payload.target !== this.el.id || !Array.isArray(payload.rows)) {
      return
    }

    payload.rows.forEach((row) => this.updateRowFromPulse(row))

    // Re-apply search visibility after pulse updates
    if (this.searchMatchingIds !== null) {
      this.applySearchVisibility()
    }
  },

  updateRowFromPulse(row) {
    if (!this.rowContainer || !row || !row.id) {
      return
    }

    const rowElement = this.rowContainer.querySelector(`tr[data-row-id="${row.id}"]`)
    if (!rowElement) {
      return
    }

    // Handle pending state (loading indicator)
    if (row.pending !== undefined) {
      this.setRowPendingState(rowElement, row.pending, row.pending_action)
    }

    // Update search text if provided
    if (row.search_text !== undefined && this.searchable) {
      rowElement.dataset.searchText = row.search_text
      if (this.searcher) {
        this.searcher.updateRowSearchText(row.id, row.search_text)
      }
    }

    // Update any field present in the payload that has a matching data-row-field element
    Object.keys(row).forEach((key) => {
      if (["id", "pending", "pending_action", "state_label", "state_class", "search_text"].includes(key)) return
      this.setFieldText(rowElement, key, row[key])
    })

    // Handle state field updates (for badge styling)
    this.setStateField(rowElement, row)
  },

  setRowPendingState(rowElement, isPending, action) {
    if (isPending) {
      rowElement.classList.add("rich-table__row--pending")
      rowElement.dataset.pendingAction = action || ""
    } else {
      rowElement.classList.remove("rich-table__row--pending")
      delete rowElement.dataset.pendingAction
    }
  },

  setFieldText(rowElement, field, value) {
    if (value == null) {
      return
    }

    const fieldEl = rowElement.querySelector(`[data-row-field="${field}"]`)
    if (fieldEl && fieldEl.textContent !== value) {
      fieldEl.textContent = value
    }
  },

  setStateField(rowElement, row) {
    const stateEl = rowElement.querySelector('[data-row-field="state"]')
    if (stateEl) {
      if (row.state_label && stateEl.textContent !== row.state_label) {
        stateEl.textContent = row.state_label
      }

      if (row.state_class) {
        // Preserve badge and badge-sm, replace the color class
        stateEl.className = `badge badge-sm ${row.state_class}`
      }

      if (row.state) {
        stateEl.dataset.state = row.state
      }
    }

    // Update action menu state and visibility
    if (row.state) {
      const actionsEl = rowElement.querySelector('[data-row-actions]')
      if (actionsEl) {
        actionsEl.dataset.state = row.state
        this.updateActionVisibility(actionsEl, row.state)
      }
    }
  },

  /**
   * Update visibility of action menu items based on state.
   * Items with data-show-when="state1 state2" are shown if current state matches any.
   */
  updateActionVisibility(actionsEl, currentState) {
    const items = actionsEl.querySelectorAll('[data-show-when]')
    items.forEach((item) => {
      const showWhen = item.dataset.showWhen.split(/\s+/)
      const shouldShow = showWhen.includes(String(currentState))
      item.style.display = shouldShow ? '' : 'none'
    })
  },

  pushTableEvent(eventName, payload) {
    if (!eventName) {
      return
    }

    if (this.el.getAttribute("phx-target")) {
      this.pushEventTo(this.el, eventName, payload)
    } else {
      this.pushEvent(eventName, payload)
    }
  },

  notifyRowDrag(state, row) {
    const eventName = this.el.dataset.rowDragEvent
    if (!eventName) {
      return
    }

    this.pushTableEvent(eventName, {
      table_id: this.el.id,
      state,
      row_id: row ? row.dataset.rowId : null
    })
  },

  // ─────────────────────────────────────────────────────────────────────────────
  // Search functionality
  // ─────────────────────────────────────────────────────────────────────────────

  initSearch() {
    if (!this.searchable) {
      this.searcher = null
      return
    }

    // Initialize or rebuild the search index
    if (!this.searcher) {
      this.searcher = new RichTableSearch()
    }
    this.searcher.buildIndex(this.el)

    // Re-apply current search if active
    if (this.searchQuery) {
      this.applySearch(this.searchQuery)
    }
  },

  handleSearchEvent(event) {
    const {target, query} = event.detail || {}

    // Only handle events targeting this table
    if (target !== this.el.id) {
      return
    }

    this.applySearch(query || "")
  },

  applySearch(query) {
    this.searchQuery = query.trim()

    if (!this.searchQuery) {
      this.clearSearch()
      return
    }

    if (!this.searcher) {
      return
    }

    // Get matching row IDs from Fuse.js
    this.searchMatchingIds = this.searcher.search(this.searchQuery)
    this.applySearchVisibility()
  },

  clearSearch() {
    this.searchQuery = ""
    this.searchMatchingIds = null

    // Show all rows
    this.getAllRows().forEach((row) => {
      row.classList.remove("rich-table__row--search-hidden")
    })

    this.dispatchSearchResult(null, this.getAllRows().length)
  },

  applySearchVisibility() {
    const rows = this.getAllRows()
    let visibleCount = 0

    rows.forEach((row) => {
      const rowId = row.dataset.rowId
      const isVisible = this.searchMatchingIds === null || this.searchMatchingIds.has(rowId)

      if (isVisible) {
        row.classList.remove("rich-table__row--search-hidden")
        visibleCount++
      } else {
        row.classList.add("rich-table__row--search-hidden")
      }
    })

    this.dispatchSearchResult(visibleCount, rows.length)
  },

  dispatchSearchResult(visible, total) {
    window.dispatchEvent(
      new CustomEvent("rich-table:search-result", {
        detail: {
          tableId: this.el.id,
          visible: visible,
          total: total,
          query: this.searchQuery
        }
      })
    )
  },

  rebuildSearchIndex() {
    if (this.searchable && this.searcher) {
      this.searcher.buildIndex(this.el)
      // Re-apply current search
      if (this.searchQuery) {
        this.searchMatchingIds = this.searcher.search(this.searchQuery)
        this.applySearchVisibility()
      }
    }
  }
}

