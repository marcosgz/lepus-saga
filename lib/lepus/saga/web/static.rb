# frozen_string_literal: true

require "digest"

module Lepus
  module Saga
    module Web
      # Serves the console page and its assets from Web::ROOT. The page gets a
      # <base href> of the mount path, so every relative URL works wherever
      # the console is mounted, and points at "assets-<digest>/", a path that
      # changes with the asset files and is therefore cached for a year.
      # Plain "assets/" paths are served too, revalidated through their ETag.
      class Static
        CONTENT_SECURITY_POLICY = [
          "default-src 'self'", "script-src 'self'", "style-src 'self'", "img-src 'self' data:",
          "font-src 'self'", "connect-src 'self'", "object-src 'none'", "base-uri 'self'",
          "form-action 'self'", "frame-ancestors 'self'"
        ].join("; ").freeze
        IMMUTABLE = "public, max-age=31536000, immutable"
        REVALIDATE = "no-cache"
        INDEX_PATHS = ["", "/", "/index.html"].freeze

        def initialize(config, root: ROOT)
          @config = config
          @root = root
          @etags = {}
        end

        def call(env)
          return not_allowed unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

          path = env["PATH_INFO"].to_s
          return index(env) if INDEX_PATHS.include?(path)

          case path
          when %r{\A/assets-(?<digest>\h+)/(?<file>.+)\z}
            asset(env, $~[:file], ($~[:digest] == assets_digest) ? IMMUTABLE : REVALIDATE)
          when %r{\A/assets/(?<file>.+)\z}
            asset(env, $~[:file], REVALIDATE)
          else
            not_found
          end
        end

        private

        attr_reader :config, :root

        def index(env)
          base = "#{env["SCRIPT_NAME"].to_s.chomp("/")}/"
          html = File.read(File.join(root, "index.html"))
            .gsub("{{base}}", Rack::Utils.escape_html(base))
            .gsub("{{assets}}", "assets-#{assets_digest}")
            .gsub("{{title}}", Rack::Utils.escape_html(config.title))
          headers = {
            "content-type" => "text/html; charset=utf-8",
            "cache-control" => REVALIDATE,
            "content-security-policy" => CONTENT_SECURITY_POLICY
          }
          respond(env, html, %("#{Digest::SHA256.hexdigest(html)[0, 32]}"), headers)
        end

        def asset(env, file, cache_control)
          path = resolve(file)
          return not_found unless path

          headers = {"content-type" => Rack::Mime.mime_type(File.extname(path), "application/octet-stream"), "cache-control" => cache_control}
          respond(env, File.binread(path), etag(path), headers)
        end

        def respond(env, content, etag, headers)
          headers = headers.merge("etag" => etag)
          return [304, headers, []] if env["HTTP_IF_NONE_MATCH"].to_s.split(/\s*,\s*/).include?(etag)

          body = (env["REQUEST_METHOD"] == "HEAD") ? [] : [content]
          [200, headers.merge("content-length" => content.bytesize.to_s), body]
        end

        def resolve(file)
          return if file.include?("\0")

          assets = File.join(root, "assets")
          path = File.expand_path(file, assets)
          path if path.start_with?("#{assets}/") && File.file?(path)
        end

        def etag(path)
          stat = File.stat(path)
          @etags[[path, stat.mtime.to_r, stat.size]] ||= %("#{Digest::SHA256.file(path).hexdigest[0, 32]}")
        end

        def assets_digest
          assets = File.join(root, "assets")
          files = Dir.glob(File.join(assets, "**", "*")).select { |path| File.file?(path) }.sort
          Digest::SHA256.hexdigest(files.map { |path| "#{path.delete_prefix(assets)}:#{etag(path)}" }.join("\n"))[0, 16]
        end

        def not_found
          [404, {"content-type" => "text/plain; charset=utf-8"}, ["Not found"]]
        end

        def not_allowed
          [405, {"content-type" => "text/plain; charset=utf-8", "allow" => "GET, HEAD"}, ["Method not allowed"]]
        end
      end
    end
  end
end
