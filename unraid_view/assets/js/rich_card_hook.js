/**
 * RichCard Hook - Card-based data display with drag & drop support
 *
 * This hook provides drag & drop reordering for card-based layouts,
 * similar to RichTableHook but adapted for card elements.
 */

const DROP_ZONE_RATIO = 0.25
const DROP_MODES = {
  BEFORE: "before",
  AFTER: "after",
  INTO: "into",
  END: "end"
}

const CARD_DROP_CLASSES = {
  before: "rich-card--drop-before",
  after: "rich-card--drop-after",
  into: "rich-card--drop-into"
}

export default {
  mounted() {
    this.draggedCard = null
    this.draggedCards = []
    this.dragPrimaryCard = null
    this.selectable = this.el.dataset.selectable === "true"
    this.selection = null
    this.selectionHash = this.el.dataset.selectionHash || null
    this.selectionEvent = this.el.dataset.selectionEvent || null
    this.touchDragState = null

    this.setup()
    this.handleEvent("rich-card:pulse", (payload) => this.applyPulseUpdates(payload))
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
    this.selectionEvent = this.el.dataset.selectionEvent || null
    this.pendingSelectionHash = this.el.dataset.selectionHash || null
    this.initCardDragging()
    this.initCardSelection()
    this.initExpandToggle()
  },

  refreshDomRefs() {
    this.cardContainer = this.el.querySelector('[data-role="rich-card-container"]')
  },

  // ---------------------------------------------------------------------------
  // Card Dragging
  // ---------------------------------------------------------------------------

  initCardDragging() {
    if (!this.cardContainer) {
      return
    }

    this.initCardContainerDropzone()

    const cards = Array.from(this.cardContainer.querySelectorAll("[data-card-id]"))
    cards.forEach((card) => {
      if (card.dataset.richCardBound !== "1") {
        card.dataset.richCardBound = "1"
        card.dataset.dragging = "0"
        card.dataset.handleActive = "0"

        card.addEventListener("dragstart", (event) => this.beginCardDrag(event, card))
        card.addEventListener("dragend", () => this.endCardDrag())
        card.addEventListener("dragover", (event) => this.handleCardDragOver(event, card))
        card.addEventListener("dragleave", () => this.clearCardDropState(card))
        card.addEventListener("drop", (event) => this.completeCardDrop(event, card))
        card.addEventListener("click", (event) => {
          if (card.dataset.dragging === "1") {
            event.preventDefault()
            event.stopImmediatePropagation()
          }
        })
      }

      this.attachCardHandle(card)
    })
  },

  attachCardHandle(card) {
    const handle = card.querySelector("[data-card-handle]")
    if (!handle) {
      return
    }

    if (handle.dataset.cardHandleBound === "1") {
      return
    }

    handle.dataset.cardHandleBound = "1"

    const enable = () => {
      if (card.dataset.draggable === "false") {
        return
      }
      card.dataset.handleActive = "1"
      card.draggable = true
    }

    const disable = () => {
      if (card.dataset.dragging === "1") {
        return
      }
      card.dataset.handleActive = "0"
      card.draggable = false
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
        this.beginTouchDrag(event, card)
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

  initCardContainerDropzone() {
    if (!this.cardContainer || this.cardContainer.dataset.richCardDropzoneBound === "1") {
      return
    }

    this.cardContainer.dataset.richCardDropzoneBound = "1"

    this.cardContainer.addEventListener("dragover", (event) => {
      if (!this.draggedCards.length) {
        return
      }
      event.preventDefault()
      this.clearAllCardDropStates()
    })

    this.cardContainer.addEventListener("drop", (event) => {
      if (!this.draggedCards.length) {
        return
      }
      event.preventDefault()
      this.moveCardDom(this.draggedCards, null, DROP_MODES.END)
      this.pushCardDropEvent(this.draggedCards, null, DROP_MODES.END)
      this.endCardDrag()
    })
  },

  beginCardDrag(event, card) {
    if (card.dataset.draggable === "false" || card.dataset.handleActive !== "1") {
      event.preventDefault()
      event.stopPropagation()
      return
    }

    const cardsToDrag = this.cardsForDrag(card)
    this.draggedCard = card
    this.dragPrimaryCard = card
    this.draggedCards = cardsToDrag
    cardsToDrag.forEach((c) => {
      c.classList.add("is-dragging")
      c.dataset.dragging = "1"
    })
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", card.dataset.cardId)
    this.notifyCardDrag("start", card)
  },

  endCardDrag() {
    const primaryCard = this.dragPrimaryCard

    if (!primaryCard && !this.draggedCards.length) {
      return
    }

    if (this.draggedCards.length) {
      this.draggedCards.forEach((card) => {
        card.classList.remove("is-dragging")
        card.dataset.dragging = "0"
        card.dataset.handleActive = "0"
        card.draggable = false
      })
    }

    this.draggedCard = null
    this.dragPrimaryCard = null
    this.draggedCards = []
    this.clearAllCardDropStates()
    this.notifyCardDrag("end", primaryCard)
  },

  // ---------------------------------------------------------------------------
  // Touch Drag & Drop (Mobile)
  // ---------------------------------------------------------------------------

  beginTouchDrag(event, card) {
    if (card.dataset.draggable === "false") {
      return
    }

    const touch = event.touches[0]
    if (!touch) {
      return
    }

    const cardsToDrag = this.cardsForDrag(card)
    this.draggedCard = card
    this.dragPrimaryCard = card
    this.draggedCards = cardsToDrag

    cardsToDrag.forEach((c) => {
      c.classList.add("is-dragging")
      c.dataset.dragging = "1"
    })

    this.touchDragState = {
      startY: touch.clientY,
      currentTarget: null,
      currentMode: null
    }

    this.notifyCardDrag("start", card)

    this._touchMoveHandler = (e) => this.handleTouchDragMove(e)
    this._touchEndHandler = (e) => this.handleTouchDragEnd(e)

    document.addEventListener("touchmove", this._touchMoveHandler, {passive: false})
    document.addEventListener("touchend", this._touchEndHandler, {passive: false})
    document.addEventListener("touchcancel", this._touchEndHandler, {passive: false})
  },

  handleTouchDragMove(event) {
    if (!this.touchDragState || !this.draggedCards.length) {
      return
    }

    event.preventDefault()

    const touch = event.touches[0]
    if (!touch) {
      return
    }

    const targetCard = this.findCardAtPoint(touch.clientX, touch.clientY)

    this.clearAllCardDropStates()

    if (targetCard && !this.draggedCards.includes(targetCard)) {
      const mode = this.cardDropModeFromPoint(touch.clientY, targetCard)

      if (targetCard.dataset.droppable === "false" && mode === DROP_MODES.INTO) {
        this.touchDragState.currentTarget = null
        this.touchDragState.currentMode = null
        return
      }

      this.setCardDropState(targetCard, mode)
      this.touchDragState.currentTarget = targetCard
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

    document.removeEventListener("touchmove", this._touchMoveHandler)
    document.removeEventListener("touchend", this._touchEndHandler)
    document.removeEventListener("touchcancel", this._touchEndHandler)
    this._touchMoveHandler = null
    this._touchEndHandler = null

    if (currentTarget && currentMode && this.draggedCards.length) {
      this.moveCardDom(this.draggedCards, currentTarget, currentMode)
      this.pushCardDropEvent(this.draggedCards, currentTarget, currentMode)
    }

    this.touchDragState = null
    this.endCardDrag()
  },

  findCardAtPoint(x, y) {
    const cards = Array.from(this.cardContainer?.querySelectorAll("[data-card-id]") || [])

    for (const card of cards) {
      const rect = card.getBoundingClientRect()
      if (y >= rect.top && y <= rect.bottom && x >= rect.left && x <= rect.right) {
        return card
      }
    }

    return null
  },

  cardDropModeFromPoint(clientY, card) {
    const rect = card.getBoundingClientRect()
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

  // ---------------------------------------------------------------------------
  // Drag Over / Drop
  // ---------------------------------------------------------------------------

  handleCardDragOver(event, card) {
    if (!this.draggedCards.length || this.draggedCards.includes(card)) {
      return
    }

    const mode = this.cardDropMode(event, card)
    if (card.dataset.droppable === "false" && mode === DROP_MODES.INTO) {
      return
    }

    event.preventDefault()
    event.stopPropagation()
    this.setCardDropState(card, mode)
  },

  completeCardDrop(event, card) {
    if (!this.draggedCards.length || this.draggedCards.includes(card)) {
      return
    }

    event.preventDefault()
    event.stopPropagation()
    const mode = this.cardDropMode(event, card)
    this.moveCardDom(this.draggedCards, card, mode)
    this.pushCardDropEvent(this.draggedCards, card, mode)
    this.endCardDrag()
  },

  cardDropMode(event, card) {
    const rect = card.getBoundingClientRect()
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

  setCardDropState(card, mode) {
    this.clearCardDropState(card)
    const className = CARD_DROP_CLASSES[mode]
    if (className) {
      card.classList.add(className)
    }
  },

  clearCardDropState(card) {
    card.classList.remove(...Object.values(CARD_DROP_CLASSES))
  },

  clearAllCardDropStates() {
    Array.from(this.cardContainer?.querySelectorAll("[data-card-id]") || []).forEach((card) =>
      this.clearCardDropState(card)
    )
  },

  // ---------------------------------------------------------------------------
  // DOM Manipulation
  // ---------------------------------------------------------------------------

  moveCardDom(sourceCards, targetCard, mode) {
    if (!this.cardContainer) {
      return
    }

    const cards = Array.isArray(sourceCards) ? sourceCards : [sourceCards]
    if (!cards.length) {
      return
    }

    if (mode === DROP_MODES.END || !targetCard) {
      cards.forEach((card) => {
        this.cardContainer.appendChild(card)
        this.setCardParent(card, null, 0)
      })
      return
    }

    if (mode === DROP_MODES.BEFORE) {
      cards.forEach((card) => {
        this.cardContainer.insertBefore(card, targetCard)
        this.setCardParent(card, targetCard.dataset.parentId, this.getCardDepth(targetCard))
      })
      return
    }

    if (mode === DROP_MODES.AFTER) {
      let reference = targetCard.nextElementSibling

      cards.forEach((card) => {
        this.cardContainer.insertBefore(card, reference)
        this.setCardParent(card, targetCard.dataset.parentId, this.getCardDepth(targetCard))
        reference = card.nextElementSibling
      })
      return
    }

    // INTO mode - nest into target
    const insertionPoint = this.findFolderInsertionPoint(targetCard)
    const depth = this.getCardDepth(targetCard) + 1
    cards.forEach((card) => {
      this.cardContainer.insertBefore(card, insertionPoint)
      this.setCardParent(card, targetCard.dataset.cardId, depth)
    })
  },

  setCardParent(card, parentId, depth) {
    card.dataset.parentId = parentId || ""
    card.dataset.depth = depth
    card.style.setProperty("--rich-card-depth", depth)
  },

  findFolderInsertionPoint(targetCard) {
    let cursor = targetCard.nextElementSibling
    const targetDepth = this.getCardDepth(targetCard)
    while (cursor) {
      const cursorDepth = this.getCardDepth(cursor)
      if (cursorDepth <= targetDepth) {
        break
      }
      cursor = cursor.nextElementSibling
    }
    return cursor
  },

  getCardDepth(card) {
    return parseInt(card?.dataset.depth || "0", 10)
  },

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  pushCardDropEvent(sourceCards, targetCard, mode) {
    const cards = Array.isArray(sourceCards) ? sourceCards : [sourceCards]
    if (!cards.length) {
      return
    }
    const primaryCard = cards[0]
    const sourceIds = cards.map((card) => card.dataset.cardId).filter((id) => id != null)

    this.pushCardEvent(this.el.dataset.rowDropEvent, {
      table_id: this.el.id,
      source_id: primaryCard.dataset.cardId,
      source_ids: sourceIds,
      target_id: targetCard ? targetCard.dataset.cardId : null,
      action: mode,
      source_parent_id: primaryCard.dataset.parentId || null,
      target_parent_id: targetCard ? targetCard.dataset.parentId || null : null,
      source_depth: this.getCardDepth(primaryCard),
      target_depth: targetCard ? this.getCardDepth(targetCard) : 0,
      source_index: this.cardIndexFor(primaryCard.dataset.cardId),
      target_index: targetCard ? this.cardIndexFor(targetCard.dataset.cardId) : this.cardCount() - 1
    })
  },

  cardIndexFor(cardId) {
    return this.getCardOrder().indexOf(cardId)
  },

  cardCount() {
    return this.getCardOrder().length
  },

  getCardOrder() {
    return Array.from(this.cardContainer?.querySelectorAll("[data-card-id]") || []).map(
      (card) => card.dataset.cardId
    )
  },

  notifyCardDrag(state, card) {
    const eventName = this.el.dataset.rowDragEvent
    if (!eventName) {
      return
    }

    this.pushCardEvent(eventName, {
      table_id: this.el.id,
      state,
      row_id: card ? card.dataset.cardId : null
    })
  },

  pushCardEvent(eventName, payload) {
    if (!eventName) {
      return
    }

    if (this.el.getAttribute("phx-target")) {
      this.pushEventTo(this.el, eventName, payload)
    } else {
      this.pushEvent(eventName, payload)
    }
  },

  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  initCardSelection() {
    if (!this.selectable) {
      this.selection = null
      this.selectionHash = null
      this.cardSelectionInputs = []
      return
    }

    if (!this.selection || this.pendingSelectionHash !== this.selectionHash) {
      this.selection = new Set(this.parseSelectedCardsAttr())
      this.selectionHash = this.pendingSelectionHash
    } else if (!this.selection) {
      this.selection = new Set()
    }

    this.pruneSelection({silent: true})

    const cardInputs = Array.from(this.el.querySelectorAll('input[data-selection-control="card"]'))
    cardInputs.forEach((input) => {
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
        this.handleCardCheckboxChange(input)
      })
    })
    this.cardSelectionInputs = cardInputs

    this.syncSelectionIntoDom()
  },

  handleCardCheckboxChange(input) {
    if (!this.selection) {
      this.selection = new Set()
    }
    const cardId = input.dataset.cardId
    if (!cardId) {
      return
    }

    if (input.checked) {
      this.selection.add(cardId)
    } else {
      this.selection.delete(cardId)
    }

    this.syncSelectionIntoDom()
    this.pushSelectionChange()
  },

  syncSelectionIntoDom() {
    if (!this.selectable) {
      return
    }

    if (!this.selection) {
      this.selection = new Set()
    }

    const selectedIds = this.selection
    const cards = this.getAllCards()
    cards.forEach((card) => {
      const isSelected = selectedIds.has(card.dataset.cardId)
      this.setCardSelectionState(card, isSelected)
    })

    if (this.cardSelectionInputs) {
      this.cardSelectionInputs.forEach((input) => {
        input.checked = selectedIds.has(input.dataset.cardId)
      })
    }
  },

  setCardSelectionState(card, selected) {
    if (!card) {
      return
    }

    if (selected) {
      card.dataset.selected = "true"
    } else {
      delete card.dataset.selected
    }

    card.classList.toggle("rich-card--selected", Boolean(selected))
  },

  getAllCards() {
    return Array.from(this.cardContainer?.querySelectorAll("[data-card-id]") || [])
  },

  getSelectableCardIds() {
    return this.getAllCards()
      .map((card) => card.dataset.cardId)
      .filter((cardId) => cardId != null)
  },

  getSelectedCardElements() {
    if (!this.selection || !this.selection.size) {
      return []
    }
    return this.getAllCards().filter((card) => this.selection.has(card.dataset.cardId))
  },

  getSelectedCardIdsInDomOrder() {
    if (!this.selection || !this.selection.size) {
      return []
    }
    return this.getAllCards()
      .map((card) => card.dataset.cardId)
      .filter((cardId) => cardId && this.selection.has(cardId))
  },

  cardsForDrag(card) {
    if (!card) {
      return []
    }

    if (!this.selectable || !this.selection || !this.selection.has(card.dataset.cardId)) {
      return [card]
    }

    const selectedCards = this.getSelectedCardElements()
    return selectedCards.length ? selectedCards : [card]
  },

  parseSelectedCardsAttr() {
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

  pruneSelection(options = {}) {
    if (!this.selection) {
      this.selection = new Set()
      return
    }

    const allowedIds = new Set(this.getSelectableCardIds())
    let changed = false

    Array.from(this.selection).forEach((cardId) => {
      if (!allowedIds.has(cardId)) {
        this.selection.delete(cardId)
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

  pushSelectionChange(options = {}) {
    if (!this.selectionEvent || options.silent) {
      return
    }

    const selectedIds = this.getSelectedCardIdsInDomOrder()
    this.pushCardEvent(this.selectionEvent, {
      table_id: this.el.id,
      selected_ids: selectedIds
    })
  },

  // ---------------------------------------------------------------------------
  // Expand/Collapse
  // ---------------------------------------------------------------------------

  initExpandToggle() {
    const toggles = Array.from(this.el.querySelectorAll("[data-expand-toggle]"))
    toggles.forEach((toggle) => {
      if (toggle.dataset.expandBound === "1") {
        return
      }
      toggle.dataset.expandBound = "1"

      toggle.addEventListener("click", (event) => {
        event.stopPropagation()
        const card = toggle.closest("[data-card-id]")
        if (card) {
          this.toggleCardExpand(card)
        }
      })
    })
  },

  toggleCardExpand(card) {
    const cardId = card.dataset.cardId
    const isExpanded = card.dataset.expanded === "true"

    // Toggle local state
    card.dataset.expanded = isExpanded ? "false" : "true"

    // Update icon
    const toggle = card.querySelector("[data-expand-toggle]")
    if (toggle) {
      toggle.setAttribute("aria-expanded", isExpanded ? "false" : "true")
      const icon = toggle.querySelector("[class*='hero-']")
      if (icon) {
        if (isExpanded) {
          icon.className = icon.className.replace("hero-chevron-down", "hero-chevron-right")
        } else {
          icon.className = icon.className.replace("hero-chevron-right", "hero-chevron-down")
        }
      }
    }

    // Toggle visibility of child cards
    this.toggleChildCardVisibility(cardId, !isExpanded)

    // Notify server
    this.pushCardEvent("rich_card:toggle_expand", {
      table_id: this.el.id,
      card_id: cardId,
      expanded: !isExpanded
    })
  },

  toggleChildCardVisibility(parentId, visible) {
    const cards = this.getAllCards()
    cards.forEach((card) => {
      if (card.dataset.parentId === parentId) {
        if (visible) {
          card.classList.remove("rich-card--hidden")
        } else {
          card.classList.add("rich-card--hidden")
        }
        // Recursively hide grandchildren if collapsing
        if (!visible) {
          this.toggleChildCardVisibility(card.dataset.cardId, false)
        }
      }
    })
  },

  // ---------------------------------------------------------------------------
  // Pulse Updates (optional real-time streaming)
  // ---------------------------------------------------------------------------

  applyPulseUpdates(payload) {
    if (!payload || payload.target !== this.el.id || !Array.isArray(payload.rows)) {
      return
    }

    payload.rows.forEach((row) => this.updateCardFromPulse(row))
  },

  updateCardFromPulse(row) {
    if (!this.cardContainer || !row || !row.id) {
      return
    }

    const cardElement = this.cardContainer.querySelector(`[data-card-id="${row.id}"]`)
    if (!cardElement) {
      return
    }

    // Handle pending state (loading indicator)
    if (row.pending !== undefined) {
      this.setCardPendingState(cardElement, row.pending, row.pending_action)
    }

    // Update any field present in the payload that has a matching data-card-field element
    Object.keys(row).forEach((key) => {
      if (["id", "pending", "pending_action", "state_label", "state_class"].includes(key)) return
      this.setFieldText(cardElement, key, row[key])
    })

    // Handle state field updates (for badge styling)
    this.setStateField(cardElement, row)
  },

  setCardPendingState(cardElement, isPending, action) {
    if (isPending) {
      cardElement.classList.add("rich-card--pending")
      cardElement.dataset.pendingAction = action || ""
    } else {
      cardElement.classList.remove("rich-card--pending")
      delete cardElement.dataset.pendingAction
    }
  },

  setFieldText(cardElement, field, value) {
    if (value == null) {
      return
    }

    const fieldEl = cardElement.querySelector(`[data-card-field="${field}"]`)
    if (fieldEl && fieldEl.textContent !== value) {
      fieldEl.textContent = value
    }
  },

  setStateField(cardElement, row) {
    const stateEl = cardElement.querySelector('[data-card-field="state"]')
    if (stateEl) {
      if (row.state_label && stateEl.textContent !== row.state_label) {
        stateEl.textContent = row.state_label
      }

      if (row.state_class) {
        stateEl.className = `badge badge-sm ${row.state_class}`
      }

      if (row.state) {
        stateEl.dataset.state = row.state
      }
    }
  }
}
