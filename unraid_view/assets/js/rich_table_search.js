import Fuse from "fuse.js";

/**
 * Rich Table Search - Fuse.js wrapper for client-side fuzzy search
 *
 * Usage:
 *   const searcher = new RichTableSearch();
 *   searcher.buildIndex(tableElement);
 *   const matchingIds = searcher.search("query");
 */
export class RichTableSearch {
  constructor(options = {}) {
    this.fuse = null;
    this.data = [];
    this.options = {
      threshold: 0.4, // 0 = exact match, 1 = match anything
      ignoreLocation: true, // Search entire string, not just beginning
      includeScore: true,
      keys: ["searchText"],
      ...options,
    };
  }

  /**
   * Build search index from table rows with data-search-text attributes
   * @param {HTMLElement} tableElement - The rich table element
   */
  buildIndex(tableElement) {
    const rows = tableElement.querySelectorAll("tbody tr[data-row-id]");
    this.data = [];

    rows.forEach((row) => {
      const rowId = row.dataset.rowId;
      const searchText = row.dataset.searchText || "";

      if (rowId) {
        this.data.push({
          id: rowId,
          searchText: searchText,
          element: row,
        });
      }
    });

    this.fuse = new Fuse(this.data, this.options);
  }

  /**
   * Update search text for a specific row (used during pulse updates)
   * @param {string} rowId - The row ID
   * @param {string} searchText - New search text
   */
  updateRowSearchText(rowId, searchText) {
    const item = this.data.find((d) => d.id === rowId);
    if (item) {
      item.searchText = searchText;
      // Rebuild the fuse index with updated data
      this.fuse = new Fuse(this.data, this.options);
    }
  }

  /**
   * Add a new row to the index
   * @param {string} rowId - The row ID
   * @param {string} searchText - Search text for the row
   * @param {HTMLElement} element - The row element
   */
  addRow(rowId, searchText, element) {
    // Check if row already exists
    const existingIndex = this.data.findIndex((d) => d.id === rowId);
    if (existingIndex >= 0) {
      this.data[existingIndex] = { id: rowId, searchText, element };
    } else {
      this.data.push({ id: rowId, searchText, element });
    }
    this.fuse = new Fuse(this.data, this.options);
  }

  /**
   * Remove a row from the index
   * @param {string} rowId - The row ID to remove
   */
  removeRow(rowId) {
    this.data = this.data.filter((d) => d.id !== rowId);
    this.fuse = new Fuse(this.data, this.options);
  }

  /**
   * Search for matching rows
   * @param {string} query - Search query
   * @returns {Set<string>} Set of matching row IDs
   */
  search(query) {
    if (!query || !query.trim() || !this.fuse) {
      return null; // null means show all
    }

    const results = this.fuse.search(query.trim());
    return new Set(results.map((r) => r.item.id));
  }

  /**
   * Get total count of indexed rows
   * @returns {number}
   */
  getTotalCount() {
    return this.data.length;
  }
}
