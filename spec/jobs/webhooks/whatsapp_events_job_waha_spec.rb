# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::WhatsappEventsJob, 'WAHA deduplication', type: :job do
  let(:job) { described_class.new }
  let(:store) { {} }

  before do
    allow(Redis::Alfred).to receive(:get) { |key| store[key] }
    allow(Redis::Alfred).to receive(:setex) { |key, value, _expiry = nil| store[key] = value }
  end

  it 'accepts the first occurrence of an event id and caches it' do
    expect(job.send(:duplicate_waha_event?, { id: 'evt-1' })).to be(false)
    expect(store).to include('waha:event:evt-1' => '1')
  end

  it 'rejects the same event id afterwards' do
    job.send(:duplicate_waha_event?, { id: 'evt-1' })

    expect(job.send(:duplicate_waha_event?, { id: 'evt-1' })).to be(true)
  end

  it 'does not deduplicate events without an id' do
    expect(job.send(:duplicate_waha_event?, { event: 'message.any' })).to be(false)
  end
end
