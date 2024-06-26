# frozen_string_literal: true

class ProjectDestroyWorker
  include ApplicationWorker

  data_consistency :always

  sidekiq_options retry: 3
  include ExceptionBacktrace

  feature_category :source_code_management

  idempotent!
  deduplicate :until_executed, ttl: 2.hours

  def perform(project_id, user_id, params)
    Gitlab::QueryLimiting.disable!('https://gitlab.com/gitlab-org/gitlab/-/issues/333366')

    project = Project.find(project_id)
    user = User.find(user_id)

    ::Projects::DestroyService.new(project, user, params.symbolize_keys).execute
  rescue ActiveRecord::RecordNotFound => error
    logger.error("Failed to delete project (#{project_id}): #{error.message}")
  end
end
