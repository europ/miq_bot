require 'rubocop'
require 'haml_lint'

module FormatterMixin
  def formatted_comment(pronto_messages)
    merge_results(parse_pronto_messages(pronto_messages))
  end

  private

  def merge_results(pronto_result)
    results = {
      "files"   => [],
      "summary" => {
        "offense_count"     => 0,
        "target_file_count" => 0,
      },
    }

    pronto_result.each do |result|
      %w(offense_count target_file_count).each do |m|
        results['summary'][m] += result['summary'][m]
      end
      results['files'] += result['files']
    end

    results
  end

  def parse_pronto_messages(pronto_messages)
    pronto_messages.group_by(&:runner).values.map do |linted| # group by linter
      output = {}

      output["files"] = linted.group_by(&:path).map do |path, value| # group by file in linter
        {
          "path"     => path,
          "offenses" => value.map do |msg| # put offenses of file in linter into an array
            {
              "severity"  => msg.level.to_s,
              "message"   => msg.msg,
              "cop_name"  => msg.runner,
              "corrected" => false,
              "line"      => msg.line.position
            }
          end
        }
      end

      output["summary"] = {
        "offense_count"     => output["files"].sum { |item| item['offenses'].length },
        "target_file_count" => output["files"].length,
      }

      output
    end
  end
end
