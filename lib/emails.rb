require "pony"
require "tilt"
require "lib/string_helper"

# Methods for sending various emails, like comment notifications and new commit notifications.
class Emails
  # This encapsulates some of the recoverable errors we have sending email, like the inability to connect
  # to the SMTP server.
  class RecoverableEmailError < StandardError
  end

  # Enqueues an email notification of a comment for delivery.
  # - send_immediately: used for testing and debugging.
  def self.send_comment_email(commit, comments, send_immediately = false)
    grit_commit = commit.grit_commit
    subject = "Comments for #{grit_commit.id_abbrev} #{grit_commit.author.user.name} - " +
        "#{grit_commit.short_message[0..60]}"
    html_body = comment_email_body(commit, comments)

    # TODO(philc): Provide a plaintext email as well.
    # TODO(philc): Delay the emails and batch them together.

    all_commenters = commit.comments.map { |comment| comment.user.email }
    to = ([commit.user.email] + all_commenters).uniq

    if send_immediately
      deliver_mail(to.join(","), subject, html_body)
    else
      EmailTask.create(:subject => subject, :to => to.join(","),
          :body => html_body,
          :status => "pending")
    end
  end

  def self.deliver_mail(to, subject, html_body)
    puts "Sending email to #{to} with subject \"#{subject}\""
    Pony.mail(:to => to, :via => :smtp, :subject => subject, :html_body => html_body,
      # These settings are from the Pony documentation and work with Gmail's TLS smtp server.
      :via_options => {
        :address => "smtp.gmail.com",
        :port => "587",
        :enable_starttls_auto => true,
        :user_name => GMAIL_USERNAME,
        :password => GMAIL_PASSWORD,
        :authentication => :plain,
        # the HELO domain provided by the client to the server
        :domain => "localhost.localdomain"
      }
    }
    begin
      Pony.mail(options.merge(pony_options))
    rescue Errno::ECONNRESET, Errno::ECONNABORTED, Errno::ETIMEDOUT => error
      raise RecoverableEmailError.new(error.message)
    end
  end

  def self.comment_email_body(commit, comments)
    general_comments, file_comments = comments.partition(&:general_comment?)

    tagged_diffs = GitHelper.get_tagged_commit_diffs(commit.git_repo.name, commit.grit_commit)

    diffs_by_file = tagged_diffs.group_by { |tagged_diff| tagged_diff[:file_name_after] }
    diffs_by_file.each { |filename, diffs| diffs_by_file[filename] = diffs.first }

    comments_by_file = file_comments.group_by { |comment| comment.commit_file.filename }
    comments_by_file.each { |filename, comments| comments.sort_by!(&:line_number) }

    template = Tilt.new(File.join(File.dirname(__FILE__), "../views/email/comment_email.erb"))
    locals = { :commit => commit, :comments_by_file => comments_by_file,
        :general_comments => general_comments,
        :diffs_by_file => diffs_by_file }
    template.render(self, locals)
  end

  #
  # Helpers for formatting the email views.
  #

  # Removes empty, unchanged lines from the edges of the given line_diffs array.
  # This is useful so that our diffs in emails don't have unnecessary whitespace around them.
  def self.strip_unchanged_blank_lines(line_diffs)
    line_diffs = line_diffs.dup
    until line_diffs.empty? do
      break unless (line_diffs.first.tag == :same && line_diffs.first.data.blank?)
      line_diffs.shift
    end
    until line_diffs.empty? do
      break unless (line_diffs.last.tag == :same && line_diffs.last.data.blank?)
      line_diffs.pop
    end
    line_diffs
  end
end
