require 'minigit'

class CommitMonitorHandlers::BugzillaCommentor
  include Sidekiq::Worker

  def initialize(*args)
    MiniGit.debug = true
    super
  end

  def perform(repo, branch, commit)
    load_configuration
    process_commit(repo, branch, commit)
  end

  private

  BZ_CREDS_YAML             = Rails.root.join('config/bugzilla_credentials.yml')
  COMMIT_MONITOR_REPOS_YAML = Rails.root.join('config/commit_monitor_repos.yml')
  COMMIT_MONITOR_YAML       = Rails.root.join('config/commit_monitor.yml')

  def logger
    Rails.logger
  end

  def process_commit(repo, branch, commit)
    message_prefix = "New commit detected on #{repo}/#{branch}:"
    commit_uri = @repos.fetch_path(repo, branch, "commit_uri")
    message = commit_message(repo, commit)

    message.each_line do |line|
      match = %r{^\s*https://bugzilla\.redhat\.com/show_bug\.cgi\?id=(?<bug_id>\d+)$}.match(line)

      if match
        comment = "#{message_prefix}\n#{commit_uri}#{commit}\n\n#{message}"
        write_to_bugzilla(match[:bug_id], comment)
      end
    end
  end

  def commit_message(repo, commit)
    MiniGitMutex.synchronize do
      git = MiniGit::Capturing.new(File.join(@repo_base, repo))
      git.log({:pretty => "fuller"}, "--stat", "-1", commit)
    end
  end

  def write_to_bugzilla(bug_id, comment)
    log_prefix = "#{self.class.name}##{__method__}"
    logger.info("#{log_prefix} Updating bug id #{bug_id} in Bugzilla.")

    RubyBugzillaMutex.synchronize do
      bz = RubyBugzilla.new(*@bz_creds.values_at("bugzilla_uri", "username", "password"))
      bz.login
      output = bz.query(:product => @options["product"], :bug_id => bug_id).chomp
      if output.length == 0
        logger.error "#{log_prefix} Unable to write for bug id #{bug_id}: Not a '#{@options["product"]}' bug."
      else
        logger.info "#{log_prefix} Writing to bugzilla for bug id #{bug_id}"
        bz.modify(bug_id, :comment => comment)
      end
    end
  rescue => err
    logger.error "#{log_prefix} Unable to write for bug id #{bug_id}: #{err}"
  end

  def load_configuration
    @repos    = YAML.load_file(COMMIT_MONITOR_REPOS_YAML)
    @options  = YAML.load_file(COMMIT_MONITOR_YAML)
    @bz_creds = YAML.load_file(BZ_CREDS_YAML)

    @repo_base = File.expand_path(@options["repository_base"])
  end
end