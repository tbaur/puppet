require 'puppet'
require 'sync'
require 'getoptlong'
require 'puppet/util/loadedfile'

class Puppet::SettingsError < Puppet::Error
end

# The class for handling configuration files.
class Puppet::Util::Settings
  include Enumerable

  require 'puppet/util/settings/string_setting'
  require 'puppet/util/settings/file_setting'
  require 'puppet/util/settings/directory_setting'
  require 'puppet/util/settings/boolean_setting'

  attr_accessor :files
  attr_reader :timer

  ReadOnly = [:run_mode, :name]

  # These are the settings that every app is required to specify; there are reasonable defaults defined in application.rb.
  REQUIRED_APP_SETTINGS = [:name, :run_mode, :logdir, :confdir, :vardir]

  def self.default_global_config_dir()
    Puppet.features.microsoft_windows? ? File.join(Dir::COMMON_APPDATA, "PuppetLabs", "puppet", "etc") : "/etc/puppet"
  end

  def self.default_user_config_dir()
    "~/.puppet"
  end

  def self.default_global_var_dir()
    Puppet.features.microsoft_windows? ? File.join(Dir::COMMON_APPDATA, "PuppetLabs", "puppet", "var") : "/var/lib/puppet"
  end

  def self.default_user_var_dir()
    "~/.puppet/var"
  end

  def self.default_config_file_name()
    "puppet.conf"
  end


  # Retrieve a config value
  def [](param)
    value(param)
  end

  # Set a config value.  This doesn't set the defaults, it sets the value itself.
  def []=(param, value)
    set_value(param, value, :memory)
  end

  # Generate the list of valid arguments, in a format that GetoptLong can
  # understand, and add them to the passed option list.
  def addargs(options)
    # Add all of the config parameters as valid options.
    self.each { |name, setting|
      setting.getopt_args.each { |args| options << args }
    }

    options
  end

  # Generate the list of valid arguments, in a format that OptionParser can
  # understand, and add them to the passed option list.
  def optparse_addargs(options)
    # Add all of the config parameters as valid options.
    self.each { |name, setting|
      options << setting.optparse_args
    }

    options
  end

  # Is our parameter a boolean parameter?
  def boolean?(param)
    param = param.to_sym
    !!(@config.include?(param) and @config[param].kind_of? BooleanSetting)
  end

  # Remove all set values, potentially skipping cli values.
  def clear
    @sync.synchronize do
      unsafe_clear
    end
  end

  # Remove all set values, potentially skipping cli values.
  def unsafe_clear(clear_cli = true, clear_application_defaults = false)
    @values.each do |name, values|
      next if ((name == :application_defaults) and !clear_application_defaults)
      next if ((name == :cli) and !clear_cli)
      @values.delete(name)
    end

    # Only clear the 'used' values if we were explicitly asked to clear out
    #  :cli values; otherwise, it may be just a config file reparse,
    #  and we want to retain this cli values.
    @used = [] if clear_cli

    @cache.clear
  end
  private :unsafe_clear



  # This is mostly just used for testing.
  def clearused
    @cache.clear
    @used = []
  end


  def app_defaults_initialized?()
    @app_defaults_initialized
  end

  def initialize_app_defaults(app_defaults)
    raise Puppet::DevError, "Attempting to initialize application default settings more than once!" if app_defaults_initialized?
    REQUIRED_APP_SETTINGS.each do |key|
      raise Puppet::SettingsError, "missing required app default setting '#{key}'" unless app_defaults.has_key?(key)
    end
    app_defaults.each do |key, value|
      set_value(key, value, :application_defaults)
    end


    @app_defaults_initialized = true
  end

  # Do variable interpolation on the value.
  def convert(value, environment = nil)
    return nil if value.nil?
    return value unless value.is_a? String
    newval = value.gsub(/\$(\w+)|\$\{(\w+)\}/) do |value|
      varname = $2 || $1
      if varname == "environment" and environment
        environment
      elsif pval = self.value(varname, environment)
        pval
      else
        raise Puppet::SettingsError, "Could not find value for #{value}"
      end
    end

    newval
  end

  # Return a value's description.
  def description(name)
    if obj = @config[name.to_sym]
      obj.desc
    else
      nil
    end
  end

  def each
    @config.each { |name, object|
      yield name, object
    }
  end

  # Iterate over each section name.
  def eachsection
    yielded = []
    @config.each do |name, object|
      section = object.section
      unless yielded.include? section
        yield section
        yielded << section
      end
    end
  end

  # Return an object by name.
  def setting(param)
    param = param.to_sym
    @config[param]
  end

  # Handle a command-line argument.
  def handlearg(opt, value = nil)
    @cache.clear

    if value.is_a?(FalseClass)
      value = "false"
    elsif value.is_a?(TrueClass)
      value = "true"
    end


    value &&= munge_value(value)
    str = opt.sub(/^--/,'')

    bool = true
    newstr = str.sub(/^no-/, '')
    if newstr != str
      str = newstr
      bool = false
    end
    str = str.intern

    if @config[str].is_a?(Puppet::Util::Settings::BooleanSetting)
      if value == "" or value.nil?
        value = bool
      end
    end

    set_value(str, value, :cli)
  end

  def include?(name)
    name = name.intern if name.is_a? String
    @config.include?(name)
  end

  # check to see if a short name is already defined
  def shortinclude?(short)
    short = short.intern if name.is_a? String
    @shortnames.include?(short)
  end

  # Create a new collection of config settings.
  def initialize
    @config = {}
    @shortnames = {}

    @created = []
    @searchpath = nil

    # Mutex-like thing to protect @values
    @sync = Sync.new

    # Keep track of set values.
    @values = Hash.new { |hash, key| hash[key] = {} }

    # And keep a per-environment cache
    @cache = Hash.new { |hash, key| hash[key] = {} }

    # The list of sections we've used.
    @used = []
  end

  # NOTE: ACS ahh the util classes. . .sigh
  # as part of a fix for 1183, I pulled the logic for the following 5 methods out of the executables and puppet.rb
  # They probably deserve their own class, but I don't want to do that until I can refactor environments
  # its a little better than where they were

  # Prints the contents of a config file with the available config settings, or it
  # prints a single value of a config setting.
  def print_config_options
    env = value(:environment)
    val = value(:configprint)
    if val == "all"
      hash = {}
      each do |name, obj|
        val = value(name,env)
        val = val.inspect if val == ""
        hash[name] = val
      end
      hash.sort { |a,b| a[0].to_s <=> b[0].to_s }.each do |name, val|
        puts "#{name} = #{val}"
      end
    else
      val.split(/\s*,\s*/).sort.each do |v|
        if include?(v)
          #if there is only one value, just print it for back compatibility
          if v == val
            puts value(val,env)
            break
          end
          puts "#{v} = #{value(v,env)}"
        else
          puts "invalid parameter: #{v}"
          return false
        end
      end
    end
    true
  end

  def generate_config
    puts to_config
    true
  end

  def generate_manifest
    puts to_manifest
    true
  end

  def print_configs
    return print_config_options if value(:configprint) != ""
    return generate_config if value(:genconfig)
    generate_manifest if value(:genmanifest)
  end

  def print_configs?
    (value(:configprint) != "" || value(:genconfig) || value(:genmanifest)) && true
  end

  # Return a given object's file metadata.
  def metadata(param)
    if obj = @config[param.to_sym] and obj.is_a?(FileSetting)
      return [:owner, :group, :mode].inject({}) do |meta, p|
        if v = obj.send(p)
          meta[p] = v
        end
        meta
      end
    else
      nil
    end
  end

  # Make a directory with the appropriate user, group, and mode
  def mkdir(default)
    obj = get_config_file_default(default)

    Puppet::Util::SUIDManager.asuser(obj.owner, obj.group) do
      mode = obj.mode || 0750
      Dir.mkdir(obj.value, mode)
    end
  end

  # Figure out the section name for the run_mode.
  def run_mode
    @run_mode || :user
  end

  # PRIVATE!  This only exists because we need a hook to validate the run mode when it's being set, and
  #  it should never, ever, ever, ever be called from outside of this file.
  def run_mode=(mode)
    raise Puppet::DevError, "Invalid run mode '#{mode}'" unless [:master, :agent, :user].include?(mode)
    @run_mode = mode
  end
  private :run_mode=

  # Return all of the parameters associated with a given section.
  def params(section = nil)
    if section
      section = section.intern if section.is_a? String
      @config.find_all { |name, obj|
        obj.section == section
      }.collect { |name, obj|
        name
      }
    else
      @config.keys
    end
  end

  # Parse the configuration file.  Just provides
  # thread safety.
  def parse
    # we are now supporting multiple config files; the "main" config file will be the one located in
    # /etc/puppet (or overridden $confdir)... but we will also look for a config file in the user's home
    # directory.  This was introduced in an effort to provide maximum backwards compatibility while
    # de-coupling the process of locating the config file from the "run mode" of the application.
    files = [main_config_file]
    files << user_config_file unless Puppet.features.root?

    @sync.synchronize do
      unsafe_parse(files)
    end
  end

  def main_config_file
    # the algorithm here is basically this:
    #  * use the explicit config file location if one has been specified; this can be affected by modifications
    #    to either the "confdir" or "config" settings (most likely via CLI arguments).
    #  * if no explicit config location has been specified, we fall back to the default.
    #
    # The easiest way to determine whether an explicit one has been specified is to simply attempt to evaluate
    #  the value of ":config".  This will obviously be successful if they've passed an explicit value for :config,
    #  but it will also result in successful interpolation if they've only passed an explicit value for :confdir.
    #
    # If they've specified neither, then the interpolation will fail and we'll get an exception.
    #
    begin
      return self[:config] if self[:config]
    rescue Puppet::SettingsError => err
      # This means we failed to interpolate, which means that they didn't explicitly specify either :config or
      # :confdir... so we'll fall out to the default value.
    end
    # return the default value.
    return File.join(self.class.default_global_config_dir, config_file_name)
  end
  private :main_config_file

  def user_config_file
    return File.join(self.class.default_user_config_dir, config_file_name)
  end
  private :user_config_file

  # This method is here to get around some life-cycle issues.  We need to be able to determine the config file name
  # before the settings / defaults are fully loaded.  However, we also need to respect any overrides of this value
  # that the user may have specified on the command line.
  #
  # The easiest way to do this is to attempt to read the setting, and if we catch an error (meaning that it hasn't been
  #  set yet), we'll fall back to the default value.
  def config_file_name
    begin
      return self[:config_file_name] if self[:config_file_name]
    rescue Puppet::SettingsError => err
      # This just means that the setting wasn't explicitly set on the command line, so we will ignore it and
      #  fall through to the default name.
    end
    return self.class.default_config_file_name
  end
  private :config_file_name

  # Unsafely parse the file -- this isn't thread-safe and causes plenty of problems if used directly.
  def unsafe_parse(files)
    raise Puppet::DevError unless files.length > 0

    # build up a single data structure that contains the values from all of the parsed files.
    data = {}
    files.each do |file|
      next unless FileTest.exist?(file)
      begin
        file_data = parse_file(file)

        # This is a little kludgy; basically we are merging a hash of hashes.  We can't use "merge" at the
        # outermost level or we risking losing data from the hash we're merging into.
        file_data.keys.each do |key|
          if data.has_key?(key)
            data[key].merge!(file_data[key])
          else
            data[key] = file_data[key]
          end
        end

      rescue => detail
        Puppet.log_exception(detail, "Could not parse #{file}: #{detail}")
        return
      end
    end

    # If we get here and don't have any data, we just return and don't muck with the current state of the world.
    return if data.empty?

    # If we get here then we have some data, so we need to clear out any previous settings that may have come from
    #  config files.
    unsafe_clear(false, false)

    # And now we can repopulate with the values from our last parsing of the config files.
    metas = {}
    data.each do |area, values|
      metas[area] = values.delete(:_meta)
      values.each do |key,value|
        set_value(key, value, area, :dont_trigger_handles => true, :ignore_bad_settings => true )
      end
    end

    # Determine our environment, if we have one.
    if @config[:environment]
      env = self.value(:environment).to_sym
    else
      env = "none"
    end

    # Call any hooks we should be calling.
    settings_with_hooks.each do |setting|
      each_source(env) do |source|
        if value = @values[source][setting.name]
          # We still have to use value to retrieve the value, since
          # we want the fully interpolated value, not $vardir/lib or whatever.
          # This results in extra work, but so few of the settings
          # will have associated hooks that it ends up being less work this
          # way overall.
          setting.handle(self.value(setting.name, env))
          break
        end
      end
    end

    # We have to do it in the reverse of the search path,
    # because multiple sections could set the same value
    # and I'm too lazy to only set the metadata once.
    searchpath.reverse.each do |source|
      source = run_mode if source == :run_mode
      source = @name if (@name && source == :name)
      if meta = metas[source]
        set_metadata(meta)
      end
    end
  end
  private :unsafe_parse


  # Create a new setting.  The value is passed in because it's used to determine
  # what kind of setting we're creating, but the value itself might be either
  # a default or a value, so we can't actually assign it.
  #
  # See #define_settings for documentation on the legal values for the ":type" option.
  def newsetting(hash)
    klass = nil
    hash[:section] = hash[:section].to_sym if hash[:section]

    if type = hash[:type]
      unless klass = {
          :string     => StringSetting,
          :file       => FileSetting,
          :directory  => DirectorySetting,
          :path       => StringSetting,
          :boolean    => BooleanSetting,
      } [type]
        raise ArgumentError, "Invalid setting type '#{type}'"
      end
      hash.delete(:type)
    else
      # The only implicit typing we still do for settings is to fall back to "String" type if they didn't explicitly
      # specify a type.  Personally I'd like to get rid of this too, and make the "type" option mandatory... but
      # there was a little resistance to taking things quite that far for now.  --cprice 2012-03-19
      klass = StringSetting
    end
    hash[:settings] = self
    setting = klass.new(hash)

    setting
  end

  # This has to be private, because it doesn't add the settings to @config
  private :newsetting

  # Iterate across all of the objects in a given section.
  def persection(section)
    section = section.to_sym
    self.each { |name, obj|
      if obj.section == section
        yield obj
      end
    }
  end

  # Reparse our config file, if necessary.
  def reparse
    if files
      if filename = any_files_changed?
        Puppet.notice "Config file #{filename} changed; triggering re-parse of all config files."
        parse
        reuse
      end
    end
  end

  def files
    return @files if @files
    @files = []
    [main_config_file, user_config_file].each do |path|
      if FileTest.exist?(path)
        @files << Puppet::Util::LoadedFile.new(path)
      end
    end
    @files
  end
  private :files

  # Checks to see if any of the config files have been modified
  # @return the filename of the first file that is found to have changed, or nil if no files have changed
  def any_files_changed?
    files.each do |file|
      return file.file if file.changed?
    end
    nil
  end
  private :any_files_changed?

  def reuse
    return unless defined?(@used)
    @sync.synchronize do # yay, thread-safe
      new = @used
      @used = []
      self.use(*new)
    end
  end

  # The order in which to search for values.
  def searchpath(environment = nil)
    if environment
      [:cli, :memory, environment, :run_mode, :main, :application_defaults]
    else
      [:cli, :memory, :run_mode, :main, :application_defaults]
    end
  end

  # Get a list of objects per section
  def sectionlist
    sectionlist = []
    self.each { |name, obj|
      section = obj.section || "puppet"
      sections[section] ||= []
      sectionlist << section unless sectionlist.include?(section)
      sections[section] << obj
    }

    return sectionlist, sections
  end

  def service_user_available?
    return @service_user_available if defined?(@service_user_available)

    return @service_user_available = false unless user_name = self[:user]

    user = Puppet::Type.type(:user).new :name => self[:user], :audit => :ensure

    @service_user_available = user.exists?
  end

  def legacy_to_mode(type, param)
    require 'puppet/util/command_line/legacy_command_line'
    if Puppet::Util::CommandLine::LegacyCommandLine::LEGACY_APPS.has_key?(type)
      new_type = Puppet::Util::CommandLine::LegacyCommandLine::LEGACY_APPS[type].run_mode
      Puppet.deprecation_warning "You have configuration parameter $#{param} specified in [#{type}], which is a deprecated section. I'm assuming you meant [#{new_type}]"
      return new_type
    end
    type
  end
  
  # Allow later inspection to determine if the setting was set on the
  # command line, or through some other code path.  Used for the
  # `dns_alt_names` option during cert generate. --daniel 2011-10-18
  def set_by_cli?(param)
    param = param.to_sym
    !@values[:cli][param].nil?
  end

  def set_value(param, value, type, options = {})
    param = param.to_sym

    unless setting = @config[param]
      if options[:ignore_bad_settings]
        return
      else
        raise ArgumentError,
          "Attempt to assign a value to unknown configuration parameter #{param.inspect}"
      end
    end

    value = setting.munge(value) if setting.respond_to?(:munge)
    setting.handle(value) if setting.respond_to?(:handle) and not options[:dont_trigger_handles]
    if ReadOnly.include? param and type != :application_defaults
      raise ArgumentError,
        "You're attempting to set configuration parameter $#{param}, which is read-only."
    end
    type = legacy_to_mode(type, param)
    @sync.synchronize do # yay, thread-safe

      @values[type][param] = value
      @cache.clear

      clearused

      # Clear the list of environments, because they cache, at least, the module path.
      # We *could* preferentially just clear them if the modulepath is changed,
      # but we don't really know if, say, the vardir is changed and the modulepath
      # is defined relative to it. We need the defined?(stuff) because of loading
      # order issues.
      Puppet::Node::Environment.clear if defined?(Puppet::Node) and defined?(Puppet::Node::Environment)
    end

    # This is a hack.  The run_mode should probably not be a "normal" setting, because the places
    #  it is used tend to create lifecycle issues and cause other weird problems.  In some places
    #  we need for it to have a default value, in other places it may be preferable to be able to
    #  determine that it has not yet been set.  There used to be a global variable that some
    #  code paths would access; as a first step towards cleaning it up, I've gotten rid of the global
    #  variable and am instead using an instance variable in this class, but that means that if
    #  someone modifies the value of the setting at a later point during execution, then the
    #  instance variable needs to be updated as well... so that's what we're doing here.
    #
    #  This code should be removed if we get a chance to remove run_mode from the defined settings.
    #  --cprice 2012-03-19
    self.run_mode = value if param == :run_mode

    value
  end




  # Deprecated; use #define_settings instead
  def setdefaults(section, defs)
    Puppet.deprecation_warning("'setdefaults' is deprecated and will be removed; please call 'define_settings' instead")
    define_settings(section, defs)
  end

  # Define a group of settings.
  #
  # @param [Symbol] section a symbol to use for grouping multiple settings together into a conceptual unit.  This value
  #   (and the conceptual separation) is not used very often; the main place where it will have a potential impact
  #   is when code calls Settings#use method.  See docs on that method for further details, but basically that method
  #   just attempts to do any preparation that may be necessary before code attempts to leverage the value of a particular
  #   setting.  This has the most impact for file/directory settings, where #use will attempt to "ensure" those
  #   files / directories.
  # @param [Hash[Hash]] defs the settings to be defined.  This argument is a hash of hashes; each key should be a symbol,
  #   which is basically the name of the setting that you are defining.  The value should be another hash that specifies
  #   the parameters for the particular setting.  Legal values include:
  #    [:default] => required; this is a string value that will be used as a default value for a setting if no other
  #       value is specified (via cli, config file, etc.)  This string may include "variables", demarcated with $ or ${},
  #       which will be interpolated with values of other settings.
  #    [:desc] => required; a description of the setting, used in documentation / help generation
  #    [:type] => not required, but highly encouraged!  This specifies the data type that the setting represents.  If
  #       you do not specify it, it will default to "string".  Legal values include:
  #       :string - A generic string setting
  #       :boolean - A boolean setting; values are expected to be "true" or "false"
  #       :file - A (single) file path; puppet may attempt to create this file depending on how the settings are used.  This type
  #           also supports additional options such as "mode", "owner", "group"
  #       :directory - A (single) directory path; puppet may attempt to create this file depending on how the settings are used.  This type
  #           also supports additional options such as "mode", "owner", "group"
  #       :path - This is intended to be used for settings whose value can contain multiple directory paths, respresented
  #           as strings separated by the system path separator (e.g. system path, module path, etc.).
  #     [:mode] => an (optional) octal value to be used as the permissions/mode for :file and :directory settings
  #     [:owner] => optional owner username/uid for :file and :directory settings
  #     [:group] => optional group name/gid for :file and :directory settings
  #
  def define_settings(section, defs)
    section = section.to_sym
    call = []
    defs.each { |name, hash|
      raise ArgumentError, "setting definition for '#{name}' is not a hash!" unless hash.is_a? Hash

      name = name.to_sym
      hash[:name] = name
      hash[:section] = section
      raise ArgumentError, "Parameter #{name} is already defined" if @config.include?(name)
      tryconfig = newsetting(hash)
      if short = tryconfig.short
        if other = @shortnames[short]
          raise ArgumentError, "Parameter #{other.name} is already using short name '#{short}'"
        end
        @shortnames[short] = tryconfig
      end
      @config[name] = tryconfig

      # Collect the settings that need to have their hooks called immediately.
      # We have to collect them so that we can be sure we're fully initialized before
      # the hook is called.
      call << tryconfig if tryconfig.call_on_define
    }

    call.each { |setting| setting.handle(self.value(setting.name)) }
  end

  # Convert the settings we manage into a catalog full of resources that model those settings.
  def to_catalog(*sections)
    sections = nil if sections.empty?

    catalog = Puppet::Resource::Catalog.new("Settings")

    @config.keys.find_all { |key| @config[key].is_a?(FileSetting) }.each do |key|
      file = @config[key]
      next unless (sections.nil? or sections.include?(file.section))
      next unless resource = file.to_resource
      next if catalog.resource(resource.ref)

      Puppet.debug("Using settings: adding file resource '#{key}': '#{resource.inspect}'")

      catalog.add_resource(resource)
    end

    add_user_resources(catalog, sections)

    catalog
  end

  # Convert our list of config settings into a configuration file.
  def to_config
    str = %{The configuration file for #{Puppet[:name]}.  Note that this file
is likely to have unused configuration parameters in it; any parameter that's
valid anywhere in Puppet can be in any config file, even if it's not used.

Every section can specify three special parameters: owner, group, and mode.
These parameters affect the required permissions of any files specified after
their specification.  Puppet will sometimes use these parameters to check its
own configured state, so they can be used to make Puppet a bit more self-managing.

Generated on #{Time.now}.

}.gsub(/^/, "# ")

