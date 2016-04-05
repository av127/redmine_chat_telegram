module RedmineChatTelegram
  def self.table_name_prefix
    'redmine_chat_telegram_'
  end

  def self.issue_url(issue_id)
    if Setting['protocol'] == 'https'
      URI::HTTPS.build({ host: Setting['host_name'], path: "/issues/#{issue_id}" }).to_s
    else
      URI::HTTP.build({ host: Setting['host_name'], path: "/issues/#{issue_id}" }).to_s
    end
  end
end
