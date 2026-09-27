# frozen_string_literal: true

module ScheduledActions
  class ExecutorService
    attr_reader :scheduled_action

    def initialize(scheduled_action)
      @scheduled_action = scheduled_action
    end

    def execute
      Rails.logger.info "ExecutorService.execute: Checking scheduled_action #{scheduled_action.id}"
      Rails.logger.info "  - scheduled? #{scheduled_action.scheduled?}"
      Rails.logger.info "  - scheduled_for: #{scheduled_action.scheduled_for}, Time.current: #{Time.current}"

      return false unless scheduled_action.scheduled?
      return false if scheduled_action.scheduled_for > Time.current

      Rails.logger.info "ExecutorService.execute: Starting execution for action #{scheduled_action.id}"
      scheduled_action.mark_as_executing!

      begin
        start_time = Time.current
        result = execute_action
        execution_time_ms = ((Time.current - start_time) * 1000).to_i

        if result[:success]
          log_execution(result, execution_time_ms, 'completed')
          scheduled_action.mark_as_completed!
          create_next_occurrence_if_recurring
          notify_success
          true
        else
          log_execution(result, execution_time_ms, 'failed')
          handle_failure(result[:error])
          false
        end
      rescue StandardError => e
        execution_time_ms = ((Time.current - start_time) * 1000).to_i
        log_execution({ success: false, error: e.message }, execution_time_ms, 'error')
        handle_failure(e)
        false
      end
    end

    private

    def execute_action
      case scheduled_action.action_type
      when 'send_message'
        execute_send_message
      when 'execute_webhook'
        execute_webhook
      when 'create_task'
        execute_create_task
      else
        { success: false, error: "Unknown action type: #{scheduled_action.action_type}. Supported types: send_message, execute_webhook, create_task" }
      end
    end

    # Unified send_message handler that supports: whatsapp, sms, email, telegram
    def execute_send_message
      return { success: false, error: 'Contact not found' } unless contact

      # The composer schedules into an existing conversation: use it so the
      # message goes out through the same inbox/provider and the correct
      # contact_inbox source_id (essential for WAHA/Evolution JIDs).
      return execute_send_message_to_conversation if scheduled_action.conversation

      channel = scheduled_action.payload['channel']

      # If no channel specified, try to use existing conversation (legacy behavior)
      unless channel
        return execute_send_message_to_conversation
      end

      case channel.downcase
      when 'email'
        execute_send_message_email
      when 'whatsapp', 'sms', 'telegram'
        execute_send_message_channel(channel.downcase)
      else
        { success: false, error: "Unknown channel: #{channel}" }
      end
    rescue StandardError => e
      { success: false, error: e.message }
    end

    # The action may target only a conversation (created from the chat composer)
    # with no contact_id stored; resolve it from the conversation.
    def contact
      @contact ||= scheduled_action.contact || scheduled_action.conversation&.contact
    end

    # Legacy behavior: send to existing conversation
    def execute_send_message_to_conversation
      conversation = scheduled_action.conversation

      unless conversation
        if contact
          conversation = contact.conversations.where(status: :open).order(created_at: :desc).first
        end
      end

      return { success: false, error: 'No conversation found for contact' } unless conversation

      message_params = {
        inbox_id: conversation.inbox_id,
        conversation_id: conversation.id,
        content: scheduled_action.payload['message'] || scheduled_action.payload['content'],
        message_type: :outgoing,
        private: scheduled_action.payload['private'] || false,
        sender: scheduled_action.creator
      }

      message = conversation.messages.build(message_params)
      attach_scheduled_files(message)
      message.save!
      { success: true, data: { message_id: message.id } }
    end

    # Unified channel message handler for WhatsApp, SMS, and Telegram
    def execute_send_message_channel(channel)
      message = scheduled_action.payload['message']
      return { success: false, error: 'Message not provided' } if message.blank?

      # Get channel configuration
      config = channel_config(channel)
      return config if config.is_a?(Hash) && config[:success] == false

      inbox = config[:inbox]
      source_id = config[:source_id]

      # Validate source_id was generated/found
      return { success: false, error: "Could not determine contact identifier for #{channel}" } if source_id.blank?

      # Get or create contact_inbox
      contact_inbox = find_or_create_contact_inbox(inbox, source_id)
      return contact_inbox if contact_inbox.is_a?(Hash) && contact_inbox[:success] == false

      # Get or create conversation
      conversation = find_or_create_conversation(inbox, contact_inbox)
      return conversation if conversation.is_a?(Hash) && conversation[:success] == false

      # Create message
      message = conversation.messages.build(
        content: message,
        message_type: :outgoing,
        sender_id: scheduled_action.created_by,
        inbox_id: inbox.id,
        conversation_id: conversation.id
      )
      attach_scheduled_files(message)
      message.save!

      { success: true, data: { message: message, conversation_id: conversation.id } }
    end

    # Copy the files stored on the scheduled action onto the outgoing message so
    # the provider (WAHA/Evolution/etc.) sends them with the text/caption. Files
    # are stored as signed_ids on the payload (see the controller).
    def attach_scheduled_files(message)
      Array(scheduled_action.payload['attachments']).each do |entry|
        signed_id = entry.is_a?(Hash) ? entry['signed_id'] : entry
        next if signed_id.blank?

        blob = ActiveStorage::Blob.find_signed(signed_id)
        next unless blob

        file_type = entry.is_a?(Hash) ? entry['file_type'] : nil
        name = entry.is_a?(Hash) ? entry['name'] : nil
        message.attachments.build(
          file: blob,
          file_type: file_type.presence || 'file',
          fallback_title: name.presence,
          extension: name.present? ? File.extname(name).delete_prefix('.').presence : nil,
          meta: nil
        )
      end
    end

    # Get channel-specific configuration
    def channel_config(channel)
      case channel
      when 'whatsapp'
        {
          inbox: whatsapp_inbox,
          error_msg: 'WhatsApp not configured for this account',
          source_id: whatsapp_source_id
        }
      when 'sms'
        {
          inbox: Inbox.where(channel_type: 'Channel::Sms').first,
          error_msg: 'SMS not configured',
          source_id: sms_source_id
        }
      when 'telegram'
        {
          inbox: Inbox.where(channel_type: 'Channel::Telegram').first,
          error_msg: 'Telegram not configured',
          source_id: telegram_source_id
        }
      else
        { success: false, error: "Unknown channel: #{channel}" }
      end.tap do |config|
        next if config[:success] == false

        if config[:inbox].blank?
          return { success: false, error: config[:error_msg] }
        end
      end
    end

    # Generate WhatsApp source_id from the existing contact_inbox when present
    # (WAHA/Evolution use chat JIDs), falling back to the phone number.
    def whatsapp_source_id
      inbox = whatsapp_inbox
      if inbox && contact
        existing = contact.contact_inboxes.find_by(inbox_id: inbox.id)
        return existing.source_id if existing&.source_id.present?
      end

      phone = contact&.phone_number
      return nil if phone.blank?

      phone.delete('+').to_s
    end

    def whatsapp_inbox
      conversation_inbox = scheduled_action.conversation&.inbox
      return conversation_inbox if conversation_inbox&.channel_type.in?(%w[Channel::Whatsapp Channel::WhatsappCloud])

      Inbox.find_by(channel_type: 'Channel::Whatsapp') ||
        Inbox.find_by(channel_type: 'Channel::WhatsappCloud')
    end

    # Generate SMS source_id from phone number
    def sms_source_id
      phone = contact&.phone_number
      return nil if phone.blank?

      phone
    end

    # Generate Telegram source_id
    # For Telegram, we reuse existing contact_inbox or generate a new UUID
    def telegram_source_id
      # Check if contact already has a Telegram contact_inbox
      telegram_inbox = Inbox.where(channel_type: 'Channel::Telegram').first
      return nil if telegram_inbox.blank?

      existing = contact&.contact_inboxes&.find_by(inbox_id: telegram_inbox.id)
      return existing.source_id if existing.present?

      # Generate new UUID for new contact-inbox pair
      SecureRandom.uuid
    end

    # Find or create contact_inbox for a channel
    def find_or_create_contact_inbox(inbox, source_id)
      contact_inbox = ContactInbox.find_by(
        inbox_id: inbox.id,
        source_id: source_id
      )

      unless contact_inbox
        contact_inbox = ContactInbox.create!(
          inbox_id: inbox.id,
          contact_id: contact.id,
          source_id: source_id
        )
      end

      contact_inbox
    rescue ActiveRecord::RecordInvalid => e
      { success: false, error: "Failed to create contact inbox: #{e.message}" }
    end

    # Find or create conversation for a contact in an inbox
    def find_or_create_conversation(inbox, contact_inbox)
      conversation = inbox.conversations.find_by(contact_id: contact.id)

      unless conversation
        conversation = inbox.conversations.create!(
          contact_id: contact.id,
          contact_inbox_id: contact_inbox.id
        )
      end

      conversation
    rescue ActiveRecord::RecordInvalid => e
      { success: false, error: "Failed to create conversation: #{e.message}" }
    end

    # Send Email via send_message with email channel
    def execute_send_message_email
      return { success: false, error: 'Email address not found' } unless contact&.email

      subject = scheduled_action.payload['subject']
      message = scheduled_action.payload['message']
      from = scheduled_action.payload['from'] || ENV.fetch('MAILER_SENDER_EMAIL', 'noreply@example.com')

      return { success: false, error: 'Subject not provided' } if subject.blank?
      return { success: false, error: 'Message not provided' } if message.blank?

      # Send email using ActionMailer
      ScheduledActionMailer.send_email(
        to: contact.email,
        subject: subject,
        body: message,
        from: from,
        contact_id: contact.id
      ).deliver_later

      { success: true, data: { email: contact.email, subject: subject } }
    end

    def execute_webhook
      webhook_url = scheduled_action.payload['webhook_url']
      return { success: false, error: 'Webhook URL not provided' } if webhook_url.blank?

      payload = scheduled_action.payload['data'] || {}
      headers = scheduled_action.payload['headers'] || { 'Content-Type' => 'application/json' }
      method = scheduled_action.payload['method'] || 'POST'

      response = HTTParty.send(
        method.downcase.to_sym,
        webhook_url,
        body: payload.to_json,
        headers: headers,
        timeout: 30
      )

      if response.success?
        { success: true, data: { status: response.code, body: response.body } }
      else
        { success: false, error: "Webhook failed with status #{response.code}" }
      end
    rescue StandardError => e
      { success: false, error: e.message }
    end

    def execute_create_task
      return { success: false, error: 'Contact not found' } unless contact

      title = scheduled_action.payload['title']
      return { success: false, error: 'Task title not provided' } if title.blank?

      description = scheduled_action.payload['description']
      due_date = scheduled_action.payload['due_date']
      assigned_to = scheduled_action.payload['assigned_to'] || scheduled_action.created_by_id

      # Create task
      task_data = {
        contact_id: contact.id,
        title: title,
        description: description,
        due_date: due_date,
        assigned_to: assigned_to,
        created_by: scheduled_action.created_by_id,
        source: 'scheduled_action',
        scheduled_action_id: scheduled_action.id
      }

      Rails.logger.info "Task scheduled for creation: #{task_data.inspect}"

      # TODO: When task system is implemented, uncomment below:
      # task = Task.create!(task_data)
      # return { success: true, data: { task_id: task.id, title: task.title } }

      # For now, return success with task parameters that will be processed later
      { success: true, data: task_data }
    rescue StandardError => e
      { success: false, error: e.message }
    end

    def handle_failure(error)
      scheduled_action.mark_as_failed!(error)
      
      if scheduled_action.can_retry?
        # Schedule retry
        ScheduledActionsProcessorJob.set(wait: calculate_retry_delay).perform_later(scheduled_action.id)
      else
        notify_failure
      end
    end

    def calculate_retry_delay
      # Exponential backoff: 5min, 15min, 30min
      case scheduled_action.retry_count
      when 1
        5.minutes
      when 2
        15.minutes
      else
        30.minutes
      end
    end

    def create_next_occurrence_if_recurring
      scheduled_action.create_next_occurrence if scheduled_action.recurring?
    end

    def notify_success
      return unless scheduled_action.notify_user_id

      ScheduledActions::NotificationService.notify_on_success(
        scheduled_action,
        scheduled_action.notify_user_id
      )
    end

    def notify_failure
      return unless scheduled_action.notify_user_id

      retry_attempt = scheduled_action.retry_count > 0
      notification_type = retry_attempt ? :retry : :failure

      if retry_attempt
        ScheduledActions::NotificationService.notify_on_retry(
          scheduled_action,
          scheduled_action.notify_user_id
        )
      else
        ScheduledActions::NotificationService.notify_on_failure(
          scheduled_action,
          scheduled_action.notify_user_id
        )
      end
    end

    def log_execution(result, execution_time_ms, status)
      message = if result.is_a?(Hash)
                  result[:error] || result[:data]&.to_s
                else
                  result.to_s
                end

      ScheduledActionExecutionLog.create!(
        scheduled_action: scheduled_action,
        status: status,
        result_message: message,
        error_details: result.is_a?(Hash) && result[:error] ? { error: result[:error] } : {},
        retry_count: scheduled_action.retry_count,
        execution_time_ms: execution_time_ms,
        execution_log: "Execution status: #{status}"
      )
    rescue StandardError => e
      Rails.logger.error "Failed to log execution for action #{scheduled_action.id}: #{e.message}"
    end
  end
end
