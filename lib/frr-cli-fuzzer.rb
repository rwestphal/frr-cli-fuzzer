require "fileutils"
require "scanf"
require_relative "frr-cli-fuzzer/libc"
require_relative "frr-cli-fuzzer/linux_namespace"
require_relative "frr-cli-fuzzer/version"

module FrrCliFuzzer
  DFLT_ITERATIONS = 1
  DFLT_RUNSTATEDIR = "/tmp/frr-cli-fuzzer"
  DFLT_FRR_SYSCONFDIR = "/etc/frr"
  DFLT_FRR_LOCALSTATE_DIR = "/var/run/frr"
  DFLT_FRR_USER = "frr"
  DFLT_FRR_GROUP = "frr"

  class << self
    def init(iterations: nil,
             random_order: nil,
             runstatedir: nil,
             frr_build_parameters: nil,
             daemons: nil,
             configs: nil,
             nodes: nil,
             regexps: nil,
             global_whitelist: nil,
             global_blacklist: nil)
      # Load configuration and default values if necessary.
      @iterations = iterations || DFLT_ITERATIONS
      @random_order = random_order || false
      @runstatedir = runstatedir || DFLT_RUNSTATEDIR
      @frr = frr_build_parameters || []
      @frr["sysconfdir"] ||= DFLT_FRR_SYSCONFDIR
      @frr["localstatedir"] ||= DFLT_FRR_LOCALSTATE_DIR
      @frr["user"] ||= DFLT_FRR_USER
      @frr["group"] ||= DFLT_FRR_GROUP
      daemons ||= []
      @daemons = Hash[daemons.collect { |daemon| [daemon, nil] }]
      @configs = configs || []
      @nodes = nodes || []
      @regexps = regexps || []
      @global_whitelist = global_whitelist || []
      @global_blacklist = global_blacklist || []

      # Initialize counters.
      @counters = {}
      @counters["non-filtered-cmds"] = 0
      @counters["filtered-blacklist"] = 0
      @counters["filtered-whitelist"] = 0
      @counters["tested-cmds"] = 0
      @counters["segfaults"] = 0
      @segfaults = {}

      # Security check to prevent accidental deletion of data.
      unless @runstatedir.include?("frr-cli-fuzzer")
        abort("The runstatedir configuration parameter must contain "\
              "\"frr-cli-fuzzer\" somewhere in the path.")
      end
      FileUtils.rm_rf(@runstatedir)
      FileUtils.mkdir_p(@runstatedir)
      FileUtils.chown_R(@frr["user"], @frr["group"], @runstatedir)

      # Create a new process on a new pid, mount and network namespace.
      @ns = LinuxNamespace.new

      # Bind mount FRR directories.
      bind_mount(@frr["sysconfdir"], @frr["user"], @frr["group"])
      bind_mount(@frr["localstatedir"], @frr["user"], @frr["group"])
    end

    # Bind mount a path under the configured runstatedir.
    def bind_mount(path, user, group)
      source = "#{@runstatedir}/#{path}"
      FileUtils.mkdir_p(path)
      FileUtils.mkdir_p(source)
      FileUtils.chown_R(user, group, source)
      system("#{@ns.nsenter} mount --bind #{source} #{path}")
    end

    # Save configuration in the file system.
    def save_config(daemon, config)
      path = "#{@runstatedir}/#{@frr['sysconfdir']}/#{daemon}.conf"
      File.open(path, "w") { |file| file.write(config) }
    end

    # Generate FRR configuration file.
    def gen_config(daemon)
      config = @configs["all"] || ""
      config += @configs[daemon] || ""

      # Replace variables.
      config.gsub!("%(daemon)", daemon)
      config.gsub!("%(logfile)", "#{@runstatedir}/#{daemon}.log")

      save_config(daemon, config)
    end

    # Generate FRR configuration files.
    def gen_configs
      save_config("vtysh", "")
      @daemons.keys.each do |daemon|
        gen_config(daemon)
      end
    end

    # Start a FRR daemon.
    def start_daemon(daemon)
      # Remove old pid file if it exists.
      FileUtils.rm_f("#{@runstatedir}/#{@frr['localstatedir']}/#{daemon}.pid")

      # Spawn new process.
      pid = Process.spawn("#{@ns.nsenter} #{daemon} --log=stdout -d",
                          out: "#{@runstatedir}/#{daemon}.stdout",
                          err: "#{@runstatedir}/#{daemon}.stderr")
      Process.detach(pid)

      # Obtain the PID of the daemon as seen in the PID namespace where
      # it resides.
      @daemons[daemon] = `#{@ns.nsenter} pidof -s #{daemon}`.rstrip
    end

    # Start all FRR daemons.
    def start_daemons
      @daemons.keys.each do |daemon|
        start_daemon(daemon)
      end
    end

    # Check if a FRR daemon is still alive.
    def daemon_alive?(daemon)
      `#{@ns.nsenter} ps aux | grep #{daemon} | grep -E -v "defunct|grep"` != ""
    end

    # Check if a command should be white-list filtered.
    def filter_whitelist(command, whitelist)
      whitelist += @global_whitelist

      return false if whitelist.empty?

      whitelist.each do |regexp|
        return false if command =~ /#{regexp}/
      end
      true
    end

    # Check if a command should be black-list filtered.
    def filter_blacklist(command, blacklist)
      blacklist += @global_blacklist

      blacklist.each do |regexp|
        return true if command =~ /#{regexp}/
      end
      false
    end

    # Prepare command to be used by the CLI fuzzing tester.
    def prepare_command(command)
      new_command = ""

      command.split.each do |word|
        # Custom regexps.
        @regexps.each_pair do |input, option|
          word.sub!(input, option)
        end

        # Handle intervals.
        if word =~ /(\d+\-\d+)/
          interval = word.scanf("(%d-%d)")
          new_command << interval[1].to_s
        else
          new_command << word
        end

        # Append whitespace after each word.
        new_command << " "
      end

      new_command.rstrip
    end

    # Obtain array of the commands we want to test.
    def prepare_commmands
      commands = []

      @nodes.each do |node|
        hierarchy = node["hierarchy"]
        whitelist = node["whitelist"] || []
        blacklist = node["blacklist"] || []

        permutations = `#{@ns.nsenter} vtysh #{hierarchy} -c \"list permutations\"`
        permutations.each_line do |command|
          command = command.strip

          # Check whitelist and blacklist.
          if filter_whitelist(command, whitelist)
            puts "filtering (whitelist): #{command}"
            @counters["filtered-whitelist"] += 1
            next
          end
          if filter_blacklist(command, blacklist)
            puts "filtering (blacklist): #{command}"
            @counters["filtered-blacklist"] += 1
            next
          end

          @counters["non-filtered-cmds"] += 1

          commands.push("vtysh #{hierarchy} -c \"#{prepare_command(command)}\"")
        end
      end
      puts "non-filtered commands: #{@counters['non-filtered-cmds']}"

      commands
    end

    # Send command to all running FRR daemons.
    def send_command(command)
      puts "testing: #{command}"

      ["stdout", "stderr"].each do |suffix|
        File.open("#{@runstatedir}/vtysh.#{suffix}", "a") { |f| f.puts command }
      end
      Kernel.system("#{@ns.nsenter} #{command}",
                    out: ["#{@runstatedir}/vtysh.stdout", "a"],
                    err: ["#{@runstatedir}/vtysh.stderr", "a"])
    end

    # Print the results of the fuzzing tests.
    def print_results
      puts "\nresults:"
      puts "- non-filtered commands: #{@counters['non-filtered-cmds']}"
      puts "- whitelist filtered commands: #{@counters['filtered-whitelist']}"
      puts "- blacklist filtered commands: #{@counters['filtered-blacklist']}"
      puts "- tested commands: #{@counters['tested-cmds']}"
      puts "- segfaults detected: #{@counters['segfaults']}"
      @segfaults.each_pair do |msg, pids|
        puts "    (x#{pids.size}) #{msg}"
        print "      PIDs:"
        pids.each { |pid| print " #{pid}" }
        puts ""
      end
    end

    # Log a segfault to both the standard output and to the fuzzer output file.
    def log_segfault(daemon, command)
      msg = "#{daemon} aborted: #{command}"
      pid = @daemons[daemon]

      @counters["segfaults"] += 1
      @segfaults[msg] ||= []
      @segfaults[msg].push(pid)
      msg << " (PID: #{pid})"
      puts msg
      File.open("#{@runstatedir}/segfaults.txt", "a") { |f| f.puts msg }
    end

    # Append PID of the aborted daemon to its log files.
    def rename_log_files(daemon)
      pid = @daemons[daemon]

      ["log", "stdout", "stderr"].each do |suffix|
        log_file = "#{@runstatedir}/#{daemon}.#{suffix}"
        FileUtils.mv(log_file, "#{log_file}.#{pid}")
      end
    end

    # Start fuzzing tests.
    def test_fuzzing
      iteration = 0
      commands = prepare_commmands
      return if commands.empty?

      loop do
        iteration += 1
        puts "\nfuzz iteration: ##{iteration}"
        commands.shuffle! if @random_order

        # Iterate over all commands.
        commands.each do |command|
          @counters["tested-cmds"] += 1
          send_command(command)

          # Check if all daemons are still alive.
          @daemons.keys.each do |daemon|
            next if daemon_alive?(daemon)

            log_segfault(daemon, command)
            rename_log_files(daemon)
            start_daemon(daemon)
          end
        end

        # Check if this is the last iteration.
        break if @iterations > 0 && iteration == @iterations
      end
    end
  end
end
