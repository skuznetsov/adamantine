require "uri"

module CrystalEditor
  module UriCodec
    def self.path_to_uri(path : Path) : String
      "file://#{URI.encode_path(path.expand.to_s)}".gsub("\\", "/")
    end

    def self.uri_to_path(uri : String) : Path?
      return nil unless uri.starts_with?("file://")

      raw_path = uri[7..]
      begin
        Path.new(URI.decode(raw_path))
      rescue
        nil
      end
    end
  end
end
