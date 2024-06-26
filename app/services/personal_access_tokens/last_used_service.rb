# frozen_string_literal: true

module PersonalAccessTokens
  class LastUsedService
    def initialize(personal_access_token)
      @personal_access_token = personal_access_token
    end

    def execute
      # Needed to avoid calling service on Oauth tokens
      return unless @personal_access_token.has_attribute?(:last_used_at)

      # We _only_ want to update last_used_at and not also updated_at (which
      # would be updated when using #touch).
      return unless update?

      ::Gitlab::Database::LoadBalancing::Session.without_sticky_writes do
        @personal_access_token.update_column(:last_used_at, Time.zone.now)
      end
    end

    private

    def update?
      return false if ::Gitlab::Database.read_only?

      last_used = @personal_access_token.last_used_at

      return true if last_used.nil?

      last_used <= 10.minutes.ago
    end
  end
end
