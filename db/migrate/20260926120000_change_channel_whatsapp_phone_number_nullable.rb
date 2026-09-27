# frozen_string_literal: true

# WAHA sessions are created before the WhatsApp account is paired, so at channel
# creation time there is no phone number to store (WAHA discovers it from
# `GET /api/sessions/{session}/me` once the session is WORKING). Relax the NOT
# NULL constraint so WAHA channels can be created without one; the unique index
# stays and Postgres allows multiple NULLs. Every other WhatsApp provider keeps
# requiring a phone number through the model validation.
class ChangeChannelWhatsappPhoneNumberNullable < ActiveRecord::Migration[7.1]
  def change
    change_column_null :channel_whatsapp, :phone_number, true
  end
end
