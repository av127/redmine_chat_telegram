class TelegramGroupCloseWorker
  include Sidekiq::Worker
  TELEGRAM_GROUP_CLOSE_LOG = Logger.new(Rails.root.join('log/chat_telegram', 'telegram-group-close.log'))

  def perform(issue_id, user_id = nil)

    user = user_id.present? ? User.find(user_id) : User.anonymous

    TELEGRAM_GROUP_CLOSE_LOG.debug user.inspect

    issue = Issue.find issue_id
    TELEGRAM_GROUP_CLOSE_LOG.debug issue.inspect

    telegram_group = issue.telegram_group

    cli_path        = REDMINE_CHAT_TELEGRAM_CONFIG['telegram_cli_path']
    public_key_path = REDMINE_CHAT_TELEGRAM_CONFIG['telegram_cli_public_key_path']
    cli_base        = "#{cli_path} -WCI -k  #{public_key_path} -e "

    chat_name = "chat##{telegram_group.telegram_id.abs}"

    TELEGRAM_GROUP_CLOSE_LOG.debug chat_name

    # Reset chat link. Old link will not work after it.
    cmd = "#{cli_base} \"export_chat_link #{chat_name}\""
    TELEGRAM_GROUP_CLOSE_LOG.debug %x( #{cmd} )


    unless user.anonymous?

    # send notification to chat
      close_message_text = 'чат закрыт из задачи'
      cmd                = "#{cli_base} \"msg #{chat_name} #{close_message_text}\""
      msg                = %x( #{cmd} )
    end

    issue.init_journal(user, 'Чат Telegram закрыт')
    issue.save

    # remove chat users

    cmd                = "#{cli_base} \"chat_info #{chat_name}\""
    chat_info          = %x( #{cmd} )

    users_array = chat_info.scan(/user#\d+/)
    users       = users_array.group_by { |u| u }.sort_by { |u| u.last.size }.map(&:first) # remove self in last order
    users.each do |telegram_user_id|
      cmd = "#{cli_base} \"chat_del_user #{chat_name} #{telegram_user_id}\""
      TELEGRAM_GROUP_CLOSE_LOG.debug %x( #{cmd} )
    end

    # post message to archive

    message_text = 'Chat closed'
    TelegramMessage.create issue_id:        issue.id,
                           sent_at:         Time.now, message: message_text,
                           from_first_name: user.firstname,
                           from_last_name:  user.lastname

    telegram_group.destroy
  rescue ActiveRecord::RecordNotFound => e
    # ignore
  end
end
