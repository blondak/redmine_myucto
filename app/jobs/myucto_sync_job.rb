# frozen_string_literal: true

# The adapter is assigned only to this class when the web process starts the
# dispatcher. Redmine's mail jobs and global queue adapter are left alone.
class MyuctoSyncJob < ActiveJob::Base
  queue_as :myucto

  def perform(kind, generation, ticket)
    Myucto::Background.perform(kind, generation, ticket)
  end
end
