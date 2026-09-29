# frozen_string_literal: true

require 'rails_helper'

# `send_attachment` action_params arrive in three shapes by the time they reach
# the handler; normalize_attachment_params must map each to (blob_ids, inbox_id).
RSpec.describe AutomationRules::ConversationActionHandlers do
  subject(:handler) { Class.new { include AutomationRules::ConversationActionHandlers }.new }

  describe '#normalize_attachment_params' do
    it 'reads ids and inbox from a hash' do
      expect(handler.send(:normalize_attachment_params, { attachment_ids: %w[a b], inbox_id: 'i' }))
        .to eq([%w[a b], 'i'])
    end

    it 'reads ids and inbox from an array wrapping a hash (current UI shape)' do
      expect(handler.send(:normalize_attachment_params, [{ 'attachment_ids' => %w[a], 'inbox_id' => 'i' }]))
        .to eq([%w[a], 'i'])
    end

    it 'keeps a legacy bare array of ids' do
      expect(handler.send(:normalize_attachment_params, %w[a b])).to eq([%w[a b], nil])
    end

    it 'wraps a legacy single id' do
      expect(handler.send(:normalize_attachment_params, 'a')).to eq([%w[a], nil])
    end
  end
end
