require 'rubygems'
require 'optparse'
require 'optparse/time'
require 'ostruct'
require 'set'
require 'zip/zipfilesystem' # from rubyzip gem
require 'pp'

MANIFEST_PATH='META-INF/MANIFEST.MF'
PLUGINXML_PATH='plugin.xml'
FRAGMENTXML_PATH='fragment.xml'

class Source
  
  attr_reader :bundles
  
  def initialize
    @bundles = []
  end
  
protected
  
end

class BinaryFolderSource < Source
  
  def initialize(path)
    super()
    @path = path
  end
  
  def to_s
    "binary plugins folder #{@path}"
  end
  
  def find_bundles(requestor)
    dir = @path
    Dir.foreach(dir) do |name|
      next if name == '.' || name == '..'
      f = File.join(dir, name)
      if File.directory?(f)
        f1 = File.join(f, MANIFEST_PATH)
        f2 = File.join(f, PLUGINXML_PATH)
        f3 = File.join(f, FRAGMENTXML_PATH)
        if File.file?(f1) || File.file?(f2) || File.file?(f3)
          bundle_name = if name =~ /_\d+(?:\.\d+(?:\.[\d\w_-]+)*)?$/ then $` else name end
          b = DirectoryBundle.new(self, bundle_name, f)
          requestor.add_bundle(b)
          @bundles << b
        end
      elsif name =~ /\.jar$/
        name = $`
        bundle_name = if name =~ /_\d+(?:\.\d+(?:\.[\d\w_-]+)*)?$/ then $` else name end
        b = FileBundle.new(self, bundle_name, f)
        requestor.add_bundle(b)
        @bundles << b
      end
    end
  end
  
end

class SourceFolderSource < Source
  
  def initialize(path)
    super()
    @path = path
  end
  
  def to_s
    "source plugins folder #{@path}"
  end
  
  def find_bundles(requestor)
    dir = @path
    Dir.foreach(dir) do |name|
      next if name == '.' || name == '..'
      f = File.join(dir, name)
      if File.directory?(f)
        f1 = File.join(f, MANIFEST_PATH)
        f2 = File.join(f, PLUGINXML_PATH)
        f3 = File.join(f, FRAGMENTXML_PATH)
        if File.file?(f1) || File.file?(f2) || File.file?(f3)
          bundle_name = name
          b = DirectorySourceBundle.new(self, bundle_name, f)
          requestor.add_bundle(b)
          @bundles << b
        end
      end
    end
  end
  
end

class Rule
end

class SourceRule < Rule
  
  def initialize(source)
    @source = source
  end
  
  def to_s
    "include all plugins in #{@source}"
  end
  
  def select_plugins(selected_plugins, lookup)
    @source.bundles.each { |b| selected_plugins << b unless selected_plugins.include?(b) }
    return selected_plugins
  end
  
end

class Options
  
  attr_accessor :sources
  attr_accessor :rules
  attr_accessor :debug
  
  def initialize
    @sources = []
    @rules = []
    @debug = {}
  end

  def self.parse(args)
    options = self.new
    include_following = false

    opts = OptionParser.new do |opts|
      opts.banner = "Usage: ecabu.rb [options]"

      opts.separator ""
      opts.separator "Specific options:"

      opts.on("-B", "--binary FOLDER",
              "Add a binary plugins FOLDER to the sources") do |folder|
        s = BinaryFolderSource.new(folder)
        options.sources << s
        options.rules << SourceRule.new(s) if include_following
      end

      opts.on("-S", "--source FOLDER",
              "Add a source plugins FOLDER to the sources") do |folder|
        s = SourceFolderSource.new(folder)
        options.sources << s
        options.rules << SourceRule.new(s) if include_following
      end

      opts.on("-I", "--[no-]include-following",
              "Include all plugins from the following sources into the build") do |v|
        include_following= v
      end

      opts.on("--debug x,y,z", Array, "Set options") do |list|
        list.each { |o| options.debug[o.intern] = true }
      end

      opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
        options.verbose = v
      end

      opts.separator ""
      opts.separator "Common options:"

      # No argument, shows at tail.  This will print an options summary.
      # Try it and see!
      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
      end

      # Another typical switch to print the version.
      opts.on_tail("--version", "Show version") do
        puts OptionParser::Version.join('.')
        exit
      end
    end

    opts.parse!(args)
    options
  end  # parse()

end

class ValueWithDirectives
  
  attr_reader :value, :directives
  
  def initialize(value, directives)
    @value = value
    @directives = directives
  end
  
  def to_s
    "#{value}; #{directives.collect {|k,v| "#{k}=#{v}"}.join(';')}"
  end
  
end

class Manifest
  
  def initialize(headers, file_name_for_errors)
    @headers = headers
    @file_name_for_errors = file_name_for_errors
  end
  
  def value(name, default = nil)
    h = @headers[name]
    return default if h.nil?
    parse_value(fixup(h), name).value
  end
  
  def value_with_directives(name, default = nil)
    h = @headers[name]
    return ValueWithDirectives.new(default, {}) if h.nil?
    parse_value(fixup(h), name)
  end
  
  def values_with_directives(name)
    h = @headers[name]
    return [] if h.nil?
    parse_values(fixup(h), name)
  end
  
  def fixup(h)
    h.gsub(/"[^"]*"/, '')
  end
  
  def self.parse(data, file_name_for_errors)
    headers = {}
    last_header = nil
    lineno = 0
    ignored = ['SHA1-Digest', 'Name']
    data.each_line do |line|
      lineno += 1
      if line =~ /^\s*$/
        next
      elsif line =~ /^ /
        if last_header.nil?
          puts "#{file_name_for_errors}(#{lineno}): line starts with whitespace: \"#{line}\""
          next
        end
        next if ignored.include?(last_header)
        headers[last_header] += $'.chomp
      elsif line =~ /([\w\d_-]+)\s*:/
        last_header = $1
        next if ignored.include?(last_header)
        unless headers[last_header].nil?
          puts "#{file_name_for_errors}(#{lineno}): duplicate directive \"#{last_header}\""
        end
        headers[last_header] = $'.lstrip.chomp
      else
        puts "#{file_name_for_errors}(#{lineno}): unrecognized line \"#{line}\""
      end
    end   
    self.new(headers, file_name_for_errors)
  end
  
private
  
  def parse_value(s, name_for_errors)
    s.strip!
    data = s.split(';')
    item_value = data.shift
    directives = {}
    data.each do |pair|
      pair.strip!
      key, value = pair.split(/:?=/, 2)
      if value.nil?
        puts "#{file_name_for_errors}: unparsable directive in #{name_for_errors}: \"#{pair}\""
        next
      end
    end
    ValueWithDirectives.new(item_value, directives)
  end
  
  def parse_values(s, name_for_errors)
    s.split(',').collect { |item| parse_value(item, name_for_errors) }
  end
  
end

class Bundle
  
  attr_reader :name, :source
  attr_reader :required_bundles
  
  def initialize(source, name)
    @source = source
    @name = name
    @parsed = false
  end
  
  def parsed?
    @parsed
  end
  
  def to_s
    "#{@name} in #{@source}"
  end
  
protected
  
  def do_parse(file_obj, path_prefix, path_prefix_for_errors, lookup)
    return if @parsed
    @parsed = true
    puts "Parsing manifest for #{self.name}"
    manifest_mf = File.join(path_prefix, MANIFEST_PATH)
    plugin_xml = File.join(path_prefix, PLUGINXML_PATH)
    plugin_xml = File.join(path_prefix, FRAGMENTXML_PATH)
    @required_bundles = []
    if file_obj.file?(manifest_mf)
      data = file_obj.open(manifest_mf, "r") { |f| f.read }
      mf = Manifest.parse(data, path_prefix_for_errors + MANIFEST_PATH)
      mf.values_with_directives('Require-Bundle').each do |vd|
        puts vd if vd.value == 'reexport'
        b = lookup.lookup(vd.value, self)
        @required_bundles << b unless b.nil?
      end
    end
  end
  
end

class DirectoryBundle < Bundle
  
  def initialize(source, name, path)
    super(source, name)
    @path = path
  end
  
  def parse(lookup)
    self.do_parse(File, @path, "#{@path}/", lookup)
  end
  
end

class FileBundle < Bundle
  
  def initialize(source, name, path)
    super(source, name)
    @path = path
  end
  
  def parse(lookup)
    Zip::ZipFile.open(@path) do |zip|
      self.do_parse(zip.file, '', "#{@path}:/", lookup)
    end
  end
  
end

class DirectorySourceBundle < Bundle
  
  def initialize(source, name, path)
    super(source, name)
    @path = path
  end
  
  def parse(lookup)
    self.do_parse(File, @path, "#{@path}/", lookup)
  end
  
end

class BundleLookup
  
  attr_reader :unresolved
  
  def initialize
    @names_to_bundles = {}
    @unresolved = []
  end
  
  def add_bundle(bundle)
    old = @names_to_bundles[bundle.name]
    @names_to_bundles[bundle.name] = bundle
    unless old.nil?
      puts "Name conflict: bundle #{bundle.name} is defined in #{old.source} and #{bundle.source}"
    end
  end
  
  def lookup(name, src_bundle)
    b = @names_to_bundles[name]
    @unresolved << [name, src_bundle] if b.nil?
    return b
  end
  
end

$LOC = {
  '@@ sources' => ['@@ source', '@@ sources'],
  '@@ rules' => ['@@ rule', '@@ rules'],
}

class String
  def /(number)
    s = $LOC[self] || self
    if s.is_a?(Array)
      #index = (number == nil ? 1 : (number == 1 ? 0 : 1))
      index = (number == 1 ? 0 : 1)
      s = s[index]
    end
    s = s.gsub('@@', "#{number}") unless number.nil?
    return s
  end
end

class Builder
  
  attr_accessor :log
  attr_reader :selected_plugins
  attr_reader :lookup
  
  def initialize(options)
    @sources = options.sources
    @rules = options.rules
  end
  
  def show_options_summary
    log.puts "OPTIONS SUMMARY"
    log.puts "@@ sources" / @sources.size
    @sources.each do |src|
      log.puts " - #{src}"
    end

    log.puts "@@ rules" / @rules.size
    @rules.each do |rule|
      log.puts " - #{rule}"
    end
  end
  
  def locate_bundles
    @lookup = BundleLookup.new
    log.puts
    @sources.each do |source|
      log.puts "Searching for plugins: #{source}..."
      source.find_bundles(@lookup)
      log.puts "... #{source.bundles.size} found"
    end
  end
  
  def select_plugins
    selected_plugins = []
    @rules.each do |rule|
      puts "Processing rule: #{rule}"
      selected_plugins = rule.select_plugins(selected_plugins, lookup)
      puts "... #{selected_plugins.size} plugins selected."
    end
    @selected_plugins = selected_plugins
  end
  
  def parse_bundles
    traverse(@selected_plugins) do |bundle|
      bundle.parse(@lookup)
      bundle.required_bundles
    end
  end
  
  def unresolved_bundles
    @lookup.unresolved
  end
  
private

  def traverse(initial_bundles)
    queue = []
    visited = Set.new
    initial_bundles.each { |b| queue << b; visited << b }
    while !queue.empty?
      current = queue.shift
      #puts "traversing #{current.name}"
      neighbours = yield current
      neighbours.each { |n| unless visited.include?(n); queue << n; visited << n; end }
    end
  end
  
end

options = Options.parse(ARGV)
builder = Builder.new(options)
builder.log = $stdout
builder.show_options_summary
builder.locate_bundles
builder.select_plugins

if builder.selected_plugins.size == 0
  puts "No plugins selected for building. Stop."
  exit
end

builder.parse_bundles
unres = builder.unresolved_bundles
unless unres.size == 0
  puts "Unresolved bundles:"
  unres.each do |name, src|
    puts " - #{name} (required by #{src.name})"
  end
  puts "Stop."
  exit
end

puts "Done."
