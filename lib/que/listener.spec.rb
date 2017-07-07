# frozen_string_literal: true

require 'spec_helper'

describe Que::Listener do
  attr_reader :connection

  let :listener do
    Que::Listener.new(pool: QUE_POOL)
  end

  around do |&block|
    QUE_POOL.checkout do |conn|
      begin
        listener.listen
        @connection = conn

        super(&block)
      ensure
        listener.unlisten
      end
    end
  end

  def notify(payload)
    payload = JSON.dump(payload) unless payload.is_a?(String)
    DB.notify("que_listener_#{connection.backend_pid}", payload: payload)
  end

  def notify_multiple(notifications)
    # Avoid race conditions by making sure that all notifications are visible at
    # the same time:
    DB.transaction { notifications.each { |n| notify(n) } }
  end

  describe "wait_for_messages" do
    it "should return empty if there were no messages before the timeout" do
      # Use a short timeout, since we'll always hit it in this spec.
      assert_equal({}, listener.wait_for_messages(0.001))
    end

    it "should return frozen messages" do
      notify(message_type: 'type_1', arg: 'blah')

      result = listener.wait_for_messages(10)[:type_1].first
      assert_equal({arg: 'blah'}, result)
      assert result.frozen?
    end

    it "should return messages to the locker in bulk by type" do
      notifications = []

      5.times do |i|
        notifications.push(message_type: 'type_1', value: i)
        notifications.push(message_type: 'type_2', value: i)
      end

      notify_multiple(notifications)

      assert_equal(
        {
          type_1: 5.times.map{|i| {value: i}},
          type_2: 5.times.map{|i| {value: i}},
        },
        listener.wait_for_messages(10),
      )
    end

    it "should accept arrays of messages" do
      notifications = []

      [0, 5].each do |i|
        notifications << (1..5).map{|j| {message_type: 'type_1', value: i + j}}
        notifications << (1..5).map{|j| {message_type: 'type_2', value: i + j}}
      end

      notify_multiple(notifications)

      assert_equal(
        {
          type_1: (1..10).map{|i| {value: i}},
          type_2: (1..10).map{|i| {value: i}},
        },
        listener.wait_for_messages(10),
      )
    end

    describe "when the messages aren't valid JSON of the format we expect" do
      def assert_ignored_notification(payload)
        notify payload
        assert_equal({}, listener.wait_for_messages(10))
      end

      it "should be resilient to messages that aren't valid JSON" do
        assert_ignored_notification "nil"
        assert_ignored_notification 'blah'
        assert_ignored_notification '{"blah:"}'
      end

      it "should be resilient to JSON messages with unexpected structures" do
        assert_ignored_notification message_type: 6
        assert_ignored_notification arg: 'blah'
        assert_ignored_notification [nil]
      end
    end
  end

  describe "unlisten" do
    it "should stop listening for new messages" do
      notify(message_type: 'blah')
      {} while connection.notifies

      listener.unlisten
      notify(message_type: 'blah')

      # Execute a new query to fetch any new notifications.
      connection.async_exec "SELECT 1"
      assert_nil connection.notifies
    end

    it "when unlistening should not leave any residual messages" do
      5.times { notify(message_type: 'blah') }

      listener.unlisten
      assert_nil connection.notifies

      # Execute a new query to fetch any remaining notifications.
      connection.async_exec "SELECT 1"
      assert_nil connection.notifies
    end
  end

  describe "message processing" do
    describe "for new_job messages" do
      it "should convert run_at values to Times" do
        timestamp = Time.now.iso8601(6)

        notify(
          message_type: 'new_job',
          priority: 90,
          run_at: timestamp,
          id: 45,
        )

        assert_equal(
          {new_job: [{priority: 90, run_at: Time.iso8601(timestamp), id: 45}]},
          listener.wait_for_messages(10),
        )
      end
    end

    describe "when the message is malformed" do
      let :message_to_malform do
        {
          priority: 90,
          run_at: Time.iso8601("2017-06-30T18:33:35.425307Z"),
          id: 45,
        }
      end

      let :all_messages do
        [
          {
            priority: 90,
            run_at: Time.iso8601("2017-06-30T18:33:33.402669Z"),
            id: 44,
          },
          message_to_malform,
          {
            priority: 90,
            run_at: Time.iso8601("2017-06-30T18:33:35.425307Z"),
            id: 46,
          },
        ]
      end

      def assert_message_ignored
        DB.transaction do
          all_messages.each { |m|
            run_at = m[:run_at]
            run_at = run_at.iso8601(6) if run_at.is_a?(Time)

            notify(
              m.merge(
                message_type: 'new_job',
                run_at: run_at,
              )
            )
          }
        end

        assert_equal(
          {
            new_job: [
              all_messages[0],
              all_messages[2],
            ]
          },
          listener.wait_for_messages(10),
        )
      end

      it "should ignore it if a field is the wrong type" do
        message_to_malform[:id] = message_to_malform[:id].to_s
        assert_message_ignored
      end

      it "should ignore it if a field is missing" do
        message_to_malform.delete(:id)
        assert_message_ignored
      end

      it "should ignore it if an extra field is present" do
        message_to_malform[:extra] = 'blah'
        assert_message_ignored
      end

      it "should asynchronously report messages that don't match the format" do
        message_to_malform.delete(:id)
        error = nil
        Que.error_notifier = proc { |e| error = e }
        assert_message_ignored
        sleep_until { !error.nil? }

        assert_instance_of Que::Error, error

        expected_message = [
          "Message of type 'new_job' doesn't match format!",
          "Message: {:priority=>90, :run_at=>2017-06-30 18:33:35 UTC}",
          "Format: {:id=>Integer, :run_at=>Time, :priority=>Integer}",
        ].join("\n")

        assert_equal expected_message, error.message
      end

      it "should report callback errors as necessary" do
        message_to_malform[:run_at] = 'blah'

        error = nil
        Que.error_notifier = proc { |e| error = e }

        assert_message_ignored
        sleep_until { !error.nil? }
        assert_instance_of ArgumentError, error
      end
    end
  end
end