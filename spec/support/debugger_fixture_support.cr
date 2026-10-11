module DebuggerFixtureSupport
  def self.ruby_executable : String
    resolve_executable("ruby") || raise "Ruby is required for local DAP fixtures"
  end

  def self.resolve_executable(name : String, search_path : String? = ENV["PATH"]?) : String?
    candidate = Process.find_executable(name, search_path)
    candidate.try { |path| canonical_executable(path) }
  end

  def self.canonical_executable(path : String) : String
    canonical = File.realpath(path)
    info = File.info?(canonical, follow_symlinks: false)
    unless info && info.not_nil!.file? && (info.not_nil!.permissions.to_i & 0o111) != 0
      raise "fixture executable is missing or not a regular executable file: #{path}"
    end
    canonical
  end
end
