require 'rubygems'
require 'tempfile'
require 'find'
require 'optparse'
require 'optparse/time'
require 'fileutils'
require 'pathname'
require 'ostruct'
require 'set'
require 'zip/zipfilesystem' # from rubyzip gem
require 'zip/zip'           # from rubyzip gem
require 'pp'

MANIFEST_PATH='META-INF/MANIFEST.MF'
PLUGINXML_PATH='plugin.xml'
FRAGMENTXML_PATH='fragment.xml'
BUILD_PROPS='build.properties'

ECABU_VERSION="2"

# exit codes
EXIT_OK = 0
EXIT_PLUGIN_NOT_FOUND = 1
EXIT_COMPILATION_ERROR = 2
EXIT_ERROR_IN_SOURCE_FILES = 3
EXIT_INVALID_ARGUMENTS = 12

$realstdout = $stdout
$stdout = $stderr

class Source
  
  attr_reader :bundles, :output_folder
  
  def initialize
    @bundles = []
  end
  
  def output_folder= folder
    @output_folder = folder
    FileUtils.mkdir_p @output_folder
  end
  
protected
  
end

class BinaryFolderSource < Source

  attr_accessor :copying_rules
  
  def initialize(path)
    super()
    @path = path
    @copying_rules = []
  end
  
  def should_copy?(bundle_name)
    current_answer = false
    @copying_rules.each do |pattern, value|
      current_answer = value if File.fnmatch(pattern, bundle_name)
    end
    return current_answer
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
  
  attr_accessor :qualifier, :building_enabled
  
  def initialize(path)
    super()
    @path = path
    @building_enabled = true
  end
  
  def should_build?
    @building_enabled
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

class ExcludePatternRule < Rule
  
  def initialize(pattern)
    @pattern = pattern
  end
  
  def to_s
    "exclude plugins matching #{@pattern}"
  end
  
  def select_plugins(selected_plugins, lookup)
    return selected_plugins.select { |p| !File.fnmatch(@pattern, p.name) }
  end
  
end

class IncludePatternRule < Rule
  
  def initialize(pattern)
    @pattern = pattern
  end
  
  def to_s
    "include all plugins matching #{@pattern}"
  end
  
  def select_plugins(selected_plugins, lookup)
    s = selected_plugins 
    lookup.all_bundles.select { |p| File.fnmatch(@pattern, p.name) }.each { |p| 
      s << p unless s.include?(p)
    }
    return s
  end
  
end

class IncludeOnlyPatternRule < Rule
  
  def initialize(pattern)
    @pattern = pattern
  end
  
  def to_s
    "exclude plugins NOT matching #{@pattern}"
  end
  
  def select_plugins(selected_plugins, lookup)
    return selected_plugins.select { |p| File.fnmatch(@pattern, p.name) }
  end
  
end

class Command
end

class BuildCommand < Command
  
  def execute(builder)
    plan = builder.create_plan
    puts "Build plan contains #{plan.size} items."
    builder.perform_build(plan)

    puts "Done."
  end
  
end

class ListDependenciesCommand < Command
  
  attr_reader :plugin_id
  
  def initialize(plugin_id)
    @plugin_id = plugin_id
  end
  
  def execute(builder)
    bundle = builder.lookup.find(plugin_id)
    if bundle.nil?
      puts "Cannot find #{plugin_id}"
      exit EXIT_PLUGIN_NOT_FOUND
    end
    
    res = Set.new
    print_r(bundle, res)
    res.each { |b| $realstdout.puts b.name }
  end
  
  def print_r(bundle, res)
    res << bundle
    (bundle.bundles_to_build_before_current_one || []).each { |b| print_r(b, res) }
  end
  
end

