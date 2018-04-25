require 'tmpdir'
require 'fileutils'

require 'pronto/runners'
require 'pronto/gem_names'
require 'pronto/git/repository'
require 'pronto/git/patches'
require 'pronto/git/patch'
require 'pronto/git/line'

require 'pronto/formatter/colorizable'
require 'pronto/formatter/base'
require 'pronto/formatter/text_formatter'
require 'pronto/formatter/json_formatter'
require 'pronto/formatter/git_formatter'
require 'pronto/formatter/commit_formatter'
require 'pronto/formatter/pull_request_formatter'
require 'pronto/formatter/github_formatter'
require 'pronto/formatter/github_status_formatter'
require 'pronto/formatter/github_pull_request_formatter'
require 'pronto/formatter/github_pull_request_review_formatter'
require 'pronto/formatter/gitlab_formatter'
require 'pronto/formatter/bitbucket_formatter'
require 'pronto/formatter/bitbucket_pull_request_formatter'
require 'pronto/formatter/bitbucket_server_pull_request_formatter'
require 'pronto/formatter/checkstyle_formatter'
require 'pronto/formatter/null_formatter'
require 'pronto/formatter/formatter'

module CodeAnalysisMixin
  def pronto_run
    pronto_result # array of Pronto::Message objects
  end

  private

  # run linters via pronto and return the pronto result
  def pronto_result
    Pronto::GemNames.new.to_a.each { |gem_name| require "pronto/#{gem_name}" }

    p_result = nil

    # temporary solution for: download repo, obtain changes, get pronto result about changes
    Dir.mktmpdir do |dir|
      FileUtils.copy_entry(@branch.repo.path.to_s, dir)
      repo = Pronto::Git::Repository.new(dir)
      rg = repo.instance_variable_get(:@repo)
      rg.fetch('origin', @branch.name.sub(/^prs/, 'pull'))
      rg.checkout('FETCH_HEAD')
      rg.reset('HEAD', :hard)
      patches = repo.diff(@branch.merge_target)
      p_result = Pronto::Runners.new.run(patches)
      asdf(p_result, commits.last) # make this as an ending point of this process of code checking (post comment and die)
    end

    p_result # TODO: remove
  end

  def asdf(result, urlcommit)
    res = pronto_format(result, urlcommit)
    comments = create_comment(res)
    replace_pronto_comments(comments)
  end

  def pronto_format(pronto_messages, urlcommit)
    owner = branch.commit_uri.scan(/https:\/\/github.com\/([^\/]+)/).flatten.first # IMPROVE ME
    repo = fq_repo_name.split("/").last # IMPROVE ME
    MiqBotFormatter.new(owner, repo, urlcommit).format(pronto_messages)
  end

  def create_comment(formatter_result)
    header, body = "", ""

    header << pronto_tag
    header << "#{"Commit".pluralize(commits.length)} #{commit_range_text} checked with ruby #{RUBY_VERSION} and:\n\n"
    header << versions_table
    header << "\n\n"

    body << formatter_result

    comment_divider(header, body)
  end

  def comment_divider(header, body)
    # TODO: Implement comment content divider - divide comment into smaller comments if necessary (GitHub has a limit for comment size).
    # COMMENT_BODY_MAX_SIZE = 65_535
    # https://github.com/ManageIQ/miq_bot/blob/master/lib/github_service/message_builder.rb
    [header + body]
  end

  def replace_pronto_comments(pronto_comments)
    logger.info("Updating #{pr_url(fq_repo_name, pr_number)} with Pronto comment.")
    GithubService.replace_comments(fq_repo_name, pr_number, pronto_comments) do |old_comment|
      pronto_comment?(old_comment)
    end
  end

  def pr_url(repo, num)
    "https://github.com/#{repo}/pull/#{num}"
  end

  def pronto_tag
    "<pronto />"
  end

  def pronto_comment?(comment)
    comment.body.start_with?(pronto_tag)
  end

  def versions_table
    str = "Pronto Runners | Version | Linters | Version\n--- | --- | --- | ---\n"

    versions.each do |ver|
      v = ver.to_a
      str << v[0].first + " | " + v[0].last + " | " + v[1].first + " | " + v[1].last + "\n"
    end

    str.strip
  end

  def gem_version(gem_name)
    Gem.loaded_specs[gem_name].version.to_s
  end

  def versions
    [pronto_rubocop_version, pronto_haml_version, pronto_yaml_version]
  end

  def pronto_rubocop_version
    # unreliable method
    # require 'pronto/rubocop/version'
    # { "pronto-rubocop" => Pronto::RubocopVersion::VERSION, "RuboCop" => RuboCop::Version.version }

    { "pronto-rubocop" => gem_version("pronto-rubocop"), "rubocop" => gem_version("rubocop") }
  end

  def pronto_haml_version
    # unreliable method
    # require 'pronto/haml/version'
    # { "pronto-haml" => Pronto::HamlLintVersion::VERSION, "Haml" => Haml::VERSION }

    { "pronto-haml" => gem_version("pronto-haml"), "haml_lint" => gem_version("haml_lint") }
  end

  def pronto_yaml_version
    # unreliable method
    # NOTE: Missing VERSION constant in pronto-yamllint.
    # { "pronto-yamllint" => "0.1.0", "yamllint" => Open3.capture3("yamllint -v")[1].strip.split(' ').last}

    { "pronto-yamllint" => gem_version("pronto-yamllint"), "yamllint" => Open3.capture3("yamllint -v")[1].strip.split(' ').last }
  end

  class MiqBotFormatter < ::Pronto::Formatter::Base
    def initialize(owner, repo, urlcommit)
      @url = "https://github.com/#{owner}/#{repo}/blob/#{urlcommit}/"
    end

    def format(messages)
      if messages.empty?
        looks_good
      else
        process(messages)
      end
    end

    def looks_good
      emoji = %w(:+1: :cookie: :star: :cake: :trophy: :ok_hand: :v: :tada:)
      "0 offenses detected :shipit:\nEverything looks fine. #{emoji.sample}"
    end

    def process(messages)
      offenses_count = messages.count
      files_count = messages.group_by(&:path).count

      string = "#{offenses_count} #{"offense".pluralize(offenses_count)} detected in #{files_count} #{"file".pluralize(files_count)}.\n\n---\n\n"

      messages.group_by(&:path).each do |file, msgs|
        string << "**[#{file}](#{url_file(msgs.first)})**\n"
        msgs.each do |msg|
          string << "- [ ] #{severity_to_emoji(msg.level)} - [Line #{msg.line.position}](#{url_file_line(msg)}) - #{msg.runner.to_s.sub!("Pronto::", '')} - #{msg.msg}\n"
        end
        string << "\n"
      end

      string.strip
    end

    def url_file(msg)
      @url + msg.path
    end

    def url_file_line(msg)
      "#{url_file(msg)}#L#{msg.line.position}"
    end

    def severity_to_emoji(level)
      case level
      when :info
        ":information_source:"
      when :warning
        ":warning:"
      when :fatal, :error
        ":bomb: :boom: :fire: :fire_engine:"
      else
        ":sos: :no_entry:"
      end
    end
  end
end
