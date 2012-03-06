#!/usr/bin/env ruby
#
# This file, hub, is generated code.
# Please DO NOT EDIT or send patches for it.
#
# Please take a look at the source from
# https://github.com/defunkt/hub
# and submit patches against the individual files
# that build hub.
#

require 'shellwords'
require 'forwardable'
require 'uri'

module Hub
  module Context
    extend Forwardable

    NULL = defined?(File::NULL) ? File::NULL : File.exist?('/dev/null') ? '/dev/null' : 'NUL'

    class GitReader
      attr_reader :executable

      def initialize(executable = nil, &read_proc)
        @executable = executable || 'git'
        read_proc ||= lambda { |cache, cmd|
          result = %x{#{command_to_string(cmd)} 2>#{NULL}}.chomp
          cache[cmd] = $?.success? && !result.empty? ? result : nil
        }
        @cache = Hash.new(&read_proc)
      end

      def add_exec_flags(flags)
        @executable = Array(executable).concat(flags)
      end

      def read_config(cmd, all = false)
        config_cmd = ['config', (all ? '--get-all' : '--get'), *cmd]
        config_cmd = config_cmd.join(' ') unless cmd.respond_to? :join
        read config_cmd
      end

      def read(cmd)
        @cache[cmd]
      end

      def stub_config_value(key, value, get = '--get')
        stub_command_output "config #{get} #{key}", value
      end

      def stub_command_output(cmd, value)
        @cache[cmd] = value.nil? ? nil : value.to_s
      end

      def stub!(values)
        @cache.update values
      end

      private

      def to_exec(args)
        args = Shellwords.shellwords(args) if args.respond_to? :to_str
        Array(executable) + Array(args)
      end

      def command_to_string(cmd)
        full_cmd = to_exec(cmd)
        full_cmd.respond_to?(:shelljoin) ? full_cmd.shelljoin : full_cmd.join(' ')
      end
    end

    module GitReaderMethods
      extend Forwardable

      def_delegator :git_reader, :read_config, :git_config
      def_delegator :git_reader, :read, :git_command

      def self.extended(base)
        base.extend Forwardable
        base.def_delegators :'self.class', :git_config, :git_command
      end
    end

    private

    def git_reader
      @git_reader ||= GitReader.new ENV['GIT']
    end

    include GitReaderMethods
    private :git_config, :git_command

    def local_repo(fatal = true)
      @local_repo ||= begin
        if is_repo?
          LocalRepo.new git_reader, current_dir
        elsif fatal
          abort "fatal: Not a git repository"
        end
      end
    end

    repo_methods = [
      :current_branch, :master_branch,
      :current_project, :upstream_project,
      :repo_owner, :repo_host,
      :remotes, :remotes_group, :origin_remote
    ]
    def_delegator :local_repo, :name, :repo_name
    def_delegators :local_repo, *repo_methods
    private :repo_name, *repo_methods

    class LocalRepo < Struct.new(:git_reader, :dir)
      include GitReaderMethods

      def name
        if project = main_project
          project.name
        else
          File.basename(dir)
        end
      end

      def repo_owner
        if project = main_project
          project.owner
        end
      end

      def repo_host
        project = main_project and project.host
      end

      def main_project
        remote = origin_remote and remote.project
      end

      def upstream_project
        if branch = current_branch and upstream = branch.upstream and upstream.remote?
          remote = remote_by_name upstream.remote_name
          remote.project
        end
      end

      def current_project
        upstream_project || main_project
      end

      def current_branch
        if branch = git_command('symbolic-ref -q HEAD')
          Branch.new self, branch
        end
      end

      def master_branch
        Branch.new self, 'refs/heads/master'
      end

      def remotes
        @remotes ||= begin
          list = git_command('remote').to_s.split("\n")
          main = list.delete('origin') and list.unshift(main)
          list.map { |name| Remote.new self, name }
        end
      end

      def remotes_group(name)
        git_config "remotes.#{name}"
      end

      def origin_remote
        remotes.first
      end

      def remote_by_name(remote_name)
        remotes.find {|r| r.name == remote_name }
      end

      def known_hosts
        git_config('hub.host', :all).to_s.split("\n") + [default_host]
      end

      def default_host
        ENV['GITHUB_HOST'] || main_host
      end

      def main_host
        'github.com'
      end
    end

    class GithubProject < Struct.new(:local_repo, :owner, :name, :host)
      def self.from_url(url, local_repo)
        if local_repo.known_hosts.include? url.host
          _, owner, name = url.path.split('/', 4)
          GithubProject.new(local_repo, owner, name.sub(/\.git$/, ''), url.host)
        end
      end

      def initialize(*args)
        super
        self.host ||= local_repo.default_host
      end

      def private?
        local_repo and host != local_repo.main_host
      end

      def owned_by(new_owner)
        new_project = dup
        new_project.owner = new_owner
        new_project
      end

      def name_with_owner
        "#{owner}/#{name}"
      end

      def ==(other)
        name_with_owner == other.name_with_owner
      end

      def remote
        local_repo.remotes.find { |r| r.project == self }
      end

      def web_url(path = nil)
        project_name = name_with_owner
        if project_name.sub!(/\.wiki$/, '')
          unless '/wiki' == path
            path = if path =~ %r{^/commits/} then '/_history'
                   else path.to_s.sub(/\w+/, '_\0')
                   end
            path = '/wiki' + path
          end
        end
        "https://#{host}/" + project_name + path.to_s
      end

      def git_url(options = {})
        if options[:https] then "https://#{host}/"
        elsif options[:private] or private? then "git@#{host}:"
        else "git://#{host}/"
        end + name_with_owner + '.git'
      end

      def api_url(type, resource, action)
        URI("https://#{host}/api/v2/#{type}/#{resource}/#{action}")
      end

      def api_show_url(type)
        api_url(type, 'repos', "show/#{owner}/#{name}")
      end

      def api_fork_url(type)
        api_url(type, 'repos', "fork/#{owner}/#{name}")
      end

      def api_create_url(type)
        api_url(type, 'repos', 'create')
      end

      def api_pullrequest_url(id, type)
        api_url(type, 'pulls', "#{owner}/#{name}/#{id}")
      end

      def api_create_pullrequest_url(type)
        api_url(type, 'pulls', "#{owner}/#{name}")
      end
    end

    class GithubURL < URI::HTTPS
      extend Forwardable

      attr_reader :project
      def_delegator :project, :name, :project_name
      def_delegator :project, :owner, :project_owner

      def self.resolve(url, local_repo)
        u = URI(url)
        if %[http https].include? u.scheme and project = GithubProject.from_url(u, local_repo)
          self.new(u.scheme, u.userinfo, u.host, u.port, u.registry,
                   u.path, u.opaque, u.query, u.fragment, project)
        end
      rescue URI::InvalidURIError
        nil
      end

      def initialize(*args)
        @project = args.pop
        super(*args)
      end

      def project_path
        path.split('/', 4)[3]
      end
    end

    class Branch < Struct.new(:local_repo, :name)
      alias to_s name

      def short_name
        name.sub(%r{^refs/(remotes/)?.+?/}, '')
      end

      def master?
        short_name == 'master'
      end

      def upstream
        if branch = local_repo.git_command("rev-parse --symbolic-full-name #{short_name}@{upstream}")
          Branch.new local_repo, branch
        end
      end

      def remote?
        name.index('refs/remotes/') == 0
      end

      def remote_name
        name =~ %r{^refs/remotes/([^/]+)} and $1 or
          raise "can't get remote name from #{name.inspect}"
      end
    end

    class Remote < Struct.new(:local_repo, :name)
      alias to_s name

      def ==(other)
        other.respond_to?(:to_str) ? name == other.to_str : super
      end

      def project
        urls.each { |url|
          if valid = GithubProject.from_url(url, local_repo)
            return valid
          end
        }
        nil
      end

      def urls
        @urls ||= local_repo.git_config("remote.#{name}.url", :all).to_s.split("\n").map { |uri|
          begin
            if uri =~ %r{^[\w-]+://}    then URI(uri)
            elsif uri =~ %r{^([^/]+?):} then URI("ssh://#{$1}/#{$'}")  # scp-like syntax
            end
          rescue URI::InvalidURIError
            nil
          end
        }.compact
      end
    end


    def github_project(name, owner = nil)
      if owner and owner.index('/')
        owner, name = owner.split('/', 2)
      elsif name and name.index('/')
        owner, name = name.split('/', 2)
      else
        name ||= repo_name
        owner ||= github_user
      end

      if local_repo(false) and main_project = local_repo.main_project
        project = main_project.dup
        project.owner = owner
        project.name = name
        project
      else
        GithubProject.new(local_repo, owner, name)
      end
    end

    def git_url(owner = nil, name = nil, options = {})
      project = github_project(name, owner)
      project.git_url({:https => https_protocol?}.update(options))
    end

    def resolve_github_url(url)
      GithubURL.resolve(url, local_repo) if url =~ /^https?:/
    end

    LGHCONF = "http://help.github.com/set-your-user-name-email-and-github-token/"

    def github_user(fatal = true, host = nil)
      if local = local_repo(false)
        host ||= local.default_host
        host = nil if host == local.main_host
      end
      host = %(."#{host}") if host
      if user = ENV['GITHUB_USER'] || git_config("github#{host}.user")
        user
      elsif fatal
        if host.nil?
          abort("** No GitHub user set. See #{LGHCONF}")
        else
          abort("** No user set for github#{host}")
        end
      end
    end

    def github_token(fatal = true, host = nil)
      if local = local_repo(false)
        host ||= local.default_host
        host = nil if host == local.main_host
      end
      host = %(."#{host}") if host
      if token = ENV['GITHUB_TOKEN'] || git_config("github#{host}.token")
        token
      elsif fatal
        if host.nil?
          abort("** No GitHub token set. See #{LGHCONF}")
        else
          abort("** No token set for github#{host}")
        end
      end
    end

    def http_clone?
      git_config('--bool hub.http-clone') == 'true'
    end

    def https_protocol?
      git_config('hub.protocol') == 'https' or http_clone?
    end

    def git_alias_for(name)
      git_config "alias.#{name}"
    end

    def rev_list(a, b)
      git_command("rev-list --cherry-pick --right-only --no-merges #{a}...#{b}")
    end

    PWD = Dir.pwd

    def current_dir
      PWD
    end

    def git_dir
      git_command 'rev-parse -q --git-dir'
    end

    def is_repo?
      !!git_dir
    end

    def git_editor
      editor = git_command 'var GIT_EDITOR'
      editor = ENV[$1] if editor =~ /^\$(\w+)$/
      editor = File.expand_path editor if (editor =~ /^[~.]/ or editor.index('/')) and editor !~ /["']/
      editor.shellsplit
    end

    def browser_launcher
      browser = ENV['BROWSER'] || (
        osx? ? 'open' : windows? ? 'start' :
        %w[xdg-open cygstart x-www-browser firefox opera mozilla netscape].find { |comm| which comm }
      )

      abort "Please set $BROWSER to a web launcher to use this command." unless browser
      Array(browser)
    end

    def osx?
      require 'rbconfig'
      RbConfig::CONFIG['host_os'].to_s.include?('darwin')
    end

    def windows?
      require 'rbconfig'
      RbConfig::CONFIG['host_os'] =~ /msdos|mswin|djgpp|mingw|windows/
    end

    def which(cmd)
      exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
      ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
        exts.each { |ext|
          exe = "#{path}/#{cmd}#{ext}"
          return exe if File.executable? exe
        }
      end
      return nil
    end

    def command?(name)
      !which(name).nil?
    end
  end
end
module Hub
  class Args < Array
    attr_accessor :executable

    def initialize(*args)
      super
      @executable = ENV["GIT"] || "git"
      @after = nil
      @skip = @noop = false
      @original_args = args.first
      @chain = [nil]
    end

    def after(cmd_or_args = nil, args = nil, &block)
      @chain.insert(-1, normalize_callback(cmd_or_args, args, block))
    end

    def before(cmd_or_args = nil, args = nil, &block)
      @chain.insert(@chain.index(nil), normalize_callback(cmd_or_args, args, block))
    end

    def chained?
      @chain.size > 1
    end

    def commands
      chain = @chain.dup
      chain[chain.index(nil)] = self.to_exec
      chain
    end

    def skip!
      @skip = true
    end

    def skip?
      @skip
    end

    def noop!
      @noop = true
    end

    def noop?
      @noop
    end

    def to_exec(args = self)
      Array(executable) + args
    end

    def add_exec_flags(flags)
      self.executable = Array(executable).concat(flags)
    end

    def words
      reject { |arg| arg.index('-') == 0 }
    end

    def flags
      self - words
    end

    def changed?
      chained? or self != @original_args
    end

    def has_flag?(*flags)
      pattern = flags.flatten.map { |f| Regexp.escape(f) }.join('|')
      !grep(/^#{pattern}(?:=|$)/).empty?
    end

    private

    def normalize_callback(cmd_or_args, args, block)
      if block
        block
      elsif args
        [cmd_or_args].concat args
      elsif Array === cmd_or_args
        self.to_exec cmd_or_args
      elsif cmd_or_args
        cmd_or_args
      else
        raise ArgumentError, "command or block required"
      end
    end
  end
end
module Hub
  module Commands
    instance_methods.each { |m| undef_method(m) unless m =~ /(^__|send|to\?$)/ }
    extend self

    extend Context

    NAME_RE = /\w[\w.-]*/
    OWNER_RE = /[a-zA-Z0-9-]+/
    NAME_WITH_OWNER_RE = /^(?:#{NAME_RE}|#{OWNER_RE}\/#{NAME_RE})$/

    def run(args)
      slurp_global_flags(args)

      args.unshift 'help' if args.empty?

      cmd = args[0]
      expanded_args = expand_alias(cmd)
      cmd = expanded_args[0] if expanded_args

      cmd = cmd.sub(/(\w)-/, '\1_')
      if method_defined?(cmd) and cmd != 'run'
        args[0, 1] = expanded_args if expanded_args
        send(cmd, args)
      end
    rescue Errno::ENOENT
      if $!.message.include? "No such file or directory - git"
        abort "Error: `git` command not found"
      else
        raise
      end
    end

    def pull_request(args)
      args.shift
      options = { }
      force = explicit_owner = false
      base_project = local_repo.main_project
      head_project = local_repo.current_project

      from_github_ref = lambda do |ref, context_project|
        if ref.index(':')
          owner, ref = ref.split(':', 2)
          project = github_project(context_project.name, owner)
        end
        [project || context_project, ref]
      end

      while arg = args.shift
        case arg
        when '-f'
          force = true
        when '-b'
          base_project, options[:base] = from_github_ref.call(args.shift, base_project)
        when '-h'
          head = args.shift
          explicit_owner = !!head.index(':')
          head_project, options[:head] = from_github_ref.call(head, head_project)
        when '-i'
          options[:issue] = args.shift
        else
          if url = resolve_github_url(arg) and url.project_path =~ /^issues\/(\d+)/
            options[:issue] = $1
            base_project = url.project
          elsif !options[:title] then options[:title] = arg
          else
            abort "invalid argument: #{arg}"
          end
        end
      end

      options[:project] = base_project
      options[:base] ||= master_branch.short_name

      if tracked_branch = options[:head].nil? && current_branch.upstream
        if !tracked_branch.remote?
          tracked_branch = nil
        elsif base_project == head_project and tracked_branch.short_name == options[:base]
          $stderr.puts "Aborted: head branch is the same as base (#{options[:base].inspect})"
          warn "(use `-h <branch>` to specify an explicit pull request head)"
          abort
        end
      end
      options[:head] ||= (tracked_branch || current_branch).short_name

      user = github_user(true, head_project.host)
      if head_project.owner != user and !tracked_branch and !explicit_owner
        head_project = head_project.owned_by(user)
      end

      remote_branch = "#{head_project.remote}/#{options[:head]}"
      options[:head] = "#{head_project.owner}:#{options[:head]}"

      if !force and tracked_branch and local_commits = rev_list(remote_branch, nil)
        $stderr.puts "Aborted: #{local_commits.split("\n").size} commits are not yet pushed to #{remote_branch}"
        warn "(use `-f` to force submit a pull request anyway)"
        abort
      end

      if args.noop?
        puts "Would reqest a pull to #{base_project.owner}:#{options[:base]} from #{options[:head]}"
        exit
      end

      unless options[:title] or options[:issue]
        base_branch = "#{base_project.remote}/#{options[:base]}"
        commits = rev_list(base_branch, remote_branch).to_s.split("\n")

        case commits.size
        when 0
          default_message = commit_summary = nil
        when 1
          format = '%w(78,0,0)%s%n%+b'
          default_message = git_command "show -s --format='#{format}' #{commits.first}"
          commit_summary = nil
        else
          format = '%h (%aN, %ar)%n%w(78,3,3)%s%n%+b'
          default_message = nil
          commit_summary = git_command "log --no-color --format='%s' --cherry %s...%s" %
            [format, base_branch, remote_branch]
        end

        options[:title], options[:body] = pullrequest_editmsg(commit_summary) { |msg|
          msg.puts default_message if default_message
          msg.puts ""
          msg.puts "# Requesting a pull to #{base_project.owner}:#{options[:base]} from #{options[:head]}"
          msg.puts "#"
          msg.puts "# Write a message for this pull request. The first block"
          msg.puts "# of text is the title and the rest is description."
        }
      end

      pull = create_pullrequest(options)

      args.executable = 'echo'
      args.replace [pull['html_url']]
    rescue HTTPExceptions
      display_http_exception("creating pull request", $!.response)
      exit 1
    end

    def clone(args)
      ssh = args.delete('-p')
      has_values = /^(--(upload-pack|template|depth|origin|branch|reference)|-[ubo])$/

      idx = 1
      while idx < args.length
        arg = args[idx]
        if arg.index('-') == 0
          idx += 1 if arg =~ has_values
        else
          if arg =~ NAME_WITH_OWNER_RE and !File.directory?(arg)
            name, owner = arg, nil
            owner, name = name.split('/', 2) if name.index('/')
            host = ENV['GITHUB_HOST']
            project = Context::GithubProject.new(nil, owner || github_user(true, host), name, host || 'github.com')
            ssh ||= args[0] != 'submodule' && project.owner == github_user(false, host) || host
            args[idx] = project.git_url(:private => ssh, :https => https_protocol?)
          end
          break
        end
        idx += 1
      end
    end

    def submodule(args)
      return unless index = args.index('add')
      args.delete_at index

      branch = args.index('-b') || args.index('--branch')
      if branch
        args.delete_at branch
        branch_name = args.delete_at branch
      end

      clone(args)

      if branch_name
        args.insert branch, '-b', branch_name
      end
      args.insert index, 'add'
    end

    def remote(args)
      if %w[add set-url].include?(args[1])
        name = args.last
        if name =~ /^(#{OWNER_RE})$/ || name =~ /^(#{OWNER_RE})\/(#{NAME_RE})$/
          user, repo = $1, $2 || repo_name
        end
      end
      return unless user # do not touch arguments

      ssh = args.delete('-p')

      if args.words[2] == 'origin' && args.words[3].nil?
        user, repo = github_user, repo_name
      elsif args.words[-2] == args.words[1]
        idx = args.index( args.words[-1] )
        args[idx] = user
      else
        args.pop
      end

      args << git_url(user, repo, :private => ssh)
    end

    def fetch(args)
      if args.include?('--multiple')
        names = args.words[1..-1]
      elsif remote_name = args.words[1]
        if remote_name =~ /^\w+(,\w+)+$/
          index = args.index(remote_name)
          args.delete(remote_name)
          names = remote_name.split(',')
          args.insert(index, *names)
          args.insert(index, '--multiple')
        else
          names = [remote_name]
        end
      else
        names = []
      end

      projects = names.map { |name|
        unless name =~ /\W/ or remotes.include?(name) or remotes_group(name)
          project = github_project(nil, name)
          project if repo_exists?(project)
        end
      }.compact

      if projects.any?
        projects.each do |project|
          args.before ['remote', 'add', project.owner, project.git_url(:https => https_protocol?)]
        end
      end
    end

    def checkout(args)
      _, url_arg, new_branch_name = args.words
      if url = resolve_github_url(url_arg) and url.project_path =~ /^pull\/(\d+)/
        pull_id = $1

        load_net_http
        response = http_request(url.project.api_pullrequest_url(pull_id, 'json'))
        pull_data = JSON.parse(response.body)['pull']

        args.delete new_branch_name
        user, branch = pull_data['head']['label'].split(':', 2)
        abort "Error: #{user}'s fork is not available anymore" unless pull_data['head']['repository']
        new_branch_name ||= "#{user}-#{branch}"

        if remotes.include? user
          args.before ['remote', 'set-branches', '--add', user, branch]
          args.before ['fetch', user, "+refs/heads/#{branch}:refs/remotes/#{user}/#{branch}"]
        else
          url = github_project(url.project_name, user).git_url(:private => pull_data['head']['repository']['private'],
                                                               :https => https_protocol?)
          args.before ['remote', 'add', '-f', '-t', branch, user, url]
        end
        idx = args.index url_arg
        args.delete_at idx
        args.insert idx, '--track', '-B', new_branch_name, "#{user}/#{branch}"
      end
    end

    def cherry_pick(args)
      unless args.include?('-m') or args.include?('--mainline')
        ref = args.words.last
        if url = resolve_github_url(ref) and url.project_path =~ /^commit\/([a-f0-9]{7,40})/
          sha = $1
          project = url.project
        elsif ref =~ /^(#{OWNER_RE})@([a-f0-9]{7,40})$/
          owner, sha = $1, $2
          project = local_repo.main_project.owned_by(owner)
        end

        if project
          args[args.index(ref)] = sha

          if remote = project.remote and remotes.include? remote
            args.before ['fetch', remote.to_s]
          else
            args.before ['remote', 'add', '-f', project.owner, project.git_url(:https => https_protocol?)]
          end
        end
      end
    end

    def am(args)
      if url = args.find { |a| a =~ %r{^https?://(gist\.)?github\.com/} }
        idx = args.index(url)
        gist = $1 == 'gist.'
        url = url.sub(/#.+/, '')
        url = url.sub(%r{(/pull/\d+)/\w*$}, '\1') unless gist
        ext = gist ? '.txt' : '.patch'
        url += ext unless File.extname(url) == ext
        patch_file = File.join(ENV['TMPDIR'] || '/tmp', "#{gist ? 'gist-' : ''}#{File.basename(url)}")
        args.before 'curl', ['-#LA', "hub #{Hub::Version}", url, '-o', patch_file]
        args[idx] = patch_file
      end
    end

    alias_method :apply, :am

    def init(args)
      if args.delete('-g')
        host = ENV['GITHUB_HOST']
        project = Context::GithubProject.new(nil, github_user(true, host), File.basename(current_dir), host || 'github.com')
        url = project.git_url(:private => true, :https => https_protocol?)
        args.after ['remote', 'add', 'origin', url]
      end
    end

    def fork(args)
      unless project = local_repo.main_project
        abort "Error: repository under 'origin' remote is not a GitHub project"
      end
      forked_project = project.owned_by(github_user(true, project.host))
      if repo_exists?(forked_project)
        warn "#{forked_project.name_with_owner} already exists on #{forked_project.host}"
      else
        fork_repo(project) unless args.noop?
      end

      if args.include?('--no-remote')
        exit
      else
        url = forked_project.git_url(:private => true, :https => https_protocol?)
        args.replace %W"remote add -f #{forked_project.owner} #{url}"
        args.after 'echo', ['new remote:', forked_project.owner]
      end
    rescue HTTPExceptions
      display_http_exception("creating fork", $!.response)
      exit 1
    end

    def create(args)
      if !is_repo?
        abort "'create' must be run from inside a git repository"
      elsif owner = github_user and github_token
        args.shift
        options = {}
        options[:private] = true if args.delete('-p')
        new_repo_name = nil

        until args.empty?
          case arg = args.shift
          when '-d'
            options[:description] = args.shift
          when '-h'
            options[:homepage] = args.shift
          else
            if arg =~ /^[^-]/ and new_repo_name.nil?
              new_repo_name = arg
              owner, new_repo_name = new_repo_name.split('/', 2) if new_repo_name.index('/')
            else
              abort "invalid argument: #{arg}"
            end
          end
        end
        new_repo_name ||= repo_name
        new_project = github_project(new_repo_name, owner)

        if repo_exists?(new_project)
          warn "#{new_project.name_with_owner} already exists on #{new_project.host}"
          action = "set remote origin"
        else
          action = "created repository"
          create_repo(new_project, options) unless args.noop?
        end

        url = new_project.git_url(:private => true, :https => https_protocol?)

        if remotes.first != 'origin'
          args.replace %W"remote add -f origin #{url}"
        else
          args.replace %W"remote -v"
        end

        args.after 'echo', ["#{action}:", new_project.name_with_owner]
      end
    rescue HTTPExceptions
      display_http_exception("creating repository", $!.response)
      exit 1
    end

    def push(args)
      return if args[1].nil? || !args[1].index(',')

      branch  = (args[2] ||= current_branch.short_name)
      remotes = args[1].split(',')
      args[1] = remotes.shift

      remotes.each do |name|
        args.after ['push', name, branch]
      end
    end

    def browse(args)
      args.shift
      browse_command(args) do
        dest = args.shift
        dest = nil if dest == '--'

        if dest
          project = github_project dest
          branch = master_branch
        else
          project = current_project
          branch = current_branch && current_branch.upstream || master_branch
        end

        abort "Usage: hub browse [<USER>/]<REPOSITORY>" unless project

        path = case subpage = args.shift
        when 'commits'
          "/commits/#{branch.short_name}"
        when 'tree', NilClass
          "/tree/#{branch.short_name}" if branch and !branch.master?
        else
          "/#{subpage}"
        end

        project.web_url(path)
      end
    end

    def compare(args)
      args.shift
      browse_command(args) do
        if args.empty?
          branch = current_branch.upstream
          if branch and not branch.master?
            range = branch.short_name
            project = current_project
          else
            abort "Usage: hub compare [USER] [<START>...]<END>"
          end
        else
          sha_or_tag = /(\w{1,2}|\w[\w.-]+\w)/
          range = args.pop.sub(/^#{sha_or_tag}\.\.#{sha_or_tag}$/, '\1...\2')
          project = if owner = args.pop then github_project(nil, owner)
                    else current_project
                    end
        end

        project.web_url "/compare/#{range}"
      end
    end

    def hub(args)
      return help(args) unless args[1] == 'standalone'
      require 'hub/standalone'
      $stdout.puts Hub::Standalone.build
      exit
    rescue LoadError
      abort "hub is running in standalone mode."
    end

    def alias(args)
      shells = {
        'sh'   => 'alias git=hub',
        'bash' => 'alias git=hub',
        'zsh'  => 'function git(){hub "$@"}',
        'csh'  => 'alias git hub',
        'fish' => 'alias git hub'
      }

      silent = args.delete('-s')

      if shell = args[1]
        if silent.nil?
          puts "Run this in your shell to start using `hub` as `git`:"
          print "  "
        end
      else
        puts "usage: hub alias [-s] SHELL", ""
        puts "You already have hub installed and available in your PATH,"
        puts "but to get the full experience you'll want to alias it to"
        puts "`git`.", ""
        puts "To see how to accomplish this for your shell, run the alias"
        puts "command again with the name of your shell.", ""
        puts "Known shells:"
        shells.map { |key, _| key }.sort.each do |key|
          puts "  " + key
        end
        puts "", "Options:"
        puts "  -s   Silent. Useful when using the output with eval, e.g."
        puts "       $ eval `hub alias -s bash`"

        exit
      end

      if shells[shell]
        puts shells[shell]
      else
        abort "fatal: never heard of `#{shell}'"
      end

      exit
    end

    def version(args)
      args.after 'echo', ['hub version', Version]
    end
    alias_method "--version", :version

    def help(args)
      command = args.words[1]

      if command == 'hub'
        puts hub_manpage
        exit
      elsif command.nil? && !args.has_flag?('-a', '--all')
        ENV['GIT_PAGER'] = '' unless args.has_flag?('-p', '--paginate') # Use `cat`.
        puts improved_help_text
        exit
      end
    end
    alias_method "--help", :help

  private

    def improved_help_text
      <<-help
usage: git [--version] [--exec-path[=<path>]] [--html-path] [--man-path] [--info-path]
           [-p|--paginate|--no-pager] [--no-replace-objects] [--bare]
           [--git-dir=<path>] [--work-tree=<path>] [--namespace=<name>]
           [-c name=value] [--help]
           <command> [<args>]

Basic Commands:
   init       Create an empty git repository or reinitialize an existing one
   add        Add new or modified files to the staging area
   rm         Remove files from the working directory and staging area
   mv         Move or rename a file, a directory, or a symlink
   status     Show the status of the working directory and staging area
   commit     Record changes to the repository

History Commands:
   log        Show the commit history log
   diff       Show changes between commits, commit and working tree, etc
   show       Show information about commits, tags or files

Branching Commands:
   branch     List, create, or delete branches
   checkout   Switch the active branch to another branch
   merge      Join two or more development histories (branches) together
   tag        Create, list, delete, sign or verify a tag object

Remote Commands:
   clone      Clone a remote repository into a new directory
   fetch      Download data, tags and branches from a remote repository
   pull       Fetch from and merge with another repository or a local branch
   push       Upload data, tags and branches to a remote repository
   remote     View and manage a set of remote repositories

Advanced commands:
   reset      Reset your staging area or working directory to another point
   rebase     Re-apply a series of patches in one branch onto another
   bisect     Find by binary search the change that introduced a bug
   grep       Print files with lines matching a pattern in your codebase

See 'git help <command>' for more information on a specific command.
help
    end

    def slurp_global_flags(args)
      flags = %w[ --noop -c -p --paginate --no-pager --no-replace-objects --bare --version --help ]
      flags2 = %w[ --exec-path= --git-dir= --work-tree= ]

      globals = []
      locals = []

      while args[0] && (flags.include?(args[0]) || flags2.any? {|f| args[0].index(f) == 0 })
        flag = args.shift
        case flag
        when '--noop'
          args.noop!
        when '--version', '--help'
          args.unshift flag.sub('--', '')
        when '-c'
          config_pair = args.shift
          key, value = config_pair.split('=', 2)
          git_reader.stub_config_value(key, value)

          globals << flag << config_pair
        when '-p', '--paginate', '--no-pager'
          locals << flag
        else
          globals << flag
        end
      end

      git_reader.add_exec_flags(globals)
      args.add_exec_flags(globals)
      args.add_exec_flags(locals)
    end

    def browse_command(args)
      url_only = args.delete('-u')
      warn "Warning: the `-p` flag has no effect anymore" if args.delete('-p')
      url = yield

      args.executable = url_only ? 'echo' : browser_launcher
      args.push url
    end

    def hub_manpage
      abort "** Can't find groff(1)" unless command?('groff')

      require 'open3'
      out = nil
      Open3.popen3(groff_command) do |stdin, stdout, _|
        stdin.puts hub_raw_manpage
        stdin.close
        out = stdout.read.strip
      end
      out
    end

    def groff_command
      "groff -Wall -mtty-char -mandoc -Tascii"
    end

    def hub_raw_manpage
      if File.exists? file = File.dirname(__FILE__) + '/../../man/hub.1'
        File.read(file)
      else
        DATA.read
      end
    end

    def puts(*args)
      page_stdout
      super
    end

    def page_stdout
      return if not $stdout.tty? or windows?

      read, write = IO.pipe

      if Kernel.fork
        $stdin.reopen(read)
        read.close
        write.close

        ENV['LESS'] = 'FSRX'

        Kernel.select [STDIN]

        pager = ENV['GIT_PAGER'] ||
          `git config --get-all core.pager`.split.first || ENV['PAGER'] ||
          'less -isr'

        pager = 'cat' if pager.empty?

        exec pager rescue exec "/bin/sh", "-c", pager
      else
        $stdout.reopen(write)
        $stderr.reopen(write) if $stderr.tty?
        read.close
        write.close
      end
    end

    def repo_exists?(project)
      load_net_http
      Net::HTTPSuccess === http_request(project.api_show_url('yaml'))
    end

    def fork_repo(project)
      load_net_http
      response = http_post project.api_fork_url('yaml')
      response.error! unless Net::HTTPSuccess === response
    end

    def create_repo(project, options = {})
      is_org = project.owner != github_user(true, project.host)
      params = {'name' => is_org ? project.name_with_owner : project.name}
      params['public'] = '0' if options[:private]
      params['description'] = options[:description] if options[:description]
      params['homepage'] = options[:homepage] if options[:homepage]

      load_net_http
      response = http_post(project.api_create_url('yaml'), params)
      response.error! unless Net::HTTPSuccess === response
    end

    def create_pullrequest(options)
      project = options.fetch(:project)
      params = {
        'pull[base]' => options.fetch(:base),
        'pull[head]' => options.fetch(:head)
      }
      params['pull[issue]'] = options[:issue] if options[:issue]
      params['pull[title]'] = options[:title] if options[:title]
      params['pull[body]'] = options[:body] if options[:body]

      load_net_http
      response = http_post(project.api_create_pullrequest_url('json'), params)
      response.error! unless Net::HTTPSuccess === response
      JSON.parse(response.body)['pull']
    end

    def pullrequest_editmsg(changes)
      message_file = File.join(git_dir, 'PULLREQ_EDITMSG')
      File.open(message_file, 'w') { |msg|
        yield msg
        if changes
          msg.puts "#\n# Changes:\n#"
          msg.puts changes.gsub(/^/, '# ').gsub(/ +$/, '')
        end
      }
      edit_cmd = Array(git_editor).dup
      edit_cmd << '-c' << 'set ft=gitcommit' if edit_cmd[0] =~ /^[mg]?vim$/
      edit_cmd << message_file
      system(*edit_cmd)
      abort "can't open text editor for pull request message" unless $?.success?
      title, body = read_editmsg(message_file)
      abort "Aborting due to empty pull request title" unless title
      [title, body]
    end

    def read_editmsg(file)
      title, body = '', ''
      File.open(file, 'r') { |msg|
        msg.each_line do |line|
          next if line.index('#') == 0
          ((body.empty? and line =~ /\S/) ? title : body) << line
        end
      }
      title.tr!("\n", ' ')
      title.strip!
      body.strip!
      
      [title =~ /\S/ ? title : nil, body =~ /\S/ ? body : nil]
    end

    def expand_alias(cmd)
      if expanded = git_alias_for(cmd)
        if expanded.index('!') != 0
          require 'shellwords' unless defined?(::Shellwords)
          Shellwords.shellwords(expanded)
        end
      end
    end

    def http_request(url, type = :Get)
      url = URI(url) unless url.respond_to? :host
      user, token = github_user(type != :Get, url.host), github_token(type != :Get, url.host)

      req = Net::HTTP.const_get(type).new(url.request_uri)
      req.basic_auth "#{user}/token", token if user and token

      http = setup_http(url)

      yield req if block_given?
      http.start { http.request(req) }
    end

    def http_post(url, params = nil)
      http_request(url, :Post) do |req|
        req.set_form_data params if params
        req['Content-Length'] = req.body ? req.body.length : 0
      end
    end

    def setup_http(url)
      port = url.port
      if use_ssl = 'https' == url.scheme and not use_ssl?
        use_ssl = false
        port = 80
      end

      http_args = [url.host, port]
      if proxy = proxy_url(use_ssl)
        http_args.concat proxy.select(:host, :port)
        if proxy.userinfo
          require 'cgi'
          http_args.concat proxy.userinfo.split(':', 2).map {|a| CGI.unescape a }
        end
      end

      http = Net::HTTP.new(*http_args)

      if http.use_ssl = use_ssl
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      return http
    end

    def load_net_http
      require 'net/https'
    rescue LoadError
      require 'net/http'
    end

    def use_ssl?
      defined? ::OpenSSL
    end

    def proxy_url(use_ssl)
      env_name = "HTTP#{use_ssl ? 'S' : ''}_PROXY"
      if proxy = ENV[env_name] || ENV[env_name.downcase]
        proxy = "http://#{proxy}" unless proxy.include? '://'
        URI.parse(proxy)
      end
    end

    module HTTPExceptions
      def self.===(exception)
        exception.class.ancestors.map {|a| a.to_s }.include? 'Net::HTTPExceptions'
      end
    end

    def display_http_exception(action, response)
      $stderr.puts "Error #{action}: #{response.message} (HTTP #{response.code})"
      case response.code.to_i
      when 401 then warn "Check your token configuration (`git config github.token`)"
      when 422
        if response.content_type =~ /\bjson\b/ and data = JSON.parse(response.body) and data["error"]
          $stderr.puts data["error"]
        end
      end
    end

  end
end
require 'strscan'
require 'forwardable'

class Hub::JSON
  def self.parse(data) new(data).parse end

  WSP = /\s+/
  OBJ = /[{\[]/;    HEN = /\}/;  AEN = /\]/
  COL = /\s*:\s*/;  KEY = /\s*,\s*/
  NUM = /-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/
  BOL = /true|false/;  NUL = /null/

  extend Forwardable

  attr_reader :scanner
  alias_method :s, :scanner
  def_delegators :scanner, :scan, :matched
  private :s, :scan, :matched

  def initialize data
    @scanner = StringScanner.new data.to_s
  end

  def parse
    space
    object
  end

  private

  def space() scan WSP end

  def endkey() scan(KEY) or space end

  def object
    matched == '{' ? hash : array if scan(OBJ)
  end

  def value
    object or string or
      scan(NUL) ? nil :
      scan(BOL) ? matched.size == 4:
      scan(NUM) ? eval(matched) :
      error
  end

  def hash
    obj = {}
    space
    repeat_until(HEN) { k = string; scan(COL); obj[k] = value; endkey }
    obj
  end

  def array
    ary = []
    space
    repeat_until(AEN) { ary << value; endkey }
    ary
  end

  SPEC = {'b' => "\b", 'f' => "\f", 'n' => "\n", 'r' => "\r", 't' => "\t"}
  UNI = 'u'; CODE = /[a-fA-F0-9]{4}/
  STR = /"/; STE = '"'
  ESC = '\\'

  def string
    if scan(STR)
      str, esc = '', false
      while c = s.getch
        if esc
          str << (c == UNI ? (s.scan(CODE) || error).to_i(16).chr : SPEC[c] || c)
          esc = false
        else
          case c
          when ESC then esc = true
          when STE then break
          else str << c
          end
        end
      end
      str
    end
  end

  def error
    raise "parse error at: #{scan(/.{1,10}/m).inspect}"
  end

  def repeat_until reg
    until scan(reg)
      pos = s.pos
      yield
      error unless s.pos > pos
    end
  end
end
module Hub
  class Runner
    attr_reader :args
    
    def initialize(*args)
      @args = Args.new(args)
      Commands.run(@args)
    end

    def self.execute(*args)
      new(*args).execute
    end

    def command
      if args.skip?
        ''
      else
        commands.join('; ')
      end
    end

    def commands
      args.commands.map do |cmd|
        if cmd.respond_to?(:join)
          cmd.map { |arg| arg = arg.to_s; (arg.index(' ') || arg.empty?) ? "'#{arg}'" : arg }.join(' ')
        else
          cmd.to_s
        end
      end
    end

    def execute
      if args.noop?
        puts commands
      elsif not args.skip?
        if args.chained?
          execute_command_chain
        else
          exec(*args.to_exec)
        end
      end
    end

    def execute_command_chain
      commands = args.commands
      commands.each_with_index do |cmd, i|
        if cmd.respond_to?(:call) then cmd.call
        elsif i == commands.length - 1
          exec(*cmd)
        else
          exit($?.exitstatus) unless system(*cmd)
        end
      end
    end
  end
end
module Hub
  Version = VERSION = '1.8.3'
end
Hub::Runner.execute(*ARGV)
__END__
.\" generated with Ronn/v0.7.3
.\" http://github.com/rtomayko/ronn/tree/0.7.3
.
.TH "HUB" "1" "March 2012" "DEFUNKT" "Git Manual"
.
.SH "NAME"
\fBhub\fR \- git + hub = github
.
.SH "SYNOPSIS"
\fBhub\fR [\fB\-\-noop\fR] \fICOMMAND\fR \fIOPTIONS\fR
.
.br
\fBhub alias\fR [\fB\-s\fR] \fISHELL\fR
.
.SS "Expanded git commands:"
\fBgit init \-g\fR \fIOPTIONS\fR
.
.br
\fBgit clone\fR [\fB\-p\fR] \fIOPTIONS\fR [\fIUSER\fR/]\fIREPOSITORY\fR \fIDIRECTORY\fR
.
.br
\fBgit remote add\fR [\fB\-p\fR] \fIOPTIONS\fR \fIUSER\fR[/\fIREPOSITORY\fR]
.
.br
\fBgit remote set\-url\fR [\fB\-p\fR] \fIOPTIONS\fR \fIREMOTE\-NAME\fR \fIUSER\fR[/\fIREPOSITORY\fR]
.
.br
\fBgit fetch\fR \fIUSER\-1\fR,[\fIUSER\-2\fR,\.\.\.]
.
.br
\fBgit checkout\fR \fIPULLREQ\-URL\fR [\fIBRANCH\fR]
.
.br
\fBgit cherry\-pick\fR \fIGITHUB\-REF\fR
.
.br
\fBgit am\fR \fIGITHUB\-URL\fR
.
.br
\fBgit apply\fR \fIGITHUB\-URL\fR
.
.br
\fBgit push\fR \fIREMOTE\-1\fR,\fIREMOTE\-2\fR,\.\.\.,\fIREMOTE\-N\fR [\fIREF\fR]
.
.br
\fBgit submodule add\fR [\fB\-p\fR] \fIOPTIONS\fR [\fIUSER\fR/]\fIREPOSITORY\fR \fIDIRECTORY\fR
.
.SS "Custom git commands:"
\fBgit create\fR [\fINAME\fR] [\fB\-p\fR] [\fB\-d\fR \fIDESCRIPTION\fR] [\fB\-h\fR \fIHOMEPAGE\fR]
.
.br
\fBgit browse\fR [\fB\-u\fR] [[\fIUSER\fR\fB/\fR]\fIREPOSITORY\fR] [SUBPAGE]
.
.br
\fBgit compare\fR [\fB\-u\fR] [\fIUSER\fR] [\fISTART\fR\.\.\.]\fIEND\fR
.
.br
\fBgit fork\fR [\fB\-\-no\-remote\fR]
.
.br
\fBgit pull\-request\fR [\fB\-f\fR] [\fITITLE\fR|\fB\-i\fR \fIISSUE\fR] [\fB\-b\fR \fIBASE\fR] [\fB\-h\fR \fIHEAD\fR]:
.
.SH "DESCRIPTION"
hub enhances various git commands to ease most common workflows with GitHub\.
.
.TP
\fBhub \-\-noop\fR \fICOMMAND\fR
Shows which command(s) would be run as a result of the current command\. Doesn\'t perform anything\.
.
.TP
\fBhub alias\fR [\fB\-s\fR] \fISHELL\fR
Writes shell aliasing code for \fISHELL\fR (\fBbash\fR, \fBsh\fR, \fBzsh\fR, \fBcsh\fR) to standard output\. With the \fB\-s\fR option, the output of this command can be evaluated directly within the shell:
.
.br
\fBeval $(hub alias \-s bash)\fR
.
.TP
\fBgit init\fR \fB\-g\fR \fIOPTIONS\fR
Create a git repository as with git\-init(1) and add remote \fBorigin\fR at "git@github\.com:\fIUSER\fR/\fIREPOSITORY\fR\.git"; \fIUSER\fR is your GitHub username and \fIREPOSITORY\fR is the current working directory\'s basename\.
.
.TP
\fBgit clone\fR [\fB\-p\fR] \fIOPTIONS\fR [\fIUSER\fR\fB/\fR]\fIREPOSITORY\fR \fIDIRECTORY\fR
Clone repository "git://github\.com/\fIUSER\fR/\fIREPOSITORY\fR\.git" into \fIDIRECTORY\fR as with git\-clone(1)\. When \fIUSER\fR/ is omitted, assumes your GitHub login\. With \fB\-p\fR, clone private repositories over SSH\. For repositories under your GitHub login, \fB\-p\fR is implicit\.
.
.TP
\fBgit remote add\fR [\fB\-p\fR] \fIOPTIONS\fR \fIUSER\fR[\fB/\fR\fIREPOSITORY\fR]
Add remote "git://github\.com/\fIUSER\fR/\fIREPOSITORY\fR\.git" as with git\-remote(1)\. When /\fIREPOSITORY\fR is omitted, the basename of the current working directory is used\. With \fB\-p\fR, use private remote "git@github\.com:\fIUSER\fR/\fIREPOSITORY\fR\.git"\. If \fIUSER\fR is "origin" then uses your GitHub login\.
.
.TP
\fBgit remote set\-url\fR [\fB\-p\fR] \fIOPTIONS\fR \fIREMOTE\-NAME\fR \fIUSER\fR[/\fIREPOSITORY\fR]
Sets the url of remote \fIREMOTE\-NAME\fR using the same rules as \fBgit remote add\fR\.
.
.TP
\fBgit fetch\fR \fIUSER\-1\fR,[\fIUSER\-2\fR,\.\.\.]
Adds missing remote(s) with \fBgit remote add\fR prior to fetching\. New remotes are only added if they correspond to valid forks on GitHub\.
.
.TP
\fBgit checkout\fR \fIPULLREQ\-URL\fR [\fIBRANCH\fR]
Checks out the head of the pull request as a local branch, to allow for reviewing, rebasing and otherwise cleaning up the commits in the pull request before merging\. The name of the local branch can explicitly be set with \fIBRANCH\fR\.
.
.TP
\fBgit cherry\-pick\fR \fIGITHUB\-REF\fR
Cherry\-pick a commit from a fork using either full URL to the commit or GitHub\-flavored Markdown notation, which is \fBuser@sha\fR\. If the remote doesn\'t yet exist, it will be added\. A \fBgit fetch <user>\fR is issued prior to the cherry\-pick attempt\.
.
.TP
\fBgit [am|apply]\fR \fIGITHUB\-URL\fR
Downloads the patch file for the pull request or commit at the URL and applies that patch from disk with \fBgit am\fR or \fBgit apply\fR\. Similar to \fBcherry\-pick\fR, but doesn\'t add new remotes\. \fBgit am\fR creates commits while preserving authorship info while \fBapply\fR only applies the patch to the working copy\.
.
.TP
\fBgit push\fR \fIREMOTE\-1\fR,\fIREMOTE\-2\fR,\.\.\.,\fIREMOTE\-N\fR [\fIREF\fR]
Push \fIREF\fR to each of \fIREMOTE\-1\fR through \fIREMOTE\-N\fR by executing multiple \fBgit push\fR commands\.
.
.TP
\fBgit submodule add\fR [\fB\-p\fR] \fIOPTIONS\fR [\fIUSER\fR/]\fIREPOSITORY\fR \fIDIRECTORY\fR
Submodule repository "git://github\.com/\fIUSER\fR/\fIREPOSITORY\fR\.git" into \fIDIRECTORY\fR as with git\-submodule(1)\. When \fIUSER\fR/ is omitted, assumes your GitHub login\. With \fB\-p\fR, use private remote "git@github\.com:\fIUSER\fR/\fIREPOSITORY\fR\.git"\.
.
.TP
\fBgit help\fR
Display enhanced git\-help(1)\.
.
.P
hub also adds some custom commands that are otherwise not present in git:
.
.TP
\fBgit create\fR [\fINAME\fR] [\fB\-p\fR] [\fB\-d\fR \fIDESCRIPTION\fR] [\fB\-h\fR \fIHOMEPAGE\fR]
Create a new public GitHub repository from the current git repository and add remote \fBorigin\fR at "git@github\.com:\fIUSER\fR/\fIREPOSITORY\fR\.git"; \fIUSER\fR is your GitHub username and \fIREPOSITORY\fR is the current working directory name\. To explicitly name the new repository, pass in \fINAME\fR, optionally in \fIORGANIZATION\fR/\fINAME\fR form to create under an organization you\'re a member of\. With \fB\-p\fR, create a private repository, and with \fB\-d\fR and \fB\-h\fR set the repository\'s description and homepage URL, respectively\.
.
.TP
\fBgit browse\fR [\fB\-u\fR] [[\fIUSER\fR\fB/\fR]\fIREPOSITORY\fR] [SUBPAGE]
Open repository\'s GitHub page in the system\'s default web browser using \fBopen(1)\fR or the \fBBROWSER\fR env variable\. If the repository isn\'t specified, \fBbrowse\fR opens the page of the repository found in the current directory\. If SUBPAGE is specified, the browser will open on the specified subpage: one of "wiki", "commits", "issues" or other (the default is "tree")\.
.
.TP
\fBgit compare\fR [\fB\-u\fR] [\fIUSER\fR] [\fISTART\fR\.\.\.]\fIEND\fR
Open a GitHub compare view page in the system\'s default web browser\. \fISTART\fR to \fIEND\fR are branch names, tag names, or commit SHA1s specifying the range of history to compare\. If a range with two dots (\fBa\.\.b\fR) is given, it will be transformed into one with three dots\. If \fISTART\fR is omitted, GitHub will compare against the base branch (the default is "master")\.
.
.TP
\fBgit fork\fR [\fB\-\-no\-remote\fR]
Forks the original project (referenced by "origin" remote) on GitHub and adds a new remote for it under your username\. Requires \fBgithub\.token\fR to be set (see CONFIGURATION)\.
.
.TP
\fBgit pull\-request\fR [\fB\-f\fR] [\fITITLE\fR|\fB\-i\fR \fIISSUE\fR|\fIISSUE\-URL\fR] [\fB\-b\fR \fIBASE\fR] [\fB\-h\fR \fIHEAD\fR]
Opens a pull request on GitHub for the project that the "origin" remote points to\. The default head of the pull request is the current branch\. Both base and head of the pull request can be explicitly given in one of the following formats: "branch", "owner:branch", "owner/repo:branch"\. This command will abort operation if it detects that the current topic branch has local commits that are not yet pushed to its upstream branch on the remote\. To skip this check, use \fB\-f\fR\.
.
.IP
If \fITITLE\fR is omitted, a text editor will open in which title and body of the pull request can be entered in the same manner as git commit message\.
.
.IP
If instead of normal \fITITLE\fR an issue number is given with \fB\-i\fR, the pull request will be attached to an existing GitHub issue\. Alternatively, instead of title you can paste a full URL to an issue on GitHub\.
.
.SH "CONFIGURATION"
Use git\-config(1) to display the currently configured GitHub username:
.
.IP "" 4
.
.nf

$ git config \-\-global github\.user
.
.fi
.
.IP "" 0
.
.P
Or, set the GitHub username and token with:
.
.IP "" 4
.
.nf

$ git config \-\-global github\.user <username>
$ git config \-\-global github\.token <token>
.
.fi
.
.IP "" 0
.
.P
You can override these values with \fIGITHUB_USER\fR and \fIGITHUB_TOKEN\fR environment variables\.
.
.P
See \fIhttp://help\.github\.com/set\-your\-user\-name\-email\-and\-github\-token/\fR for more information\.
.
.P
If you prefer the HTTPS protocol for GitHub repositories, you can set "hub\.protocol" to "https"\. This will affect \fBclone\fR, \fBfork\fR, \fBremote add\fR and other operations that expand references to GitHub repositories as full URLs that otherwise use git and ssh protocols\.
.
.IP "" 4
.
.nf

$ git config \-\-global hub\.protocol https
.
.fi
.
.IP "" 0
.
.SS "GitHub Enterprise"
By default, hub will only work with repositories that have remotes which point to github\.com\. GitHub Enterprise hosts need to be whitelisted to configure hub to treat such remotes same as github\.com:
.
.IP "" 4
.
.nf

$ git config \-\-global \-\-add hub\.host my\.git\.org
.
.fi
.
.IP "" 0
.
.P
API username and token need also be configured for each Enterprise host:
.
.IP "" 4
.
.nf

$ git config \-\-global github\."my\.git\.org"\.user <username>
$ git config \-\-global github\."my\.git\.org"\.token <token>
.
.fi
.
.IP "" 0
.
.P
The default host for commands like \fBinit\fR and \fBclone\fR is still github\.com, but this can be affected with the \fIGITHUB_HOST\fR environment variable:
.
.IP "" 4
.
.nf

$ GITHUB_HOST=my\.git\.org git clone myproject
.
.fi
.
.IP "" 0
.
.SH "EXAMPLES"
.
.SS "git clone"
.
.nf

$ git clone schacon/ticgit
> git clone git://github\.com/schacon/ticgit\.git

$ git clone \-p schacon/ticgit
> git clone git@github\.com:schacon/ticgit\.git

$ git clone resque
> git clone git@github\.com/YOUR_USER/resque\.git
.
.fi
.
.SS "git remote add"
.
.nf

$ git remote add rtomayko
> git remote add rtomayko git://github\.com/rtomayko/CURRENT_REPO\.git

$ git remote add \-p rtomayko
> git remote add rtomayko git@github\.com:rtomayko/CURRENT_REPO\.git

$ git remote add origin
> git remote add origin git://github\.com/YOUR_USER/CURRENT_REPO\.git
.
.fi
.
.SS "git fetch"
.
.nf

$ git fetch mislav
> git remote add mislav git://github\.com/mislav/REPO\.git
> git fetch mislav

$ git fetch mislav,xoebus
> git remote add mislav \.\.\.
> git remote add xoebus \.\.\.
> git fetch \-\-multiple mislav xoebus
.
.fi
.
.SS "git cherry\-pick"
.
.nf

$ git cherry\-pick http://github\.com/mislav/REPO/commit/SHA
> git remote add \-f mislav git://github\.com/mislav/REPO\.git
> git cherry\-pick SHA

$ git cherry\-pick mislav@SHA
> git remote add \-f mislav git://github\.com/mislav/CURRENT_REPO\.git
> git cherry\-pick SHA

$ git cherry\-pick mislav@SHA
> git fetch mislav
> git cherry\-pick SHA
.
.fi
.
.SS "git am, git apply"
.
.nf

$ git am https://github\.com/defunkt/hub/pull/55
> curl https://github\.com/defunkt/hub/pull/55\.patch \-o /tmp/55\.patch
> git am /tmp/55\.patch

$ git am \-\-ignore\-whitespace https://github\.com/davidbalbert/hub/commit/fdb9921
> curl https://github\.com/davidbalbert/hub/commit/fdb9921\.patch \-o /tmp/fdb9921\.patch
> git am \-\-ignore\-whitespace /tmp/fdb9921\.patch

$ git apply https://gist\.github\.com/8da7fb575debd88c54cf
> curl https://gist\.github\.com/8da7fb575debd88c54cf\.txt \-o /tmp/gist\-8da7fb575debd88c54cf\.txt
> git apply /tmp/gist\-8da7fb575debd88c54cf\.txt
.
.fi
.
.SS "git fork"
.
.nf

$ git fork
[ repo forked on GitHub ]
> git remote add \-f YOUR_USER git@github\.com:YOUR_USER/CURRENT_REPO\.git
.
.fi
.
.SS "git pull\-request"
.
.nf

# while on a topic branch called "feature":
$ git pull\-request
[ opens text editor to edit title & body for the request ]
[ opened pull request on GitHub for "YOUR_USER:feature" ]

# explicit title, pull base & head:
$ git pull\-request "I\'ve implemented feature X" \-b defunkt:master \-h mislav:feature

$ git pull\-request \-i 123
[ attached pull request to issue #123 ]
.
.fi
.
.SS "git checkout"
.
.nf

# $ git checkout https://github\.com/defunkt/hub/pull/73
# > git remote add \-f \-t feature git://github:com/mislav/hub\.git
# > git checkout \-\-track \-B mislav\-feature mislav/feature

# $ git checkout https://github\.com/defunkt/hub/pull/73 custom\-branch\-name
.
.fi
.
.SS "git create"
.
.nf

$ git create
[ repo created on GitHub ]
> git remote add origin git@github\.com:YOUR_USER/CURRENT_REPO\.git

# with description:
$ git create \-d \'It shall be mine, all mine!\'

$ git create recipes
[ repo created on GitHub ]
> git remote add origin git@github\.com:YOUR_USER/recipes\.git

$ git create sinatra/recipes
[ repo created in GitHub organization ]
> git remote add origin git@github\.com:sinatra/recipes\.git
.
.fi
.
.SS "git init"
.
.nf

$ git init \-g
> git init
> git remote add origin git@github\.com:YOUR_USER/REPO\.git
.
.fi
.
.SS "git push"
.
.nf

$ git push origin,staging,qa bert_timeout
> git push origin bert_timeout
> git push staging bert_timeout
> git push qa bert_timeout
.
.fi
.
.SS "git browse"
.
.nf

$ git browse
> open https://github\.com/YOUR_USER/CURRENT_REPO

$ git browse \-\- commit/SHA
> open https://github\.com/YOUR_USER/CURRENT_REPO/commit/SHA

$ git browse \-\- issues
> open https://github\.com/YOUR_USER/CURRENT_REPO/issues

$ git browse schacon/ticgit
> open https://github\.com/schacon/ticgit

$ git browse schacon/ticgit commit/SHA
> open https://github\.com/schacon/ticgit/commit/SHA

$ git browse resque
> open https://github\.com/YOUR_USER/resque

$ git browse resque network
> open https://github\.com/YOUR_USER/resque/network
.
.fi
.
.SS "git compare"
.
.nf

$ git compare refactor
> open https://github\.com/CURRENT_REPO/compare/refactor

$ git compare 1\.0\.\.1\.1
> open https://github\.com/CURRENT_REPO/compare/1\.0\.\.\.1\.1

$ git compare \-u fix
> (https://github\.com/CURRENT_REPO/compare/fix)

$ git compare other\-user patch
> open https://github\.com/other\-user/REPO/compare/patch
.
.fi
.
.SS "git submodule"
.
.nf

$ hub submodule add wycats/bundler vendor/bundler
> git submodule add git://github\.com/wycats/bundler\.git vendor/bundler

$ hub submodule add \-p wycats/bundler vendor/bundler
> git submodule add git@github\.com:wycats/bundler\.git vendor/bundler

$ hub submodule add \-b ryppl ryppl/pip vendor/pip
> git submodule add \-b ryppl git://github\.com/ryppl/pip\.git vendor/pip
.
.fi
.
.SS "git help"
.
.nf

$ git help
> (improved git help)
$ git help hub
> (hub man page)
.
.fi
.
.SH "BUGS"
\fIhttps://github\.com/defunkt/hub/issues\fR
.
.SH "AUTHORS"
\fIhttps://github\.com/defunkt/hub/contributors\fR
.
.SH "SEE ALSO"
git(1), git\-clone(1), git\-remote(1), git\-init(1), \fIhttp://github\.com\fR, \fIhttps://github\.com/defunkt/hub\fR
