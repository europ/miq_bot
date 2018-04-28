require 'rugged'

class CodeAnalyzer
  include Sidekiq::Worker
  sidekiq_options :queue => :miq_bot_glacial

  include BranchWorkerMixin
  include ::CodeAnalysisMixin

  def perform(branch_id)
    return unless find_branch(branch_id, :regular)

    analyze
  end

  private

  def analyze
    branch.repo.git_fetch
    @results = formatted_comment(pronto_run)
    offense_count = @results.fetch_path("summary", "offense_count")
    branch.update_attributes(:linter_offense_count => offense_count)
  end
end
