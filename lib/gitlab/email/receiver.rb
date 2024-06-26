# frozen_string_literal: true

require_dependency 'gitlab/email/handler'

# Inspired in great part by Discourse's Email::Receiver
module Gitlab
  module Email
    class Receiver
      include Gitlab::Utils::StrongMemoize

      RECEIVED_HEADER_REGEX = /for\s+\<([^<]+)\>/

      # Errors that are purely from users and not anything we can control
      USER_ERRORS = [
        Gitlab::Email::AutoGeneratedEmailError, Gitlab::Email::ProjectNotFound, Gitlab::Email::EmptyEmailError,
        Gitlab::Email::UserNotFoundError, Gitlab::Email::UserBlockedError, Gitlab::Email::UserNotAuthorizedError,
        Gitlab::Email::NoteableNotFoundError, Gitlab::Email::InvalidAttachment, Gitlab::Email::InvalidRecordError,
        Gitlab::Email::EmailTooLarge
      ].freeze

      def initialize(raw)
        @raw = raw
      end

      def execute
        raise EmptyEmailError if @raw.blank?

        ignore_auto_reply!

        raise UnknownIncomingEmail unless handler

        handler.execute.tap do
          Gitlab::Metrics::BackgroundTransaction.current&.add_event(handler.metrics_event, handler.metrics_params)
        end
      rescue *USER_ERRORS => e
        # do not send a metric event since these are purely user errors that we can't control
        raise e
      rescue StandardError => e
        Gitlab::Metrics::BackgroundTransaction.current&.add_event('email_receiver_error', error: e.class.name)
        raise e
      end

      def mail_metadata
        {
          mail_uid: mail.message_id,
          from_address: from,
          to_address: to,
          mail_key: mail_key,
          references: Array(mail.references),
          delivered_to: delivered_to.map(&:value),
          envelope_to: envelope_to.map(&:value),
          x_envelope_to: x_envelope_to.map(&:value),
          x_original_to: x_original_to.map(&:value),
          cc_address: cc,
          # reduced down to what looks like an email in the received headers
          received_recipients: recipients_from_received_headers,
          meta: {
            client_id: "email/#{from.first}",
            project: handler&.project&.full_path
          }
        }
      end

      def mail
        strong_memoize(:mail) { build_mail }
      end

      private

      def handler
        strong_memoize(:handler) { find_handler }
      end

      def find_handler
        Handler.for(mail, mail_key)
      end

      def build_mail
        # See https://github.com/mikel/mail/blob/641060598f8f4be14d79bad8d703e9f2967e1cdb/spec/mail/message_spec.rb#L569
        # for mail structure
        Mail::Message.new(@raw)
      rescue Encoding::UndefinedConversionError,
             Encoding::InvalidByteSequenceError => e
        raise EmailUnparsableError, e
      end

      def mail_key
        strong_memoize(:mail_key) do
          find_most_concrete_key_from(to) || key_from_additional_headers
        end
      end

      def find_most_concrete_key_from(items)
        find_first_key_from(items) do |email|
          Gitlab::Email::ServiceDesk::CustomEmail.key_from_reply_address(email) || email_class.key_from_address(email)
        end
      end

      def find_first_key_from(items)
        items.each do |item|
          email = item.is_a?(Mail::Field) ? item.value : item

          key = block_given? ? yield(email) : email_class.key_from_address(email)

          return key if key
        end
        nil
      end

      def key_from_additional_headers
        find_key_from_references ||
          find_first_key_from(delivered_to) ||
          find_first_key_from(envelope_to) ||
          find_first_key_from(x_envelope_to) ||
          find_first_key_from(recipients_from_received_headers) ||
          find_first_key_from(x_original_to) ||
          find_first_key_from(cc)
      end

      def ensure_references_array(references)
        case references
        when Array
          references
        when String
          # Handle emails from clients which append with commas,
          # example clients are Microsoft exchange and iOS app
          email_class.scan_fallback_references(references)
        when nil
          []
        end
      end

      def find_key_from_references
        ensure_references_array(mail.references).find do |mail_id|
          key = email_class.key_from_fallback_message_id(mail_id)
          break key if key
        end
      end

      def from
        Array(mail.from)
      end

      def to
        Array(mail.to)
      end

      def cc
        Array(mail.cc)
      end

      def delivered_to
        Array(mail[:delivered_to])
      end

      def envelope_to
        Array(mail[:envelope_to])
      end

      def x_envelope_to
        Array(mail[:x_envelope_to])
      end

      def received
        Array(mail[:received])
      end

      def x_original_to
        Array(mail[:x_original_to])
      end

      def recipients_from_received_headers
        strong_memoize :emails_from_received_headers do
          received.filter_map { |header| header.value[RECEIVED_HEADER_REGEX, 1] }
        end
      end

      def ignore_auto_reply!
        if auto_submitted? || auto_replied?
          raise AutoGeneratedEmailError
        end
      end

      def auto_submitted?
        # Mail::Header#[] is case-insensitive
        auto_submitted = mail.header['Auto-Submitted']&.value

        # Mail::Field#value would strip leading and trailing whitespace
        # See also https://www.rfc-editor.org/rfc/rfc3834
        auto_submitted && auto_submitted != 'no'
      end

      def auto_replied?
        autoreply = mail.header['X-Autoreply']&.value

        autoreply && autoreply == 'yes'
      end

      def email_class
        Gitlab::Email::IncomingEmail
      end
    end
  end
end
