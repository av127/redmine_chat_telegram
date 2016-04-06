def chat_user_full_name(telegram_user)
  [telegram_user.first_name, telegram_user.last_name].compact.join
end

def chat_telegram_bot_init
  Process.daemon(true, true) if Rails.env.production?

  if ENV['PID_DIR']
    pid_dir = ENV['PID_DIR']
    PidFile.new(piddir: pid_dir, pidfile: 'telegram-chat-bot.pid')
  else
    PidFile.new(pidfile: 'telegram-chat-bot.pid')
  end

  at_exit { LOG.error 'aborted by some reasons' }

  Signal.trap('TERM') do
    at_exit { LOG.error 'Aborted with TERM signal' }
    abort 'Aborted with TERM signal'
  end
  Signal.trap('QUIT') do
    at_exit { LOG.error 'Aborted with QUIT signal' }
    abort 'Aborted with QUIT signal'
  end
  Signal.trap('HUP') do
    at_exit { LOG.error 'Aborted with HUP signal' }
    abort 'Aborted with HUP signal'
  end

  LOG.info 'Start daemon...'

  token = Setting.plugin_redmine_chat_telegram['bot_token']

  unless token.present?
    LOG.error 'Telegram Bot Token not found. Please set it in the plugin config web-interface.'
    exit
  end

  LOG.info 'Telegram Bot: Connecting to telegram...'
  bot      = Telegrammer::Bot.new(token)
  bot_name = bot.me.username

  Setting.plugin_redmine_chat_telegram['bot_name'] = "user##{bot.me.id}"

  until bot_name.present?

    LOG.error 'Telegram Bot Token is invalid or Telegram API is in downtime. I will try again after minute'
    sleep 60

    LOG.info 'Telegram Bot: Connecting to telegram...'
    bot      = Telegrammer::Bot.new(token)
    bot_name = bot.me.username

  end

  LOG.info "#{bot_name}: connected"
  LOG.info "#{bot_name}: waiting for new messages in group chats..."
  bot
end

namespace :chat_telegram do
  # bundle exec rake chat_telegram:bot PID_DIR='/tmp'
  desc "Runs telegram bot process (options: PID_DIR='/pid/dir')"
  task :bot => :environment do
    LOG = Rails.env.production? ? Logger.new(Rails.root.join('log/chat_telegram', 'bot.log')) : Logger.new(STDOUT)
    I18n.locale = Setting['default_language']

    bot = chat_telegram_bot_init

    bot.get_updates(fail_silently: false) do |message|
      begin
        telegram_chat_id = message.chat.id
        telegram_id      = message.message_id
        sent_at          = message.date

        from_id         = message.from.id
        from_first_name = message.from.first_name
        from_last_name  = message.from.last_name
        from_username   = message.from.username

        begin
          issue = Issue.joins(:telegram_group).find_by!(redmine_chat_telegram_telegram_groups: {telegram_id: telegram_chat_id})
        rescue Exception => e
          LOG.error "#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}"
          next
        end

        if message.group_chat_created

          issue_url = RedmineChatTelegram.issue_url(issue.id)
          bot.send_message(chat_id:                  telegram_chat_id,
                           text:                     I18n.t('redmine_chat_telegram.messages.hello', issue_url: issue_url),
                           disable_web_page_preview: true)

          # Localized in archive
          message_text     = 'chat_was_created'
          telegram_message = TelegramMessage.create issue_id:       issue.id,
                                                    telegram_id:    telegram_id,
                                                    sent_at:        sent_at, message: message_text,
                                                    from_id:        from_id, from_first_name: from_first_name,
                                                    from_last_name: from_last_name, from_username: from_username,
                                                    is_system: true, bot_message: true
        else

          if message.new_chat_participant.present?
            new_chat_participant = message.new_chat_participant

            # TODO: Localize it
            message_text         = if message.from.id == new_chat_participant.id
                                     'joined to the group'
                                   else
                                     "invited #{chat_user_full_name(new_chat_participant)}"
                                   end
            telegram_message     = TelegramMessage.create issue_id:       issue.id,
                                                          telegram_id:    telegram_id,
                                                          sent_at:        sent_at, message: message_text,
                                                          from_id:        from_id, from_first_name: from_first_name,
                                                          from_last_name: from_last_name, from_username: from_username,
                                                          is_system: true, bot_message: true
          elsif message.left_chat_participant.present?
            left_chat_participant = message.left_chat_participant
            # TODO: Localize it
            message_text          = if message.from.id == left_chat_participant.id
                                      'left the group'
                                    else
                                      "kicked #{chat_user_full_name(left_chat_participant)}"
                                    end
            telegram_message      = TelegramMessage.create issue_id:       issue.id,
                                                           telegram_id:    telegram_id,
                                                           sent_at:        sent_at, message: message_text,
                                                           from_id:        from_id, from_first_name: from_first_name,
                                                           from_last_name: from_last_name, from_username: from_username,
                                                           is_system: true, bot_message: true

          elsif message.text.present? and message.chat.type == 'group'
            issue_url = RedmineChatTelegram.issue_url(issue.id)

            message_text = message.text
            issue_url_text = "#{issue.subject}\n#{issue_url}"

            if message_text.include?('/task') or message_text.include?('/link') or message_text.include?('/url')
              bot.send_message(chat_id:                  telegram_chat_id,
                               text:                     issue_url_text,
                               disable_web_page_preview: true)

              next unless message_text.gsub('/task', '').gsub('/link', '').gsub('/url', '').strip.present?

            end

            bot_message_regexp = Regexp.new(
                I18n.t('redmine_chat_telegram.messages').values.map {|m| m.gsub(/%{.+}/, '.+')}.join('|'))

            bot_message = (message_text == issue_url_text) or (message_text =~ bot_message_regexp ).present?

            telegram_message = TelegramMessage.new issue_id:       issue.id,
                                                   telegram_id:    telegram_id,
                                                   sent_at:        sent_at, message: message_text,
                                                   from_id:        from_id, from_first_name: from_first_name,
                                                   from_last_name: from_last_name, from_username: from_username,
                                                   bot_message: bot_message

            if message_text.include?('/log')
              telegram_message.message = message_text.gsub('/log', '')

              journal_text = telegram_message.as_text(with_time: false)
              # TODO: Localize it
              issue.init_journal(User.current, "_Из Telegram:_ \n\n#{journal_text}")
              issue.save
            end

            telegram_message.save!

          end
        end

      rescue Exception => e
        LOG.error "#{e.class}: #{e.message}"
        print e.backtrace.join("\n")
      end
    end
  end
end