class Options
  
  attr_accessor :sources
  attr_accessor :rules
  attr_accessor :debug
  attr_accessor :command
  attr_accessor :allow_unresolved
  
  def initialize
    @sources = []
    @rules = []
    @debug = {}
    @command = BuildCommand.new
    @allow_unresolved = false
  end

  def self.parse(args)
    options = self.new
    include_following = false
    last_qualifier = nil
    copy_binaries = false
    copy_overrides = []
    building_enabled = []
    output_folder = nil

    opts = OptionParser.new do |opts|
      opts.banner = "Usage: ecabu.rb [options]"

      opts.separator ""
      opts.separator "Specifying sources:"

      opts.on("-B", "--binary FOLDER",
              "Add a binary plugins FOLDER to the sources") do |folder|
        s = BinaryFolderSource.new(folder)
        if output_folder.nil?
          puts "No output folder specified for source #{folder}. See --output. Stop."
          exit EXIT_INVALID_ARGUMENTS
        end
        s.output_folder = output_folder
        s.copying_rules = [['*', copy_binaries], *copy_overrides]
        options.sources << s
        options.rules << SourceRule.new(s) if include_following
      end

      opts.on("-S", "--source FOLDER",
              "Add a source plugins FOLDER to the sources") do |folder|
        s = SourceFolderSource.new(folder)
        if output_folder.nil?
          puts "No output folder specified for source #{folder}. See --output. Stop."
          exit EXIT_INVALID_ARGUMENTS
        end
        s.output_folder = output_folder
        s.qualifier = last_qualifier unless last_qualifier.nil?
        s.building_enabled = building_enabled
        options.sources << s
        options.rules << SourceRule.new(s) if include_following
      end

      opts.separator ""
      opts.separator "Specifying plugins to build:"

      opts.on("-i", "--include PATTERN",
              "Include all plugins matching shell glob PATTERN") do |v|
        options.rules << IncludePatternRule.new(v)
      end

      opts.on("-x", "--exclude PATTERN",
              "Exclude currently included plugins matching shell glob PATTERN") do |v|
        options.rules << ExcludePatternRule.new(v)
      end

      opts.on("-y", "--include-only PATTERN",
              "Exclude currently included plugins NOT matching shell glob PATTERN") do |v|
        options.rules << IncludeOnlyPatternRule.new(v)
      end

      opts.separator ""
      opts.separator "Options that take effect on the subsequent sources:"

      opts.on("-O", "--output FOLDER",
              "Put the built binaries into FOLDER") do |folder|
        output_folder = folder
      end

      opts.on("-I", "--[no-]include-following",
              "Include all plugins from the following sources into the build") do |v|
        include_following = v
      end

      opts.on("--enable-building", "Build all required source plugins (default)") do
        building_enabled = true
      end

      opts.on("--disable-building", "Don't build any source plugins (only use them to determine other required plugins)") do
        building_enabled = false
      end

      opts.on("--copy-binaries", "Copy all binary plugins to the output folder") do
        copy_binaries = true
        copy_overrides = []
      end

      opts.on("--no-copy-binaries", "Don't copy any binary plugins to the output folder (default)") do
        copy_binaries = false
        copy_overrides = []
      end

      opts.on("--do-copy PATTERN", "Copy specific binary plugins to the output folder") do |v|
        copy_overrides << [v, true]
      end

      opts.on("--dont-copy PATTERN", "Don't copy specific binary plugins to the output folder") do
        copy_overrides << [v, false]
      end

      opts.on("-Q", "--qualifier QUALIFIER",
              "Substitute '.qualifier' in source bundle versions with QUALIFIER") do |qualifier|
        last_qualifier = qualifier
      end

      opts.separator ""
      opts.separator "Special operations (executed instead of building):"

      opts.on("--list-dependencies PLUGIN",
              "List all plugins required by PLUGIN") do |v|
        options.command = ListDependenciesCommand.new(v)
      end

      opts.on("--allow-unresolved",
              "Don't stop if some bundles cannot be resolved") do |v|
        options.allow_unresolved = true
      end

      opts.separator ""
      opts.separator "Common options:"

      opts.on("--debug x,y,z", Array, "Set debug options") do |list|
        list.each { |o| options.debug[o.intern] = true }
      end

      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
      end

      opts.on_tail("--version", "Show version") do
        puts ECABU_VERSION
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
      elsif line =~ /^([\w\d_-]+)\s*:/
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
      directives[key] = value
    end
    ValueWithDirectives.new(item_value, directives)
  end
  
  def parse_values(s, name_for_errors)
    s.split(',').collect { |item| parse_value(item, name_for_errors) }
  end
  
end

class JavaProperties
  
  def self.parse(data, file_name_for_errors)
    headers = {}
    last_header = nil
    lineno = 0
    cont = false
    data.each_line do |line|
      lineno += 1
      if cont
        v = line.strip
        cont = v[-1] == ?\\
        v = (v[0,v.length-1] || '') if cont
        headers[last_header] += v
      elsif line =~ /^\s*$/
        next
      elsif line =~ /^\s*#/
        next
      elsif line =~ /^\s*([^\s=]+)\s*=/
        last_header = $1
        v = $'.strip
        cont = v[-1] == ?\\
        v = (v[0,v.length-1] || '') if cont
        headers[last_header] = v
      else
        puts "#{file_name_for_errors}(#{lineno}): unrecognized line \"#{line}\""
      end
    end   
    headers
  end
  
