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
    this.ensureColumnOrder()
    this.initColumnResizing()
    this.initColumnReordering()
    this.initRowDragging()
    this.initRowSelection()
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
    if (this.draggedRows.length) {
      this.draggedRows.forEach((row) => {
        row.classList.remove("is-dragging")
        row.dataset.dragging = "0"
        row.dataset.handleActive = "0"
      })
    }
    const primaryRow = this.dragPrimaryRow
    this.draggedRow = null
    this.dragPrimaryRow = null
    this.draggedRows = []
    this.clearAllRowDropStates()
    this.notifyRowDrag("end", primaryRow)
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

