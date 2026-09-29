# frozen_string_literal: true

# Attachment URL generation (EVO-1747 / EVO-2006).
#
# file_url/download_url/thumb_url route through ActiveStorage's
# resolve_model_to_route: proxy mode (default) serves the bytes through the
# app so the storage endpoint stays private; ATTACHMENT_DELIVERY=redirect
# restores storage redirects. These specs assert the URLs actually generated
# for a real blob — route helpers ignore ActiveStorage::Current.url_options,
# so ACTIVE_STORAGE_URL must have no effect here.

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Attachment URL options' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails) && defined?(ActiveStorage::Blob)

RSpec.describe Attachment, type: :model do
  let(:blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('attachment-bytes'),
      filename: 'picture.png',
      content_type: 'image/png'
    )
  end
  let(:attachment) do
    described_class.new(file_type: :image).tap { |record| record.file.attach(blob) }
  end

  def with_redirect_mode
    previous = ActiveStorage.resolve_model_to_route
    ActiveStorage.resolve_model_to_route = :rails_storage_redirect
    yield
  ensure
    ActiveStorage.resolve_model_to_route = previous
  end

  describe '#file_url' do
    it 'returns an empty string when no file is attached' do
      expect(described_class.new(file_type: :image).file_url).to eq('')
    end

    it 'returns an app-served proxy URL for the blob' do
      url = attachment.file_url
      expect(url).to include('/rails/active_storage/blobs/proxy/')
      expect(url).to end_with('/picture.png')
    end

    it 'uses the app host from routes.default_url_options' do
      expected = Rails.application.routes.url_helpers.rails_storage_proxy_url(
        blob, **Rails.application.routes.default_url_options
      )
      expect(attachment.file_url).to eq(expected)
    end

    it 'is not affected by ACTIVE_STORAGE_URL (route helpers ignore Current.url_options)' do
      base = attachment.file_url
      ENV['ACTIVE_STORAGE_URL'] = 'https://media.example.com:8443'
      expect(attachment.file_url).to eq(base)
    ensure
      ENV['ACTIVE_STORAGE_URL'] = nil
    end

    it 'falls back to a redirect URL when ATTACHMENT_DELIVERY=redirect' do
      with_redirect_mode do
        expect(attachment.file_url).to include('/rails/active_storage/blobs/redirect/')
      end
    end
  end

  describe '#download_url' do
    it 'returns an empty string when no file is attached' do
      expect(described_class.new(file_type: :image).download_url).to eq('')
    end

    it 'returns the same app-served proxy URL as file_url' do
      expect(attachment.download_url).to eq(attachment.file_url)
      expect(attachment.download_url).to include('/rails/active_storage/blobs/proxy/')
    end
  end

  describe '#thumb_url' do
    it 'returns an empty string when no file is attached' do
      expect(described_class.new(file_type: :image).thumb_url).to eq('')
    end

    it 'returns an app-served proxy URL for the representation' do
      url = attachment.thumb_url
      expect(url).to include('/rails/active_storage/representations/proxy/')
      expect(url).to end_with('/picture.png')
    end

    it 'falls back to a redirect URL when ATTACHMENT_DELIVERY=redirect' do
      with_redirect_mode do
        expect(attachment.thumb_url).to include('/rails/active_storage/representations/redirect/')
      end
    end
  end

  describe '#push_event_data (display title/extension)' do
    let(:doc_blob) do
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new('pdf-bytes'),
        filename: 'contrato.pdf',
        content_type: 'application/pdf'
      )
    end
    let(:doc_attachment) do
      described_class.new(file_type: :file).tap { |record| record.file.attach(doc_blob) }
    end

    it 'falls back to the stored file name when fallback_title is blank' do
      data = doc_attachment.push_event_data

      expect(data[:fallback_title]).to eq('contrato.pdf')
      expect(data[:extension]).to eq('pdf')
    end

    it 'prefers the explicit fallback_title and extension' do
      doc_attachment.fallback_title = 'Nome Bonito.pdf'
      doc_attachment.extension = 'pdf'

      data = doc_attachment.push_event_data

      expect(data[:fallback_title]).to eq('Nome Bonito.pdf')
    end
  end
end