end

class Bundle
  
  attr_reader :name, :source
  # available after parsing
  attr_reader :bundles_to_build_before_current_one, :exported_packages, :fragment_host, :version, :qualified_version
  # available after build
  attr_reader :exported_classpath
  
  def initialize(source, name)
    @source = source
    @name = name
    @parsed = false
    @exported_classpath = []
  end
  
  def parsed?
    @parsed
  end
  
  def to_s
    "#{@name} in #{@source}"
  end
  
  def contribute_to_plan(plan, lookup)
    return if plan.include?(self)
    @bundles_to_build_before_current_one.each { |b| b.contribute_to_plan(plan, lookup) }
    swt_hack = (@name == 'org.eclipse.swt')
    plan.add(self) unless swt_hack
    @fragments = lookup.fragments(self)
    @fragments.each { |b| b.contribute_to_plan(plan, lookup) }
    plan.add(self) if swt_hack
  end
  
  def can_be_jarred?
    @bundle_classpath.all? { |e| e == '.' }
  end
  
  def resolve_packages!(lookup)
  end
  
protected
  
  def do_parse(file_obj, path_prefix, path_prefix_for_errors, lookup)
    return if @parsed
    @parsed = true
    puts "Parsing manifest for #{self.name}"
    manifest_mf = File.join(path_prefix, MANIFEST_PATH)
    plugin_xml = File.join(path_prefix, PLUGINXML_PATH)
    plugin_xml = File.join(path_prefix, FRAGMENTXML_PATH)
    @bundles_to_build_before_current_one = []
    @imported_bundles = []
    @imported_packages = []
    @exported_packages = []
    @reexported_requires = []
    @bundle_classpath = []
    @extensible_api = false
    @version = ''
    if file_obj.file?(manifest_mf)
      data = file_obj.open(manifest_mf, "r") { |f| f.read }
      mf = Manifest.parse(data, path_prefix_for_errors + MANIFEST_PATH)
      mf.values_with_directives('Require-Bundle').each do |vd|
        b = lookup.lookup(vd.value, self)
        unless b.nil?
            @bundles_to_build_before_current_one << b
            @imported_bundles << b
            @reexported_requires << b if vd.directives['visibility'] == 'reexport'
        end
      end
      mf.values_with_directives('Fragment-Host').each do |vd|
        b = lookup.lookup(vd.value, self)
        @imported_bundles << b unless b.nil? 
      end
      mf.values_with_directives('Export-Package').each do |vd|
        @exported_packages << vd.value
      end
      mf.values_with_directives('Import-Package').each do |vd|
        @imported_packages << vd.value
      end
      mf.values_with_directives('Bundle-ClassPath').each do |vd|
        @bundle_classpath << vd.value
      end
      @extensible_api = true if mf.value('Eclipse-ExtensibleAPI', 'false') == 'true'
      @fragment_host = mf.value('Fragment-Host', nil)
      @version = mf.value('Bundle-Version', '')
    end
    @qualified_version = @version # subclasses can overwrite that field
  end
  
  def resolve_bundle_classpath(rootdir, classdir = nil)
    result = []
    (if @bundle_classpath.empty? then ['.'] else @bundle_classpath end).each do |entry|
      entry.strip!
      if entry == '.'
        result << classdir unless classdir.nil?
      else
        result << File.join(rootdir, entry)
      end
    end
    result
  end
  
  def post_build
    @reexported_requires.each do |bundle|
      @exported_classpath += bundle.exported_classpath
      puts "Bundle #{self.name} reexports #{bundle.exported_classpath.size} classpath entries from #{bundle.name}."
    end
    if @extensible_api
      @fragments.each do |bundle|
        @exported_classpath += bundle.exported_classpath
        puts "Bundle #{self.name} reexports #{bundle.exported_classpath.size} classpath entries from fragments #{bundle.name}."
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
  
  def perform_build(build_state)
    if @source.should_copy?(name)
      puts "Copying unpacked binary plugin #{self.name}."
      FileUtils.cp_r(@path, @source.output_folder)
      bin_path = File.join(@source.output_folder, File.basename(@path))
    else
      bin_path = @path
    end
    @exported_classpath += resolve_bundle_classpath(bin_path, bin_path)
    self.post_build
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
  
  def perform_build(build_state)
    if @source.should_copy?(name)
      puts "Copying packed binary plugin #{self.name}."
      FileUtils.cp_r(@path, @source.output_folder)
      bin_path = File.join(@source.output_folder, File.basename(@path))
    else
      bin_path = @path
    end
    @exported_classpath << bin_path
    self.post_build
  end
  
