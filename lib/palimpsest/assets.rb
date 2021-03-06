require 'active_support/inflector'
require 'open3'
require 'pathname'
require 'sprockets'

module Palimpsest
  # Flexible asset pipeline using Sprockets.
  # Paths are loaded into a `Sprockets::Environment` (relative to {#directory} if given).
  # Asset tags are used in source code and replaced
  # with generated asset path or compiled source if `inline` is used.
  #
  # For example, if type is set to `:javascripts` the following replacements would be made:
  #
  #     [% javascript app %] -> app-9413c7f112033f0c6f2a8e8dd313399c18d93878.js
  #     [% javascript lib/jquery %] -> lib/jquery-e2a8cde3f5b3cdb011e38a673556c7a94729e0d1.js
  #     [% javascript inline tracking %] -> <compiled source of tracking.js asset>
  #
  # Disable some cops until they can be refactored in the rubocop branch.
  # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/CyclomaticComplexity
  class Assets
    # Default {#options}.
    DEFAULT_OPTIONS = {
      # Backend to use for file search operations.
      # :grep to use grep.
      search_backend: :grep,

      # Default path to output all saved assets (relative to directory).
      output: nil,

      # Default path to serve all assets from.
      # Does not affect where assets are saved.
      # This is prepended to all generated asset references.
      # If `output` is also specified, this will replace it in all asset references only.
      serve_root: nil,

      # Assume assets will be served under this url,
      # e.g., `https://cdn.example.com/`.
      cdn: '',

      # Keyword to use in asset tag for inline assets.
      inline: 'inline',

      # If true, use sprockets-image_compressor with pngcrush and jpegoptim.
      image_compression: false,

      # If true, also generate a gzipped asset.
      gzip: false,

      # Include hash in asset name.
      # Can be set to `:also_unhashed` to include a hash,
      # but additionally write an unhased file.
      hash: true,

      # Opening and closing brackets for asset source tags.
      src_pre: '[%',
      src_post: '%]',

      # Allowed options for `Sprockets::Environment`.
      sprockets_options: [:js_compressor, :css_compressor]
    }

    # @!attribute directory
    #   @return [String] directory which all paths will be relative to if set
    #
    # @!attribute paths
    #   @return [Array] paths to load into sprockets environment
    #
    # @!attribute type
    #   @return [Symbol] type of asset
    attr_accessor :directory, :paths, :type

    def initialize(directory: nil, options: {}, paths: {})
      self.options options
      self.directory = directory
      self.paths = paths
    end

    # Uses {DEFAULT_OPTIONS} as initial value.
    # @param options [Hash] merged with current options
    # @return [Hash] current options
    def options(options = {})
      @options ||= DEFAULT_OPTIONS
      @options = @options.merge options
    end

    # @return [Sprockets::Environment] the current sprockets environment
    def sprockets
      @sprockets ||= Sprockets::Environment.new
    end

    # Load options into the sprockets environment.
    # Values are loaded from {#options}.
    def load_options
      options[:sprockets_options].each do |opt|
        sprockets.send "#{opt}=".to_sym, options[opt] if options[opt]
      end

      if options[:image_compression]
        Sprockets::ImageCompressor::Integration.setup sprockets
      end

      self
    end

    # Load paths into the sprockets environment.
    # Values are loaded from {#paths}.
    def load_paths
      paths.each do |path|
        full_path = path
        full_path = File.join(directory, path) unless directory.nil?
        sprockets.append_path full_path
      end
      self
    end

    # @return [Sprockets::Environment] sprockets environment with {#options} and {#paths} loaded
    def assets
      unless @loaded
        load_options
        load_paths
      end
      @loaded = true
      sprockets
    end

    # Write a target asset to file with a hashed name.
    # @param target [String] logical path to asset
    # @param gzip [Boolean] if the asset should be gzipped
    # @param hash [Boolean] if the asset name should include the hash
    # @return [String, nil] the relative path to the written asset or `nil` if no such asset
    def write(target, gzip: options[:gzip], hash: options[:hash])
      asset = assets[target]

      return if asset.nil?

      name = hash ? asset.digest_path : asset.logical_path.to_s
      name = File.join(options[:output], name) unless options[:output].nil?

      path = name
      path = File.join(directory, path) unless directory.nil?

      write(target, gzip: gzip, hash: false) if hash == :also_unhashed

      asset.write_to "#{path}.gz", compress: true if gzip
      asset.write_to path
      name
    end

    # (see #update_source)
    # @note this modifies the `source` `String` in place
    def update_source!(source)
      # e.g. /\[%\s+javascript\s+((\S+)\s?(\S+))\s+%\]/
      regex = /
        #{Regexp.escape options[:src_pre]}
        \s+#{type.to_s.singularize}
        \s+((\S+)\s?(\S+))\s+
        #{Regexp.escape options[:src_post]}
      /x
      source.gsub! regex do
        if Regexp.last_match[2] == options[:inline]
          assets[Regexp.last_match[3]].to_s
        else
          asset = write Regexp.last_match[1]

          # @todo Raise warning or error if asset not found.
          p "asset not found: #{Regexp.last_match[1]}" && next if asset.nil?

          "#{options[:cdn]}#{format_path asset}"
        end
      end
      true
    end

    # Replaces all asset tags in source string with asset path or asset source.
    # Writes any referenced assets to disk.
    # @param source [String] code to find and replace asset tags
    # @return [String] copy of `source` with asset tags replaced
    def update_source(source)
      s = source
      update_source! s
      s
    end

    # Scans all non-binary files under `path` ({#directory} by default) for asset tags.
    # Uses current asset {#type} (if set) and {#options}.
    # @param path [String] where to look for source files
    # @return [Array] files with asset tags
    def find_tags(path: directory)
      self.class.find_tags path, type, options
    end

    # Scans all non-binary files under `path` for asset tags.
    # @param path [String] where to look for source files
    # @param type [String, nil] only look for asset tags with this type (or any type if `nil`)
    # @param options [Hash] merged with {DEFAULT_OPTIONS}
    # (see #find_tags)
    # @todo Add support for stdlib backend.
    def self.find_tags(path, type = nil, options = {})
      backend = options[:search_backend]
      fail 'Only grep supported.' unless backend == :grep

      options = DEFAULT_OPTIONS.merge options
      pre = Regexp.escape options[:src_pre]
      post = Regexp.escape options[:src_post]

      regex = \
        if type.nil?
          pre + '(.*?)' + post
        else
          pre + '\s+' + type.to_s + '\s+(.*?)' + post
        end

      Utils.search_files regex, path, backend: options[:search_backend]
    end

    private

    # @todo Refactor this and add tests.
    def format_path(path)
      return path unless options[:serve_root]

      pn = Pathname.new path
      if options[:output]
        output = Pathname.new options[:output]
        pn = Pathname.new pn.to_s.gsub("#{output}#{File::SEPARATOR}", '')
      end

      Pathname.new(options[:serve_root]) + pn
    end
  end
end
