# frozen_string_literal: true

# Loaded only by background_smoke.rb in a disposable container. Network calls
# are replaced, while the real worker claims/events and real Async jobs run.
raise 'Disposable test required' unless ENV['MYUCTO_DISPOSABLE_TEST'] == '1'

module MyuctoBackgroundFixture
  def initialize(**_args); end

  private

  def process(event)
    File.open('/tmp/myucto-background-executions', 'a') { |file| file.puts(event.id) }
  end
end
Myucto::Worker.prepend(MyuctoBackgroundFixture)

module MyuctoBackgroundStarts
  def start!
    previous = instance_variable_get(:@instance)
    previous_pid = instance_variable_get(:@pid)
    super
    if instance_variable_get(:@instance) && (!previous || previous_pid != Process.pid)
      File.open('/tmp/myucto-background-starts', 'a') { |file| file.puts(Process.pid) }
    end
  end
end
Myucto::Background.singleton_class.prepend(MyuctoBackgroundStarts)

Rails.application.routes.append do
  post '/myucto-background-smoke', to: ->(_env) {
    event = MyuctoSyncEvent.create!(time_entry_id: 900_010, payload: '{}')
    [202, { 'content-type' => 'text/plain' }, [event.id.to_s]]
  }
end
