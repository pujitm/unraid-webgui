/**
 * LogViewerScroll - Hook for efficient log scrolling and "following" behavior
 *
 * Features:
 * - Auto-scroll to bottom when "following" is active
 * - Detect manual scroll up to disable following
 * - Load more history when scrolling to top
 */
const LogViewerScroll = {
  mounted() {
    this.container = this.el;
    this.autoScroll = this.el.dataset.autoScroll === "true";
    this.loadingMore = false;
    this.userScrolled = false;

    // Track user-initiated scroll actions
    this.container.addEventListener("wheel", () => {
      this.userScrolled = true;
    });
    this.container.addEventListener("touchmove", () => {
      this.userScrolled = true;
    });
    this.container.addEventListener("keydown", (e) => {
      if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End"].includes(e.key)) {
        this.userScrolled = true;
      }
    });

    // Scroll event listener - check state after scroll completes
    this.container.addEventListener("scroll", () => {
      this.checkScroll();
    });

    // Handle events from server
    this.handleEvent("log_viewer:scroll_to_bottom", ({ id }) => {
      // Only scroll if this event is for this specific container
      const myId = this.el.id.replace(/-scroll-container$/, "");
      if (id === myId) {
        this.scrollToBottom();
      }
    });

    this.handleEvent("log_viewer:history_loaded", () => {
      this.loadingMore = false;
    });

    // Initial scroll if auto-scroll enabled
    if (this.autoScroll) {
      this.scrollToBottom();
    }
  },

  updated() {
    this.autoScroll = this.el.dataset.autoScroll === "true";
  },

  checkScroll() {
    const isAtTop = this.container.scrollTop <= 50;

    // Only disable auto-scroll if user explicitly scrolled away
    if (this.userScrolled && this.autoScroll) {
      const tolerance = 5;
      const isAtBottom =
        this.container.scrollHeight - this.container.scrollTop - this.container.clientHeight <= tolerance;

      if (!isAtBottom) {
        this.pushEvent("toggle_auto_scroll", { value: false });
        this.autoScroll = false;
      }
      this.userScrolled = false;
    }

    // Request more history when near top
    if (isAtTop && !this.loadingMore && !this.autoScroll) {
      this.loadingMore = true;
      const containerId = this.el.id;
      const componentId = containerId.replace(/-scroll-container$/, "");
      this.pushEvent("load_more_history", { id: componentId });
    }
  },

  scrollToBottom() {
    this.container.scrollTop = this.container.scrollHeight;
  }
};

export default LogViewerScroll;