#         Add a section heading that matches our name.
if @config.include?(:run_mode)
  str += "[#{self[:run_mode]}]\n"
    end
    eachsection do |section|
      persection(section) do |obj|
        str += obj.to_config + "\n" unless ReadOnly.include? obj.name or obj.name == :genconfig
      end
    end

    return str
  end

  # Convert to a parseable manifest
  def to_manifest
    catalog = to_catalog
    catalog.resource_refs.collect do |ref|
      catalog.resource(ref).to_manifest
    end.join("\n\n")
  end

  # Create the necessary objects to use a section.  This is idempotent;
  # you can 'use' a section as many times as you want.
  def use(*sections)
    sections = sections.collect { |s| s.to_sym }
    @sync.synchronize do # yay, thread-safe
      sections = sections.reject { |s| @used.include?(s) }

      return if sections.empty?

      begin
        catalog = to_catalog(*sections).to_ral
      rescue => detail
        Puppet.log_and_raise(detail, "Could not create resources for managing Puppet's files and directories in sections #{sections.inspect}: #{detail}")
      end

      catalog.host_config = false
      catalog.apply do |transaction|
        if transaction.any_failed?
          report = transaction.report
          failures = report.logs.find_all { |log| log.level == :err }
          raise "Got #{failures.length} failure(s) while initializing: #{failures.collect { |l| l.to_s }.join("; ")}"
        end
      end

      sections.each { |s| @used << s }
      @used.uniq!
    end
  end

  def valid?(param)
    param = param.to_sym
    @config.has_key?(param)
  end

  def uninterpolated_value(param, environment = nil)
    param = param.to_sym
    environment &&= environment.to_sym

    # See if we can find it within our searchable list of values
    val = find_value(environment, param)

    # If we didn't get a value, use the default
    val = @config[param].default if val.nil?

    val
  end

  def find_value(environment, param)
      each_source(environment) do |source|
        # Look for the value.  We have to test the hash for whether
        # it exists, because the value might be false.
        @sync.synchronize do
          return @values[source][param] if @values[source].include?(param)
        end
      end
      return nil
  end
  private :find_value

  # Find the correct value using our search path.  Optionally accept an environment
  # in which to search before the other configuration sections.
  def value(param, environment = nil)
    param = param.to_sym
    environment &&= environment.to_sym

    # Short circuit to nil for undefined parameters.
    return nil unless @config.include?(param)

    # Yay, recursion.
    #self.reparse unless [:config, :filetimeout].include?(param)

    # Check the cache first.  It needs to be a per-environment
    # cache so that we don't spread values from one env
    # to another.
    if cached = @cache[environment||"none"][param]
      return cached
    end

    val = uninterpolated_value(param, environment)

    if param == :code
      # if we interpolate code, all hell breaks loose.
      return val
    end

    # Convert it if necessary
    begin
      val = convert(val, environment)
    rescue Puppet::SettingsError => err
      raise Puppet::SettingsError.new("Error converting value for param '#{param}': #{err}")
    end


    # And cache it
    @cache[environment||"none"][param] = val
    val
  end

  # Open a file with the appropriate user, group, and mode
  def write(default, *args, &bloc)
    obj = get_config_file_default(default)
    writesub(default, value(obj.name), *args, &bloc)
  end

  # Open a non-default file under a default dir with the appropriate user,
  # group, and mode
  def writesub(default, file, *args, &bloc)
    obj = get_config_file_default(default)
    chown = nil
    if Puppet.features.root?
      chown = [obj.owner, obj.group]
    else
      chown = [nil, nil]
    end

    Puppet::Util::SUIDManager.asuser(*chown) do
      mode = obj.mode ? obj.mode.to_i : 0640
      args << "w" if args.empty?

      args << mode

      # Update the umask to make non-executable files
      Puppet::Util.withumask(File.umask ^ 0111) do
        File.open(file, *args) do |file|
          yield file
        end
      end
    end
  end

  def readwritelock(default, *args, &bloc)
    file = value(get_config_file_default(default).name)
    tmpfile = file + ".tmp"
    sync = Sync.new
    raise Puppet::DevError, "Cannot create #{file}; directory #{File.dirname(file)} does not exist" unless FileTest.directory?(File.dirname(tmpfile))

    sync.synchronize(Sync::EX) do
      File.open(file, ::File::CREAT|::File::RDWR, 0600) do |rf|
        rf.lock_exclusive do
          if File.exist?(tmpfile)
            raise Puppet::Error, ".tmp file already exists for #{file}; Aborting locked write. Check the .tmp file and delete if appropriate"
          end

          # If there's a failure, remove our tmpfile
          begin
            writesub(default, tmpfile, *args, &bloc)
          rescue
            File.unlink(tmpfile) if FileTest.exist?(tmpfile)
            raise
          end

          begin
            File.rename(tmpfile, file)
          rescue => detail
            Puppet.err "Could not rename #{file} to #{tmpfile}: #{detail}"
            File.unlink(tmpfile) if FileTest.exist?(tmpfile)
          end
        end
      end
    end
  end

  private

  def get_config_file_default(default)
    obj = nil
    unless obj = @config[default]
      raise ArgumentError, "Unknown default #{default}"
    end

    raise ArgumentError, "Default #{default} is not a file" unless obj.is_a? FileSetting

    obj
  end

  def add_user_resources(catalog, sections)
    return unless Puppet.features.root?
    return if Puppet.features.microsoft_windows?
    return unless self[:mkusers]

    @config.each do |name, setting|
      next unless setting.respond_to?(:owner)
      next unless sections.nil? or sections.include?(setting.section)

      if user = setting.owner and user != "root" and catalog.resource(:user, user).nil?
        resource = Puppet::Resource.new(:user, user, :parameters => {:ensure => :present})
        resource[:gid] = self[:group] if self[:group]
        catalog.add_resource resource
      end
      if group = setting.group and ! %w{root wheel}.include?(group) and catalog.resource(:group, group).nil?
        catalog.add_resource Puppet::Resource.new(:group, group, :parameters => {:ensure => :present})
      end
    end
  end

  # Yield each search source in turn.
  def each_source(environment)
    searchpath(environment).each do |source|

      # Modify the source as necessary.
      source = self.run_mode if source == :run_mode
      yield source
    end
  end

  # Return all settings that have associated hooks; this is so
  # we can call them after parsing the configuration file.
  def settings_with_hooks
    @config.values.find_all { |setting| setting.respond_to?(:handle) }
  end

  # Extract extra setting information for files.
  def extract_fileinfo(string)
    result = {}
    value = string.sub(/\{\s*([^}]+)\s*\}/) do
      params = $1
      params.split(/\s*,\s*/).each do |str|
        if str =~ /^\s*(\w+)\s*=\s*([\w\d]+)\s*$/
          param, value = $1.intern, $2
          result[param] = value
          raise ArgumentError, "Invalid file option '#{param}'" unless [:owner, :mode, :group].include?(param)

          if param == :mode and value !~ /^\d+$/
            raise ArgumentError, "File modes must be numbers"
          end
        else
          raise ArgumentError, "Could not parse '#{string}'"
        end
      end
      ''
    end
    result[:value] = value.sub(/\s*$/, '')
    result
  end

  # Convert arguments into booleans, integers, or whatever.
  def munge_value(value)
    # Handle different data types correctly
    return case value
      when /^false$/i; false
      when /^true$/i; true
      when /^\d+$/i; Integer(value)
      when true; true
      when false; false
      else
        value.gsub(/^["']|["']$/,'').sub(/\s+$/, '')
    end
  end

  # This method just turns a file in to a hash of hashes.
  def parse_file(file)
    text = read_file(file)

    result = Hash.new { |names, name|
      names[name] = {}
    }

    count = 0

    # Default to 'main' for the section.
    section = :main
    result[section][:_meta] = {}
    text.split(/\n/).each do |line|
      count += 1
      case line
      when /^\s*\[(\w+)\]\s*$/
        section = $1.intern # Section names
        #disallow application_defaults in config file
        if section == :application_defaults
          raise Puppet::Error.new("Illegal section 'application_defaults' in config file", file, line)
        end
        # Add a meta section
        result[section][:_meta] ||= {}
      when /^\s*#/; next # Skip comments
      when /^\s*$/; next # Skip blanks
      when /^\s*(\w+)\s*=\s*(.*?)\s*$/ # settings
        var = $1.intern

        # We don't want to munge modes, because they're specified in octal, so we'll
        # just leave them as a String, since Puppet handles that case correctly.
        if var == :mode
          value = $2
        else
          value = munge_value($2)
        end

        # Check to see if this is a file argument and it has extra options
        begin
          if value.is_a?(String) and options = extract_fileinfo(value)
            value = options[:value]
            options.delete(:value)
            result[section][:_meta][var] = options
          end
          result[section][var] = value
        rescue Puppet::Error => detail
          detail.file = file
          detail.line = line
          raise
        end
      else
        error = Puppet::Error.new("Could not match line #{line}")
        error.file = file
        error.line = line
        raise error
      end
    end

    result
  end

  # Read the file in.
  def read_file(file)
    begin
      return File.read(file)
    rescue Errno::ENOENT
      raise ArgumentError, "No such file #{file}"
    rescue Errno::EACCES
      raise ArgumentError, "Permission denied to file #{file}"
    end
  end

  # Set file metadata.
  def set_metadata(meta)
    meta.each do |var, values|
      values.each do |param, value|
        @config[var].send(param.to_s + "=", value)
      end
    end
  end

  # Private method for internal test use only; allows to do a comprehensive clear of all settings between tests.
  #
  # @return nil
  def clear_everything_for_tests()
    @sync.synchronize do
      unsafe_clear(true, true)
      @app_defaults_initialized = false
    end
  end
  private :clear_everything_for_tests

end
