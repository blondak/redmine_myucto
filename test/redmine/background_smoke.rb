# frozen_string_literal: true

raise 'Disposable test required' unless ENV['MYUCTO_DISPOSABLE_TEST'] == '1'
require 'net/http'
raise 'Runner started automatic synchronization' if Myucto::Background.instance_variable_get(:@instance)
puts 'PASS runner does not start background synchronization'

File.write(Rails.root.join('config/additional_environment.rb'), <<~RUBY)
  config.after_initialize do
    require #{File.join(__dir__, 'background_fixture.rb').inspect}
  end
RUBY
File.write('/tmp/myucto-background-executions', '')
File.write('/tmp/myucto-background-starts', '')

wait_for = ->(description, &condition) {
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
  until ActiveRecord::Base.uncached { condition.call }
    raise "Timed out: #{description}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.1
  end
  puts "PASS #{description}"
}

create_event = ->(id, **attrs) {
  MyuctoSyncEvent.create!({ time_entry_id: id, payload: '{}' }.merge(attrs))
}

child = nil
start_server = ->(workers: '0', enabled: '1') {
  File.write('/tmp/myucto-background-starts', '')
  log = File.open('/tmp/myucto-background-server.log', 'w')
  child = Process.spawn({ 'WEB_CONCURRENCY' => workers, 'MYUCTO_AUTO_SYNC' => enabled },
                        'bundle', 'exec', 'rails', 'server', '-b', '127.0.0.1', '-p', '3010',
                        chdir: Rails.root.to_s, out: log, err: log)
  log.close
}
stop_server = -> {
  if child
    Process.kill('TERM', child)
    Process.wait(child)
    child = nil
  end
}

begin
  first = create_event.call(900_001)
  future = create_event.call(900_002, available_at: Time.current + 10, attempts: 1)
  done = create_event.call(900_003, state: 'done')
  interrupted = create_event.call(900_004, state: 'processing')
  start_server.call
  wait_for.call('rails server refills existing pending events without an HTTP request') { first.reload.state == 'done' }
  wait_for.call('scheduled pending retry is processed without an HTTP request') { future.reload.state == 'done' }
  response = Net::HTTP.post(URI('http://127.0.0.1:3010/myucto-background-smoke'), '')
  raise "Synthetic request failed: #{response.code}" unless response.code == '202'
  web_event = MyuctoSyncEvent.find(response.body.to_i)
  wait_for.call('web transaction wakes real Async immediately after commit') { web_event.reload.state == 'done' }
  raise 'Interrupted event was automatically reset' unless interrupted.reload.state == 'processing'
  raise 'Completed event was processed again' if File.readlines('/tmp/myucto-background-executions').map(&:to_i).include?(done.id)
  puts 'PASS completed and interrupted events are preserved'
  stop_server.call

  restart_event = create_event.call(900_005)
  start_server.call
  wait_for.call('server restart refills pending events again') { restart_event.reload.state == 'done' }
  stop_server.call

  disabled = create_event.call(900_006)
  start_server.call(enabled: '0')
  wait_for.call('disabled server boots') { File.read('/tmp/myucto-background-server.log').include?('Listening on') }
  raise 'Disabled auto sync started' unless File.read('/tmp/myucto-background-starts').empty?
  raise 'Disabled auto sync processed event' unless disabled.reload.state == 'pending'
  puts 'PASS MYUCTO_AUTO_SYNC=0 keeps web running with no auto sync'
  stop_server.call

  start_server.call(workers: '2')
  wait_for.call('Puma cluster starts both child dispatchers without HTTP traffic') {
    File.readlines('/tmp/myucto-background-starts').map(&:to_i).uniq.size == 2
  }
  wait_for.call('Puma cluster refills the pending event') { disabled.reload.state == 'done' }
  executions = File.readlines('/tmp/myucto-background-executions').map(&:to_i)
  raise 'A duplicate job applied the same event twice' unless executions.uniq.size == executions.size
  puts "PASS real Async / Redmine #{Redmine::VERSION} / Ruby #{RUBY_VERSION}"
ensure
  stop_server.call
  puts File.read('/tmp/myucto-background-server.log') if $! && File.exist?('/tmp/myucto-background-server.log')
end