end

def javac(*args)
  f = Tempfile.new('javacargs')
  args.each { |a| f.puts "\"#{a}\"" }
  f.close
  
  begin
    puts "Running javac..."
    pid = Process.fork do
      exec('javac', '@' + f.path)
      Process.exit!(255)
    end
    pid, status = Process.wait2(pid)
    FileUtils.cp(f.path, '/tmp/javacargs')
    f.unlink
    if status.exitstatus != 0
      puts "Compilation failed! See /tmp/javacargs"
      exit EXIT_COMPILATION_ERROR
    end  
  rescue NotImplementedError
    puts "Running javac via system..."
    rv = system('javac', '@' + f.path)
    f.unlink
    unless rb
      puts "Compilation failed! See /tmp/javacargs"
      exit EXIT_COMPILATION_ERROR
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
    @qualified_version = @version.gsub('qualifier', @source.qualifier) unless @source.qualifier.nil?
  end

  def resolve_packages!(lookup)
    @imported_packages.each do |package|
      b = lookup.lookup_package(package, self)
      unless b.nil?
          @bundles_to_build_before_current_one << b
          @imported_bundles << b
      end
    end
  end
  
  def perform_build(build_state)
    unless @source.should_build?
      puts "Skipped building of #{self.name}."
      self.post_build
      return
    end
    
    puts "Building #{self.name}."
    qualified_name = "#{@name}_#{@qualified_version}"
    outpath = File.join(@source.output_folder, qualified_name)
    FileUtils.mkdir_p(outpath)
    
    # parse build.properties
    build_props = File.join(@path, BUILD_PROPS)
    unless File.file?(build_props)
      puts "#{@path}: no #{BUILD_PROPS} found, don't know what to build."
      exit EXIT_ERROR_IN_SOURCE_FILES
    end
    data = File.open(build_props, "r") { |f| f.read }
    props = JavaProperties.parse(data, build_props)
    
    # compile the sources
    src_folders = []
    props.each { |k, v| src_folders += v.split(',').collect { |s| s.strip }.select { |s| s.length > 0 } if k =~ /^source\./ }
    classes_dir = nil
    unless src_folders.empty?
      sources = []
      src_folders.each do |src_folder|
        base_path = File.join(@path, src_folder)
        Find.find(File.join(base_path)) do |path|
          if FileTest.directory?(path)
            if File.basename(path)[0] == ?.
              Find.prune
            end
          elsif path =~ /\.java$/
            sources << path
          else
            puts "Resource: #{path}"
            rel = path[base_path.size..-1]
            rel = rel[1..-1] if rel[0] == ?/
            out = File.join(outpath, rel)
            FileUtils.mkdir_p(File.dirname(out))
            FileUtils.cp_r(path, out)
          end
        end
      end
    
      class_path = []
      @imported_bundles.each { |b| class_path += b.exported_classpath }
      class_path += resolve_bundle_classpath(@path, nil)
      
      Dir.chdir(@path)
      javac('-nowarn', '-d', outpath, '-cp', class_path.join(':'), *sources) unless sources.empty?
      
      classes_dir = outpath if src_folders.size > 0
    end

    # copy additional files from bin.includes
    bin_includes = (props['bin.includes'] || '').split(',').collect { |s| s.strip }.select { |s| s.length > 0 }
    bin_includes.each do |bi|
      next if bi == '.' # don't know what it means, but used by DLTK and obviously should be ignored
      bi = bi[0,-2] if bi[-1] == '/'
      src = File.join(@path, bi)
      unless File.exists?(src)
        puts "#{self.name}: bin.includes entry not found: #{bi}"
        next
      end
      src = File.join(src, '.') if File.directory?(src)
      dst = File.join(outpath, bi)
      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp_r(src, dst)
    end
    
    # patch version qualifier in MANIFEST.MF
    unless @qualified_version == @version
      fn = File.join(outpath, MANIFEST_PATH)
      if File.file?(fn)
        data = File.open(fn, 'rb') { |f| f.read }
        data.gsub!(/^(\s*Bundle-Version\s*:\s*)#{@version}/) { "#{$1}#{@qualified_version}" }
        File.open(fn, 'wb') { |f| f.write(data) }
      end
    end
    
    # jar
    if can_be_jarred?
      @jar_name = File.join(@source.output_folder, qualified_name + ".jar")
      puts "Compressing into #{File.basename(@jar_name)}"
      Zip::ZipOutputStream.open(@jar_name) do |zip|
        outpn = Pathname.new(outpath)
        Find.find(outpath) do |path|
          if FileTest.directory?(path)
            if File.basename(path)[0] == ?.
              Find.prune
            end
          else
            pn = Pathname.new(path).relative_path_from(outpn).to_s
            zip.put_next_entry(pn)
            zip << File.open(path, 'rb') { |f| f.read }
          end
        end
      end
      @exported_classpath << @jar_name if src_folders.size > 0
      FileUtils.rm_rf(outpath)
    else
      @exported_classpath += resolve_bundle_classpath(outpath, classes_dir)
    end
    
    self.post_build
  end
  
end

class BundleLookup
  
  attr_reader :unresolved, :unresolved_packages
  
  def initialize
    @names_to_bundles = {}
    @unresolved = []
    @unresolved_packages = []
    @fragments = {}
    @packages = {}
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
  
  def lookup_package(name, src_bundle)
    b = @packages[name]
    @unresolved_packages << [name, src_bundle] if b.nil?
    return b
  end
  
  def find(name)
    @names_to_bundles[name]
  end
  
  def all_bundles
    @names_to_bundles.values
  end
  
  def fragments(bundle)
    @fragments[bundle] || []
  end
  
  def index_fragments!
    all_bundles.each do |bundle|
      next unless bundle.parsed?
      host = bundle.fragment_host
      next if host.nil?
      host = lookup(host, bundle)
      next if host.nil?
      (@fragments[host] ||= []) << bundle
    end
  end
  
  def index_packages!
    all_bundles.each do |bundle|
      next unless bundle.parsed?
      bundle.exported_packages.each { |p| @packages[p] = bundle }
    end
  end
  
  def resolve_packages!
    all_bundles.each do |b|
      next unless b.parsed?
      b.resolve_packages!(self)
    end
  end
  
end

class BuildState
  
  attr_reader :bundles_to_binaries
  
  def initialize
    @bundles_to_binaries = {}
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

class BuildPlan
  
  def initialize
    @order = []
    @items = Set.new
  end
  
  def add(bundle)
    @order << bundle
    @items << bundle
  end
  
  def include?(bundle)
    @items.include?(bundle)
  end
  
  def size
    @order.size
  end

  def each(&block)
    @order.each(&block)
  end
  
end

class Builder
  
  attr_accessor :log
  attr_reader :selected_plugins
  attr_reader :lookup
  
  def initialize(options)
    @sources = options.sources
    @rules = options.rules
    @options = options
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
      bundle.bundles_to_build_before_current_one
    end
    @lookup.index_packages!
    @lookup.resolve_packages!
  end
  
  def create_plan
    @lookup.index_fragments!
    plan = BuildPlan.new
    @selected_plugins.each do |bundle|
      bundle.contribute_to_plan(plan, lookup)
    end
    plan
  end
  
  def perform_build(plan)
    build_state = BuildState.new
    plan.each do |bundle|
      bundle.perform_build(build_state)
    end
  end
  
  def unresolved_bundles
    @lookup.unresolved
  end
  
  def unresolved_packages
    @lookup.unresolved_packages
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
  exit EXIT_INVALID_ARGUMENTS
end

builder.parse_bundles
unres = builder.unresolved_bundles
unresolved_packages = builder.unresolved_packages
unless options.allow_unresolved || (unres.size == 0 && unresolved_packages.size == 0)
  unless unres.size == 0
    puts "Unresolved bundles:"
    unres.each do |name, src|
      puts " - #{name} (required by #{src.name})"
    end
  end
  unless unresolved_packages.size == 0
    puts "Unresolved packages:"
    unresolved_packages.each do |name, src|
      puts " - #{name} (imported by #{src.name})"
    end
  end
  puts "Stop."
  exit EXIT_PLUGIN_NOT_FOUND
end

options.command.execute(builder)
