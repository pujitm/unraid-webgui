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
    this.columnOrder = []

    this.setup()
    this.handleEvent("rich-table:pulse", (payload) => this.applyPulseUpdates(payload))
  },

  updated() {
    this.setup()
  },

  destroyed() {
    this.teardownColumnResize()
  },

  setup() {
    this.refreshDomRefs()
    this.ensureColumnOrder()
    this.initColumnResizing()
    this.initColumnReordering()
    this.initRowDragging()
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
    const startWidth = th.offsetWidth
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
        row.addEventListener("dragend", () => this.endRowDrag(row))
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
      },
      {passive: false}
    )
    handle.addEventListener(
      "touchend",
      (event) => {
        event.stopPropagation()
        event.preventDefault()
        disable()
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
      if (!this.draggedRow) {
        return
      }
      event.preventDefault()
      this.clearAllRowDropStates()
    })

    this.rowContainer.addEventListener("drop", (event) => {
      if (!this.draggedRow) {
        return
      }
      event.preventDefault()
      this.moveRowDom(this.draggedRow, null, DROP_MODES.END)
      this.pushRowDropEvent(this.draggedRow, null, DROP_MODES.END)
      this.endRowDrag(this.draggedRow)
    })
  },

  beginRowDrag(event, row) {
    if (row.dataset.draggable === "false" || row.dataset.handleActive !== "1") {
      event.preventDefault()
      event.stopPropagation()
      return
    }

    this.draggedRow = row
    row.classList.add("is-dragging")
    row.dataset.dragging = "1"
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", row.dataset.rowId)
    this.notifyRowDrag("start", row)
  },

  endRowDrag(row) {
    if (row) {
      row.classList.remove("is-dragging")
    }
    if (row) {
      row.dataset.dragging = "0"
      row.dataset.handleActive = "0"
    }
    this.draggedRow = null
    this.clearAllRowDropStates()
    this.notifyRowDrag("end", row)
  },

  handleRowDragOver(event, row) {
    if (!this.draggedRow || row === this.draggedRow) {
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
    if (!this.draggedRow || row === this.draggedRow) {
      return
    }

    event.preventDefault()
    event.stopPropagation()
    const mode = this.rowDropMode(event, row)
    this.moveRowDom(this.draggedRow, row, mode)
    this.pushRowDropEvent(this.draggedRow, row, mode)
    this.endRowDrag(this.draggedRow)
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

  moveRowDom(sourceRow, targetRow, mode) {
    if (!this.rowContainer) {
      return
    }

    if (mode === DROP_MODES.END || !targetRow) {
      this.rowContainer.appendChild(sourceRow)
      this.setRowParent(sourceRow, null, 0)
      return
    }

    if (mode === DROP_MODES.BEFORE) {
      this.rowContainer.insertBefore(sourceRow, targetRow)
      this.setRowParent(sourceRow, targetRow.dataset.parentId, this.getRowDepth(targetRow))
    } else if (mode === DROP_MODES.AFTER) {
      this.rowContainer.insertBefore(sourceRow, targetRow.nextElementSibling)
      this.setRowParent(sourceRow, targetRow.dataset.parentId, this.getRowDepth(targetRow))
    } else {
      const insertionPoint = this.findFolderInsertionPoint(targetRow)
      const depth = this.getRowDepth(targetRow) + 1
      this.rowContainer.insertBefore(sourceRow, insertionPoint)
      this.setRowParent(sourceRow, targetRow.dataset.rowId, depth)
    }
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

  pushRowDropEvent(sourceRow, targetRow, mode) {
    this.pushTableEvent(this.el.dataset.rowDropEvent, {
      table_id: this.el.id,
      source_id: sourceRow.dataset.rowId,
      target_id: targetRow ? targetRow.dataset.rowId : null,
      action: mode,
      source_parent_id: sourceRow.dataset.parentId || null,
      target_parent_id: targetRow ? targetRow.dataset.parentId || null : null,
      source_depth: this.getRowDepth(sourceRow),
      target_depth: targetRow ? this.getRowDepth(targetRow) : 0,
      source_index: this.rowIndexFor(sourceRow.dataset.rowId),
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

  applyPulseUpdates(payload) {
    if (!payload || payload.target !== this.el.id || !Array.isArray(payload.rows)) {
      return
    }

    payload.rows.forEach((row) => this.updateRowFromPulse(row))
  },

  updateRowFromPulse(row) {
    if (!this.rowContainer || !row || !row.id) {
      return
    }

    const rowElement = this.rowContainer.querySelector(`tr[data-row-id="${row.id}"]`)
    if (!rowElement) {
      return
    }

    this.setFieldText(rowElement, "description", row.description)
    this.setFieldText(rowElement, "updated_at", row.updated_at)
    this.setStatusField(rowElement, row)
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

  setStatusField(rowElement, row) {
    const statusEl = rowElement.querySelector('[data-row-field="status"]')
    if (!statusEl) {
      return
    }

    if (row.status_label && statusEl.textContent !== row.status_label) {
      statusEl.textContent = row.status_label
    }

    if (row.status_class) {
      statusEl.className = `badge badge-sm text-xs tracking-tight ${row.status_class}`
    }

    if (row.status) {
      statusEl.dataset.status = row.status
    }
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
  }
}

