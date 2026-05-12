# grainet_sortable.rb — Grainet::Sortable mixins.
#
# Mixins to wire HTML5 drag-and-drop reordering into a Widget with
# minimal boilerplate. Two mixins, one per role:
#
#   Grainet::Sortable::Item — the draggable row itself. Include and
#   call `make_sortable` in setup. The widget's root gets all five
#   native DnD handlers and dispatches `:sortable_reorder` (bubbling)
#   with detail `{ "src" => ..., "dst" => ..., "pos" => "before"|"after" }`
#   on drop.
#
#   Grainet::Sortable::List — the widget that owns the list. Include
#   and call `sortable_target(refs.list, signal, key: "id")` in setup.
#   Listens for `:sortable_reorder` from rows and applies the reorder
#   to the signal; also handles drops in empty list space (below the
#   last row, in the gap between rows) as "append to end".
#
# Pure data operations (`reorder_items`, `move_to_end`, `drop_before?`)
# live on the parent `Grainet::Sortable` module so they're testable
# without needing a Widget instance.
#
# CSS classes the Item mixin toggles on the row root:
#   is-dragging  — set on the source row while it's being dragged
#   drop-before  — on the hovered target row when cursor is in upper half
#   drop-after   — on the hovered target row when cursor is in lower half
# Style these in your sheet (`opacity: 0.4`, top-edge shadow, etc.).

module Grainet
  module Sortable
    DEFAULT_EVENT = :sortable_reorder

    # ---- Item mixin (row side) ------------------------------------

    module Item
      # Row-side wiring. `id:` names the data-* attribute holding the
      # row identity (defaults to `:id` → `data-id`).
      def make_sortable(id: :id, event: DEFAULT_EVENT)
        id_key = id
        reorder_event = event

        root.on(:dragstart) do |ev|
          ev[:dataTransfer].setData("text/plain", root.data(id_key))
          ev[:dataTransfer][:effectAllowed] = "move"
          root.toggle_class("is-dragging", true)
        end

        root.on(:dragend) do |_ev|
          root.toggle_class("is-dragging", false)
        end

        root.on(:dragover) do |ev|
          ev.preventDefault
          ev[:dataTransfer][:dropEffect] = "move"
          before = Sortable.drop_before?(root, ev)
          root.toggle_class("drop-before", before)
          root.toggle_class("drop-after", !before)
        end

        root.on(:dragleave) do |_ev|
          root.toggle_class("drop-before", false)
          root.toggle_class("drop-after", false)
        end

        root.on(:drop) do |ev|
          ev.preventDefault
          # The List-side `<ul>`-level drop handler is an "off-row"
          # fallback — once a specific row has handled the drop, stop
          # the native event before it bubbles up and triggers
          # append-to-end.
          ev.stopPropagation
          root.toggle_class("drop-before", false)
          root.toggle_class("drop-after", false)
          src_id = ev[:dataTransfer].getData("text/plain").to_s
          dst_id = root.data(id_key).to_s
          pos = Sortable.drop_before?(root, ev) ? "before" : "after"
          root.dispatch(reorder_event,
                        detail: { "src" => src_id, "dst" => dst_id, "pos" => pos },
                        bubbles: true)
        end
      end
    end

    # ---- List mixin (host side) -----------------------------------

    module List
      # Host-side wiring. Listens for the reorder event on the list
      # element itself (`el_ref`) — that scopes naturally to row
      # events from this `<ul>` only, so multiple sortable lists
      # inside one widget (or nested sortable trees) don't cross-fire.
      # Also adds a fallback drop handler on `el_ref` so cursors
      # released in empty list space (below the last row, in the gap
      # between rows) still append the source instead of being lost.
      # `key:` is the Hash key inside each item that carries the row
      # identity (e.g. `"id"`).
      def sortable_target(el_ref, signal, key:, event: DEFAULT_EVENT)
        el = el_ref.is_a?(RefElement) ? el_ref : wrap(el_ref)

        el.on(event) do |ev|
          src_id = ev[:detail][:src].to_s
          dst_id = ev[:detail][:dst].to_s
          pos    = ev[:detail][:pos].to_s
          next if src_id == dst_id
          signal.update { |arr| Sortable.reorder_items(arr, key, src_id, dst_id, pos) }
        end

        el.on(:dragover) do |ev|
          ev.preventDefault
          ev[:dataTransfer][:dropEffect] = "move"
        end

        el.on(:drop) do |ev|
          ev.preventDefault
          src_id = ev[:dataTransfer].getData("text/plain").to_s
          next if src_id.empty?
          signal.update { |arr| Sortable.move_to_end(arr, key, src_id) }
        end
      end
    end

    # ---- Pure data ops (exposed for tests) -------------------------

    # Pull src out of arr, then re-insert before / after dst. Comparison
    # is via `.to_s` on both sides so callers can mix String / Integer
    # ids without normalising upstream.
    def self.reorder_items(arr, key, src_id, dst_id, pos)
      src = src_id.to_s
      dst = dst_id.to_s
      item = arr.find { |it| it[key].to_s == src }
      return arr unless item
      filtered = arr.reject { |it| it[key].to_s == src }
      dst_idx = filtered.index { |it| it[key].to_s == dst }
      return arr unless dst_idx
      dst_idx += 1 if pos == "after"
      filtered.insert(dst_idx, item)
    end

    def self.move_to_end(arr, key, src_id)
      src = src_id.to_s
      item = arr.find { |it| it[key].to_s == src }
      return arr unless item
      arr.reject { |it| it[key].to_s == src } + [item]
    end

    def self.drop_before?(root_el, event)
      rect = root_el.to_js.call(:getBoundingClientRect)
      midpoint = (rect[:top].to_f + rect[:bottom].to_f) / 2.0
      event[:clientY].to_f < midpoint
    end
  end
end
