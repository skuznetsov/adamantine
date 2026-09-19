require "./session_store"

module Adamantine
  # Owns the opt-in boundary around UI-session persistence.  The store is
  # deliberately constructed during App.new but remains inactive until the
  # real application lifecycle starts; construction alone must not touch the
  # state directory.
  class SessionController
    getter enabled : Bool

    def initialize(
      state_root : Path? = nil,
      enabled : Bool? = nil,
      @report : Proc(String, Nil)? = nil,
    )
      @enabled = enabled.nil? ? ENV["ADAMANTINE_SESSION"]? != "0" : enabled.not_nil!
      @store = SessionStore.new(state_root, enabled: @enabled)
      @active = false
    end

    def activate : Nil
      @active = @enabled
    end

    def deactivate : Nil
      @active = false
    end

    def active? : Bool
      @active && @enabled
    end

    def load(project_root : Path) : SessionStore::LoadResult?
      return nil unless active?

      result = @store.load(project_root)
      report_warnings(result.warnings)
      result
    rescue ex
      report("Session restore failed: #{ex.message || ex.class}")
      nil
    end

    def save(snapshot : SessionStore::Snapshot) : Bool
      return false unless active?

      result = @store.save(snapshot)
      report_warnings(result.warnings)
      unless result.saved?
        report("Session state was not saved") if result.warnings.empty?
      end
      result.saved?
    rescue ex
      report("Session save failed: #{ex.message || ex.class}")
      false
    end

    def state_path(project_root : Path) : Path
      @store.state_path(project_root)
    end

    private def report_warnings(warnings : Array(String)) : Nil
      warnings.each { |warning| report(warning) }
    end

    private def report(message : String) : Nil
      @report.try(&.call(message))
    end
  end
end
