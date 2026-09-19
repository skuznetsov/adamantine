# App-owned bridge to the pinned crystal_tui piece tree.
#
# The dependency is pinned to c70c5426a09f0487ece0fbb9264b4d73ef402818 in
# shard.yml.  Keep this seam small: it deliberately uses only the private
# tree operations that implement the public snapshot/edit contracts at that
# revision.  If the dependency moves, this file must be re-audited before the
# application is built.
module Tui
  class PieceTreeBuffer
    # Replace one already-validated byte range as a single root construction.
    # Unlike delete + insert, this never exposes a transient root whose
    # boundary is an invalid CRLF split (for example, replacing X in "\rX\n").
    # The removed range is not materialized, so the operation does not create
    # a document-sized deleted-string copy.
    def replace_range_atomic(offset : Int32, length : Int32, replacement : String) : Nil
      validate_range(offset, length)
      raise ArgumentError.new("replacement text must be valid UTF-8") unless replacement.valid_encoding?
      return if length == 0 && replacement.empty?

      left, suffix = split(@root, offset)
      _removed, right = split(suffix, length)
      inserted = tree_for_insert(replacement)
      @root = concatenate(concatenate(left, inserted), right)
      ensure_height_bound!
    end

    # Prepare a candidate that shares the immutable current root and snapshot
    # token, but owns its append page.  The token must remain shared so the
    # candidate root can be adopted by the live buffer after history captures
    # the old root.
    def replace_fork : PieceTreeBuffer
      fork = dup
      fork.replace_reset_append_page!
      fork
    end

    # Adopt a prepared candidate's root and mutable allocation state.  The
    # caller must have checked same_state?(the original snapshot) immediately
    # before opening history; this method itself performs the token guard.
    def adopt_replace_fork!(candidate : PieceTreeBuffer) : Nil
      root, add_page, priority_state, token = candidate.replace_fork_state
      raise ArgumentError.new("replacement candidate belongs to different buffer storage") unless token.same?(@snapshot_token)

      @root = root
      @add_page = add_page
      @priority_state = priority_state
    end

    protected def replace_reset_append_page! : Nil
      @add_page = IO::Memory.new
    end

    protected def replace_fork_state
      {@root, @add_page, @priority_state, @snapshot_token}
    end
  end
end
